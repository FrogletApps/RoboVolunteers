import 'package:flutter/material.dart';

/// Supported volunteer qualifications and roles for VEX competitions.
/// Based on the Global Robotics Library catalog of local event volunteer roles.
enum VolunteerRole {
  headRef(
    'head_ref',
    'Head Referee',
    'Rules on match play, makes final scoring decisions, and handles rules questions',
    Icons.sports,
  ),
  ref(
    'ref',
    'Scorekeeper Referee',
    'Scores matches alongside the Head Referee and tracks scoring elements',
    Icons.sports_score,
  ),
  robotInspector(
    'robot_inspector',
    'Robot Inspector',
    'Checks robots against the inspection checklist for size and rules compliance',
    Icons.fact_check_outlined,
  ),
  judgeAdvisor(
    'judge_advisor',
    'Judge Advisor',
    'Lead volunteer guiding team judging deliberations and awards',
    Icons.gavel,
  ),
  judge(
    'judge',
    'Judge',
    'Interviews teams and evaluates engineering notebooks',
    Icons.rate_review,
  ),
  tmOperator(
    'tm_operator',
    'Tournament Manager Operator',
    'Runs event software, enters match results, and manages schedules and displays',
    Icons.computer,
  ),
  emcee(
    'emcee',
    'Emcee',
    'Announces matches, keeps teams and spectators engaged, and hosts awards',
    Icons.mic,
  ),
  fieldResetter(
    'field_resetter',
    'Field Resetter',
    'Resets fields and positions game elements between matches',
    Icons.refresh,
  ),
  queuer(
    'queuer',
    'Queuer',
    'Gets the right teams to the right field on time to keep matches on schedule',
    Icons.queue,
  ),
  pitAdmin(
    'pit_admin',
    'Team Check-In & Pit Admin',
    'Checks teams in, hands out pit assignments, and supports the pit area',
    Icons.badge_outlined,
  ),
  hospitality(
    'hospitality',
    'Concessions & Hospitality',
    'Runs concessions and keeps volunteers fed and hydrated throughout the event',
    Icons.local_cafe_outlined,
  ),
  other(
    'other',
    'Other',
    'Any other event volunteer role not listed above',
    Icons.more_horiz,
  );

  static const String roleDetailsGuideUrl =
      'https://library.globalrobotics.org/hc/en-us/articles/51905218620820-Volunteer-Roles-at-a-Local-Event';

  final String id;
  final String label;
  final String description;
  final IconData icon;

  const VolunteerRole(this.id, this.label, this.description, this.icon);

  static VolunteerRole fromId(String id) {
    return VolunteerRole.values.firstWhere(
      (r) => r.id == id,
      orElse: () => VolunteerRole.other,
    );
  }

  Color get color {
    switch (this) {
      case VolunteerRole.headRef:
        return const Color(0xFFD97706); // Amber / Gold
      case VolunteerRole.ref:
        return const Color(0xFF2563EB); // Royal Blue
      case VolunteerRole.robotInspector:
        return const Color(0xFF0D9488); // Teal
      case VolunteerRole.judgeAdvisor:
        return const Color(0xFF7C3AED); // Purple
      case VolunteerRole.judge:
        return const Color(0xFF059669); // Emerald Green
      case VolunteerRole.tmOperator:
        return const Color(0xFF4F46E5); // Indigo
      case VolunteerRole.emcee:
        return const Color(0xFFE11D48); // Rose / Crimson
      case VolunteerRole.fieldResetter:
        return const Color(0xFF0891B2); // Cyan
      case VolunteerRole.queuer:
        return const Color(0xFFEA580C); // Orange
      case VolunteerRole.pitAdmin:
        return const Color(0xFFDB2777); // Pink
      case VolunteerRole.hospitality:
        return const Color(0xFF65A30D); // Olive / Lime
      case VolunteerRole.other:
        return const Color(0xFF475569); // Slate Grey
    }
  }
}
