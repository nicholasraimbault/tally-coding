import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:tally_coding_app/theme/theme_builder.dart';
import 'package:tally_coding_app/theme/theme_catalog.dart';
import 'package:tally_coding_app/widgets/brutal/agent_avatar.dart';

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

// ─── AgentAvatar previews ───────────────────────────────────────────────────

@Preview(name: 'Architect — active', group: 'AgentAvatar')
Widget agentAvatarArchitectActive() => _wrap(
      const AgentAvatar(role: AgentRole.architect, active: true),
    );

@Preview(name: 'Architect — inactive', group: 'AgentAvatar')
Widget agentAvatarArchitectInactive() => _wrap(
      const AgentAvatar(role: AgentRole.architect, active: false),
    );

@Preview(name: 'Coder — active', group: 'AgentAvatar')
Widget agentAvatarCoderActive() => _wrap(
      const AgentAvatar(role: AgentRole.coder, active: true),
    );

@Preview(name: 'Coder — inactive', group: 'AgentAvatar')
Widget agentAvatarCoderInactive() => _wrap(
      const AgentAvatar(role: AgentRole.coder, active: false),
    );

@Preview(name: 'Reader — active', group: 'AgentAvatar')
Widget agentAvatarReaderActive() => _wrap(
      const AgentAvatar(role: AgentRole.reader, active: true),
    );

@Preview(name: 'Reader — inactive', group: 'AgentAvatar')
Widget agentAvatarReaderInactive() => _wrap(
      const AgentAvatar(role: AgentRole.reader, active: false),
    );

@Preview(name: 'Tester — active', group: 'AgentAvatar')
Widget agentAvatarTesterActive() => _wrap(
      const AgentAvatar(role: AgentRole.tester, active: true),
    );

@Preview(name: 'Tester — inactive', group: 'AgentAvatar')
Widget agentAvatarTesterInactive() => _wrap(
      const AgentAvatar(role: AgentRole.tester, active: false),
    );

@Preview(name: 'All roles — active (row)', group: 'AgentAvatar')
Widget agentAvatarAllActive() {
  final tokens = themeCatalog['tokyo-night']!.tokens;
  return MaterialApp(
    theme: themeFromTokens(tokens),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: tokens.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Active row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final role in AgentRole.values) ...[
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AgentAvatar(role: role, size: 28, active: true),
                        const SizedBox(height: 4),
                        Text(
                          role.name,
                          style: TextStyle(color: tokens.fgXdim, fontSize: 9),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              // Inactive row (same roles, dimmed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final role in AgentRole.values) ...[
                    AgentAvatar(role: role, size: 28, active: false),
                    const SizedBox(width: 12),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'inactive',
                style: TextStyle(color: tokens.fgXdim, fontSize: 9, letterSpacing: 0.5),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
