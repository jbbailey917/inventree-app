import "dart:convert";

import "package:flutter/material.dart";
import "package:sembast/sembast_io.dart";
import "package:path_provider/path_provider.dart";
import "package:path/path.dart";

import "package:inventree/helpers.dart";

import "package:inventree/barcode/handler.dart";
import "package:inventree/barcode/tones.dart";

import "package:inventree/inventree/part.dart";
import "package:inventree/inventree/stock.dart";
import "package:inventree/inventree/purchase_order.dart";

/// Enum representing the type of a scanned barcode item.
enum BulkScanItemType {
  stockitem,
  part,
  stocklocation,
  purchaseorder,
}

/// Human-readable label for each item type.
String bulkScanItemTypeLabel(BulkScanItemType type) {
  switch (type) {
    case BulkScanItemType.stockitem:
      return "Stock Item";
    case BulkScanItemType.part:
      return "Part";
    case BulkScanItemType.stocklocation:
      return "Location";
    case BulkScanItemType.purchaseorder:
      return "Purchase Order";
  }
}

/// Data class representing a single scanned item in the bulk scan list.
class BulkScanItem {
  BulkScanItem({
    required this.id,
    required this.barcode,
    required this.type,
    this.pk = -1,
    this.partPk,
    this.partName = "",
    this.partIpn = "",
    this.location = "",
    this.locationPk,
    this.quantity = 1,
    this.timestamp,
  });

  final String id;
  final String barcode;
  final BulkScanItemType type;
  final int pk;
  final int? partPk;
  final String partName;
  final String partIpn;
  final String location;
  final int? locationPk;
  final double quantity;
  final int? timestamp;

  String get typeLabel => bulkScanItemTypeLabel(type);

  /// Serialize to JSON for persistence.
  Map<String, dynamic> toJson() => {
        "id": id,
        "barcode": barcode,
        "type": type.name,
        "pk": pk,
        "part_pk": partPk,
        "part_name": partName,
        "part_ipn": partIpn,
        "location": location,
        "location_pk": locationPk,
        "quantity": quantity,
        "timestamp": timestamp ?? DateTime.now().millisecondsSinceEpoch,
      };

  /// Deserialize from JSON.
  factory BulkScanItem.fromJson(Map<String, dynamic> json) {
    return BulkScanItem(
      id: json["id"] as String? ?? "",
      barcode: json["barcode"] as String? ?? "",
      type: BulkScanItemType.values.firstWhere(
        (e) => e.name == json["type"],
        orElse: () => BulkScanItemType.stockitem,
      ),
      pk: json["pk"] as int? ?? -1,
      partPk: json["part_pk"] as int?,
      partName: json["part_name"] as String? ?? "",
      partIpn: json["part_ipn"] as String? ?? "",
      location: json["location"] as String? ?? "",
      locationPk: json["location_pk"] as int?,
      quantity: (json["quantity"] as num?)?.toDouble() ?? 1,
      timestamp: json["timestamp"] as int?,
    );
  }
}

/// Manages the bulk scan item list with sembast persistence.
class BulkScanState {
  BulkScanState() {
    _init();
  }

  static const String _storeName = "bulk_scan";
  static const String _keyName = "items";

  List<BulkScanItem> items = [];
  Set<String> selectedIds = {};

  Database? _db;
  final StoreRef<String, String> _store = StoreRef(_storeName);

