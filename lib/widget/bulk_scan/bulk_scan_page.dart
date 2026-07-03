import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/helpers.dart";
import "package:inventree/l10.dart";

import "package:inventree/barcode/barcode.dart";
import "package:inventree/barcode/bulk_scan_handler.dart";
import "package:inventree/barcode/tones.dart";

import "package:inventree/widget/bulk_scan/bulk_scan_move_page.dart";
import "package:inventree/widget/bulk_scan/bulk_scan_add_stock_page.dart";
import "package:inventree/widget/bulk_scan/bulk_scan_pricing_page.dart";
import "package:inventree/widget/barcode_link_sheet.dart";
import "package:inventree/widget/snacks.dart";

/// Main page for the bulk barcode scanning workflow.
///
/// Displays a scan input bar, a table of scanned items with checkboxes,
/// and action buttons for Move, Receive, Reconcile, and Pricing.
class BulkScanPage extends StatefulWidget {
  const BulkScanPage({Key? key}) : super(key: key);

  @override
  BulkScanPageState createState() => BulkScanPageState();
}

class BulkScanPageState extends State<BulkScanPage> {
  final BulkScanState scanState = BulkScanState();
  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  bool _isAdding = false;

  @override
  void initState() {
    super.initState();
    // Wait for sembast to initialize then refresh
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _addBarcode(String barcode) async {
    if (barcode.trim().isEmpty) return;

    final trimmed = barcode.trim();
    setState(() => _isAdding = true);

    try {
      final response = await InvenTreeAPI().post(
        "barcode/",
        body: {"barcode": trimmed},
        expectedStatusCode: null,
      );

      if (response.isValid() && response.isMap()) {
        final data = response.asMap();

        if (data.containsKey("success")) {
          final item = _extractItemFromResponse(data, trimmed);
          if (item != null) {
            final added = scanState.addItem(item);
            if (added) {
              barcodeSuccessTone();
              showSnackIcon(
                "${L10().bulkScanAdded}: ${item.partName}",
                success: true,
              );
            } else {
              barcodeFailureTone();
              showSnackIcon(
                L10().bulkScanDuplicate,
                success: false,
              );
            }
          } else {
            barcodeFailureTone();
            showSnackIcon(L10().barcodeNoMatch, success: false);
          }
        } else {
          // No match — offer to link this barcode to a part
          await _offerLinkBarcode(trimmed);
        }
      } else {
        // No match — offer to link this barcode to a part
        await _offerLinkBarcode(trimmed);
      }
    } catch (e) {
      await _offerLinkBarcode(trimmed);
    }

    setState(() => _isAdding = false);
    _barcodeController.clear();

    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// Show a bottom sheet to search for a part and link the scanned barcode.
  Future<void> _offerLinkBarcode(String barcode) async {
    if (!mounted) return;

    // Try IPN lookup before offering to link
    try {
      final ipnRes = await InvenTreeAPI().get("part/", params: {
        "IPN": barcode,
        "limit": "2",
      });
      List<dynamic>? results;
      if (ipnRes.isValid()) {
        results = ipnRes.isMap()
            ? ipnRes.resultsList()
            : (ipnRes.isList() ? ipnRes.asList() : null);
      }
      if (results != null && results.isNotEmpty) {
        final part = results.first as Map<String, dynamic>;
        barcodeSuccessTone();
        final item = BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.part,
          pk: part["pk"] as int,
          partPk: part["pk"] as int,
          partName: (part["name"] ?? "").toString(),
          partIpn: (part["IPN"] ?? "").toString(),
          location: "",
          locationPk: null,
          quantity: 1,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        scanState.addItem(item);
        showSnackIcon("${L10().bulkScanAdded}: ${item.partName}", success: true);
        return;
      }
    } catch (_) {}

    barcodeFailureTone();
    final part = await showBarcodeLinkSheet(context, barcode);

    if (part == null || !mounted) return;

    // Link the barcode to the selected part
    try {
      final linkRes = await InvenTreeAPI().post(
        "barcode/link/",
        body: {"barcode": barcode, "part": part["pk"]},
        expectedStatusCode: null,
      );

      if (linkRes.isValid()) {
        barcodeSuccessTone();
        final item = BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.part,
          pk: part["pk"] as int,
          partPk: part["pk"] as int,
          partName: (part["name"] ?? "").toString(),
          partIpn: (part["IPN"] ?? "").toString(),
          location: "",
          locationPk: null,
          quantity: 1,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        scanState.addItem(item);
        showSnackIcon(
          "${L10().bulkScanAdded}: ${item.partName}",
          success: true,
        );
      } else {
        showSnackIcon(
          "Failed to link barcode to part",
          success: false,
        );
      }
    } catch (e) {
      showSnackIcon("Link error: $e", success: false);
    }
  }



  BulkScanItem? _extractItemFromResponse(
    Map<String, dynamic> data,
    String barcode,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // StockItem
    if (data.containsKey("stockitem")) {
      final si = data["stockitem"] as Map<String, dynamic>?;
      if (si != null && (si["pk"] as int? ?? -1) > 0) {
        final instance = si["instance"] as Map<String, dynamic>? ?? {};
        final partDetail =
            instance["part_detail"] as Map<String, dynamic>? ?? {};
        final locDetail =
            instance["location_detail"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.stockitem,
          pk: si["pk"] as int,
          partPk: partDetail["pk"] as int?,
          partName: (partDetail["name"] ?? "Unknown Part").toString(),
          partIpn: (partDetail["IPN"] ?? "").toString(),
          location: (locDetail["name"] ?? "").toString(),
          locationPk: locDetail["pk"] as int?,
          quantity: ((instance["quantity"] ?? 1) as num).toDouble(),
          timestamp: now,
        );
      }
    }

    // Part
    if (data.containsKey("part")) {
      final p = data["part"] as Map<String, dynamic>?;
      if (p != null && (p["pk"] as int? ?? -1) > 0) {
        final instance = p["instance"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.part,
          pk: p["pk"] as int,
          partPk: p["pk"] as int,
          partName: (instance["name"] ?? "Unknown Part").toString(),
          partIpn: (instance["IPN"] ?? "").toString(),
          location: "",
          locationPk: null,
          quantity: 1,
          timestamp: now,
        );
      }
    }

    // Location
    if (data.containsKey("stocklocation")) {
      final loc = data["stocklocation"] as Map<String, dynamic>?;
      if (loc != null && (loc["pk"] as int? ?? -1) > 0) {
        final instance = loc["instance"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.stocklocation,
          pk: loc["pk"] as int,
          partPk: null,
          partName: (instance["name"] ?? "Location").toString(),
          partIpn: "",
          location: (instance["name"] ?? "").toString(),
          locationPk: loc["pk"] as int,
          quantity: 1,
          timestamp: now,
        );
      }
    }

    // PurchaseOrder
    if (data.containsKey("purchaseorder")) {
      final po = data["purchaseorder"] as Map<String, dynamic>?;
      if (po != null && (po["pk"] as int? ?? -1) > 0) {
        final instance = po["instance"] as Map<String, dynamic>? ?? {};
        final ref = (instance["reference"] ?? po["pk"]).toString();
        final supplierName =
            (instance["supplier_name"] ?? "").toString();
        return BulkScanItem(
          id: _generateId(),
          barcode: barcode,
          type: BulkScanItemType.purchaseorder,
          pk: po["pk"] as int,
          partPk: null,
          partName: "PO #$ref — $supplierName",
          partIpn: "",
          location: "",
          locationPk: null,
          quantity: 1,
          timestamp: now,
        );
      }
    }

    return null;
  }

  Future<void> _pickPartFromSearch() async {
    final part = await showBarcodeLinkSheet(context, "");
    if (part == null || !mounted) return;

    final item = BulkScanItem(
      id: _generateId(),
      barcode: (part["IPN"] ?? "").toString(),
      type: BulkScanItemType.part,
      pk: part["pk"] as int,
      partPk: part["pk"] as int,
      partName: (part["name"] ?? "").toString(),
      partIpn: (part["IPN"] ?? "").toString(),
      location: "",
      locationPk: null,
      quantity: 1,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    final added = scanState.addItem(item);
    if (added) {
      barcodeSuccessTone();
      showSnackIcon("Added: ${item.partName}", success: true);
    } else {
      showSnackIcon("Already in list", success: false);
    }
    setState(() {});
  }

  String _generateId() {
    final now = DateTime.now();
    return "${now.millisecondsSinceEpoch}_${now.microsecondsSinceEpoch % 1000000}";
  }

  Future<void> _openCameraScanner() async {
    final handler = BulkScanHandler(scanState);
    if (mounted) {
      await scanBarcode(context, handler: handler);
      // After scanner closes, refresh the UI
      if (mounted) setState(() {});
    }
  }

  void _navigateToMove() {
    final selected = scanState.getSelected();
    if (selected.isEmpty) {
      showSnackIcon(L10().bulkScanSelectItems, success: false);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BulkScanMovePage(selectedItems: selected),
      ),
    );
  }

  void _navigateToAddStock() {
    final selected = scanState.getSelected();
    if (selected.isEmpty) {
      showSnackIcon(L10().bulkScanSelectItems, success: false);
      return;
    }
    final hasPart = selected.any((item) => item.partPk != null);
    if (!hasPart) {
      showSnackIcon(
        "Select a scanned part or stock item to add stock",
        success: false,
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BulkScanAddStockPage(selectedItems: selected),
      ),
    );
  }

  void _navigateToPricing() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BulkScanPricingPage()),
    );
  }

  Color _badgeColor(BulkScanItemType type) {
    switch (type) {
      case BulkScanItemType.stockitem:
        return const Color(0xFF1565C0);
      case BulkScanItemType.part:
        return const Color(0xFF2E7D32);
      case BulkScanItemType.stocklocation:
        return const Color(0xFFE65100);
      case BulkScanItemType.purchaseorder:
        return const Color(0xFF7B1FA2);
    }
  }

  Color _badgeBgColor(BulkScanItemType type) {
    switch (type) {
      case BulkScanItemType.stockitem:
        return const Color(0xFFE3F2FD);
      case BulkScanItemType.part:
        return const Color(0xFFE8F5E9);
      case BulkScanItemType.stocklocation:
        return const Color(0xFFFFF3E0);
      case BulkScanItemType.purchaseorder:
        return const Color(0xFFF3E5F5);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = scanState.hasSelection;
    final selectedCount = scanState.selectedCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(L10().bulkScanTitle),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          // Scan camera button
          IconButton(
            icon: const Icon(TablerIcons.camera),
            tooltip: "Scan with camera",
            onPressed: _openCameraScanner,
          ),
          // Pricing dashboard
          IconButton(
            icon: const Icon(TablerIcons.chart_bar),
            tooltip: L10().bulkScanPricing,
            onPressed: _navigateToPricing,
          ),
        ],
      ),
      body: Column(
        children: [
          // --- Scan Input Bar ---
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _barcodeController,
                    focusNode: _inputFocus,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: "Scan barcode or type to search...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: const Icon(TablerIcons.search, size: 20),
                        tooltip: "Search for a part",
                        onPressed: _pickPartFromSearch,
                      ),
                    ),
                    onSubmitted: (value) => _addBarcode(value),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isAdding
                      ? null
                      : () => _addBarcode(_barcodeController.text),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: COLOR_ACTION,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isAdding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text("Add", style: TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),

          // --- Action Buttons ---
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(TablerIcons.transfer, size: 18),
                  label: Text(L10().bulkScanMoveStock),
                  onPressed: hasSelection ? _navigateToMove : null,
                ),
                ActionChip(
                  avatar: const Icon(TablerIcons.package_import, size: 18),
                  label: const Text("Add Stock"),
                  onPressed: hasSelection ? _navigateToAddStock : null,
                ),
                if (hasSelection)
                  ActionChip(
                    avatar: const Icon(TablerIcons.x, size: 18),
                    label: Text(L10().bulkScanDeselectAll),
                    onPressed: () {
                      setState(() => scanState.deselectAll());
                    },
                  ),
              ],
            ),
          ),

          const Divider(),

          // --- Item Table / Empty State ---
          Expanded(
            child: scanState.items.isEmpty ? _buildEmptyState() : _buildTable(),
          ),

          // --- Footer Bar ---
          if (scanState.items.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    hasSelection
                        ? "$selectedCount of ${scanState.items.length} selected"
                        : "${scanState.items.length} item${scanState.items.length != 1 ? 's' : ''}",
                    style: const TextStyle(fontSize: 13),
                  ),
                  TextButton(
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(L10().bulkScanClearAll),
                          content: Text(L10().bulkScanRemoveConfirm),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(L10().ok),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() => scanState.clearAll());
                                Navigator.pop(ctx);
                              },
                              child: Text(
                                L10().bulkScanClearAll,
                                style: const TextStyle(color: COLOR_DANGER),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Text(
                      "Clear All",
                      style: TextStyle(color: COLOR_DANGER),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(TablerIcons.qrcode, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            L10().bulkScanNoItems,
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(
            L10().bulkScanNoItemsHint,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildTable() {
    return ListView.builder(
      itemCount: scanState.items.length + 1, // +1 for header
      itemBuilder: (context, index) {
        if (index == 0) return _buildTableHeader();
        final itemIndex = index - 1;
        final item = scanState.items[itemIndex];
        final selected = scanState.isSelected(item.id);

        return ListTile(
          selected: selected,
          leading: Checkbox(
            value: selected,
            onChanged: (_) {
              setState(() => scanState.toggleSelect(item.id));
            },
          ),
          title: Text(
            item.partName,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.barcode,
                style: TextStyle(
                  fontFamily: "monospace",
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
              if (item.location.isNotEmpty)
                Text(
                  item.location,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: _badgeBgColor(item.type),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.typeLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _badgeColor(item.type),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (item.type == BulkScanItemType.stockitem)
                Text(
                  item.quantity > 0
                      ? simpleNumberString(item.quantity)
                      : "-",
                  style: const TextStyle(fontSize: 13),
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(TablerIcons.x, size: 18),
                color: COLOR_DANGER,
                onPressed: () {
                  setState(() => scanState.removeItem(itemIndex));
                },
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTableHeader() {
    final allSelected =
        scanState.items.isNotEmpty &&
        scanState.selectedCount == scanState.items.length;

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Checkbox(
            value: allSelected,
            onChanged: (_) {
              setState(() {
                if (allSelected) {
                  scanState.deselectAll();
                } else {
                  scanState.selectAll();
                }
              });
            },
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              "Barcode / Part",
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          const Text(
            "Type",
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(width: 60),
        ],
      ),
    );
  }
}

