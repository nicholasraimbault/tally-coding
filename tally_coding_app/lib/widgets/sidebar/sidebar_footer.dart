import 'package:flutter/material.dart';
import 'package:tally_coding_app/theme/tc_tokens.dart';

/// Settings footer docked at the very bottom of the desktop sidebar.
///
/// Shows a small workspace badge (first letter of [workspaceName]) + the
/// workspace name + a settings gear icon. Tapping the gear calls
/// [onSettingsTap], which should open [WorkspaceSettingsScreen].
///
/// This gives desktop users the same settings affordance that mobile users
/// get from the narrow AppBar gear (added in F4). Without this widget,
/// settings is unreachable on desktop.
///
/// Example:
/// ```dart
/// SidebarFooter(
///   workspaceName: 'pronoic',
///   onSettingsTap: () => _openSettings(),
/// )
/// ```
class SidebarFooter extends StatelessWidget {
  final String workspaceName;
  final VoidCallback onSettingsTap;

  const SidebarFooter({
    super.key,
    required this.workspaceName,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      decoration: BoxDecoration(
        color: tc.elev,
        border: Border(top: BorderSide(color: tc.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Small workspace badge — matches WorkspaceRow style at smaller scale.
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: tc.green,
              border: Border.all(color: tc.borderStr, width: 1),
            ),
            alignment: Alignment.center,
            child: Text(
              (workspaceName.isNotEmpty ? workspaceName[0] : 'W').toUpperCase(),
              style: TextStyle(
                color: tc.bg,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              workspaceName.isEmpty ? '(no workspace)' : workspaceName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tc.fg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 28, minHeight: 28),
            icon: Icon(Icons.settings_outlined, color: tc.fgDim),
            onPressed: onSettingsTap,
          ),
        ],
      ),
    );
  }
}
