import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/l10.dart";

import "package:inventree/widget/barcode_link_sheet.dart";
import "package:inventree/widget/snacks.dart";

/// Scan-driven bulk receiving page.
///
/// Flow:
///  1. Pick a PO
///  2. Scan a destination (stock location) to set it active
///  3. Scan item barcodes → items accumulate under the active destination
///  4. Scan another destination → switches contexts, previous data preserved
///  5. Tap [Finish] → submits everything as a single bulk transaction
class BulkReceivePage extends StatefulWidget {
  const BulkReceivePage({Key? key}) : super(key: key);

  @override
  BulkReceivePageState createState() => BulkReceivePageState();
}

class BulkReceivePageState extends State<BulkReceivePage> {
  final TextEditingController _scanController = TextEditingController();
  final FocusNode _scanFocus = FocusNode();

  bool _loading = true;
  bool _submitting = false;

  // Data
  List<Map<String, dynamic>> _purchaseOrders = [];
  List<Map<String, dynamic>> _locations = [];

  // Selection
  String? _selectedPoPk;

  // Scanned destinations (ordered list of location PKs)
  final List<int> _destOrder = [];
  int? _activeDestPk;

  // Accumulated data: dest pk → line pk → {line, quantity}
  final Map<int, Map<int, _AccumulatedItem>> _accum = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);

    try {
      final results = await Future.wait([
        _fetchAll("order/po/", {"outstanding": "true", "supplier_detail": "true"}),
        _fetchLocations(),
      ]);

      final pos = results[0];
      pos.sort((a, b) =>
          (a["reference"] ?? "").toString().compareTo((b["reference"] ?? "").toString()));

      _purchaseOrders = pos;
      _locations = results[1];
    } catch (e) {
      if (mounted) showSnackIcon("Failed to load: $e", success: false);
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<List<Map<String, dynamic>>> _fetchAll(
    String endpoint,
    Map<String, String> params,
  ) async {
    final all = <Map<String, dynamic>>[];
    final query = _encodeParams(params);
    String? nextUrl = query.isNotEmpty ? "$endpoint?$query" : endpoint;

    while (nextUrl != null) {
      final url = nextUrl.startsWith("/api/") ? nextUrl.substring(4) : nextUrl;
      final response = await InvenTreeAPI().get(url);
      if (!response.isValid()) break;

      if (response.isMap()) {
        final data = response.asMap();
        if (data.containsKey("results")) {
          // Paginated response
          final results = data["results"] as List<dynamic>? ?? [];
          for (final r in results) {
            if (r is Map<String, dynamic>) all.add(r);
          }
          nextUrl = data["next"] as String?;
        } else if (data.containsKey("pk")) {
          // Single object
          all.add(data);
          nextUrl = null;
        } else {
          nextUrl = null;
        }
      } else if (response.isList()) {
        // Raw list response
        final list = response.asList();
        if (list != null) {
          for (final r in list) {
            if (r is Map<String, dynamic>) all.add(r);
          }
        }
        nextUrl = null;
      } else {
        break;
      }
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

  Future<List<Map<String, dynamic>>> _fetchLocations() async {
    // Always pass params to get paginated dict format across all InvenTree versions
    return _fetchAll("stock/location/", {
      "structural": "false",
      "external": "false",
      "limit": "500",
    });
  }

  bool get _selectedPoIsPlaced {
    if (_selectedPoPk == null) return false;
    for (final po in _purchaseOrders) {
      if ("${po["pk"]}" == _selectedPoPk) {
        return (po["status"] as int?) == 20;
      }
    }
    return false;
  }

  Map<String, dynamic>? get _selectedPo {
    if (_selectedPoPk == null) return null;
    for (final po in _purchaseOrders) {
      if ("${po["pk"]}" == _selectedPoPk) return po;
    }
    return null;
  }

  String _locationPath(int pk) {
    for (final loc in _locations) {
      if (loc["pk"] == pk) {
        return (loc["pathstring"] ?? loc["name"] ?? "Location $pk").toString();
      }
    }
    return "Location $pk";
  }

  int _totalItemsForDest(int destPk) {
    final items = _accum[destPk];
    if (items == null) return 0;
    int total = 0;
    for (final item in items.values) {
      total += item.totalItems;
    }
    return total;
  }

  int get _totalAllItems {
    int total = 0;
    for (final pk in _destOrder) {
      total += _totalItemsForDest(pk);
    }
    return total;
  }

  int get _totalPackages {
    int total = 0;
    for (final pk in _destOrder) {
      final items = _accum[pk];
      if (items != null) {
        for (final item in items.values) {
          total += item.quantity;
        }
      }
    }
    return total;
  }

  void _refocusInput() {
    _scanController.clear();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _scanFocus.requestFocus();
    });
  }

  Future<void> _handleScan(String raw) async {
    final barcode = raw.trim();
    if (barcode.isEmpty) return;

    _scanController.clear();

    // Check if this is a location barcode
    Map<String, dynamic>? locationData;
    try {
      final locRes = await InvenTreeAPI().post(
        "barcode/",
        body: {"barcode": barcode},
        expectedStatusCode: null,
      );
      if (locRes.isValid() && locRes.isMap()) {
        final data = locRes.asMap();
        if (data.containsKey("stocklocation")) {
          locationData = data["stocklocation"] as Map<String, dynamic>;
        }
      }
    } catch (_) {}

    if (locationData != null) {
      final pk = locationData!["pk"] as int;
      if (_destOrder.contains(pk)) {
        setState(() => _activeDestPk = pk);
        showSnackIcon("Switched to ${_locationPath(pk)}", success: true);
      } else {
        setState(() {
          _destOrder.add(pk);
          _activeDestPk = pk;
          _accum[pk] ??= {};
        });
        showSnackIcon("New destination: ${_locationPath(pk)}", success: true);
      }
      _refocusInput();
      return;
    }

    // Need an active destination for item scans
    if (_activeDestPk == null) {
      showSnackIcon("Scan a destination location first", success: false);
      _refocusInput();
      return;
    }

    // Try barcode lookup
    Map<String, dynamic>? part;
    try {
      final itemRes = await InvenTreeAPI().post(
        "barcode/",
        body: {"barcode": barcode},
        expectedStatusCode: null,
      );
      if (itemRes.isValid() && itemRes.isMap()) {
        final data = itemRes.asMap();
        if (data.containsKey("part")) {
          part = data["part"] as Map<String, dynamic>;
        } else if (data.containsKey("stockitem")) {
          final si = data["stockitem"] as Map<String, dynamic>;
          final instance = si["instance"] as Map<String, dynamic>? ?? {};
          part = instance["part_detail"] as Map<String, dynamic>?;
        }
      }
    } catch (_) {}

    if (part != null) {
      await _addToDest(part);
      _refocusInput();
      return;
    }

    // No barcode match — try IPN lookup
    try {
      final ipnRes = await InvenTreeAPI().get("part/", params: {
        "IPN": barcode,
        "limit": "2",
      });
      if (ipnRes.isValid()) {
        final results = ipnRes.isMap()
            ? ipnRes.resultsList()
            : (ipnRes.isList() ? ipnRes.asList() : null);
        if (results != null && results.isNotEmpty) {
          part = results.first as Map<String, dynamic>;
        }
      }
    } catch (_) {}

    if (part != null) {
      await _addToDest(part);
      _refocusInput();
      return;
    }

    // No match — offer to link
    if (mounted) {
      await _offerLinkBarcode(barcode);
    }
    _refocusInput();
  }

  Future<void> _offerLinkBarcode(String barcode) async {
    if (!mounted) return;

    final part = await showBarcodeLinkSheet(context, barcode);

    if (part == null || !mounted) return;

    try {
      final linkRes = await InvenTreeAPI().post(
        "barcode/link/",
        body: {"barcode": barcode, "part": part["pk"]},
        expectedStatusCode: null,
      );

      if (linkRes.isValid()) {
        showSnackIcon("Linked to ${part["name"]}", success: true);
        await _addToDest(part);
      } else {
        showSnackIcon("Failed to link barcode", success: false);
      }
    } catch (e) {
      showSnackIcon("Link error: $e", success: false);
    }
  }

  Future<void> _addToDest(Map<String, dynamic> part) async {
    final partPk = part["pk"] as int;
    // Barcode API nests name inside 'instance', search/link/IPN paths put it at top level
    final instance = part["instance"] as Map<String, dynamic>?;
    final partName = (instance?["name"] ?? part["name"] ?? "Unknown").toString();

    // Find the PO line item for this part
    Map<String, dynamic>? lineItem;
    double packSize = 1;

    if (_selectedPoPk != null) {
      // Fetch line items for this PO and part
      try {
        final lineRes = await InvenTreeAPI().get(
          "order/po-line/",
          params: {
            "order": _selectedPoPk!,
            "base_part": "$partPk",
            "part_detail": "true",
            "supplier_part_detail": "true",
          },
        );
        if (lineRes.isValid() && (lineRes.isMap() || lineRes.isList())) {
          final lines = lineRes.resultsList();
          if (lines.isNotEmpty) {
            lineItem = lines.first as Map<String, dynamic>;
            final spd = lineItem?["supplier_part_detail"] as Map<String, dynamic>?;
            if (spd != null) {
              packSize = ((spd["pack_quantity_native"] ?? spd["pack_quantity"] ?? 1) as num)
                  .toDouble();
              if (packSize <= 0) packSize = 1;
            }
          }
        }
      } catch (_) {}
    }

    final destPk = _activeDestPk!;
    setState(() {
      _accum[destPk] ??= {};
      final destItems = _accum[destPk]!;
      final lineKey = lineItem != null ? lineItem["pk"] as int : partPk;

      if (destItems.containsKey(lineKey)) {
        destItems[lineKey]!.quantity += 1;
      } else {
        destItems[lineKey] = _AccumulatedItem(
          lineItem: lineItem,
          partPk: partPk,
          partName: partName,
          linePk: lineKey,
          quantity: 1,
          packSize: packSize.toInt(),
        );
      }
    });

    showSnackIcon("+$packSize $partName → ${_locationPath(destPk)}", success: true);
  }

  Future<void> _submit() async {
    if (_selectedPoPk == null || !_selectedPoIsPlaced) {
      showSnackIcon("Select a placed purchase order", success: false);
      return;
    }
    if (_activeDestPk == null) {
      showSnackIcon("Select a destination location first", success: false);
      return;
    }
    if (_accum.isEmpty) {
      showSnackIcon("No items scanned", success: false);
      return;
    }

    setState(() => _submitting = true);

    try {
      final recUrl = "order/po/$_selectedPoPk/receive/";
      int poLineCount = 0;
      int extraCount = 0;

      // Build PO line items — one entry per pack for individual stock items
      final items = <Map<String, dynamic>>[];
      for (final destPk in _destOrder) {
        final destItems = _accum[destPk];
        if (destItems == null) continue;
        for (final entry in destItems.values) {
          if (entry.lineItem != null) {
            for (int i = 0; i < entry.quantity; i++) {
              items.add({
                "line_item": entry.linePk,
                "quantity": 1,
                "location": destPk,
              });
            }
            poLineCount += entry.quantity;
          }
        }
      }

      // Submit PO line items
      if (items.isNotEmpty) {
        final response = await InvenTreeAPI().post(
          recUrl,
          body: {"items": items},
        );
        if (!response.isValid()) {
          showSnackIcon("PO receive failed: ${response.error}", success: false);
          setState(() => _submitting = false);
          return;
        }
      }

      // Submit extras (not on PO line items)
      for (final destPk in _destOrder) {
        final destItems = _accum[destPk];
        if (destItems == null) continue;
        for (final entry in destItems.values) {
          if (entry.lineItem == null) {
            for (int i = 0; i < entry.quantity; i++) {
              await InvenTreeAPI().post("stock/", body: {
                "part": entry.partPk,
                "quantity": 1,
                "location": destPk,
                "purchase_order": int.parse(_selectedPoPk!),
                "notes": "Extra — not on original PO line items",
              });
            }
            extraCount += entry.quantity;
          }
        }
      }

      showSnackIcon(
        "Received ${_totalPackages} packages (${_totalAllItems} items) across ${_destOrder.length} destinations",
        success: true,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }

    if (mounted) setState(() => _submitting = false);
  }

  Future<void> _pickPartManually() async {
    final part = await showBarcodeLinkSheet(context, "");
    if (part != null && mounted) {
      await _addToDest(part);
      _refocusInput();
    }
  }

  Future<void> _pickDestManually() async {
    final loc = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _LocationPicker(locations: _locations),
    );
    if (loc != null && mounted) {
      if (_destOrder.contains(loc)) {
        setState(() => _activeDestPk = loc);
        showSnackIcon("Switched to ${_locationPath(loc)}", success: true);
      } else {
        setState(() {
          _destOrder.add(loc);
          _activeDestPk = loc;
          _accum[loc] ??= {};
        });
        showSnackIcon("New destination: ${_locationPath(loc)}", success: true);
      }
      _refocusInput();
    }
  }

  void _removeItem(int destPk, int lineKey) {
    setState(() {
      _accum[destPk]?.remove(lineKey);
      if (_accum[destPk]?.isEmpty == true) {
        _accum.remove(destPk);
        _destOrder.remove(destPk);
        if (_activeDestPk == destPk) {
          _activeDestPk = _destOrder.isNotEmpty ? _destOrder.first : null;
        }
      }
    });
  }

  void _editQuantity(int destPk, _AccumulatedItem item) {
    final controller = TextEditingController(text: "${item.quantity}");
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.partName),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: "Quantity",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              final qty = int.tryParse(controller.text);
              if (qty != null && qty > 0) {
                setState(() => item.quantity = qty);
              }
              Navigator.pop(ctx);
            },
            child: const Text("Update"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text("Bulk Receive"), backgroundColor: COLOR_APP_BAR),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      canPop: _destOrder.isEmpty || _submitting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Bulk Receive"),
          backgroundColor: COLOR_APP_BAR,
        actions: [
          if (_totalAllItems > 0)
            TextButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      "Finish (${_totalPackages} packages)",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
            ),
        ],
      ),
      body: Column(
        children: [
          // PO selector
          Padding(
            padding: const EdgeInsets.all(12),
            child: DropdownButtonFormField<String>(
              value: _selectedPoPk,
              decoration: const InputDecoration(
                labelText: "Purchase Order",
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text("Select a purchase order..."),
                ),
                ...(_purchaseOrders.map((po) {
                  final ref = (po["reference"] ?? "?").toString();
                  final supDetail = po["supplier_detail"] as Map<String, dynamic>?;
                  final sup = supDetail?["name"]?.toString() ?? (po["supplier"] ?? "?").toString();
                  return DropdownMenuItem<String>(
                    value: "${po["pk"]}",
                    child: Text("$ref — $sup", style: const TextStyle(fontSize: 13)),
                  );
                })),
              ],
              onChanged: (v) {
                setState(() {
                  _selectedPoPk = v;
                  _destOrder.clear();
                  _accum.clear();
                  _activeDestPk = null;
                });
              },
            ),
          ),

          // Destinations bar
          if (_selectedPoPk != null && _selectedPoIsPlaced) ...[
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  ..._destOrder.map((pk) {
                    final active = pk == _activeDestPk;
                    final count = _totalItemsForDest(pk);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: active,
                        label: Text(
                          "${_locationPath(pk)} ($count)",
                          style: TextStyle(
                            fontSize: 12,
                            color: active ? Colors.white : null,
                          ),
                        ),
                        selectedColor: COLOR_ACTION,
                        onSelected: (_) => setState(() => _activeDestPk = pk),
                      ),
                    );
                  }),
                  // Hint when no destinations
                  if (_destOrder.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        "Scan a destination to begin →",
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(),

            // Scan input
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _scanController,
                      focusNode: _scanFocus,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: _activeDestPk != null
                            ? "Scan item barcode..."
                            : "Scan destination location...",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        isDense: true,
                        prefixIcon: Icon(
                          _activeDestPk != null
                              ? TablerIcons.qrcode
                              : TablerIcons.map_pin,
                          size: 20,
                        ),
                      ),
                      onSubmitted: _handleScan,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _handleScan(_scanController.text),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: COLOR_ACTION,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text("Scan"),
                  ),
                ],
              ),
            ),

            // Manual selectors
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(TablerIcons.box, size: 16),
                      label: const Text("Pick Part", style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _activeDestPk == null ? null : _pickPartManually,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(TablerIcons.map_pin, size: 16),
                      label: const Text("Pick Destination", style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _pickDestManually,
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Accumulated items grouped by destination
            Expanded(
              child: _destOrder.isEmpty
                  ? Center(
                      child: Text(
                        "No items yet",
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _destOrder.length,
                      itemBuilder: (context, index) {
                        final destPk = _destOrder[index];
                        final items = _accum[destPk];
                        if (items == null || items.isEmpty) return const SizedBox.shrink();

                        final active = destPk == _activeDestPk;
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          color: active ? const Color(0xFFE3F2FD) : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Destination header
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                                child: Row(
                                  children: [
                                    Icon(Icons.inventory_2, size: 16, color: Colors.grey.shade600),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        _locationPath(destPk),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: active ? COLOR_ACTION : null,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      "${_totalItemsForDest(destPk)} items",
                                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                              // Items in this destination
                              ...items.values.map((item) => ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      backgroundColor: item.lineItem != null
                                          ? const Color(0xFFE8F5E9)
                                          : const Color(0xFFFFF3E0),
                                      radius: 14,
                                      child: Text(
                                        "${item.quantity}",
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: item.lineItem != null
                                              ? const Color(0xFF2E7D32)
                                              : const Color(0xFFE65100),
                                        ),
                                      ),
                                    ),
                                    title: Text(item.partName, style: const TextStyle(fontSize: 13)),
                                    subtitle: Text(
                                      [
                                        if (item.lineItem != null) "${_selectedPo?["reference"] ?? "PO"} line #${item.linePk}" else "Extra (not on PO)",
                                        if (item.packSize > 1) "${item.quantity} package${item.quantity != 1 ? 's' : ''} × ${item.packSize} pcs",
                                      ].join(" — "),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: item.lineItem != null
                                            ? Colors.grey.shade500
                                            : const Color(0xFFE65100),
                                        fontStyle: item.lineItem != null
                                            ? FontStyle.normal
                                            : FontStyle.italic,
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(TablerIcons.pencil, size: 16),
                                          onPressed: () => _editQuantity(destPk, item),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        IconButton(
                                          icon: const Icon(TablerIcons.x, size: 16),
                                          color: COLOR_DANGER,
                                          onPressed: () => _removeItem(destPk, item.linePk),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ],
                                    ),
                                  )),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ] else if (_selectedPoPk != null && !_selectedPoIsPlaced)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  "This PO is not yet placed. Only placed orders can receive stock.",
                  style: TextStyle(color: Color(0xFFE65100), fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    )
  );
  }

  void _confirmDiscard() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Discard items?"),
        content: Text(
          "You have ${_totalAllItems} items across ${_destOrder.length} destinations. Leave without finishing?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Stay"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text("Discard", style: TextStyle(color: COLOR_DANGER)),
          ),
        ],
      ),
    );
  }
}


