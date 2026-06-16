import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";

import "package:inventree/widget/barcode_link_sheet.dart";
import "package:inventree/widget/snacks.dart";

/// Build a skid by scanning source locations and stock items.
///
/// Flow: scan source location → scan items from that location →
/// switch locations → repeat → Build / Label when done.
class SkidDetailPage extends StatefulWidget {
  const SkidDetailPage({Key? key, required this.skidId}) : super(key: key);
  final int skidId;

  @override
  SkidDetailPageState createState() => SkidDetailPageState();
}

class SkidDetailPageState extends State<SkidDetailPage> {
  final TextEditingController _scanController = TextEditingController();
  final FocusNode _scanFocus = FocusNode();

  Map<String, dynamic>? _skid;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _acting = false;

  // Source locations (ordered list of location PKs)
  final List<int> _sourceOrder = [];
  int? _activeSourcePk;
  String _activeSourceName = "";
  final Map<int, String> _sourceNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanController.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await InvenTreeAPI().get("/plugin/skids/skids/${widget.skidId}/");
      if (res.isValid() && res.isMap()) {
        final data = res.asMap();
        setState(() {
          _skid = data;
          _items = (data["items"] as List<dynamic>?)
                  ?.map((i) => i as Map<String, dynamic>)
                  .toList() ??
              [];
        });
        // Restore source locations from items
        _rebuildSources();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _rebuildSources() {
    _sourceOrder.clear();
    _sourceNames.clear();
    final seen = <int>{};
    for (final item in _items) {
      final detail = item["stock_item_detail"] as Map<String, dynamic>? ?? {};
      final locPk = detail["location_pk"] as int?;
      final locName = detail["location_name"]?.toString() ?? "";
      if (locPk != null && seen.add(locPk)) {
        _sourceOrder.add(locPk);
        _sourceNames[locPk] = locName;
      }
    }
    // Keep active source if still present, otherwise switch to first
    if (_activeSourcePk != null && !_sourceOrder.contains(_activeSourcePk)) {
      _activeSourcePk = _sourceOrder.isNotEmpty ? _sourceOrder.first : null;
      _activeSourceName = _activeSourcePk != null ? _sourceName(_activeSourcePk!) : "";
    }
  }

  String _sourceName(int pk) => _sourceNames[pk] ?? "Location $pk";

  int get _totalItems => _items.length;

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
      final instance = locationData!["instance"] as Map<String, dynamic>? ?? {};
      final name = (instance["name"]?.toString()) ?? (locationData!["name"]?.toString()) ?? "Location $pk";
      if (!_sourceOrder.contains(pk)) {
        setState(() {
          _sourceOrder.add(pk);
          _sourceNames[pk] = name;
        });
      }
      setState(() {
        _activeSourcePk = pk;
        _activeSourceName = name;
      });
      showSnackIcon("Scanning from: $name", success: true);
      _refocusInput();
      return;
    }

    // Need an active source
    if (_activeSourcePk == null) {
      showSnackIcon("Scan a source location first", success: false);
      _refocusInput();
      return;
    }

    // Find stock item via barcode
    Map<String, dynamic>? stockItem;
    try {
      final res = await InvenTreeAPI().post(
        "barcode/",
        body: {"barcode": barcode},
        expectedStatusCode: null,
      );
      if (res.isValid() && res.isMap()) {
        final data = res.asMap();
        if (data.containsKey("stockitem")) {
          stockItem = data["stockitem"] as Map<String, dynamic>;
        } else if (data.containsKey("part")) {
          // Got a part — use the stock picker
          final part = data["part"] as Map<String, dynamic>;
          final picked = await _pickStockItem(part["pk"] as int);
          if (picked != null) {
            await _addItem(picked);
          }
          return; // Handled via dialog — don't fall through
        }
      }
    } catch (_) {}

    if (stockItem != null) {
      await _addItem(stockItem);
      return;
    }

