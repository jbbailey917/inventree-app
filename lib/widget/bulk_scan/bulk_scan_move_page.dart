import "package:flutter/material.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/helpers.dart";
import "package:inventree/l10.dart";

import "package:inventree/barcode/bulk_scan_handler.dart";

import "package:inventree/widget/snacks.dart";

/// Page for moving selected stock items from source to destination locations.
class BulkScanMovePage extends StatefulWidget {
  const BulkScanMovePage({Key? key, required this.selectedItems})
    : super(key: key);

  final List<BulkScanItem> selectedItems;

  @override
  BulkScanMovePageState createState() => BulkScanMovePageState();
}

class BulkScanMovePageState extends State<BulkScanMovePage> {
  bool _loading = true;
  bool _submitting = false;

  // Stock items fetched from the server
  List<Map<String, dynamic>> _allStockItems = [];
  // Locations
  List<Map<String, dynamic>> _locations = [];
  // Part package sizes: partPk -> packageQty
  Map<int, int> _packageSizes = {};
  // Stock groups by (part, location)
  List<_StockGroup> _stockGroups = [];
  // Move state: groupKey -> {packages, units}
  final Map<String, _MoveQty> _moveState = {};

  int? _sourceLocationPk;
  int? _destLocationPk;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Set<int> get _partIds {
    final ids = <int>{};
    for (final item in widget.selectedItems) {
      final pk =
          item.type == BulkScanItemType.part
              ? item.partPk
              : item.type == BulkScanItemType.stockitem
              ? item.partPk
              : null;
      if (pk != null) ids.add(pk);
    }
    return ids;
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);