/// A single accumulated item in a destination.
class _AccumulatedItem {
  _AccumulatedItem({
    this.lineItem,
    required this.partPk,
    required this.partName,
    required this.linePk,
    required this.quantity,
    this.packSize = 1,
  });

  final Map<String, dynamic>? lineItem;
  final int partPk;
  final String partName;
  final int linePk;
  int quantity;
  int packSize;

  int get totalItems => quantity * packSize;
}

/// Simple searchable location picker bottom sheet.
class _LocationPicker extends StatefulWidget {
  const _LocationPicker({required this.locations});

  final List<Map<String, dynamic>> locations;

  @override
  State<_LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<_LocationPicker> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = List.from(widget.locations);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filter(String query) {
    setState(() {
      if (query.isEmpty) {
        _filtered = List.from(widget.locations);
      } else {
        final q = query.toLowerCase();
        _filtered = widget.locations.where((l) {
          final name = (l["name"] ?? "").toString().toLowerCase();
          final path = (l["pathstring"] ?? "").toString().toLowerCase();
          return name.contains(q) || path.contains(q);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Search locations...",
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                onChanged: _filter,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(
                        child: Text("No locations found",
                            style: TextStyle(color: Colors.grey.shade500)),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final loc = _filtered[index];
                          final name = loc["name"]?.toString() ?? "?";
                          final path =
                              loc["pathstring"]?.toString() ?? name;
                          return ListTile(
                            leading: Icon(Icons.inventory_2,
                                size: 20, color: Colors.grey.shade600),
                            title: Text(name,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(path,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500)),
                            onTap: () => Navigator.pop(
                                context, loc["pk"] as int),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
