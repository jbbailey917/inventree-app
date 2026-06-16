import "package:flutter/material.dart";

import "package:inventree/api.dart";

/// Reusable bottom sheet for linking an unrecognized barcode to a part.
///
/// Usage:
/// ```dart
/// final part = await showBarcodeLinkSheet(context, barcode);
/// if (part != null) {
///   // Link the barcode: POST /api/barcode/link/
///   await InvenTreeAPI().post("barcode/link/", body: {
///     "barcode": barcode,
///     "part": part["pk"],
///   });
/// }
/// ```
Future<Map<String, dynamic>?> showBarcodeLinkSheet(
  BuildContext context,
  String barcode,
) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _BarcodeLinkSheet(barcode: barcode),
  );
}

class _BarcodeLinkSheet extends StatefulWidget {
  const _BarcodeLinkSheet({required this.barcode});

  final String barcode;

  @override
  State<_BarcodeLinkSheet> createState() => _BarcodeLinkSheetState();
}

class _BarcodeLinkSheetState extends State<_BarcodeLinkSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    try {
      final res = await InvenTreeAPI().get("part/", params: {
        "search": query.isNotEmpty ? query : "",
        "ordering": "name",
        "limit": "20",
      });
      final parts = <Map<String, dynamic>>[];
      if (res.isValid() && res.isMap()) {
        for (final item in res.resultsList()) {
          if (item is Map<String, dynamic> &&
              item.containsKey("pk") &&
              item.containsKey("name")) {
            parts.add({
              "pk": item["pk"],
              "name": item["name"],
              "IPN": item["IPN"] ?? "",
              "description": item["description"] ?? "",
            });
          }
        }
      }
      if (mounted) setState(() => _results = parts);
    } catch (_) {
      if (mounted) setState(() => _results = []);
    }
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              Text("Link Barcode to Part",
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(widget.barcode,
                  style: TextStyle(
                      fontFamily: "monospace",
                      fontSize: 14,
                      color: Colors.grey.shade600)),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Search for a part...",
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _search('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                onChanged: (value) => _search(value),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _searching
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? Center(
                            child: Text(
                                _searchController.text.isNotEmpty
                                    ? "No parts found"
                                    : "Type to search for a part",
                                style: TextStyle(
                                    color: Colors.grey.shade500)),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: _results.length,
                            itemBuilder: (context, index) {
                              final part = _results[index];
                              return ListTile(
                                leading: const Icon(Icons.widgets, size: 20),
                                title: Text(part["name"]?.toString() ?? "",
                                    style: const TextStyle(fontSize: 14)),
                                subtitle: Text(
                                    (part["IPN"]?.toString() ?? "").isNotEmpty
                                        ? "IPN: ${part["IPN"]}"
                                        : (part["description"]
                                                ?.toString() ??
                                            ""),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500)),
                                onTap: () => Navigator.pop(context, part),
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
