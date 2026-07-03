import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";

/// Inventory + sales rollup for a single location.
class RollupPage extends StatefulWidget {
  const RollupPage({Key? key}) : super(key: key);

  @override
  RollupPageState createState() => RollupPageState();
}

class RollupPageState extends State<RollupPage> {
  List<Map<String, dynamic>> _locations = [];
  int? _selectedLocationPk;
  String _selectedLocationName = "";

  List<Map<String, dynamic>> _parts = [];
  bool _loadingLocations = true;
  bool _loadingRollup = false;
  DateTimeRange? _dateRange;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    setState(() => _loadingLocations = true);
    try {
      final res = await InvenTreeAPI().get(
        "stock/location/",
        params: {"structural": "false", "external": "false", "limit": "500"},
      );
      if (res.isValid()) {
        final raw = res.isMap()
            ? res.resultsList()
            : (res.isList() ? res.asList() : null);
        if (raw != null) {
          final locs = raw.map((l) => l as Map<String, dynamic>).toList();
          locs.sort((a, b) =>
              (a["name"] ?? "").toString().compareTo((b["name"] ?? "").toString()));
          setState(() => _locations = locs);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingLocations = false);
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _dateRange,
    );
    if (range != null) {
      setState(() => _dateRange = range);
      if (_selectedLocationPk != null) _loadRollup();
    }
  }

  Future<void> _loadRollup() async {
    if (_selectedLocationPk == null) return;
    setState(() => _loadingRollup = true);
    try {
      final params = <String, String>{
        "location": "$_selectedLocationPk",
      };
      if (_dateRange != null) {
        params["start"] =
            "${_dateRange!.start.year}-${_dateRange!.start.month.toString().padLeft(2, '0')}-${_dateRange!.start.day.toString().padLeft(2, '0')}";
        params["end"] =
            "${_dateRange!.end.year}-${_dateRange!.end.month.toString().padLeft(2, '0')}-${_dateRange!.end.day.toString().padLeft(2, '0')}";
      }

      final res = await InvenTreeAPI().get(
        "/plugin/inventory-rollup/rollup/",
        params: params,
      );
      if (res.isValid() && res.isMap()) {
        final data = res.asMap();
        setState(() {
          _parts = (data["parts"] as List<dynamic>?)
                  ?.map((p) => p as Map<String, dynamic>)
                  .toList() ??
              [];
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingRollup = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Inventory Rollup"),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          IconButton(
            icon: Icon(
              _dateRange != null ? TablerIcons.calendar_check : TablerIcons.calendar,
              size: 20,
            ),
            tooltip: _dateRange != null ? "Filtered by date" : "Filter by date",
            onPressed: _pickDateRange,
          ),
        ],
      ),
      body: Column(
        children: [
          // Location selector
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(TablerIcons.map_pin, size: 18, color: COLOR_ACTION),
                const SizedBox(width: 8),
                Expanded(
                  child: _loadingLocations
                      ? const Text("Loading locations...",
                          style: TextStyle(color: Colors.grey))
                      : DropdownButton<int?>(
                          value: _selectedLocationPk,
                          isExpanded: true,
                          hint: const Text("Select a location"),
                          underline: const SizedBox(),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text("-- Select a location --",
                                  style: TextStyle(color: Colors.grey)),
                            ),
                            ..._locations.map((loc) {
                              final pk = loc["pk"] as int;
                              final name = loc["name"]?.toString() ?? "?";
                              return DropdownMenuItem<int?>(
                                value: pk,
                                child: Text(name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                        fontSize: 14)),
                              );
                            }),
                          ],
                          onChanged: (pk) {
                            if (pk != null) {
                              final loc = _locations.firstWhere(
                                  (l) => l["pk"] == pk);
                              setState(() {
                                _selectedLocationPk = pk;
                                _selectedLocationName =
                                    loc["name"]?.toString() ?? "";
                              });
                              _loadRollup();
                            }
                          },
                        ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Summary
          if (_parts.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  _SummaryChip(label: "Parts", value: "${_parts.length}"),
                  const SizedBox(width: 8),
                  _SummaryChip(
                      label: "Location", value: _selectedLocationName),
                  if (_dateRange != null) ...[
                    const SizedBox(width: 8),
                    _SummaryChip(
                        label: "Range",
                        value:
                            "${_dateRange!.start.month}/${_dateRange!.start.day} — ${_dateRange!.end.month}/${_dateRange!.end.day}"),
                  ],
                ],
              ),
            ),

          // Table
          Expanded(
            child: _loadingRollup
                ? const Center(child: CircularProgressIndicator())
                : _selectedLocationPk == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(TablerIcons.package,
                                size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            Text("Select a location to see inventory rollup",
                                style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey.shade600)),
                          ],
                        ),
                      )
                    : _parts.isEmpty
                        ? Center(
                            child: Text("No data",
                                style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey.shade500)),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadRollup,
                            child: ListView.builder(
                              itemCount: _parts.length + 1, // +1 for header
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    color: Colors.grey.shade100,
                                    child: const Row(
                                      children: [
                                        Expanded(child: Text("Part", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                                        SizedBox(width: 60, child: Text("Cases", textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                                        SizedBox(width: 50, child: Text("Units", textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                                        SizedBox(width: 40, child: Text("Sales", textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                                      ],
                                    ),
                                  );
                                }
                                final part = _parts[index - 1];
                                final name =
                                    part["part_name"]?.toString() ?? "?";
                                final packSize =
                                    part["pack_size"] as int? ?? 0;
                                final cases = part["cases"] as int? ?? 0;
                                final units =
                                    (part["units"] as num?)?.toDouble() ?? 0;
                                final sales =
                                    part["sales"] as int? ?? 0;

                                String casesText = cases > 0
                                    ? (packSize > 0
                                        ? "$cases (×$packSize)"
                                        : "$cases")
                                    : "—";
                                String unitsText = units > 0
                                    ? units
                                        .toStringAsFixed(2)
                                        .replaceAll(RegExp(r"0+$"), "")
                                        .replaceAll(RegExp(r"\.$"), "")
                                    : "—";

                                return ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    backgroundColor:
                                        cases > 0
                                            ? const Color(0xFFE8F5E9)
                                            : const Color(0xFFF5F5F5),
                                    radius: 16,
                                    child: Text(
                                      cases > 0 ? "$cases" : "—",
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: cases > 0
                                            ? const Color(0xFF2E7D32)
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  title: Text(name,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 60,
                                        child: Text(
                                          cases > 0 ? casesText : "—",
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: cases > 0
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                            color: cases > 0
                                                ? const Color(0xFF2E7D32)
                                                : Colors.grey,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      SizedBox(
                                        width: 50,
                                        child: Text(
                                          units > 0 ? unitsText : "—",
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: units > 0
                                                ? Colors.black87
                                                : Colors.grey,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      SizedBox(
                                        width: 40,
                                        child: Text(
                                          sales > 0 ? "$sales" : "—",
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: sales > 0
                                                ? FontWeight.w700
                                                : FontWeight.normal,
                                            color: sales > 0
                                                ? const Color(0xFF1565C0)
                                                : Colors.grey,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text("$label: $value",
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w600)),
    );
  }
}
