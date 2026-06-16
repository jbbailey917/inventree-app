import "package:flutter/material.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/l10.dart";

import "package:inventree/widget/snacks.dart";

/// Page for reconciling physical stock counts with system records.
class BulkScanReconcilePage extends StatefulWidget {
  const BulkScanReconcilePage({
    Key? key,
    required this.partId,
    required this.partName,
  }) : super(key: key);

  final int partId;
  final String partName;

  @override
  BulkScanReconcilePageState createState() => BulkScanReconcilePageState();
}

class BulkScanReconcilePageState extends State<BulkScanReconcilePage> {
  bool _loading = true;
  bool _dataLoaded = false;
  bool _submitting = false;

  List<Map<String, dynamic>> _locations = [];

  int? _selectedLocationPk;
  int? _destLocationPk; // only if reconciling to different location
  bool _reconcileToDifferent = false;

  int? _lostStolenPk;

  int _packageSize = 1;
  int _systemPackages = 0;
  double _systemLoose = 0;
  int _brokenPackageCount = 0;
  double _brokenAllocatedUnits = 0;
  List<Map<String, dynamic>> _packageItems = [];
  List<Map<String, dynamic>> _looseItems = [];

  int _physicalPackages = 0;
  int _physicalLoose = 0;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    final locs = await _fetchAllPages("stock/location/", {});
    _locations = locs;
    _ensureLostStolen();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _ensureLostStolen() async {
    try {
      final res = await InvenTreeAPI().get(
        "stock/location/",
        params: {"search": "Lost/Stolen"},
      );
      if (res.isValid() && res.isMap()) {
        final results = res.resultsList();
        if (results.isNotEmpty) {
          _lostStolenPk = (results.first as Map<String, dynamic>)["pk"] as int?;
          return;
        }
      }
      // Create one
      final createRes = await InvenTreeAPI().post(
        "stock/location/",
        body: {
          "name": "Lost/Stolen",
          "description": "Auto-created for stock reconciliation",
        },
      );
      if (createRes.isValid() && createRes.isMap()) {
        _lostStolenPk = createRes.asMap()["pk"] as int?;
      }
    } catch (_) {}
  }

