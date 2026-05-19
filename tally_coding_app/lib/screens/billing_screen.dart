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
  Future<Map<String, dynamic>>? _cost;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _usage = widget.client.billingUsage();
      _cost = widget.client.billingCost();
    });
  }

  /// Derive the Clerk Account Portal URL from the publishable key.
  ///
  /// **Important:** the *frontend API host* (where the SDK fetches
  /// `/v1/environment` etc.) is `<slug>.clerk.accounts.dev`, but the
  /// *hosted Account Portal* (the user-facing profile + billing
  /// pages) is `<slug>.accounts.dev` — no `clerk.` prefix.  We have
  /// to strip the `clerk.` segment when building the portal URL or
  /// users get a 404.  Billing lives inside the UserProfile widget
  /// as a tab; the public route is `/user` and Clerk auto-selects
  /// the Billing tab when you append `#/billing` to the hash route.
  Uri? _billingPortalUri() {
    final pk = widget.publishableKey;
    for (final prefix in ['pk_test_', 'pk_live_']) {
      if (!pk.startsWith(prefix)) continue;
      final tail = pk.substring(prefix.length);
      try {
        final padded = tail.padRight(((tail.length + 3) ~/ 4) * 4, '=');
        final decoded = utf8.decode(base64.decode(padded));
        final frontend = decoded.endsWith(r'$')
            ? decoded.substring(0, decoded.length - 1)
            : decoded;
        // Strip the leading `clerk.` segment to get the portal host.
        final portalHost = frontend.startsWith('clerk.')
            ? frontend.substring('clerk.'.length)
            : frontend.replaceFirst('.clerk.', '.');
        return Uri.parse('https://$portalHost/user#/billing');
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
                const SizedBox(height: 12),
                _CostCard(future: _cost),
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

/// Sprint 39: cost breakdown panel — total LLM spend this period
/// plus per-kind (architect / agent) and per-model splits.  Numbers
/// are estimates based on the orchestrator's static price table;
/// real billing is on Red Pill's side and only available there.
class _CostCard extends StatelessWidget {
  final Future<Map<String, dynamic>>? future;
  const _CostCard({required this.future});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D31),
        borderRadius: BorderRadius.circular(8),
      ),
      child: FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          if (snap.hasError) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('LLM cost this period',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  '${snap.error}',
                  style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
                ),
              ],
            );
          }
          final data = snap.data!;
          final totalMicro = (data['total_micro_usd'] as num?)?.toInt() ?? 0;
          final totalTokens = (data['total_tokens'] as num?)?.toInt() ?? 0;
          final byKind = (data['by_kind'] as List?) ?? const [];
          final byModel = (data['by_model'] as List?) ?? const [];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('LLM cost this period',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _formatUsd(totalMicro),
                    style: const TextStyle(
                      color: Color(0xFF57F287),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_thousands(totalTokens)} tokens',
                    style: const TextStyle(color: Color(0xFFB9BBBE), fontSize: 12),
                  ),
                ],
              ),
              if (byKind.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('By kind',
                    style: TextStyle(color: Color(0xFF8E9297), fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final k in byKind.cast<Map<String, dynamic>>())
                  _CostRow(
                    label: '${k['kind']}',
                    micro: (k['total_micro_usd'] as num?)?.toInt() ?? 0,
                    tokens: (k['total_tokens'] as num?)?.toInt() ?? 0,
                    calls: (k['calls'] as num?)?.toInt() ?? 0,
                  ),
              ],
              if (byModel.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('By model',
                    style: TextStyle(color: Color(0xFF8E9297), fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final m in byModel.cast<Map<String, dynamic>>())
                  _CostRow(
                    label: _shortModel('${m['model']}'),
                    micro: (m['total_micro_usd'] as num?)?.toInt() ?? 0,
                    tokens: (m['total_tokens'] as num?)?.toInt() ?? 0,
                    calls: (m['calls'] as num?)?.toInt() ?? 0,
                  ),
              ],
              const SizedBox(height: 10),
              const Text(
                'Estimates from orchestrator-side price table. Real billing on Red Pill.',
                style: TextStyle(color: Color(0xFF6E7378), fontSize: 10),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _formatUsd(int microUsd) {
    final usd = microUsd / 1_000_000;
    if (usd >= 0.01) return '\$${usd.toStringAsFixed(2)}';
    if (usd > 0) return '\$${usd.toStringAsFixed(4)}';
    return '\$0.00';
  }

  static String _thousands(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String _shortModel(String full) {
    // "meta-llama/llama-3.3-70b-instruct" → "llama-3.3-70b"
    final slash = full.lastIndexOf('/');
    var trimmed = slash >= 0 ? full.substring(slash + 1) : full;
    trimmed = trimmed.replaceAll('-instruct', '');
    return trimmed;
  }
}

class _CostRow extends StatelessWidget {
  final String label;
  final int micro;
  final int tokens;
  final int calls;
  const _CostRow({
    required this.label,
    required this.micro,
    required this.tokens,
    required this.calls,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFFC4C9CE), fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _CostCard._formatUsd(micro),
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 8),
          Text(
            '$calls call${calls == 1 ? '' : 's'}',
            style: const TextStyle(color: Color(0xFF8E9297), fontSize: 11),
          ),
        ],
      ),
    );
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
