import "package:flutter/material.dart";
import "package:flutter_tabler_icons/flutter_tabler_icons.dart";

import "package:inventree/api.dart";
import "package:inventree/app_colors.dart";
import "package:inventree/helpers.dart";
import "package:inventree/l10.dart";

/// Pricing dashboard page.
///
/// Requires the inventree-bulk-scan plugin installed on the server
/// to provide the custom /api/pricing/ endpoint.
class BulkScanPricingPage extends StatefulWidget {
  const BulkScanPricingPage({Key? key}) : super(key: key);

  @override
  BulkScanPricingPageState createState() => BulkScanPricingPageState();
}

class BulkScanPricingPageState extends State<BulkScanPricingPage> {
  bool _loading = true;
  bool _pluginMissing = false;
  String? _error;

  double _totalRetailValue = 0;
  double _totalStockCost = 0;
  double _overallMarkupPct = 0;
  List<Map<String, dynamic>> _topParts = [];

  @override
  void initState() {
    super.initState();
    _loadPricing();
  }

  Future<void> _loadPricing() async {
    setState(() => _loading = true);

    try {
      final response = await InvenTreeAPI().get(
        "plugin/bulk-scan/api/pricing/",
        expectedStatusCode: null,
      );

      if (response.isValid() && response.isMap()) {
        final data = response.asMap();
        setState(() {
          _totalRetailValue =
              (data["total_retail_value"] as num?)?.toDouble() ?? 0;
          _totalStockCost =
              (data["total_stock_cost"] as num?)?.toDouble() ?? 0;
          _overallMarkupPct =
              (data["overall_markup_pct"] as num?)?.toDouble() ?? 0;
          final topParts = data["top_parts"] as List<dynamic>? ?? [];
          _topParts = topParts
              .map((e) => e as Map<String, dynamic>)
              .toList();
          _loading = false;
        });
      } else if (response.statusCode == 404 || response.statusCode == 500) {
        setState(() {
          _pluginMissing = true;
          _loading = false;
        });
      } else {
        setState(() {
          _error = response.error.isNotEmpty ? response.error : "Failed to load pricing data";
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _pluginMissing = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10().bulkScanPricing),
        backgroundColor: COLOR_APP_BAR,
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loadPricing,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pluginMissing
              ? _buildPluginMissing()
              : _error != null
                  ? _buildError()
                  : _buildContent(),
    );
  }

  Widget _buildPluginMissing() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(TablerIcons.plug, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              "Plugin Required",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "The inventree-bulk-scan plugin must be installed on the InvenTree server to view pricing data.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(TablerIcons.refresh),
              label: const Text("Retry"),
              onPressed: _loadPricing,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(TablerIcons.exclamation_circle, size: 64, color: COLOR_DANGER),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: COLOR_DANGER),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              icon: const Icon(TablerIcons.refresh),
              label: const Text("Retry"),
              onPressed: _loadPricing,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary cards
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  "Total Retail Value",
                  renderCurrency(_totalRetailValue, "USD"),
                  TablerIcons.coins,
                  const Color(0xFF2E7D32),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  "Total Stock Cost",
                  renderCurrency(_totalStockCost, "USD"),
                  TablerIcons.receipt,
                  const Color(0xFF1565C0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Overall markup
          _buildStatCard(
            "Overall Markup",
            "${_overallMarkupPct.toStringAsFixed(1)}%",
            TablerIcons.percentage,
            _overallMarkupPct >= 0 ? const Color(0xFF7B1FA2) : COLOR_DANGER,
          ),

          const SizedBox(height: 24),

          // Top 5 parts by markup
          Text(
            "Top 5 Parts by Markup",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 8),

          if (_topParts.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  "No pricing data available",
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ),
            )
          else
            ...List.generate(_topParts.length, (i) {
              final part = _topParts[i];
              final name = (part["name"] ?? "").toString();
              final markup = (part["markup_pct"] as num?)?.toDouble() ?? 0;
              final retail =
                  (part["retail_value"] as num?)?.toDouble() ?? 0;

              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: COLOR_ACTION.withValues(alpha: 0.1),
                    child: Text(
                      "${i + 1}",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(name),
                  subtitle: Text(renderCurrency(retail, "USD")),
                  trailing: Text(
                    "${markup.toStringAsFixed(1)}%",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: markup >= 0 ? const Color(0xFF2E7D32) : COLOR_DANGER,
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
