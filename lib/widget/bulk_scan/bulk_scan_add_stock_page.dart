import "package:flutter/material.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";

import "package:inventree/barcode/bulk_scan_handler.dart";

import "package:inventree/widget/snacks.dart";

/// Page for adding stock (cases and/or loose units) for selected parts.
///
/// Shows a table similar to Move Stock: Part | Cases to Add | Units to Add.
/// Case sizes are derived from SupplierPart.pack_quantity_native.
class BulkScanAddStockPage extends StatefulWidget {
  const BulkScanAddStockPage({Key? key, required this.selectedItems})
    : super(key: key);

  final List<BulkScanItem> selectedItems;

  @override
  BulkScanAddStockPageState createState() => BulkScanAddStockPageState();
}

class BulkScanAddStockPageState extends State<BulkScanAddStockPage> {
  bool _loading = true;
  bool _submitting = false;

  List<Map<String, dynamic>> _locations = [];
  int? _destLocationPk;

  // partPk → packSize
  final Map<int, int> _packageSizes = {};
  // partPk → supplierPartPk
  final Map<int, int> _supplierPartPks = {};
  // partPk → {partName, partIpn}
  final Map<int, _PartInfo> _partInfos = {};
  // "partPk" → _AddQty
  final Map<int, _AddQty> _addState = {};

  Set<int> get _partIds {
    final ids = <int>{};
    for (final item in widget.selectedItems) {
      if (item.partPk != null) ids.add(item.partPk!);
    }
    return ids;
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);

