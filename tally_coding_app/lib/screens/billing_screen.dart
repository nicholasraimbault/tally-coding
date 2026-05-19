import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';

/// Sprint 33-rest: read-only billing screen.  Reads `/billing/usage`
/// to show plan + period counters + caps.  "Manage subscription"
/// launches the Clerk Account Portal in the system browser, where
/// the user can subscribe / change plan via the hosted PricingTable.
/// On return, the screen refetches usage so the new plan shows up
/// (orchestrator opportunistically syncs from the JWT `pla` claim;
/// the Clerk webhook is the authoritative async path).
class BillingScreen extends StatefulWidget {
  final TallyOrchClient client;
  final String publishableKey;
  const BillingScreen({super.key, required this.client, required this.publishableKey});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  Future<Map<String, dynamic>>? _usage;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _usage = widget.client.billingUsage());
  }

  /// Derive the Clerk Account Portal URL from the publishable key,
  /// then append `/billing` so users land on the plan-management
  /// surface.  Publishable keys look like
  /// `pk_test_<base64-of-frontend-api$>`; we strip the `$` and
  /// build `https://<frontend>/billing`.
  Uri? _billingPortalUri() {
    final pk = widget.publishableKey;
    for (final prefix in ['pk_test_', 'pk_live_']) {
      if (!pk.startsWith(prefix)) continue;
      final tail = pk.substring(prefix.length);
      try {
        final padded = tail.padRight(((tail.length + 3) ~/ 4) * 4, '=');
        final decoded = utf8.decode(base64.decode(padded));
        final frontend = decoded.endsWith(r'$') ? decoded.substring(0, decoded.length - 1) : decoded;
        return Uri.parse('https://$frontend/billing');
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _openPortal() async {
    final uri = _billingPortalUri();
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not derive Clerk billing portal URL from publishable key.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open $uri')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        foregroundColor: Colors.white,
        title: const Text('Billing & Usage'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _usage,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      '${snap.error}',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          final data = snap.data!;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PlanCard(plan: data['plan'] as String, label: data['plan_label'] as String),
                const SizedBox(height: 16),
                _UsageCard(
                  title: 'Tasks this period',
                  used: (data['tasks']?['used'] as num?)?.toInt() ?? 0,
                  cap: (data['tasks']?['cap'] as num?)?.toInt() ?? 0,
                ),
                const SizedBox(height: 12),
                _UsageCard(
                  title: 'Agent seconds this period',
                  used: (data['agent_seconds']?['used'] as num?)?.toInt() ?? 0,
                  cap: (data['agent_seconds']?['cap'] as num?)?.toInt() ?? 0,
                  formatter: _formatSeconds,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _openPortal,
                      icon: const Icon(Icons.credit_card),
                      label: const Text('Manage subscription'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF7C5CFC),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _refresh,
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFFB9BBBE)),
                      child: const Text("I've subscribed — refresh"),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Plans are managed by Clerk. Your subscription state syncs into Tally automatically when you upgrade or cancel.',
                  style: TextStyle(color: Color(0xFF99AAB5), fontSize: 12),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _formatSeconds(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${(s / 60).toStringAsFixed(1)}m';
    return '${(s / 3600).toStringAsFixed(1)}h';
  }
}

class _PlanCard extends StatelessWidget {
  final String plan;
  final String label;
  const _PlanCard({required this.plan, required this.label});

  Color get _accent {
    switch (plan) {
      case 'pro':
        return const Color(0xFF57F287);
      case 'team':
        return const Color(0xFFFAA61A);
      case 'unlimited':
        return const Color(0xFFEB459E);
      default:
        return const Color(0xFF99AAB5);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: TextStyle(color: _accent, fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              'Current plan',
              style: TextStyle(color: Color(0xFFB9BBBE)),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  final String title;
  final int used;
  final int cap;
  final String Function(int)? formatter;
  const _UsageCard({
    required this.title,
    required this.used,
    required this.cap,
    this.formatter,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = cap > 0 ? (used / cap).clamp(0.0, 1.0) : 0.0;
    final fmt = formatter ?? (int i) => i.toString();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            '${fmt(used)} / ${fmt(cap)}',
            style: const TextStyle(color: Color(0xFFB9BBBE)),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              backgroundColor: const Color(0xFF1E1F22),
              valueColor: AlwaysStoppedAnimation(
                fraction > 0.9
                    ? const Color(0xFFED4245)
                    : (fraction > 0.7 ? const Color(0xFFFAA61A) : const Color(0xFF7C5CFC)),
              ),
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}
