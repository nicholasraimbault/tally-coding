/// Sprint 25: agent role metadata used by the Discord-shaped UI. Mirrors
/// the orchestrator's `agent_roles` seed (services/orchestrator/.../service.py).
/// Kept here as a static map because Tally's team is one of 7 known roles —
/// no need to fetch the list at runtime for icon/colour rendering.
library;

import 'package:flutter/material.dart';

class AgentRole {
  final String name;
  final String glyph;
  final Color tint;
  final String tagline;
  const AgentRole({
    required this.name,
    required this.glyph,
    required this.tint,
    required this.tagline,
  });
}

const Map<String, AgentRole> agentRoles = {
  'Planner': AgentRole(
    name: 'Planner',
    glyph: '📋',
    tint: Color(0xFF5865F2),
    tagline: 'breaks tasks into steps',
  ),
  'Coder': AgentRole(
    name: 'Coder',
    glyph: '👤',
    tint: Color(0xFF57F287),
    tagline: 'writes the code',
  ),
  'Reviewer': AgentRole(
    name: 'Reviewer',
    glyph: '🔍',
    tint: Color(0xFFFEE75C),
    tagline: 'reads for bugs and style',
  ),
  'Tester': AgentRole(
    name: 'Tester',
    glyph: '🧪',
    tint: Color(0xFFEB459E),
    tagline: 'runs the tests',
  ),
  'DocWriter': AgentRole(
    name: 'DocWriter',
    glyph: '📚',
    tint: Color(0xFFED4245),
    tagline: 'writes the README',
  ),
  'SecReviewer': AgentRole(
    name: 'SecReviewer',
    glyph: '🛡',
    tint: Color(0xFFFAA61A),
    tagline: 'audits for security',
  ),
  'DBA': AgentRole(
    name: 'DBA',
    glyph: '🗃',
    tint: Color(0xFF9B59B6),
    tagline: 'designs the schema',
  ),
};

AgentRole agentRoleOf(String name) =>
    agentRoles[name] ??
    AgentRole(
      name: name,
      glyph: '🧠',
      tint: const Color(0xFF99AAB5),
      tagline: 'agent',
    );

/// Tally itself — appears at the top of the members sidebar on #general.
const tallyMember = AgentRole(
  name: 'Tally',
  glyph: '✨',
  tint: Color(0xFF7C5CFC),
  tagline: 'architect — picks the team for each task',
);
