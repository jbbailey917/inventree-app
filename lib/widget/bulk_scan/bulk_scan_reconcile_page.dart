import "package:flutter/material.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/l10.dart";

import "package:inventree/widget/snacks.dart";

/// Standalone reconciliation page — shows ALL parts at a location with
/// system vs physical counts, letting the operator adjust inline and
/// submit corrections (surplus only — creates missing stock).
class BulkScanReconcilePage extends StatefulWidget {
  const BulkScanReconcilePage({Key? key}) : super(key: key);

  @override
  BulkScanReconcilePageState createState() => BulkScanReconcilePageState();
}

class BulkScanReconcilePageState extends State<BulkScanReconcilePage> {
  bool _loadingData = false;
  bool _submitting = false;

  List<Map<String, dynamic>> _locations = [];
  int? _selectedLocationPk;

  List<_ReconcileRow> _rows = [];
  final Map<int, int> _supplierPartPks = {};
  // partPk → pack_quantity_native (cached alongside supplier part lookup)
  final Map<int, double> _packSizes = {};

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    setState(() => _loadingData = true);
    try {
      final res = await InvenTreeAPI().get(
        "stock/location/",
        params: {"structural": "false", "external": "false"},
      );
      if (res.isValid() && res.isMap()) {
        _locations = (res.resultsList())
            .map((l) => l as Map<String, dynamic>)
            .toList();
      } else if (res.isList()) {
        _locations =
            (res.data as List).map((l) => l as Map<String, dynamic>).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingData = false);
  }

  Future<void> _loadReconcileData() async {
    if (_selectedLocationPk == null) return;
    setState(() => _loadingData = true);
    _rows = [];

    try {
      final rollupRes = await InvenTreeAPI().get(
        "/plugin/inventory-rollup/rollup/",
        params: {"location": "$_selectedLocationPk"},
      );
      if (!rollupRes.isValid() || !rollupRes.isMap()) {
        if (mounted) {
          showSnackIcon("Failed to load rollup data", success: false);
        }
        setState(() => _loadingData = false);
        return;
      }

      final data = rollupRes.asMap();
      final parts = data["parts"] as List<dynamic>? ?? [];

      for (final p in parts) {
        final pMap = p as Map<String, dynamic>;
        final pk = pMap["part_pk"] as int;
        final sysCases = pMap["cases"] as int? ?? 0;
        final sysUnits = (pMap["units"] as num?)?.toDouble() ?? 0;
        _rows.add(_ReconcileRow(
          partPk: pk,
          partName: (pMap["part_name"] ?? "").toString(),
          systemCases: sysCases,
          systemUnits: sysUnits,
          physicalCases: sysCases,
          physicalUnits: sysUnits,
        ));
      }

      await _batchLoadSupplierParts();
    } catch (e) {
      if (mounted) {
        showSnackIcon("Failed to load: $e", success: false);
      }
    }
    if (mounted) setState(() => _loadingData = false);
  }

  Future<void> _batchLoadSupplierParts() async {
    final needed = _rows
        .map((r) => r.partPk)
        .where((pk) => !_packSizes.containsKey(pk))
        .toList();
    if (needed.isEmpty) return;

    const chunkSize = 10;
    for (int chunkStart = 0; chunkStart < needed.length; chunkStart += chunkSize) {
      final chunk = needed.sublist(
          chunkStart,
          (chunkStart + chunkSize).clamp(0, needed.length));
      final futures = chunk.map((pk) => InvenTreeAPI().get(
            "company/part/",
            params: {"part": "$pk", "limit": "1"},
          ));
      final results = await Future.wait(futures);

      for (int i = 0; i < chunk.length; i++) {
        final pk = chunk[i];
        try {
          final res = results[i];
          if (res.isValid() && res.isMap()) {
            final spList = res.resultsList();
            if (spList.isNotEmpty) {
              final sp = spList.first as Map<String, dynamic>;
              final rawPk = sp["pk"];
              if (rawPk is int) _supplierPartPks[pk] = rawPk;
              final pn = (sp["pack_quantity_native"] as num?)?.toDouble() ?? 1.0;
              if (pn > 0) _packSizes[pk] = pn;
            }
          }
        } catch (_) {}
      }
    }
  }