    try {
      // Load all locations
      await _loadLocations();

      // Load stock for each part
      final allItems = <Map<String, dynamic>>[];
      for (final partId in _partIds) {
        final items = await _fetchAllPages(
          "stock/",
          {"part": "$partId", "in_stock": "true", "part_detail": "true",
           "location_detail": "true"},
        );
        allItems.addAll(items);
      }

      _allStockItems = allItems;
      _computePackageSizes();
      _buildStockGroups();
      _initMoveState();
    } catch (e) {
      if (mounted) {
        showSnackIcon("Failed to load stock: $e", success: false);
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadLocations() async {
    final locs = await _fetchAllPages("stock/location/", {});
    _locations = locs;
  }

  Future<List<Map<String, dynamic>>> _fetchAllPages(
    String endpoint,
    Map<String, String> params,
  ) async {
    final all = <Map<String, dynamic>>[];
    String? nextUrl = "$endpoint?${_encodeParams(params)}";

    while (nextUrl != null) {
      // Remove base URL prefix if present
      final url = nextUrl.startsWith("/api/")
          ? nextUrl.substring(4)
          : nextUrl;
      final response = await InvenTreeAPI().get(url);
      if (!response.isValid() || !response.isMap()) break;

      final data = response.asMap();
      final results = data["results"] as List<dynamic>? ?? [];
      for (final r in results) {
        if (r is Map<String, dynamic>) all.add(r);
      }

      nextUrl = data["next"] as String?;
      // Handle full URL vs relative
      if (nextUrl != null && nextUrl.startsWith("http")) {
        final uri = Uri.parse(nextUrl);
        nextUrl = uri.path + (uri.query.isNotEmpty ? "?${uri.query}" : "");
      }
    }

    return all;
  }

  String _encodeParams(Map<String, String> params) {
    return params.entries
        .map((e) => "${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}")
        .join("&");
  }

  void _computePackageSizes() {
    final freq = <int, Map<double, int>>{};
    for (final item in _allStockItems) {
      final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
      if (qty <= 1) continue;
      final part = (item["part"] ?? item["part_detail"]?["pk"]) as int?;
      if (part == null) continue;
      freq.putIfAbsent(part, () => {});
      freq[part]![qty] = (freq[part]![qty] ?? 0) + 1;
    }

    final sizes = <int, int>{};
    for (final entry in freq.entries) {
      double bestQty = 0;
      int bestCount = 0;
      for (final qe in entry.value.entries) {
        if (qe.value > bestCount || (qe.value == bestCount && qe.key > bestQty)) {
          bestCount = qe.value;
          bestQty = qe.key;
        }
      }
      if (bestQty > 0) sizes[entry.key] = bestQty.toInt();
    }
    _packageSizes = sizes;
  }

  void _buildStockGroups() {
    final map = <String, _StockGroup>{};
    for (final item in _allStockItems) {
      final locPk = (item["location"] ?? item["location_detail"]?["pk"]) as int?;
      final part = (item["part"] ?? item["part_detail"]?["pk"]) as int?;
      if (part == null) continue;

      final key = "${part}_$locPk";
      final pkgQty = _packageSizes[part] ?? 0;
      final allocated = (item["allocated"] as num?)?.toDouble() ?? 0;
      final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
      final availableQty = qty - allocated;
      final isPkg = pkgQty > 0 && availableQty == pkgQty && allocated == 0;

      map.putIfAbsent(key, () => _StockGroup(
        partPk: part,
        partDetail: item["part_detail"] as Map<String, dynamic>? ?? {},
        locationPk: locPk,
        locationDetail: item["location_detail"] as Map<String, dynamic>? ?? {},
        packageQty: pkgQty,
      ));

      final g = map[key]!;
      if (isPkg) {
        g.packageCount++;
        g.packageItems.add(item);
      } else {
        g.looseQty += availableQty;
        g.looseItems.add(item);
      }
    }
    _stockGroups = map.values.toList();
  }

  void _initMoveState() {
    _moveState.clear();
    for (final g in _stockGroups) {
      _moveState["${g.partPk}_${g.locationPk}"] = _MoveQty();
    }
  }

  String _partName(int partPk) {
    for (final item in _allStockItems) {
      final d = item["part_detail"] as Map<String, dynamic>?;
      if (d != null && d["pk"] == partPk) {
        return (d["name"] ?? "Part #$partPk").toString();
      }
    }
    return "Part #$partPk";
  }

  int get _totalUnitsToMove {
    int total = 0;
    for (final g in _stockGroups) {
      if (_sourceLocationPk != null && g.locationPk != _sourceLocationPk) continue;
      final key = "${g.partPk}_${g.locationPk}";
      final m = _moveState[key] ?? _MoveQty();
      total += (m.packages * g.packageQty) + m.units;
    }
    return total;
  }

  Future<void> _submit() async {
    if (_destLocationPk == null) {
      showSnackIcon(L10().bulkScanDestLocationRequired, success: false);
      return;
    }
    if (_totalUnitsToMove == 0) {
      showSnackIcon("Enter a quantity to move", success: false);
      return;
    }

    setState(() => _submitting = true);

    final transferItems = <Map<String, dynamic>>[];
    for (final group in _stockGroups) {
      if (_sourceLocationPk != null && group.locationPk != _sourceLocationPk) continue;
      final key = "${group.partPk}_${group.locationPk}";
      final move = _moveState[key] ?? _MoveQty();
      if (move.packages == 0 && move.units == 0) continue;

      // Allocate packages
      var pkgsRem = move.packages;
      for (int i = 0; i < group.packageItems.length && pkgsRem > 0; i++) {
        final item = group.packageItems[i];
        transferItems.add({
          "item": item["pk"],
          "quantity": (item["quantity"] as num?)?.toDouble() ?? 0,
        });
        pkgsRem--;
      }

      // Allocate loose units
      var unitsRem = move.units;
      for (int i = 0; i < group.looseItems.length && unitsRem > 0; i++) {
        final item = group.looseItems[i];
        final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
        final alloc = (item["allocated"] as num?)?.toDouble() ?? 0;
        final take = (qty - alloc).clamp(0, unitsRem.toDouble()).toInt();
        if (take > 0) {
          transferItems.add({"item": item["pk"], "quantity": take});
          unitsRem -= take;
        }
      }

      // Split from remaining packages
      for (int i = 0; i < group.packageItems.length && unitsRem > 0; i++) {
        if (move.packages > 0 && i < move.packages) continue;
        final item = group.packageItems[i];
        final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
        final take = unitsRem.clamp(0, qty.toInt());
        if (take > 0) {
          transferItems.add({"item": item["pk"], "quantity": take});
          unitsRem -= take;
        }
      }
    }

    if (transferItems.isEmpty) {
      showSnackIcon("Enter a quantity to move", success: false);
      setState(() => _submitting = false);
      return;
    }

    try {
      final response = await InvenTreeAPI().post(
        "stock/transfer/",
        body: {
          "items": transferItems,
          "location": _destLocationPk,
        },
      );

      if (response.isValid() && (response.statusCode == 200 || response.statusCode == 201)) {
        showSnackIcon(L10().bulkScanMoveSuccess, success: true);
        if (mounted) Navigator.pop(context);
      } else {
        showSnackIcon(L10().bulkScanMoveFailed, success: false);
      }
    } catch (e) {
      showSnackIcon("${L10().bulkScanMoveFailed}: $e", success: false);
    }

    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(L10().bulkScanMoveStock),
          backgroundColor: COLOR_APP_BAR,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final filtered = _sourceLocationPk != null
        ? _stockGroups.where((g) => g.locationPk == _sourceLocationPk).toList()
        : _stockGroups;

    return Scaffold(
      appBar: AppBar(
        title: Text(L10().bulkScanMoveStock),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _totalUnitsToMove > 0
                        ? "Move ${_totalUnitsToMove} unit(s)"
                        : L10().bulkScanMoveStock,
                    style: const TextStyle(color: Colors.white),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Part summary
            Text(
              "${L10().bulkScanSelectedParts} (${_partIds.length})",
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 4),
            ...(_partIds.map((pk) => Text(
                  "• ${_partName(pk)}",
                  style: const TextStyle(fontSize: 14),
                ))),
            const SizedBox(height: 16),

            // Source location filter
            Text(
              L10().bulkScanSourceLocation,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<int?>(
              value: _sourceLocationPk,
              items: [
                const DropdownMenuItem<int?>(
                  value: null,
                  child: Text("All locations"),
                ),
                ...(_locations.map((loc) => DropdownMenuItem<int?>(
                      value: loc["pk"] as int?,
                      child: Text(
                        (loc["pathstring"] ?? loc["name"] ?? "").toString(),
                      ),
                    ))),
              ],
              onChanged: (v) {
                setState(() => _sourceLocationPk = v);
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 16),

            // Stock table
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text("No stock found")),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text("Part")),
                    DataColumn(label: Text("Location")),
                    DataColumn(label: Text("Avail. Pkgs")),
                    DataColumn(label: Text("Avail. Units")),
                    DataColumn(label: Text("Pkgs to Move")),
                    DataColumn(label: Text("Units to Move")),
                  ],
                  rows: filtered.map((g) {
                    final key = "${g.partPk}_${g.locationPk}";
                    final move = _moveState[key] ?? _MoveQty();
                    final maxPkgs = g.packageCount;
                    final maxUnits = g.looseQty.toInt() +
                        (g.packageCount - move.packages) * g.packageQty;

                    return DataRow(cells: [
                      DataCell(Text(
                        _partName(g.partPk),
                        style: const TextStyle(fontSize: 13),
                      )),
                      DataCell(Text(
                        g.locationName,
                        style: const TextStyle(fontSize: 13),
                      )),
                      DataCell(Text(
                        g.packageCount > 0
                            ? "${g.packageCount} × ${g.packageQty}"
                            : "-",
                        style: const TextStyle(fontSize: 13),
                      )),
                      DataCell(Text(
                        g.looseQty > 0 ? simpleNumberString(g.looseQty) : "-",
                        style: const TextStyle(fontSize: 13),
                      )),
                      DataCell(
                        maxPkgs > 0
                            ? SizedBox(
                                width: 70,
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                  ),
                                  controller: TextEditingController(
                                    text: move.packages > 0
                                        ? "${move.packages}"
                                        : "",
                                  ),
                                  onChanged: (v) {
                                    final val = int.tryParse(v) ?? 0;
                                    setState(() {
                                      _moveState[key] = _MoveQty(
                                        packages: val.clamp(0, maxPkgs),
                                        units: move.units,
                                      );
                                    });
                                  },
                                ),
                              )
                            : const Text("-"),
                      ),
                      DataCell(
                        maxUnits > 0
                            ? SizedBox(
                                width: 70,
                                child: TextField(
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                  ),
                                  controller: TextEditingController(
                                    text: move.units > 0
                                        ? "${move.units}"
                                        : "",
                                  ),
                                  onChanged: (v) {
                                    final val = int.tryParse(v) ?? 0;
                                    setState(() {
                                      _moveState[key] = _MoveQty(
                                        packages: move.packages,
                                        units: val.clamp(0, maxUnits),
                                      );
                                    });
                                  },
                                ),
                              )
                            : const Text("-"),
                      ),
                    ]);
                  }).toList(),
                ),
              ),

            const SizedBox(height: 16),

            // Destination location
            Text(
              "${L10().bulkScanDestLocation} *",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<int>(
              value: _destLocationPk,
              items: [
                const DropdownMenuItem<int>(
                  value: -1,
                  child: Text("Select destination location..."),
                ),
                ...(_locations.map((loc) => DropdownMenuItem<int>(
                      value: loc["pk"] as int,
                      child: Text(
                        (loc["pathstring"] ?? loc["name"] ?? "").toString(),
                      ),
                    ))),
              ],
              onChanged: (v) {
                setState(() => _destLocationPk = v == -1 ? null : v);
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StockGroup {
  _StockGroup({
    required this.partPk,
    required this.partDetail,
    this.locationPk,
    this.locationDetail,
    this.packageQty = 0,
  });

  final int partPk;
  final Map<String, dynamic> partDetail;
  final int? locationPk;
  final Map<String, dynamic>? locationDetail;
  final int packageQty;
  int packageCount = 0;
  double looseQty = 0;
  final List<Map<String, dynamic>> packageItems = [];
  final List<Map<String, dynamic>> looseItems = [];

  String get locationName {
    if (locationDetail != null) {
      return (locationDetail!["name"] ?? "-").toString();
    }
    return "-";
  }
}

class _MoveQty {
  _MoveQty({this.packages = 0, this.units = 0});
  int packages;
  int units;
}