    // Try IPN lookup
    try {
      final ipnRes = await InvenTreeAPI().get("part/", params: {"IPN": barcode, "limit": "2"});
      if (ipnRes.isValid()) {
        final results = ipnRes.isMap() ? ipnRes.resultsList() : (ipnRes.isList() ? ipnRes.asList() : null);
        if (results != null && results.isNotEmpty) {
          final picked = await _pickStockItem(results.first["pk"] as int);
          if (picked != null) {
            await _addItem(picked);
          }
          return; // Handled via dialog
        }
      }
    } catch (_) {}

    // No match — offer to link
    if (mounted) {
      final part = await showBarcodeLinkSheet(context, barcode);
      if (part != null && mounted) {
        try {
          await InvenTreeAPI().post(
            "barcode/link/",
            body: {"barcode": barcode, "part": part["pk"]},
            expectedStatusCode: null,
          );
          final picked = await _pickStockItem(part["pk"] as int);
          if (picked != null) {
            await _addItem(picked);
          }
          return; // Handled via dialog
        } catch (e) {
          showSnackIcon("Link error: $e", success: false);
        }
      }
    }
    _refocusInput();
  }

  /// Finds stock for [partPk] at the active source, preferring full cases
  /// matching the supplier pack quantity.  Shows a dialog if only opened
  /// packages are available, or offers to create a new stock item if none exist.
  Future<Map<String, dynamic>?> _pickStockItem(int partPk) async {
    final already = _items
        .map((i) => ((i["stock_item_detail"] as Map<String, dynamic>?) ?? {})["pk"] as int?)
        .whereType<int>()
        .toSet();

    int packQty = 1;
    // First try supplier part
    try {
      final spRes = await InvenTreeAPI().get("company/part/", params: {
        "part": "$partPk",
        "ordering": "-pk",
        "limit": "1",
      });
      if (spRes.isValid()) {
        final sps = spRes.isMap() ? spRes.resultsList() : (spRes.isList() ? spRes.asList() : null);
        if (sps != null && sps.isNotEmpty) {
          final sp = sps.first as Map<String, dynamic>;
          packQty = (sp["pack_quantity_native"] ?? sp["pack_quantity"] ?? 1) as int;
          if (packQty <= 0) packQty = 1;
        }
      }
    } catch (_) {}
    // Fallback: use largest stock quantity at this location as the pack size
    if (packQty <= 1) {
      try {
        final siRes = await InvenTreeAPI().get("stock/", params: {
          "part": "$partPk",
          "location": "$_activeSourcePk",
          "in_stock": "true",
          "ordering": "-quantity",
          "limit": "50",
        });
        if (siRes.isValid()) {
          final results = siRes.isMap() ? siRes.resultsList() : (siRes.isList() ? siRes.asList() : null);
          if (results != null && results.isNotEmpty) {
            for (final s in results) {
              final q = ((s as Map<String, dynamic>)["quantity"] as num?)?.toDouble() ?? 0;
              if (q > packQty) packQty = q.toInt();
            }
          }
        }
      } catch (_) {}
    }

    // Query stock at active source for this part
    List<Map<String, dynamic>> allStock = [];
    try {
      final siRes = await InvenTreeAPI().get("stock/", params: {
        "part": "$partPk",
        "location": "$_activeSourcePk",
        "in_stock": "true",
        "ordering": "-quantity",
        "limit": "50",
      });
      if (siRes.isValid()) {
        final results = siRes.isMap() ? siRes.resultsList() : (siRes.isList() ? siRes.asList() : null);
        if (results != null) {
          allStock = results.map((s) => s as Map<String, dynamic>).toList();
        }
      }
    } catch (_) {}

    // Filter out already-added
    final available = <Map<String, dynamic>>[];
    for (final s in allStock) {
      final pk = s["pk"] as int?;
      if (pk != null && !already.contains(pk)) {
        available.add(s);
      }
    }

    // Split into full cases and opened
    final fullCases = <Map<String, dynamic>>[];
    final opened = <Map<String, dynamic>>[];
    for (final s in available) {
      final q = (s["quantity"] as num?)?.toDouble() ?? 0;
      if (q >= packQty) {
        fullCases.add(s);
      } else if (q > 0) {
        opened.add(s);
      }
    }

    // No stock at all
    if (available.isEmpty) {
      if (mounted) {
        final create = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("No stock available"),
            content: Text("No stock at $_activeSourceName for this part.\n\nCreate a new stock item with quantity $packQty?"),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Create")),
            ],
          ),
        );
        if (create == true) {
          await _createStockItem(partPk, packQty);
          // Recurse to find the newly created item
          return _pickStockItem(partPk);
        }
      }
      return null;
    }

    // Only opened packages — show selection dialog
    if (fullCases.isEmpty && opened.isNotEmpty) {
      if (!mounted) return null;
      final selected = await showDialog<List<Map<String, dynamic>>>(
        context: context,
        builder: (ctx) => _OpenedStockPicker(
          opened: opened,
          packQty: packQty,
          needed: 1,
        ),
      );
      if (selected != null) {
        if (selected.isEmpty) {
          // User chose "Create new"
          await _createStockItem(partPk, packQty);
          return _pickStockItem(partPk); // Recurse to find the new item
        }
        for (final s in selected) {
          await _addItem(s);
        }
        return selected.first;
      }
      return null;
    }

    // Full cases available — return first (largest qty)
    if (fullCases.isNotEmpty) return fullCases.first;

    return null;
  }

  Future<void> _createStockItem(int partPk, int quantity) async {
    try {
      await InvenTreeAPI().post("stock/", body: {
        "part": partPk,
        "quantity": quantity,
        "location": _activeSourcePk,
      }, expectedStatusCode: null);
      showSnackIcon("Created stock item (qty $quantity)", success: true);
    } catch (e) {
      showSnackIcon("Create failed: $e", success: false);
    }
  }

  Future<void> _addItem(Map<String, dynamic> si) async {
    final pk = si["pk"] as int;
    final name = (si["part_detail"]?["name"] ?? si["part_name"] ?? "Item $pk").toString();

    try {
      final res = await InvenTreeAPI().post(
        "/plugin/skids/skids/${widget.skidId}/add/",
        body: {"stock_item_pks": [pk]},
      );
      if (res.isValid()) {
        final added = (res.asMap()["added"] ?? 0) as int;
        if (added > 0) {
          showSnackIcon("Added $name", success: true);
        } else {
          // Duplicate — find next available stock item of same part at this location
          await _addNextStockItem(si);
          return;
        }
        _load();
      }
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
    _refocusInput();
  }

  Future<void> _addNextStockItem(Map<String, dynamic> si) async {
    final partPk = (si["part"] as int?) ?? (si["part_detail"] as Map<String, dynamic>?)?["pk"];
    if (partPk == null) {
      showSnackIcon("Already in skid — no other stock available", success: true);
      _load();
      return;
    }
    final picked = await _pickStockItem(partPk);
    if (picked != null) {
      await _addItem(picked);
    } else {
      _load();
    }
  }

  Future<void> _removeItem(int skidItemPk) async {
    try {
      await InvenTreeAPI().post(
        "/plugin/skids/skids/${widget.skidId}/remove/",
        body: {"skid_item_pk": skidItemPk},
      );
      _load();
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
  }

  Future<void> _pickLocationAndMove() async {
    final locs = <Map<String, dynamic>>[];
    try {
      final res = await InvenTreeAPI().get("stock/location/");
      if (res.isValid()) {
        final raw = res.isMap() ? res.resultsList() : (res.isList() ? res.asList() : null);
        if (raw != null) locs.addAll(raw.map((l) => l as Map<String, dynamic>));
      }
    } catch (_) {}

    if (!mounted) return;
    final loc = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _LocationPicker(locations: locs),
    );
    if (loc == null || !mounted) return;

    setState(() => _acting = true);
    try {
      final res = await InvenTreeAPI().post(
        "/plugin/skids/skids/${widget.skidId}/move/",
        body: {"location": loc},
      );
      if (res.isValid()) {
        showSnackIcon("Moved ${res.asMap()["moved"]} items", success: true);
        _load();
      }
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
    if (mounted) setState(() => _acting = false);
  }

  Future<void> _build() async {
    setState(() => _acting = true);
    try {
      final res = await InvenTreeAPI().post("/plugin/skids/skids/${widget.skidId}/build/", expectedStatusCode: null);
      if (res.isValid()) {
        showSnackIcon("Skid built", success: true);
        _load();
      }
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
    if (mounted) setState(() => _acting = false);
  }

  Future<void> _unpack() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Unpack skid?"),
        content: const Text("Items stay at their current location."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Unpack", style: TextStyle(color: COLOR_DANGER))),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _acting = true);
    try {
      await InvenTreeAPI().post("/plugin/skids/skids/${widget.skidId}/unpack/", expectedStatusCode: null);
      showSnackIcon("Skid unpacked", success: true);
      _load();
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
    if (mounted) setState(() => _acting = false);
  }

  void _showLabel() {
    final name = _skid?["name"]?.toString() ?? "Skid";
    final pk = _skid?["id"] ?? widget.skidId;
    final qrData = Uri.encodeComponent('{"skid":$pk,"name":"$name"}');
    final qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=$qrData";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.network(qrUrl, width: 200, height: 200),
              const SizedBox(height: 12),
              Text("Skid #$pk  •  $_totalItems items", style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              const Divider(),
              for (final item in _items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text((item["stock_item_detail"] as Map<String, dynamic>?)?.let((d) => d["part_name"]?.toString()) ?? "?", style: const TextStyle(fontSize: 13))),
                      Text((item["stock_item_detail"] as Map<String, dynamic>?)?.let((d) => d["quantity"]?.toString()) ?? "", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close"))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text("Skid"), backgroundColor: COLOR_APP_BAR),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final name = _skid?["name"]?.toString() ?? "Skid";
    final status = _skid?["status"]?.toString() ?? "building";
    final canModify = status == "building";

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        backgroundColor: COLOR_APP_BAR,
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: status == "built" ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
            child: Row(
              children: [
                Text("$_totalItems items  •  $status", style: const TextStyle(fontSize: 12)),
                const Spacer(),
                if (_acting) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),

          // Source locations bar
          if (canModify) ...[
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  ..._sourceOrder.map((pk) {
                    final active = pk == _activeSourcePk;
                    final count = _items.where((i) {
                      final d = (i["stock_item_detail"] as Map<String, dynamic>?) ?? {};
                      return d["location_pk"] == pk;
                    }).length;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: active,
                        label: Text("${_sourceName(pk)} ($count)", style: TextStyle(fontSize: 12, color: active ? Colors.white : null)),
                        selectedColor: COLOR_ACTION,
                        onSelected: (_) => setState(() {
                          _activeSourcePk = pk;
                          _activeSourceName = _sourceName(pk);
                        }),
                      ),
                    );
                  }),
                  if (_sourceOrder.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text("Scan a source location →", style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],

          // Scan input
          if (canModify)
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
                        hintText: _activeSourcePk != null ? "Scan item barcode..." : "Scan source location...",
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        isDense: true,
                        prefixIcon: Icon(_activeSourcePk != null ? TablerIcons.qrcode : TablerIcons.map_pin, size: 20),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text("Scan"),
                  ),
                ],
              ),
            ),

          const Divider(height: 1),

          // Items list
          Expanded(
            child: _items.isEmpty
                ? Center(child: Text("No items yet", style: TextStyle(color: Colors.grey.shade500)))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      final detail = (item["stock_item_detail"] as Map<String, dynamic>?) ?? {};
                      final partName = detail["part_name"]?.toString() ?? "?";
                      final qty = detail["quantity"]?.toString() ?? "?";
                      final locName = detail["location_name"]?.toString() ?? "";
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFE3F2FD),
                          radius: 14,
                          child: Text(qty, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1565C0))),
                        ),
                        title: Text(partName, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(locName, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                        trailing: canModify
                            ? IconButton(
                                icon: const Icon(TablerIcons.x, size: 16),
                                color: COLOR_DANGER,
                                onPressed: () => _removeItem(item["id"] as int),
                                visualDensity: VisualDensity.compact,
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _totalItems > 0
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ActionChip(
                      avatar: const Icon(TablerIcons.transfer, size: 18),
                      label: const Text("Move"),
                      onPressed: _acting ? null : _pickLocationAndMove,
                    ),
                    if (canModify)
                      ActionChip(
                        avatar: const Icon(TablerIcons.check, size: 18),
                        label: const Text("Build"),
                        onPressed: _acting ? null : _build,
                      ),
                    if (status == "built")
                      ActionChip(
                        avatar: const Icon(TablerIcons.package_export, size: 18),
                        label: const Text("Unpack"),
                        onPressed: _acting ? null : _unpack,
                      ),
                    ActionChip(
                      avatar: const Icon(TablerIcons.qrcode, size: 18),
                      label: const Text("Label"),
                      onPressed: _showLabel,
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// Searchable location picker bottom sheet.
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
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Search locations...",
                  prefixIcon: const Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                onChanged: _filter,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(child: Text("No locations found", style: TextStyle(color: Colors.grey.shade500)))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final loc = _filtered[index];
                          return ListTile(
                            leading: Icon(Icons.inventory_2, size: 20, color: Colors.grey.shade600),
                            title: Text(loc["name"]?.toString() ?? "?", style: const TextStyle(fontSize: 14)),
                            subtitle: Text(loc["pathstring"]?.toString() ?? "", style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                            onTap: () => Navigator.pop(context, loc["pk"] as int),
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

/// Dialog showing opened (partial) packages with checkboxes.
class _OpenedStockPicker extends StatefulWidget {
  const _OpenedStockPicker({
    required this.opened,
    required this.packQty,
    required this.needed,
  });
  final List<Map<String, dynamic>> opened;
  final int packQty;
  final int needed;

  @override
  State<_OpenedStockPicker> createState() => _OpenedStockPickerState();
}

class _OpenedStockPickerState extends State<_OpenedStockPicker> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Only opened packages available"),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "No full cases (≥${widget.packQty}) at this location. Select partial packages to add:",
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ...widget.opened.map((s) {
              final pk = s["pk"] as int;
              final name = (s["part_detail"] as Map<String, dynamic>?)?["name"]?.toString() ?? "Item $pk";
              final qty = s["quantity"]?.toString() ?? "?";
              return CheckboxListTile(
                dense: true,
                value: _selected.contains(pk),
                onChanged: (v) {
                  setState(() {
                    if (v == true) _selected.add(pk); else _selected.remove(pk);
                  });
                },
                title: Text(name, style: const TextStyle(fontSize: 13)),
                subtitle: Text("Qty: $qty", style: TextStyle(fontSize: 11, color: Colors.grey)),
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        TextButton(
          onPressed: () => Navigator.pop(context, <Map<String, dynamic>>[]),
          child: const Text("Create new"),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, widget.opened.where((s) => _selected.contains(s["pk"] as int)).toList()),
          child: Text("Add ${_selected.isEmpty ? "" : _selected.length}"),
        ),
      ],
    );
  }
}

extension Let<T> on T {
  R let<R>(R Function(T it) fn) => fn(this);
}
