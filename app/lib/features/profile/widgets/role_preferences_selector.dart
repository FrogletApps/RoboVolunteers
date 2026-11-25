import 'package:flutter/material.dart';
import '../../../core/constants/roles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/role_details_link.dart';

/// Dual role selector for account preferences:
/// 1. "Qualified" — roles the volunteer is qualified to fill.
/// 2. "I want to do this" — preferred roles (pre-selected by default when signing up for an event).
class RolePreferencesSelector extends StatelessWidget {
  final Set<String> qualifications;
  final Set<String> preferredRoles;
  final void Function(String roleId, bool isQualified) onQualificationChanged;
  final void Function(String roleId, bool isPreferred) onPreferredChanged;
  final String title;
  final VoidCallback? onOpenGuide;

  const RolePreferencesSelector({
    super.key,
    required this.qualifications,
    required this.preferredRoles,
    required this.onQualificationChanged,
    required this.onPreferredChanged,
    this.title = 'Volunteer Roles & Preferences',
    this.onOpenGuide,
  });

  @override
  Widget build(BuildContext context) {
    final selectableRoles =
        VolunteerRole.values.where((r) => r != VolunteerRole.other).toList();
    final selectableIds = selectableRoles.map((r) => r.id).toSet();
    final activeQualifiedCount =
        qualifications.where(selectableIds.contains).length;
    final activePreferredCount = preferredRoles
        .where((r) => selectableIds.contains(r) && qualifications.contains(r))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              'Qualified: $activeQualifiedCount • Preferred: $activePreferredCount',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.brandGreen.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppTheme.brandGreen.withValues(alpha: 0.18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '• Qualified: Roles you are qualified or experienced to fill on your profile.',
                style: TextStyle(fontSize: 12, color: Colors.grey[800]),
              ),
              const SizedBox(height: 4),
              Text(
                '• I want to do this: Roles you prefer — these will be pre-selected by default for each event.',
                style: TextStyle(fontSize: 12, color: Colors.grey[800]),
              ),
              const SizedBox(height: 6),
              RoleDetailsLink(onTap: onOpenGuide),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ...selectableRoles.map((role) {
          final isQualified = qualifications.contains(role.id);
          final isPreferred = isQualified && preferredRoles.contains(role.id);

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              key: Key('role_card_${role.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isPreferred
                    ? role.color.withValues(alpha: 0.09)
                    : isQualified
                        ? role.color.withValues(alpha: 0.04)
                        : Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isPreferred
                      ? role.color
                      : isQualified
                          ? role.color.withValues(alpha: 0.55)
                          : const Color(0xFFE2E8F0),
                  width: isPreferred ? 1.5 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(role.icon, color: role.color, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              role.label,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: isQualified ? role.color : null,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              role.description,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilterChip(
                        key: Key('role_qualified_${role.id}'),
                        label: const Text('Qualified'),
                        selected: isQualified,
                        selectedColor: role.color.withValues(alpha: 0.16),
                        checkmarkColor: role.color,
                        side: BorderSide(
                          color: isQualified
                              ? role.color
                              : const Color(0xFFCBD5E1),
                        ),
                        labelStyle: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isQualified ? FontWeight.bold : FontWeight.w500,
                          color: isQualified ? role.color : Colors.grey[800],
                        ),
                        visualDensity: VisualDensity.compact,
                        onSelected: (selected) =>
                            onQualificationChanged(role.id, selected),
                      ),
                      FilterChip(
                        key: Key('role_wanted_${role.id}'),
                        avatar: Icon(
                          isPreferred ? Icons.star : Icons.star_border,
                          size: 16,
                          color: isPreferred
                              ? AppTheme.brandGreen
                              : Colors.grey[600],
                        ),
                        label: const Text('I want to do this'),
                        selected: isPreferred,
                        showCheckmark: false,
                        selectedColor:
                            AppTheme.brandGreen.withValues(alpha: 0.16),
                        side: BorderSide(
                          color: isPreferred
                              ? AppTheme.brandGreen
                              : const Color(0xFFCBD5E1),
                        ),
                        labelStyle: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isPreferred ? FontWeight.bold : FontWeight.w500,
                          color: isPreferred
                              ? AppTheme.brandGreen
                              : Colors.grey[800],
                        ),
                        visualDensity: VisualDensity.compact,
                        onSelected: (selected) =>
                            onPreferredChanged(role.id, selected),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
