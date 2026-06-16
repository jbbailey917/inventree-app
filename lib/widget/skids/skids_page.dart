import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";

import "package:inventree/widget/skids/skid_detail_page.dart";
import "package:inventree/widget/snacks.dart";

/// Lists all skids, with option to create new ones.
class SkidsPage extends StatefulWidget {
  const SkidsPage({Key? key}) : super(key: key);

  @override
  SkidsPageState createState() => SkidsPageState();
}

class SkidsPageState extends State<SkidsPage> {
  List<Map<String, dynamic>> _skids = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await InvenTreeAPI().get("/plugin/skids/skids/");
      if (res.isValid()) {
        final raw = res.isMap() ? res.resultsList() : (res.isList() ? res.asList() : null);
        if (raw != null) {
          _skids = raw.map((s) => s as Map<String, dynamic>).toList();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createSkid() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text("New Skid"),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: "SKID-...",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text("Create"),
            ),
          ],
        );
      },
    );

    if (name == null || name.isEmpty) return;

    try {
      final res = await InvenTreeAPI().post(
        "/plugin/skids/skids/create/",
        body: {"name": name},
      );
      if (res.isValid()) {
        showSnackIcon("Created $name", success: true);
        _load();
      }
    } catch (e) {
      showSnackIcon("Error: $e", success: false);
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case "building":
        return "Building";
      case "built":
        return "Built";
      case "unpacked":
        return "Unpacked";
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case "building":
        return const Color(0xFFE65100);
      case "built":
        return const Color(0xFF2E7D32);
      case "unpacked":
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Skids"),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.plus),
            onPressed: _createSkid,
            tooltip: "New Skid",
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skids.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(TablerIcons.packages, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text("No skids yet", style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        icon: const Icon(TablerIcons.plus, size: 18),
                        label: const Text("New Skid"),
                        onPressed: _createSkid,
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _skids.length,
                    itemBuilder: (context, index) {
                      final skid = _skids[index];
                      final status = skid["status"]?.toString() ?? "building";
                      final count = skid["item_count"] ?? 0;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _statusColor(status).withOpacity(0.15),
                          child: Icon(TablerIcons.packages, color: _statusColor(status), size: 20),
                        ),
                        title: Text(skid["name"]?.toString() ?? "?", style: const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text("$count items — ${_statusLabel(status)}"),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: _statusColor(status).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _statusLabel(status),
                            style: TextStyle(fontSize: 11, color: _statusColor(status), fontWeight: FontWeight.w600),
                          ),
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (ctx) => SkidDetailPage(skidId: skid["id"] as int)),
                          );
                          _load();
                        },
                      );
                    },
                  ),
                ),
    );
  }
}
