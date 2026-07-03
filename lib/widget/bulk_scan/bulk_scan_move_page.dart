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
  static const String _defaultLocationName = "Where-House";

  bool _loading = true;
  bool _submitting = false;
  String _submitProgress = "";

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
  // Part PKs that have zero stock in the default source location
  final Set<int> _partsWithNoStockHere = {};

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

      // Default source location to Where-House
      _resolveDefaultSourceLocation();

      // Load stock for each part
      final allItems = <Map<String, dynamic>>[];
      for (final partId in _partIds) {
        try {
          final items = await _fetchAllPages(
            "stock/",
            {"part": "$partId", "in_stock": "true", "part_detail": "true",
             "location_detail": "true"},
          );
          allItems.addAll(items);
        } catch (e) {
          debug("Failed to fetch stock for part $partId: $e");
        }
      }

      _allStockItems = allItems;
      await _loadSupplierPackSizes();
      _buildStockGroups();
      _initMoveState();
      _findPartsWithNoStockHere();
    } catch (e) {
      if (mounted) {
        showSnackIcon("Failed to load stock: $e", success: false);
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  /// Set [_sourceLocationPk] to the default location if it exists.
  void _resolveDefaultSourceLocation() {
    final defaultLoc = _locations.where((loc) {
      final name = (loc["name"] ?? "").toString();
      return name.toLowerCase().trim() == _defaultLocationName.toLowerCase();
    }).firstOrNull;
    _sourceLocationPk = defaultLoc?["pk"] as int?;
  }

  /// Find parts that have zero stock in the currently selected source location.
  void _findPartsWithNoStockHere() {
    _partsWithNoStockHere.clear();
    if (_sourceLocationPk == null) return;

    final partIdsWithStock = <int>{};
    for (final g in _stockGroups) {
      if (g.locationPk == _sourceLocationPk) {
        partIdsWithStock.add(g.partPk);
      }
    }

    for (final partId in _partIds) {
      if (!partIdsWithStock.contains(partId)) {
        _partsWithNoStockHere.add(partId);
      }
    }
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
    final query = _encodeParams(params);
    String? nextUrl = query.isNotEmpty ? "$endpoint?$query" : endpoint;

    while (nextUrl != null) {
      // Remove base URL prefix if present
      final url = nextUrl.startsWith("/api/")
          ? nextUrl.substring(4)
          : nextUrl;
      final response = await InvenTreeAPI().get(url);
      if (!response.isValid()) break;

      // Handle both paginated dict {count,results,next} and flat list [] formats
      if (response.isMap()) {
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
      } else if (response.isList()) {
        for (final r in response.data as List<dynamic>) {
          if (r is Map<String, dynamic>) all.add(r);
        }
        break; // flat list — no pagination
      } else {
        break;
      }
    }

    return all;
  }

  String _encodeParams(Map<String, String> params) {
    return params.entries
        .map((e) => "${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}")
        .join("&");
  }

  Future<void> _loadSupplierPackSizes() async {
    final sizes = <int, int>{};
    for (final partId in _partIds) {
      try {
        final res = await InvenTreeAPI().get(
          "company/part/",
          params: {"part": "$partId", "ordering": "-pk", "limit": "1"},
        );
        if (res.isValid() && res.isMap()) {
          final results = res.resultsList();
          if (results.isNotEmpty) {
            final sp = results.first as Map<String, dynamic>;
            final pn = (sp["pack_quantity_native"] as num?)?.toDouble() ?? 0;
            if (pn > 0) sizes[partId] = pn.toInt();
          }
        }
      } catch (_) {}
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
      // Default to moving 1 case (package) when packages are available
      final defaultPkgs = g.packageCount > 0 ? 1 : 0;
      _moveState["${g.partPk}_${g.locationPk}"] = _MoveQty(
        packages: defaultPkgs,
      );
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

  /// Maximum number of stock items to transfer per API request.
  /// Keeps each request fast enough to avoid timeouts.
  static const int _transferBatchSize = 5;

  /// Timeout in seconds for each batch transfer request.
  static const int _transferTimeout = 120;

  Future<void> _submit() async {
    if (_destLocationPk == null) {
      showSnackIcon(L10().bulkScanDestLocationRequired, success: false);
      return;
    }
    if (_totalUnitsToMove == 0) {
      showSnackIcon("Enter a quantity to move", success: false);
      return;
    }

    setState(() {
      _submitting = true;
      _submitProgress = "";
    });

    // Build the full transfer items list
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
          "pk": item["pk"],
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
          transferItems.add({"pk": item["pk"], "quantity": take});
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
          transferItems.add({"pk": item["pk"], "quantity": take});
          unitsRem -= take;
        }
      }
    }

    if (transferItems.isEmpty) {
      showSnackIcon("Enter a quantity to move", success: false);
      setState(() => _submitting = false);
      return;
    }

    // Split into batches
    final batches = <List<Map<String, dynamic>>>[];
    for (int i = 0; i < transferItems.length; i += _transferBatchSize) {
      final end = (i + _transferBatchSize).clamp(0, transferItems.length);
      batches.add(transferItems.sublist(i, end));
    }

    final totalBatches = batches.length;
    setState(() {
      _submitProgress = "Moving batch 1 of $totalBatches...";
    });

    int succeededItems = 0;
    int failedItems = 0;

    for (int batchIdx = 0; batchIdx < batches.length; batchIdx++) {
      final batch = batches[batchIdx];
      setState(() {
        _submitProgress = "Moving batch ${batchIdx + 1} of $totalBatches "
            "(${succeededItems + batch.length} of ${transferItems.length} items)...";
      });

      try {
        final response = await InvenTreeAPI().post(
          "stock/transfer/",
          body: {
            "items": batch,
            "location": _destLocationPk,
          },
          timeoutSeconds: _transferTimeout,
        );

        if (response.isValid() && (response.statusCode == 200 || response.statusCode == 201)) {
          succeededItems += batch.length;
        } else {
          failedItems += batch.length;
          // Continue with remaining batches rather than failing entirely
        }
      } catch (e) {
        failedItems += batch.length;
        // Continue with remaining batches
      }
    }

    if (mounted) {
      setState(() => _submitting = false);

      if (failedItems == 0) {
        showSnackIcon(L10().bulkScanMoveSuccess, success: true);
        Navigator.pop(context);
      } else if (succeededItems > 0) {
        showSnackIcon(
          "Moved $succeededItems items, but $failedItems failed. "
          "Check stock locations and retry the remaining items.",
          success: false,
        );
      } else {
        showSnackIcon(L10().bulkScanMoveFailed, success: false);
      }
    }
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
            style: TextButton.styleFrom(
              backgroundColor: const Color(0x33000000),
            ),
            child: _submitting
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      if (_submitProgress.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          _submitProgress,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  )
                : Text(
                    _totalUnitsToMove > 0
                        ? "Move ${_totalUnitsToMove} unit(s)"
                        : L10().bulkScanMoveStock,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
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
            ...(_partIds.map((pk) {
              final noStock = _partsWithNoStockHere.contains(pk);
              return Row(
                children: [
                  Text(
                    "• ${_partName(pk)}",
                    style: TextStyle(
                      fontSize: 14,
                      color: noStock ? Colors.amber.shade800 : null,
                    ),
                  ),
                  if (noStock) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Colors.amber.shade800,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "No stock in $_defaultLocationName",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.amber.shade800,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              );
            })),
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
                setState(() {
                  _sourceLocationPk = v;
                  _findPartsWithNoStockHere();
                });
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            // Warning banner when some parts have no stock here
            if (_sourceLocationPk != null && _partsWithNoStockHere.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border.all(color: Colors.amber.shade200),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18,
                        color: Colors.amber.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "${_partsWithNoStockHere.length} of ${_partIds.length} "
                        "part${_partIds.length != 1 ? 's' : ''} "
                        "${_partsWithNoStockHere.length != 1 ? 'have' : 'has'} "
                        "no stock in $_defaultLocationName.",
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                                  controller: move.casesCtrl,
                                  onChanged: (v) {
                                    final val = int.tryParse(v) ?? 0;
                                    move.packages = val.clamp(0, maxPkgs);
                                    _moveState[key] = move;
                                    if (move.packages > 0) {
                                      if (move.casesCtrl.text != "${move.packages}") {
                                        move.casesCtrl.text = "${move.packages}";
                                        move.casesCtrl.selection = TextSelection.fromPosition(
                                            TextPosition(offset: move.casesCtrl.text.length));
                                      }
                                    }
                                    setState(() {});
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
                                  controller: move.unitsCtrl,
                                  onChanged: (v) {
                                    final val = int.tryParse(v) ?? 0;
                                    move.units = val.clamp(0, maxUnits);
                                    _moveState[key] = move;
                                    if (move.units > 0) {
                                      if (move.unitsCtrl.text != "${move.units}") {
                                        move.unitsCtrl.text = "${move.units}";
                                        move.unitsCtrl.selection = TextSelection.fromPosition(
                                            TextPosition(offset: move.unitsCtrl.text.length));
                                      }
                                    }
                                    setState(() {});
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
  _MoveQty({this.packages = 0, this.units = 0})
      : casesCtrl = TextEditingController(text: packages > 0 ? "$packages" : ""),
        unitsCtrl = TextEditingController(text: units > 0 ? "$units" : "");

  int packages;
  int units;
  final TextEditingController casesCtrl;
  final TextEditingController unitsCtrl;
}
