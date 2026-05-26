import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/tally_avatar.dart';

Widget _wrap(Widget child) {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: Padding(padding: const EdgeInsets.all(24), child: child),
      ),
    ),
  );
}

// ─── TallyAvatar previews ───────────────────────────────────────────────────

@Preview(name: 'Online (default, 28px)', group: 'TallyAvatar')
Widget tallyAvatarOnlineDefault() => _wrap(const TallyAvatar());

@Preview(name: 'Offline (28px)', group: 'TallyAvatar')
Widget tallyAvatarOffline() => _wrap(const TallyAvatar(online: false));

@Preview(name: 'Size 18px — online', group: 'TallyAvatar')
Widget tallyAvatarSize18() => _wrap(const TallyAvatar(size: 18));

@Preview(name: 'Size 22px — online', group: 'TallyAvatar')
Widget tallyAvatarSize22() => _wrap(const TallyAvatar(size: 22));

@Preview(name: 'Size 28px — online', group: 'TallyAvatar')
Widget tallyAvatarSize28() => _wrap(const TallyAvatar(size: 28));

@Preview(name: 'Size 38px — online', group: 'TallyAvatar')
Widget tallyAvatarSize38() => _wrap(const TallyAvatar(size: 38));

@Preview(name: 'All sizes — online', group: 'TallyAvatar')
Widget tallyAvatarAllSizes() {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final size in [18.0, 22.0, 28.0, 38.0]) ...[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TallyAvatar(size: size),
                    const SizedBox(height: 6),
                    Text(
                      '${size.round()}',
                      style: TextStyle(color: tokens.fgXdim, fontSize: 9),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