  bool get _hasVariances =>
      _rows.any((r) => r.physicalCases != r.systemCases || r.physicalUnits != r.systemUnits);

  Future<void> _submit() async {
    if (_selectedLocationPk == null) return;
    if (!_hasVariances) {
      showSnackIcon("No changes to submit", success: false);
      return;
    }

    setState(() => _submitting = true);

    try {
      int created = 0;
      int removed = 0;

      for (final row in _rows) {
        final caseDiff = row.physicalCases - row.systemCases;
        final unitDiff = (row.physicalUnits - row.systemUnits).round();
        final spPk = _supplierPartPks[row.partPk];

        // Surplus cases → create stock items
        for (int i = 0; i < caseDiff; i++) {
          final body = <String, dynamic>{
            "part": row.partPk,
            "quantity": 1,
            "use_pack_size": true,
            "location": _selectedLocationPk,
          };
          if (spPk != null) body["supplier_part"] = spPk;
          await InvenTreeAPI().post("stock/", body: body);
          created++;
        }

        // Surplus units → create one stock item
        if (unitDiff > 0) {
          final body = <String, dynamic>{
            "part": row.partPk,
            "quantity": unitDiff,
            "location": _selectedLocationPk,
          };
          if (spPk != null) body["supplier_part"] = spPk;
          await InvenTreeAPI().post("stock/", body: body);
          created++;
        }

        // Shortfall → delete excess stock items (smallest-first)
        if (caseDiff < 0 || unitDiff < 0) {
          final totalToRemove = (-caseDiff) + (-unitDiff).clamp(0, 999999);
          if (totalToRemove <= 0) continue;

          final stockRes = await InvenTreeAPI().get(
            "stock/",
            params: {
              "part": "${row.partPk}",
              "location": "$_selectedLocationPk",
              "in_stock": "true",
              "ordering": "quantity",
            },
          );
          if (!stockRes.isValid()) continue;

          final stockItems = stockRes.isMap()
              ? stockRes.resultsList()
                  .map((s) => s as Map<String, dynamic>)
                  .toList()
              : <Map<String, dynamic>>[];

          int toRemove = totalToRemove;
          for (final si in stockItems) {
            if (toRemove <= 0) break;
            final siPk = si["pk"] as int;
            await InvenTreeAPI().delete("stock/$siPk/");
            toRemove--;
            removed++;
          }
        }
      }

      if (mounted) {
        final parts = <String>[];
        if (created > 0) parts.add("$created created");
        if (removed > 0) parts.add("$removed removed");
        showSnackIcon("Reconciled: ${parts.join(", ")}", success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showSnackIcon("${L10().bulkScanReconcileFailed}: $e", success: false);
      }
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10().bulkScanReconcileStock),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          if (_hasVariances)
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
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text("Submit",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: DropdownButtonFormField<int>(
              value: _selectedLocationPk,
              decoration: const InputDecoration(
                labelText: "Location to reconcile",
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: [
                const DropdownMenuItem<int>(
                  value: null,
                  child: Text("Select a location..."),
                ),
                ...(_locations.map((loc) => DropdownMenuItem<int>(
                      value: loc["pk"] as int,
                      child: Text(
                        (loc["pathstring"] ?? loc["name"] ?? "").toString(),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ))),
              ],
              onChanged: (v) {
                setState(() {
                  _selectedLocationPk = v;
                  _rows = [];
                });
                if (v != null) _loadReconcileData();
              },
            ),
          ),

          const Divider(height: 1),

          Expanded(
            child: _loadingData
                ? const Center(child: CircularProgressIndicator())
                : _selectedLocationPk == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.inventory_2,
                                size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            Text("Select a location to reconcile",
                                style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey.shade600)),
                          ],
                        ),
                      )
                    : _rows.isEmpty
                        ? Center(
                            child: Text("No parts found",
                                style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey.shade500)),
                          )
                        : ListView.builder(
                            itemCount: _rows.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) return _buildHeader();
                              final row = _rows[index - 1];
                              final caseDiff =
                                  row.physicalCases - row.systemCases;
                              final unitDiff =
                                  (row.physicalUnits - row.systemUnits)
                                      .round();
                              final hasChange =
                                  caseDiff != 0 || unitDiff != 0;

