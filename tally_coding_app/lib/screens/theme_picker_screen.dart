import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/brutal/brutal.dart';

/// Full-screen theme picker: sidebar list (340 px) + live preview pane.
///
/// Example navigation:
/// ```dart
/// Navigator.of(context).push(
///   MaterialPageRoute(builder: (_) => const ThemePickerScreen()),
/// );
/// ```
class ThemePickerScreen extends StatefulWidget {
  const ThemePickerScreen({super.key});

  @override
  State<ThemePickerScreen> createState() => _ThemePickerScreenState();
}

class _ThemePickerScreenState extends State<ThemePickerScreen> {
  String _filter = '';

  List<MapEntry<String, ThemeEntry>> get _visibleThemes {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return themeCatalog.entries.toList();
    return themeCatalog.entries.where((e) {
      final hay = '${e.value.name} ${e.value.desc}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    final controller = context.watch<ThemeController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'APPEARANCE · THEME',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        backgroundColor: tc.bg,
        elevation: 0,
        foregroundColor: tc.fg,
        shape: Border(bottom: BorderSide(color: tc.border, width: 1)),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // LEFT: filter + scrollable theme list (fixed 340 px)
          SizedBox(
            width: 340,
            child: Container(
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: tc.border, width: 1)),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                    child: TextField(
                      onChanged: (v) => setState(() => _filter = v),
                      decoration: InputDecoration(
                        hintText: 'filter themes…',
                        hintStyle: TextStyle(color: tc.fgXdim, fontSize: 11),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(color: tc.fgXdim),
                        ),
                      ),
                      style: TextStyle(fontSize: 11, color: tc.fg),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final entry in _visibleThemes)
                            ThemeTile(
                              slug: entry.key,
                              entry: entry.value,
                              active: entry.key == controller.activeSlug,
                              onTap: () => controller.setTheme(entry.key),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // RIGHT: live preview pane
          const Expanded(child: _PreviewPane()),
        ],
      ),
    );
  }
}

/// Single row in the theme list. Shows 4 color swatches + name + description.
/// Active state: cardHov background + 2 px green left border.
class ThemeTile extends StatelessWidget {
  final String slug;
  final ThemeEntry entry;
  final bool active;
  final VoidCallback onTap;

  const ThemeTile({
    super.key,
    required this.slug,
    required this.entry,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? tc.cardHov : null,
          border: Border(
            left: BorderSide(
              color: active ? tc.green : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            // 4 color swatches: bg / fg / green / red
            Row(
              children: [
                Container(width: 12, height: 24, color: entry.tokens.bg),
                Container(width: 12, height: 24, color: entry.tokens.fg),
                Container(width: 12, height: 24, color: entry.tokens.green),
                Container(width: 12, height: 24, color: entry.tokens.red),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: tc.fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.desc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: tc.fgXdim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Right pane: live Brutal Terminal component preview in the active theme.
class _PreviewPane extends StatelessWidget {
  const _PreviewPane();

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PREVIEW',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: tc.fgXdim,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 22,
            runSpacing: 22,
            children: [
              // Card with avatars + progress bar
              SizedBox(
                width: 280,
                child: BrutalCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sample · preview reflects active theme',
                        style: TextStyle(
                          color: tc.fg,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 11),
                      Row(
                        children: [
                          const AgentAvatar(
                            role: AgentRole.architect,
                            active: false,
                          ),
                          const SizedBox(width: 4),
                          const AgentAvatar(
                            role: AgentRole.coder,
                            active: true,
                          ),
                          const Spacer(),
                          Text(
                            '~5m left',
                            style: TextStyle(color: tc.fgDim, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 11),
                      const BrutalProgressBar(value: 0.6),
                    ],
                  ),
                ),
              ),
              // Tally narration bubble
              SizedBox(
                width: 280,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const TallyAvatar(online: false),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BrutalBubble(
                        maxWidth: double.infinity,
                        child: Text(
                          'Diagnosed the daily-deals bug. Coder is patching — PR in ~5 min.',
                          style: TextStyle(color: tc.fg, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Action buttons
              SizedBox(
                width: 280,
                child: Row(
                  children: [
                    Expanded(
                      child: BrutalButton.primary(
                        label: '2 decimals',
                        onPressed: () {},
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: BrutalButton.outline(
                        label: 'keep 4',
                        onPressed: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