  Future<void> _fetchReconcileData() async {
    if (_selectedLocationPk == null) return;

    setState(() => _dataLoaded = false);

    try {
      // Fetch supplier parts and stock in parallel
      final results = await Future.wait([
        InvenTreeAPI().get(
          "company/part/",
          params: {"part": "${widget.partId}", "supplier_detail": "true"},
        ),
        _fetchAllStockAtLocation(),
      ]);

      final supplierRes = results[0] as APIResponse;
      final stockItems = results[1] as List<Map<String, dynamic>>;

      // Determine package size
      int packageSize = 1;
      if (supplierRes.isValid() && supplierRes.isMap()) {
        final supplierData = supplierRes.resultsList();
        for (final sp in supplierData) {
          final pq = sp["pack_quantity"] as num?;
          if (pq != null && pq.toInt() > 1) {
            packageSize = pq.toInt();
            break;
          }
        }
      }

      // Categorize stock
      final packageItems = <Map<String, dynamic>>[];
      final looseItems = <Map<String, dynamic>>[];
      int systemPackages = 0;
      double systemLoose = 0;
      int brokenPackageCount = 0;
      double brokenAllocatedUnits = 0;

      for (final item in stockItems) {
        final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
        final allocated = (item["allocated"] as num?)?.toDouble() ?? 0;
        final availableQty = qty - allocated;

        if (packageSize > 1 && availableQty == packageSize && allocated == 0) {
          packageItems.add(item);
          systemPackages++;
        } else {
          looseItems.add(item);
          systemLoose += availableQty;
          if (packageSize > 1 && qty == packageSize && allocated > 0) {
            brokenPackageCount++;
            brokenAllocatedUnits += allocated;
          }
        }
      }

      setState(() {
        _packageSize = packageSize;
        _systemPackages = systemPackages;
        _systemLoose = systemLoose;
        _brokenPackageCount = brokenPackageCount;
        _brokenAllocatedUnits = brokenAllocatedUnits;
        _packageItems = packageItems;
        _looseItems = looseItems;
        _physicalPackages = 0;
        _physicalLoose = 0;
        _dataLoaded = true;
      });
    } catch (e) {
      if (mounted) {
        showSnackIcon("Failed to load: $e", success: false);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchAllStockAtLocation() async {
    final all = <Map<String, dynamic>>[];
    String? nextUrl = "stock/?part=${widget.partId}&location=$_selectedLocationPk&in_stock=true&part_detail=true&location_detail=true";

    while (nextUrl != null) {
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
      if (nextUrl != null && nextUrl.startsWith("http")) {
        final uri = Uri.parse(nextUrl);
        nextUrl = uri.path + (uri.query.isNotEmpty ? "?${uri.query}" : "");
      }
    }

    return all;
  }

  Future<List<Map<String, dynamic>>> _fetchAllPages(
    String endpoint,
    Map<String, String> params,
  ) async {
    final all = <Map<String, dynamic>>[];
    final query = params.entries
        .map((e) => "${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}")
        .join("&");
    String? nextUrl = "$endpoint?$query";

    while (nextUrl != null) {
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
      if (nextUrl != null && nextUrl.startsWith("http")) {
        final uri = Uri.parse(nextUrl);
        nextUrl = uri.path + (uri.query.isNotEmpty ? "?${uri.query}" : "");
      }
    }

    return all;
  }

  int get _pkgDiff => _physicalPackages - _systemPackages;
  int get _looseDiff => _physicalLoose - _systemLoose.toInt();

  bool get _hasVariance => _pkgDiff != 0 || _looseDiff != 0;

  String _locName(int pk) {
    for (final loc in _locations) {
      if (loc["pk"] == pk) {
        return (loc["name"] ?? loc["pathstring"] ?? "").toString();
      }
    }
    return "";
  }

  String get _effectiveDestName {
    if (_reconcileToDifferent && _destLocationPk != null) {
      return _locName(_destLocationPk!);
    } else if (_selectedLocationPk != null) {
      return _locName(_selectedLocationPk!);
    }
    return "";
  }

  Future<void> _submit() async {
    if (_selectedLocationPk == null) return;
    if (!_hasVariance) return;
    if (_lostStolenPk == null) {
      showSnackIcon("Lost/Stolen location not available", success: false);
      return;
    }

    final destPk = (_reconcileToDifferent && _destLocationPk != null)
        ? _destLocationPk!
        : _selectedLocationPk!;

    // Check destination has existing stock if different
    if (_reconcileToDifferent && _destLocationPk != _selectedLocationPk) {
      final res = await InvenTreeAPI().get(
        "stock/",
        params: {
          "part": "${widget.partId}",
          "location": "$_destLocationPk",
          "in_stock": "true",
        },
      );
      if (res.isValid() && res.isMap()) {
        final count = res.asMap()["count"] as int? ?? 0;
        if (count == 0) {
          showSnackIcon(
            "Cannot reconcile to ${_locName(_destLocationPk!)} — no existing stock of ${widget.partName} found there.",
            success: false,
          );
          return;
        }
      }
    }

    setState(() => _submitting = true);

    try {
      final actions = _computeActions(destPk);

      // Phase 1: Create surplus + transfer shortfall to LS (parallel)
      final phase1 = <Future<void>>[];

      for (final create in actions["surplusCreates"] as List<Map<String, dynamic>>) {
        phase1.add(InvenTreeAPI().post("stock/", body: create));
      }

      final lsTransfer = actions["lsTransfer"] as List<Map<String, dynamic>>;
      if (lsTransfer.isNotEmpty) {
        phase1.add(InvenTreeAPI().post(
          "stock/transfer/",
          body: {
            "items": lsTransfer,
            "location": _lostStolenPk,
            "notes": "Reconciliation shortfall",
          },
        ));
      }

      await Future.wait(phase1);

      // Phase 2: Transfer remaining to destination (if different)
      final destTransfer = actions["destTransfer"] as List<Map<String, dynamic>>;
      if (destTransfer.isNotEmpty) {
        await InvenTreeAPI().post(
          "stock/transfer/",
          body: {
            "items": destTransfer,
            "location": destPk,
          },
        );
      }

      if (mounted) {
        final totalCreated =
            (actions["surplusCreates"] as List).length;
        final totalTransferred =
            lsTransfer.length + destTransfer.length;
        final parts = <String>[];
        if (totalCreated > 0) {
          parts.add("$totalCreated item${totalCreated != 1 ? 's' : ''} created");
        }
        if (totalTransferred > 0) {
          parts.add("$totalTransferred transfer${totalTransferred != 1 ? 's' : ''} completed");
        }
        showSnackIcon(
          "Reconciliation complete: ${parts.join(', ')}",
          success: true,
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showSnackIcon("${L10().bulkScanReconcileFailed}: $e", success: false);
      }
    }

    if (mounted) setState(() => _submitting = false);
  }

  Map<String, dynamic> _computeActions(int destPk) {
    final surplusCreates = <Map<String, dynamic>>[];
    final lsTransfer = <Map<String, dynamic>>[];
    final destTransfer = <Map<String, dynamic>>[];

    final destDiff = destPk != _selectedLocationPk;

    // --- Package operations ---
    final pkgShortfall = (_systemPackages - _physicalPackages).clamp(0, 999999);
    final pkgSurplus = (_physicalPackages - _systemPackages).clamp(0, 999999);

    for (int i = 0; i < pkgSurplus; i++) {
      surplusCreates.add({
        "part": widget.partId,
        "quantity": _packageSize,
        "location": destPk,
      });
    }

    var pkgUsed = 0;
    for (final item in _packageItems) {
      if (pkgUsed < pkgShortfall) {
        lsTransfer.add({
          "item": item["pk"],
          "quantity": (item["quantity"] as num?)?.toDouble() ?? _packageSize.toDouble(),
        });
        pkgUsed++;
      } else if (destDiff) {
        destTransfer.add({
          "item": item["pk"],
          "quantity": (item["quantity"] as num?)?.toDouble() ?? _packageSize.toDouble(),
        });
      }
    }

    // --- Loose operations ---
    final looseShortfall =
        (_systemLoose.toInt() - _physicalLoose).clamp(0, 999999);
    final looseSurplus =
        (_physicalLoose - _systemLoose.toInt()).clamp(0, 999999);

    if (looseSurplus > 0) {
      surplusCreates.add({
        "part": widget.partId,
        "quantity": looseSurplus,
        "location": destPk,
      });
    }

    var lsLooseRemaining = looseShortfall;
    for (final item in _looseItems) {
      final qty = (item["quantity"] as num?)?.toDouble() ?? 0;
      final alloc = (item["allocated"] as num?)?.toDouble() ?? 0;
      final available = (qty - alloc).toInt();

      if (lsLooseRemaining > 0) {
        final take = lsLooseRemaining.clamp(0, available);
        if (take > 0) {
          lsTransfer.add({"item": item["pk"], "quantity": take});
          lsLooseRemaining -= take;
          if (destDiff && available > take) {
            destTransfer.add({
              "item": item["pk"],
              "quantity": available - take,
            });
          }
        }
      } else if (destDiff) {
        destTransfer.add({"item": item["pk"], "quantity": available});
      }
    }

    return {
      "surplusCreates": surplusCreates,
      "lsTransfer": lsTransfer,
      "destTransfer": destTransfer,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(L10().bulkScanReconcileStock),
          backgroundColor: COLOR_APP_BAR,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final canSubmit = _dataLoaded && _hasVariance;

    return Scaffold(
      appBar: AppBar(
        title: Text("${L10().bulkScanReconcileStock} — ${widget.partName}"),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          TextButton(
            onPressed: canSubmit && !_submitting ? _submit : null,
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
                    L10().bulkScanReconcileStock,
                    style: TextStyle(
                      color: canSubmit ? Colors.white : Colors.white70,
                    ),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Location selector
            Text(
              "Which location are you reconciling? *",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<int>(
              value: _selectedLocationPk,
              items: [
                const DropdownMenuItem<int>(
                  value: -1,
                  child: Text("Select location..."),
                ),
                ...(_locations.map((loc) => DropdownMenuItem<int>(
                      value: loc["pk"] as int,
                      child: Text(
                        (loc["pathstring"] ?? loc["name"] ?? "").toString(),
                      ),
                    ))),
              ],
              onChanged: (v) {
                setState(() {
                  _selectedLocationPk = v == -1 ? null : v;
                  _dataLoaded = false;
                });
                if (_selectedLocationPk != null) _fetchReconcileData();
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 16),

            if (_selectedLocationPk != null && !_dataLoaded)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              ),

            if (_dataLoaded) ...[
              // Stock counts table
              Text(
                "Stock Counts",
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 8),
              DataTable(
                columns: const [
                  DataColumn(label: Text("")),
                  DataColumn(label: Text("System Count")),
                  DataColumn(label: Text("Physical Count")),
                ],
                rows: [
                  DataRow(cells: [
                    DataCell(Text(
                      _packageSize > 1
                          ? "Packages (×$_packageSize)"
                          : "Packages",
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    )),
                    DataCell(Text(
                      "$_systemPackages${_packageSize > 1 ? ' (${_systemPackages * _packageSize} units)' : ''}",
                    )),
                    DataCell(SizedBox(
                      width: 80,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(isDense: true),
                        controller: TextEditingController(
                          text: _physicalPackages > 0
                              ? "$_physicalPackages"
                              : "",
                        ),
                        onChanged: (v) {
                          setState(() {
                            _physicalPackages = int.tryParse(v) ?? 0;
                          });
                        },
                      ),
                    )),
                  ]),
                  DataRow(cells: [
                    DataCell(const Text(
                      "Loose units",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    )),
                    DataCell(Text("${_systemLoose.toInt()}")),
                    DataCell(SizedBox(
                      width: 80,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(isDense: true),
                        controller: TextEditingController(
                          text: _physicalLoose > 0
                              ? "$_physicalLoose"
                              : "",
                        ),
                        onChanged: (v) {
                          setState(() {
                            _physicalLoose = int.tryParse(v) ?? 0;
                          });
                        },
                      ),
                    )),
                  ]),
                ],
              ),

              // Broken packages note
              if (_brokenPackageCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    "($_brokenPackageCount package${_brokenPackageCount != 1 ? 's' : ''} opened — ${_brokenAllocatedUnits.toInt()} unit${_brokenAllocatedUnits.toInt() != 1 ? 's' : ''} allocated)",
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),

              const SizedBox(height: 16),

              // Reconcile to different location
              CheckboxListTile(
                value: _reconcileToDifferent,
                onChanged: (v) {
                  setState(() => _reconcileToDifferent = v ?? false);
                },
                title: Text(L10().bulkScanReconcileToDifferent),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),

              if (_reconcileToDifferent) ...[
                const SizedBox(height: 8),
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
                    ...(_locations
                        .where((loc) => loc["pk"] != _lostStolenPk)
                        .map((loc) => DropdownMenuItem<int>(
                              value: loc["pk"] as int,
                              child: Text(
                                (loc["pathstring"] ?? loc["name"] ?? "")
                                    .toString(),
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

              const SizedBox(height: 16),

              // Variance display
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9F9F9),
                  border: Border.all(color: const Color(0xFFE0E0E0)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10().bulkScanVariance,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (!_hasVariance)
                      Text(
                        L10().bulkScanNoVariance,
                        style: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    if (_pkgDiff > 0)
                      Text(
                        "+$_pkgDiff package${_pkgDiff != 1 ? 's' : ''} → create ${_pkgDiff} new stock item${_pkgDiff != 1 ? 's' : ''} (${_packageSize} unit${_packageSize != 1 ? 's' : ''} each) in $_effectiveDestName",
                        style: const TextStyle(
                          color: Color(0xFF2E7D32),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    if (_pkgDiff < 0)
                      Text(
                        "${_pkgDiff} package${-_pkgDiff != 1 ? 's' : ''} → move ${-_pkgDiff} package${-_pkgDiff != 1 ? 's' : ''} to Lost/Stolen",
                        style: const TextStyle(
                          color: Color(0xFFC62828),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    if (_looseDiff > 0)
                      Text(
                        "+$_looseDiff loose → create $_looseDiff new loose unit${_looseDiff != 1 ? 's' : ''} in $_effectiveDestName",
                        style: const TextStyle(
                          color: Color(0xFF2E7D32),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    if (_looseDiff < 0)
                      Text(
                        "${_looseDiff} loose → move ${-_looseDiff} unit${-_looseDiff != 1 ? 's' : ''} to Lost/Stolen",
                        style: const TextStyle(
                          color: Color(0xFFC62828),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
