import 'package:flutter/material.dart';
import '../../theme/tc_tokens.dart';
import 'workspace_row.dart';
import 'sidebar_channels_list.dart';
import 'sidebar_footer.dart';
import 'sidebar_mini_dash.dart';

/// The 240 px desktop sidebar that replaces ServerRail + _ChannelList.
///
/// Layout (top to bottom):
/// 1. [WorkspaceRow] — workspace badge + name + search icon
/// 2. [SidebarChannelsList] — scrollable compact channel rows (fills remaining space)
/// 3. [SidebarMiniDash] — docked ambient/escalation area
/// 4. [SidebarFooter] — workspace badge + name + settings gear (F5)
///
/// A 1 px hairline borders the right edge to separate from the main pane.
///
/// Example:
/// ```dart
/// SidebarShell(
///   workspaceName: 'pronoic',
///   channels: myChannels,
///   activeChannelName: 'general',
///   openCount: 6,
///   doneToday: 3,
///   tasks: runningTasks,
///   narratorText: 'Coder is patching.',
///   narratorEmphasis: ['Coder is patching'],
///   escalations: const [],
///   onWorkspaceSwitcherTap: () => _showWorkspacePicker(context),
///   onSearchTap: () => _openSearch(context),
///   onChannelTap: (name) => setState(() => _selected = name),
///   onAddChannel: () => _showNewChannelModal(context),
///   onQuickReply: (reply) => _resolveEscalation(reply),
///   onSkipEscalation: () => _skipEscalation(),
///   onOpenChannel: () => _openEscalationChannel(),
///   onSettingsTap: () => _openSettings(context),
/// )
/// ```
class SidebarShell extends StatelessWidget {
  // WorkspaceRow props
  final String workspaceName;
  final VoidCallback onWorkspaceSwitcherTap;
  final VoidCallback onSearchTap;
  // SidebarChannelsList props
  final List<SidebarChannelEntry> channels;
  final String? activeChannelName;
  /// When true, the Board nav entry in [SidebarChannelsList] is highlighted.
  final bool isBoardSelected;
  /// Invoked when the user taps the Board entry. Wired from [_buildWide] in
  /// discord_shell.dart to set [_selected = const BoardSelected()].
  final VoidCallback? onBoardTap;
  final void Function(String name) onChannelTap;
  final VoidCallback onAddChannel;
  // SidebarMiniDash props (ambient)
  final int openCount;
  final int doneToday;
  final List<SidebarMiniTaskData> tasks;
  /// Narrator text from the WS stream. Null = no narrator event yet;
  /// [SidebarMiniDash] hides the bubble when this is null.
  final String? narratorText;
  final List<String> narratorEmphasis;
  // SidebarMiniDash props (escalation)
  final List<SidebarEscalationData> escalations;
  final void Function(String reply) onQuickReply;
  final VoidCallback onSkipEscalation;
  final VoidCallback onOpenChannel;
  final int activeEscalationIndex;
  /// Invoked when the user taps the settings gear in [SidebarFooter].
  /// Should open [WorkspaceSettingsScreen] — mirrors the gear in the
  /// narrow AppBar added in F4.
  final VoidCallback onSettingsTap;

  const SidebarShell({
    super.key,
    required this.workspaceName,
    required this.onWorkspaceSwitcherTap,
    required this.onSearchTap,
    required this.channels,
    required this.activeChannelName,
    this.isBoardSelected = false,
    this.onBoardTap,
    required this.onChannelTap,
    required this.onAddChannel,
    required this.openCount,
    required this.doneToday,
    required this.tasks,
    this.narratorText,
    required this.narratorEmphasis,
    required this.escalations,
    required this.onQuickReply,
    required this.onSkipEscalation,
    required this.onOpenChannel,
    this.activeEscalationIndex = 0,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final tc = context.tc;
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: tc.bg,
        border: Border(right: BorderSide(color: tc.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top: workspace row
          WorkspaceRow(
            workspaceName: workspaceName,
            onSwitcherTap: onWorkspaceSwitcherTap,
            onSearchTap: onSearchTap,
          ),
          // Middle: scrollable channel list
          Expanded(
            child: SingleChildScrollView(
              child: SidebarChannelsList(
                channels: channels,
                activeChannelName: activeChannelName,
                isBoardSelected: isBoardSelected,
                onBoardTap: onBoardTap,
                onChannelTap: onChannelTap,
                onAddChannel: onAddChannel,
              ),
            ),
          ),
          // Bottom: docked mini dash (ambient or escalation)
          SidebarMiniDash(
            openCount: openCount,
            doneToday: doneToday,
            tasks: tasks,
            narratorText: narratorText,
            narratorEmphasis: narratorEmphasis,
            escalations: escalations,
            onQuickReply: onQuickReply,
            onSkipEscalation: onSkipEscalation,
            onOpenChannel: onOpenChannel,
            activeEscalationIndex: activeEscalationIndex,
          ),
          // Footer: workspace badge + name + settings gear (F5).
          // Gives desktop users the same settings affordance as the
          // narrow AppBar gear added in F4.
          SidebarFooter(
            workspaceName: workspaceName,
            onSettingsTap: onSettingsTap,
          ),
        ],
      ),
    );
  }
}