  Future<void> _init() async {
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final dbPath = join(appDocDir.path, "InvenTreeBulkScan.db");
      _db = await databaseFactoryIo.openDatabase(dbPath);
      await _loadFromDb();
    } catch (e) {
      debug("BulkScanState._init failed: $e");
    }
  }

  bool get isReady => _db != null;

  /// Persist items to sembast.
  Future<void> saveToDb() async {
    if (_db == null) return;
    try {
      final jsonList = items.map((item) => item.toJson()).toList();
      await _store.record(_keyName).put(_db!, jsonEncode(jsonList));
    } catch (e) {
      debug("BulkScanState.saveToDb failed: $e");
    }
  }

  /// Load items from sembast.
  Future<void> _loadFromDb() async {
    if (_db == null) return;
    try {
      final stored = await _store.record(_keyName).get(_db!);
      if (stored != null) {
        final List<dynamic> jsonList = jsonDecode(stored) as List<dynamic>;
        items = jsonList
            .map((e) => BulkScanItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debug("BulkScanState._loadFromDb failed: $e");
    }
  }

  /// Add an item to the list, checking for duplicates.
  /// Returns true if the item was added, false if it's a duplicate.
  bool addItem(BulkScanItem item) {
    // Check for duplicates by barcode + type
    final dup = items.any(
      (i) => i.barcode == item.barcode && i.type == item.type,
    );
    if (dup) return false;

    items.add(item);
    saveToDb();
    return true;
  }

  /// Remove an item by index.
  void removeItem(int index) {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    selectedIds.remove(item.id);
    items.removeAt(index);
    saveToDb();
  }

  /// Remove an item by ID.
  void removeItemById(String id) {
    selectedIds.remove(id);
    items.removeWhere((i) => i.id == id);
    saveToDb();
  }

  /// Clear all items.
  void clearAll() {
    items.clear();
    selectedIds.clear();
    saveToDb();
  }

  /// Toggle selection for a specific item.
  void toggleSelect(String id) {
    if (selectedIds.contains(id)) {
      selectedIds.remove(id);
    } else {
      selectedIds.add(id);
    }
  }

  /// Select all items.
  void selectAll() {
    selectedIds = items.map((i) => i.id).toSet();
  }

  /// Deselect all items.
  void deselectAll() {
    selectedIds.clear();
  }

  /// Get the list of selected BulkScanItems.
  List<BulkScanItem> getSelected() {
    return items.where((i) => selectedIds.contains(i.id)).toList();
  }

  /// Check if an item is selected.
  bool isSelected(String id) => selectedIds.contains(id);

  /// Number of selected items.
  int get selectedCount => selectedIds.length;

  /// Whether any items are selected.
  bool get hasSelection => selectedIds.isNotEmpty;
}

/// BarcodeHandler subclass for the bulk scanning workflow.
///
/// Unlike BarcodeScanHandler which navigates to detail pages,
/// this handler adds scanned items to a BulkScanState list and
/// keeps the scanner open for continuous scanning.
class BulkScanHandler extends BarcodeHandler {
  BulkScanHandler(this.scanState);

  final BulkScanState scanState;

  @override
  String getOverlayText(BuildContext context) {
    // This will be replaced by the page-level scanning UI,
    // but provide a fallback overlay.
    return "Bulk Scan";
  }

  @override
  Future<void> onBarcodeMatched(Map<String, dynamic> data) async {
    final item = _extractBulkScanItem(data);

    if (item != null) {
      final added = scanState.addItem(item);
      if (added) {
        barcodeSuccessTone();
      } else {
        // Duplicate
        barcodeFailureTone();
      }
    } else {
      barcodeFailureTone();
    }
  }

  @override
  Future<void> onBarcodeUnknown(Map<String, dynamic> data) async {
    barcodeFailureTone();
  }

  /// Extract a BulkScanItem from the barcode API response.
  /// Reuses the same resolution logic as BarcodeScanHandler.
  BulkScanItem? _extractBulkScanItem(Map<String, dynamic> data) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // StockItem match
    if (data.containsKey(InvenTreeStockItem.MODEL_TYPE)) {
      final si = data[InvenTreeStockItem.MODEL_TYPE] as Map<String, dynamic>?;
      if (si != null && (si["pk"] as int? ?? -1) > 0) {
        final instance = si["instance"] as Map<String, dynamic>? ?? {};
        final partDetail =
            instance["part_detail"] as Map<String, dynamic>? ?? {};
        final locDetail =
            instance["location_detail"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: (data["barcode_data"] ?? data["barcode"] ?? "").toString(),
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

    // Part match
    if (data.containsKey(InvenTreePart.MODEL_TYPE)) {
      final p = data[InvenTreePart.MODEL_TYPE] as Map<String, dynamic>?;
      if (p != null && (p["pk"] as int? ?? -1) > 0) {
        final instance = p["instance"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: (data["barcode_data"] ?? data["barcode"] ?? "").toString(),
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

    // Location match
    if (data.containsKey(InvenTreeStockLocation.MODEL_TYPE)) {
      final loc =
          data[InvenTreeStockLocation.MODEL_TYPE] as Map<String, dynamic>?;
      if (loc != null && (loc["pk"] as int? ?? -1) > 0) {
        final instance = loc["instance"] as Map<String, dynamic>? ?? {};
        return BulkScanItem(
          id: _generateId(),
          barcode: (data["barcode_data"] ?? data["barcode"] ?? "").toString(),
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

    // PurchaseOrder match
    if (data.containsKey(InvenTreePurchaseOrder.MODEL_TYPE)) {
      final po =
          data[InvenTreePurchaseOrder.MODEL_TYPE] as Map<String, dynamic>?;
      if (po != null && (po["pk"] as int? ?? -1) > 0) {
        final instance = po["instance"] as Map<String, dynamic>? ?? {};
        final ref = (instance["reference"] ?? po["pk"]).toString();
        final supplierName =
            (instance["supplier_name"] ?? "").toString();
        return BulkScanItem(
          id: _generateId(),
          barcode: (data["barcode_data"] ?? data["barcode"] ?? "").toString(),
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

  String _generateId() {
    return "${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecondsSinceEpoch % 1000000}";
  }
}