    try {
      // Load locations
      final locs = await _fetchAllPages("stock/location/", {});
      _locations = locs;

      // Collect part info from selected items
      for (final item in widget.selectedItems) {
        if (item.partPk != null && !_partInfos.containsKey(item.partPk!)) {
          _partInfos[item.partPk!] = _PartInfo(
            name: item.partName,
            ipn: item.partIpn,
          );
        }
      }

      // Load supplier part pack sizes
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
              final spPk = sp["pk"] as int?;
              final pn =
                  (sp["pack_quantity_native"] as num?)?.toDouble() ?? 0;
              if (pn > 0) {
                _packageSizes[partId] = pn.toInt();
                if (spPk != null) _supplierPartPks[partId] = spPk;
              }
            }
          }
        } catch (_) {}
      }

      // Init add state
      for (final partId in _partIds) {
        _addState[partId] = _AddQty();
      }
    } catch (e) {
      if (mounted) showSnackIcon("Failed to load: $e", success: false);
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<List<Map<String, dynamic>>> _fetchAllPages(
    String endpoint,
    Map<String, String> params,
  ) async {
    final all = <Map<String, dynamic>>[];
    final query = params.entries
        .map((e) =>
            "${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}")
        .join("&");
    String? nextUrl = query.isNotEmpty ? "$endpoint?$query" : endpoint;

    while (nextUrl != null) {
      final url =
          nextUrl.startsWith("/api/") ? nextUrl.substring(4) : nextUrl;
      final response = await InvenTreeAPI().get(url);
      if (!response.isValid()) break;

      if (response.isMap()) {
        final data = response.asMap();
        final results = data["results"] as List<dynamic>? ?? [];
        for (final r in results) {
          if (r is Map<String, dynamic>) all.add(r);
        }
        nextUrl = data["next"] as String?;
        if (nextUrl != null && nextUrl.startsWith("http")) {
          final uri = Uri.parse(nextUrl);
          nextUrl = uri.path + (uri.query.isNotEmpty ? "?${uri.query}" : "");
        }
      } else if (response.isList()) {
        for (final r in response.data as List<dynamic>) {
          if (r is Map<String, dynamic>) all.add(r);
        }
        break;
      } else {
        break;
      }
    }
    return all;
  }

  int get _totalCasesToAdd {
    int total = 0;
    for (final e in _addState.values) {
      total += e.cases;
    }
    return total;
  }

  int get _totalUnitsToAdd {
    int total = 0;
    for (final e in _addState.values) {
      total += e.units;
    }
    return total;
  }

  Future<void> _submit() async {
    if (_destLocationPk == null) {
      showSnackIcon("Select a destination location", success: false);
      return;
    }
    if (_totalCasesToAdd == 0 && _totalUnitsToAdd == 0) {
      showSnackIcon("Enter quantities to add", success: false);
      return;
    }

    setState(() => _submitting = true);

    int created = 0;
    int failed = 0;

    for (final partId in _partIds) {
      final add = _addState[partId] ?? _AddQty();
      final spPk = _supplierPartPks[partId];

      // Create case stock items — each case = one full pack
      for (int i = 0; i < add.cases; i++) {
        try {
          final body = <String, dynamic>{
            "part": partId,
            "quantity": 1,
            "use_pack_size": true,
            "location": _destLocationPk,
          };
          if (spPk != null) body["supplier_part"] = spPk;
          final res = await InvenTreeAPI().post("stock/", body: body);
          if (res.isValid()) {
            created++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }

      // Create loose unit stock items — raw quantity, no pack size
      if (add.units > 0) {
        try {
          final body = <String, dynamic>{
            "part": partId,
            "quantity": add.units,
            "location": _destLocationPk,
          };
          if (spPk != null) body["supplier_part"] = spPk;
          final res = await InvenTreeAPI().post("stock/", body: body);
          if (res.isValid()) {
            created++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }
    }

    if (mounted) {
      showSnackIcon(
        "Added $created item${created != 1 ? 's' : ''}"
        "${failed > 0 ? ' ($failed failed)' : ''}",
        success: failed == 0,
      );
      if (failed == 0) Navigator.pop(context);
    }

    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text("Add Stock"),
          backgroundColor: COLOR_APP_BAR,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final parts = _partIds.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Add Stock"),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          TextButton(
            onPressed: _submitting ? null : _submit,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0x33000000),
            ),
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
                    _totalCasesToAdd > 0 || _totalUnitsToAdd > 0
                        ? "Add ${_totalCasesToAdd + _totalUnitsToAdd} total"
                        : "Add Stock",
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
              "Selected Parts (${parts.length})",
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 4),
            ...(parts.map((pk) => Text(
                  "• ${_partInfos[pk]?.name ?? 'Part #$pk'}",
                  style: const TextStyle(fontSize: 14),
                ))),
            const SizedBox(height: 16),

            // Destination location (required)
            Text(
              "Destination Location *",
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
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 16),

            // Stock table
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text("Part")),
                  DataColumn(label: Text("Pack Size")),
                  DataColumn(label: Text("Cases to Add")),
                  DataColumn(label: Text("Units to Add")),
                ],
                rows: parts.map((partId) {
                  final info = _partInfos[partId]!;
                  final packSize = _packageSizes[partId] ?? 1;
                  final add = _addState[partId] ?? _AddQty();
                  return DataRow(cells: [
                    DataCell(Text(info.name,
                        style: const TextStyle(fontSize: 13))),
                    DataCell(Text(packSize > 1 ? "$packSize" : "—",
                        style: const TextStyle(fontSize: 13))),
                    DataCell(
                      SizedBox(
                        width: 80,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                          ),
                          controller: add.casesCtrl,
                          onChanged: (v) {
                            final val = int.tryParse(v) ?? 0;
                            add.cases = val.clamp(0, 999999);
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                    DataCell(
                      SizedBox(
                        width: 80,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                          ),
                          controller: add.unitsCtrl,
                          onChanged: (v) {
                            final val = int.tryParse(v) ?? 0;
                            add.units = val.clamp(0, 999999);
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                  ]);
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartInfo {
  _PartInfo({required this.name, this.ipn = ""});
  final String name;
  final String ipn;
}

class _AddQty {
  _AddQty({this.cases = 0, this.units = 0})
      : casesCtrl = TextEditingController(text: cases > 0 ? "$cases" : ""),
        unitsCtrl = TextEditingController(text: units > 0 ? "$units" : "");

  int cases;
  int units;
  final TextEditingController casesCtrl;
  final TextEditingController unitsCtrl;
}