                              return Container(
                                color: hasChange
                                    ? const Color(0xFFF9FBE7)
                                    : null,
                                child: ListTile(
                                  dense: true,
                                  title: Text(row.partName,
                                      style: const TextStyle(fontSize: 13)),
                                  subtitle: Text(
                                    "System: ${row.systemCases} cases, ${row.systemUnits.toInt()} units",
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade500),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 60,
                                        child: TextField(
                                          keyboardType:
                                              TextInputType.number,
                                          decoration: InputDecoration(
                                            isDense: true,
                                            labelText: "Cases",
                                            labelStyle: TextStyle(
                                                fontSize: 9,
                                                color:
                                                    Colors.grey.shade500),
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2),
                                          ),
                                          style: const TextStyle(
                                              fontSize: 13),
                                          controller:
                                              TextEditingController(
                                            text: row.physicalCases > 0
                                                ? "${row.physicalCases}"
                                                : "",
                                          ),
                                          onChanged: (v) {
                                            setState(() {
                                              row.physicalCases =
                                                  int.tryParse(v) ?? 0;
                                            });
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 60,
                                        child: TextField(
                                          keyboardType:
                                              TextInputType.number,
                                          decoration: InputDecoration(
                                            isDense: true,
                                            labelText: "Units",
                                            labelStyle: TextStyle(
                                                fontSize: 9,
                                                color:
                                                    Colors.grey.shade500),
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                    vertical: 2),
                                          ),
                                          style: const TextStyle(
                                              fontSize: 13),
                                          controller:
                                              TextEditingController(
                                            text: row.physicalUnits > 0
                                                ? "${row.physicalUnits.toInt()}"
                                                : "",
                                          ),
                                          onChanged: (v) {
                                            setState(() {
                                              row.physicalUnits =
                                                  double.tryParse(v) ??
                                                      0;
                                            });
                                          },
                                        ),
                                      ),
                                      if (hasChange)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                              left: 4),
                                          child: Text(
                                            caseDiff > 0
                                                ? "+$caseDiff cases"
                                                : caseDiff < 0
                                                    ? "$caseDiff cases"
                                                    : unitDiff > 0
                                                        ? "+$unitDiff units"
                                                        : "$unitDiff units",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: caseDiff > 0 ||
                                                      unitDiff > 0
                                                  ? const Color(0xFF2E7D32)
                                                  : const Color(0xFFC62828),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
          ),

          if (_rows.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "${_rows.length} parts — ${_hasVariances ? "${_rows.where((r) => r.physicalCases != r.systemCases || r.physicalUnits != r.systemUnits).length} with changes" : "No changes"}",
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey.shade100,
      child: const Row(
        children: [
          Expanded(
              child: Text("Part / System Counts",
                  style:
                      TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
          SizedBox(
              width: 200,
              child: Text("Physical Counts",
                  style:
                      TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
        ],
      ),
    );
  }
}

class _ReconcileRow {
  _ReconcileRow({
    required this.partPk,
    required this.partName,
    this.systemCases = 0,
    this.systemUnits = 0,
    this.physicalCases = 0,
    this.physicalUnits = 0,
  });

  final int partPk;
  final String partName;
  final int systemCases;
  final double systemUnits;
  int physicalCases;
  double physicalUnits;
}
