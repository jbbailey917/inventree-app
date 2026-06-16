import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/l10.dart";

import "package:inventree/widget/snacks.dart";

/// Page for receiving stock against a purchase order or directly into inventory.
class BulkScanReceivePage extends StatefulWidget {
  const BulkScanReceivePage({
    Key? key,
    required this.partId,
    required this.partName,
  }) : super(key: key);

  final int partId;
  final String partName;

  @override
  BulkScanReceivePageState createState() => BulkScanReceivePageState();
}

class BulkScanReceivePageState extends State<BulkScanReceivePage> {
  bool _loading = true;
  bool _submitting = false;

  List<Map<String, dynamic>> _purchaseOrders = [];
  List<Map<String, dynamic>> _matchingLines = [];
  List<Map<String, dynamic>> _locations = [];

  String? _selectedPoPk; // String representation; "__none__" for no PO
  int? _selectedLinePk;
  double _quantity = 0;
  int? _destLocationPk;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);

    try {
      // Fetch outstanding POs, matching lines, and locations in parallel
      final results = await Future.wait([
        _fetchAllPages("order/po/", {"outstanding": "true", "supplier_detail": "true"}),
        _fetchAllPages(
          "order/po-line/",
          {
            "base_part": "${widget.partId}",
            "order_status": "20",
            "part_detail": "true",
            "supplier_part_detail": "true",
          },
        ),
        _fetchAllPages("stock/location/", {}),
      ]);

      final pos = results[0];
      final lines = results[1];
      final locs = results[2];

      // Build set of PO PKs with matching lines
      final matching = <int, bool>{};
      for (final l in lines) {
        matching[l["order"] as int] = true;
      }

      // Sort: matching first, then by reference
      pos.sort((a, b) {
        final aM = matching[a["pk"]] == true ? 0 : 1;
        final bM = matching[b["pk"]] == true ? 0 : 1;
        if (aM != bM) return aM.compareTo(bM);
        return (a["reference"] ?? "").toString().compareTo((b["reference"] ?? "").toString());
      });

      _purchaseOrders = pos;
      _matchingLines = lines;
      _locations = locs;
    } catch (e) {
      if (mounted) {
        showSnackIcon("Failed to load: $e", success: false);
      }
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<List<Map<String, dynamic>>> _fetchAllPages(
    String endpoint,
    Map<String, String> params,
  ) async {
    final all = <Map<String, dynamic>>[];
    String? nextUrl = "$endpoint?${_encodeParams(params)}";

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

  String _encodeParams(Map<String, String> params) {
    return params.entries
        .map((e) => "${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}")
        .join("&");
  }

  bool get _selectedPoIsPlaced {
    if (_selectedPoPk == null || _selectedPoPk == "__none__") return true;
    for (final po in _purchaseOrders) {
      if ("${po["pk"]}" == _selectedPoPk) {
        return (po["status"] as int?) == 20;
      }
    }
    return false;
  }

  List<Map<String, dynamic>> get _linesForSelectedPo {
    if (_selectedPoPk == null || _selectedPoPk == "__none__") return [];
    return _matchingLines.where((l) => "${l["order"]}" == _selectedPoPk).toList();
  }

  double _lineRemaining(Map<String, dynamic> line) {
    final qty = (line["quantity"] as num?)?.toDouble() ?? 0;
    final received = (line["received"] as num?)?.toDouble() ?? 0;
    return (qty - received).clamp(0, double.infinity);
  }

  int _supplierPackQuantity() {
    if (_selectedLinePk == null) return 1;
    for (final line in _matchingLines) {
      if (line["pk"] == _selectedLinePk) {
        final spd = line["supplier_part_detail"] as Map<String, dynamic>?;
        if (spd != null) {
          final raw = spd["pack_quantity_native"] ?? spd["pack_quantity"];
          if (raw != null) {
            final n = (raw as num).toInt();
            if (n > 1) return n;
          }
        }
        break;
      }
    }
    return 1;
  }

  Future<void> _submit() async {
    if (_quantity <= 0) {
      showSnackIcon("Enter a positive quantity to receive", success: false);
      return;
    }

    setState(() => _submitting = true);

    try {
      if (_selectedLinePk != null && _selectedPoPk != null && _selectedPoPk != "__none__") {
        // Receive against a PO line
        final packSize = _supplierPackQuantity();
        final totalQty = _quantity.toInt();
        final recUrl = "order/po/$_selectedPoPk/receive/";

        if (packSize > 1 && totalQty >= packSize) {
          // Split into package-sized chunks
          final fullPackages = totalQty ~/ packSize;
          final remainder = totalQty % packSize;

          for (int p = 0; p < fullPackages; p++) {
            final payload = {
              "items": [
                {
                  "line_item": _selectedLinePk,
                  "quantity": packSize,
                  if (_destLocationPk != null) "location": _destLocationPk,
                },
              ],
            };
            await InvenTreeAPI().post(recUrl, body: payload);
          }
          if (remainder > 0) {
            final payload = {
              "items": [
                {
                  "line_item": _selectedLinePk,
                  "quantity": remainder,
                  if (_destLocationPk != null) "location": _destLocationPk,
                },
              ],
            };
            await InvenTreeAPI().post(recUrl, body: payload);
          }
        } else {
          final payload = {
            "items": [
              {
                "line_item": _selectedLinePk,
                "quantity": totalQty,
                if (_destLocationPk != null) "location": _destLocationPk,
              },
            ],
          };
          final response = await InvenTreeAPI().post(recUrl, body: payload);
          if (!response.isValid()) {
            throw Exception(response.error.isNotEmpty ? response.error : "Request failed");
          }
        }
      } else {
        // Add stock directly
        final payload = <String, dynamic>{
          "part": widget.partId,
          "quantity": _quantity.toInt(),
          if (_destLocationPk != null) "location": _destLocationPk,
        };
        if (_selectedPoPk != null &&
            _selectedPoPk != "__none__") {
          payload["purchase_order"] = int.tryParse(_selectedPoPk!) ?? -1;
          payload["notes"] = "Unexpected receipt — not on original PO line items";
        }
        final response = await InvenTreeAPI().post("stock/", body: payload);
        if (!response.isValid()) {
          throw Exception(response.error.isNotEmpty ? response.error : "Request failed");
        }
      }

      if (mounted) {
        showSnackIcon(L10().bulkScanReceiveSuccess, success: true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        showSnackIcon("${L10().bulkScanReceiveFailed}: $e", success: false);
      }
    }

    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(L10().bulkScanReceiveStock),
          backgroundColor: COLOR_APP_BAR,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final canSubmit = _quantity > 0 && _selectedPoIsPlaced;

    return Scaffold(
      appBar: AppBar(
        title: Text(L10().bulkScanReceiveStock),
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
                    _selectedLinePk != null
                        ? "Receive ${_quantity.toInt()} unit(s)"
                        : "Add ${_quantity.toInt()} unit(s)",
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
            // Part info
            ListTile(
              leading: const Icon(TablerIcons.box),
              title: Text(widget.partName),
              subtitle: Text("Part #${widget.partId}"),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // PO selection
            Text(
              "Purchase Order",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _selectedPoPk,
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text("Select a purchase order..."),
                ),
                ...(_purchaseOrders.map((po) {
                  final hasPart = _matchingLines.any((l) => l["order"] == po["pk"]);
                  final ref = (po["reference"] ?? "?").toString();
                  final supplierDetail =
                      po["supplier_detail"] as Map<String, dynamic>?;
                  final supplierName =
                      (supplierDetail?["name"] ?? po["supplier"] ?? "?").toString();
                  return DropdownMenuItem<String>(
                    value: "${po["pk"]}",
                    child: Text(
                      "${hasPart ? "● " : "  "}$ref — $supplierName",
                      style: const TextStyle(fontSize: 13),
                    ),
                  );
                })),
                const DropdownMenuItem<String>(
                  value: "__none__",
                  child: Text("+ Receive without PO (add directly to stock)"),
                ),
              ],
              onChanged: (v) {
                setState(() {
                  _selectedPoPk = v;
                  _selectedLinePk = null;
                  _quantity = 0;
                });
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 16),

            // Line items table (when PO is selected)
            if (_selectedPoPk != null && _selectedPoPk != "__none__") ...[
              if (!_selectedPoIsPlaced)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    "This order is not yet placed. Only placed orders can receive stock.",
                    style: TextStyle(color: Color(0xFFE65100), fontSize: 13),
                  ),
                ),

              if (_selectedPoIsPlaced) ...[
                if (_linesForSelectedPo.isNotEmpty) ...[
                  const Text(
                    "Line Items",
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text("Line")),
                        DataColumn(label: Text("Expected")),
                        DataColumn(label: Text("Received")),
                        DataColumn(label: Text("Remaining")),
                      ],
                      rows: _linesForSelectedPo.map((line) {
                        final isSelected = _selectedLinePk == line["pk"];
                        final rem = _lineRemaining(line);
                        return DataRow(
                          selected: isSelected,
                          onSelectChanged: (_) {
                            setState(() {
                              _selectedLinePk = line["pk"] as int;
                              _quantity = rem;
                            });
                          },
                          cells: [
                            DataCell(Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? COLOR_ACTION
                                    : const Color(0xFFE0E0E0),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                "#${line["pk"]}",
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black87,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )),
                            DataCell(Text("${line["quantity"] ?? 0}")),
                            DataCell(Text("${line["received"] ?? 0}")),
                            DataCell(Text(
                              rem > 0 ? "${rem.toInt()}" : "0",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: rem > 0 ? null : Colors.grey,
                              ),
                            )),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3F2FD),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      "This part is not listed on this PO. Stock will be added directly to inventory.",
                      style: TextStyle(color: Color(0xFF1565C0), fontSize: 13),
                    ),
                  ),
                ],
              ],
            ],

            // Receive without PO message
            if (_selectedPoPk == "__none__")
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(L10().bulkScanReceiveWithoutPo,
                    style: const TextStyle(color: Color(0xFF1565C0), fontSize: 13)),
              ),

            if (_selectedPoIsPlaced && (_selectedPoPk != null)) ...[
              const SizedBox(height: 16),

              // Quantity input
              if (_selectedLinePk != null) ...[
                Text(
                  "Remaining: ${_lineRemaining(_matchingLines.firstWhere((l) => l["pk"] == _selectedLinePk)).toInt()}",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              TextFormField(
                initialValue: _quantity > 0 ? "${_quantity.toInt()}" : "",
                decoration: InputDecoration(
                  labelText: L10().bulkScanQuantityToReceive,
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  setState(() => _quantity = double.tryParse(v) ?? 0);
                },
              ),
              const SizedBox(height: 16),

              // Destination location
              Text(
                L10().bulkScanDestLocation,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              DropdownButtonFormField<int>(
                value: _destLocationPk,
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
                  setState(() => _destLocationPk = v == -1 ? null : v);
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
