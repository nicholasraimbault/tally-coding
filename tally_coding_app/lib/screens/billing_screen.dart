import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../widgets/credit_balance_widget.dart';

/// Sprint 46: credit-based billing screen.  Replaces the Sprint 33
/// Clerk-portal screen with a full credit management UI:
///   • Credit balance widget (subscription + prepaid split)
///   • Buy credits one-time (Stripe Checkout redirect)
///   • Auto-recharge setup (Stripe SetupIntent redirect)
///   • Auto-recharge mode + block-size + monthly-cap controls
///   • Per-task / daily / weekly spend caps
///   • Notifications & alerts shortcut tile
class BillingScreen extends StatefulWidget {
  final TallyOrchClient client;
  const BillingScreen({super.key, required this.client});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  Map<String, dynamic>? _balance;
  Map<String, dynamic>? _caps;
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        widget.client.getCreditsBalance(),
        widget.client.getCaps(),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = results[0];
        _caps = results[1];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _buyCredits() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => const _CreditPickerDialog(),
    );
    if (picked == null) return;
    try {
      final out = await widget.client.postCreditsCheckout(credits: picked);
      final url = Uri.parse(out['url'] as String);
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _setupAutoRecharge() async {
    try {
      final out = await widget.client.postAutoRechargeSetup();
      final url = Uri.parse(out['url'] as String);
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        foregroundColor: Colors.white,
        title: const Text('Billing'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          'Error: $_error',
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _error = null;
                            });
                            _refresh();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    CreditBalanceWidget(
                      planLabel: _balance!['plan_label'] as String,
                      isBeta: _balance!['is_beta'] as bool,
                      usedCredits: _balance!['used_credits'] as int,
                      includedCredits: _balance!['included_credits'] as int,
                      prepaidCreditBalance: _balance!['prepaid_credit_balance'] as int,
                      periodStart: (_balance!['period_start'] as num).toDouble(),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add),
                            label: const Text('Buy credits'),
                            onPressed: _buyCredits,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.autorenew),
                            label: const Text('Auto-recharge'),
                            onPressed: _setupAutoRecharge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _AutoRechargeCard(
                      client: widget.client,
                      balance: _balance!,
                      onChanged: _refresh,
                    ),
                    const SizedBox(height: 16),
                    _CapsCard(
                      client: widget.client,
                      caps: _caps!,
                      onChanged: _refresh,
                    ),
                    const SizedBox(height: 16),
                    Card(
                      color: const Color(0xFF2B2D31),
                      child: ListTile(
                        leading: const Icon(Icons.notifications_outlined, color: Colors.white70),
                        title: const Text(
                          'Notifications & alerts',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          'Configure spend alerts and devices',
                          style: TextStyle(color: Color(0xFFB9BBBE)),
                        ),
                        trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                        onTap: () {
                          // B7 will register the /notifications route.
                          // Until then, show a placeholder snackbar.
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Notifications — coming soon')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ─── _CreditPickerDialog ────────────────────────────────────────────────────

class _CreditPickerDialog extends StatefulWidget {
  const _CreditPickerDialog();

  @override
  State<_CreditPickerDialog> createState() => _CreditPickerDialogState();
}

class _CreditPickerDialogState extends State<_CreditPickerDialog> {
  int _credits = 500;

  @override
  Widget build(BuildContext context) {
    final usd = _credits * 0.02;
    return AlertDialog(
      title: const Text('Buy credits'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: _credits.toDouble(),
            min: 250,
            max: 5000,
            divisions: 19,
            label: '$_credits credits',
            onChanged: (v) => setState(() => _credits = v.round()),
          ),
          Text('$_credits credits · \$${usd.toStringAsFixed(2)}'),
          const SizedBox(height: 8),
          const Text(
            'Minimum: 250 credits (\$5)',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _credits),
          child: const Text('Buy'),
        ),
      ],
    );
  }
}

// ─── _AutoRechargeCard ──────────────────────────────────────────────────────

class _AutoRechargeCard extends StatefulWidget {
  final TallyOrchClient client;
  final Map<String, dynamic> balance;
  final VoidCallback onChanged;

  const _AutoRechargeCard({
    required this.client,
    required this.balance,
    required this.onChanged,
  });

  @override
  State<_AutoRechargeCard> createState() => _AutoRechargeCardState();
}

class _AutoRechargeCardState extends State<_AutoRechargeCard> {
  late int _mode;
  late int _blockCredits;
  late int? _monthlyCapMicroUsd;

  @override
  void initState() {
    super.initState();
    _mode = widget.balance['auto_recharge_mode'] as int;
    _blockCredits = widget.balance['auto_recharge_block_credits'] as int;
    _monthlyCapMicroUsd = widget.balance['auto_recharge_monthly_cap_micro_usd'] as int?;
  }

  Future<void> _save() async {
    try {
      await widget.client.patchAutoRecharge(
        mode: _mode,
        blockCredits: _blockCredits,
        monthlyCapMicroUsd: _monthlyCapMicroUsd,
      );
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  static const _modes = [
    (0, 'Subscription only', 'Hard stop when credits run out'),
    (1, 'Pre-paid manual', 'Buy credit blocks; no auto-charge'),
    (2, 'Auto-recharge with cap', 'Auto-buy blocks up to monthly limit'),
    (3, 'Full auto (no cap)', 'Never run out; bills as usage grows'),
  ];

  @override
  Widget build(BuildContext context) {
    final hasCard = widget.balance['stripe_payment_method_id'] != null;
    return Card(
      color: const Color(0xFF2B2D31),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Auto-recharge',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            for (final (id, label, desc) in _modes)
              RadioListTile<int>(
                value: id,
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: Text(label, style: const TextStyle(color: Colors.white)),
                subtitle: Text(desc, style: const TextStyle(color: Color(0xFFB9BBBE))),
                dense: true,
                activeColor: const Color(0xFF7C5CFC),
              ),
            if (_mode >= 2) ...[
              const Divider(color: Color(0xFF3F4147)),
              Text(
                'Block size: $_blockCredits credits · \$${(_blockCredits * 0.02).toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.white70),
              ),
              Slider(
                value: _blockCredits.toDouble(),
                min: 250,
                max: 2500,
                divisions: 9,
                activeColor: const Color(0xFF7C5CFC),
                onChanged: (v) => setState(() => _blockCredits = v.round()),
              ),
              if (_mode == 2) ...[
                const SizedBox(height: 8),
                Text(
                  'Monthly cap: \$${((_monthlyCapMicroUsd ?? 0) / 1000000).toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white70),
                ),
                Slider(
                  value: ((_monthlyCapMicroUsd ?? 20000000) / 1000000).clamp(5, 500),
                  min: 5,
                  max: 500,
                  divisions: 99,
                  activeColor: const Color(0xFF7C5CFC),
                  onChanged: (v) => setState(() {
                    _monthlyCapMicroUsd = (v * 1000000).round();
                  }),
                ),
              ],
              if (!hasCard) ...[
                const SizedBox(height: 12),
                const Text(
                  'No saved card. Use "Auto-recharge" button above to add one.',
                  style: TextStyle(color: Colors.orange),
                ),
              ],
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── _CapsCard ──────────────────────────────────────────────────────────────

class _CapsCard extends StatefulWidget {
  final TallyOrchClient client;
  final Map<String, dynamic> caps;
  final VoidCallback onChanged;

  const _CapsCard({
    required this.client,
    required this.caps,
    required this.onChanged,
  });

  @override
  State<_CapsCard> createState() => _CapsCardState();
}

class _CapsCardState extends State<_CapsCard> {
  late TextEditingController _perTask;
  late TextEditingController _daily;
  late TextEditingController _weekly;

  @override
  void initState() {
    super.initState();
    _perTask = TextEditingController(
      text: '${widget.caps['per_task_cap_credits'] ?? ''}',
    );
    _daily = TextEditingController(
      text: '${widget.caps['daily_spend_cap_credits'] ?? ''}',
    );
    _weekly = TextEditingController(
      text: '${widget.caps['weekly_spend_cap_credits'] ?? ''}',
    );
  }

  @override
  void dispose() {
    _perTask.dispose();
    _daily.dispose();
    _weekly.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    int? parse(String s) => s.trim().isEmpty ? null : int.tryParse(s.trim());
    try {
      await widget.client.patchCaps(
        perTaskCapCredits: parse(_perTask.text),
        dailySpendCapCredits: parse(_daily.text),
        weeklySpendCapCredits: parse(_weekly.text),
      );
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF2B2D31),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Spend caps',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _perTask,
              decoration: const InputDecoration(
                labelText: 'Per-task cap (credits)',
                hintText: 'e.g. 100',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _daily,
              decoration: const InputDecoration(
                labelText: 'Daily cap (credits)',
                hintText: 'optional',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _weekly,
              decoration: const InputDecoration(
                labelText: 'Weekly cap (credits)',
                hintText: 'optional',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
