import 'package:flutter/material.dart';
import '../../../core/constants/roles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/widgets/role_details_link.dart';

/// Dual role selector for account preferences:
/// 1. "Qualified" — roles the volunteer is qualified to fill.
/// 2. "Favourite" — preferred roles (pre-selected by default when signing up for an event).
class RolePreferencesSelector extends StatelessWidget {
  final Set<String> qualifications;
  final Set<String> preferredRoles;
  final void Function(String roleId, bool isQualified) onQualificationChanged;
  final void Function(String roleId, bool isPreferred) onPreferredChanged;
  final String title;
  final VoidCallback? onOpenGuide;
  final VoidCallback? onOpenCertificationCourse;

  static const double _baseChipColumnWidth = 114;
  static const double _columnSpacing = 8;
  static const double _sideBySideBreakpoint = 460;

  const RolePreferencesSelector({
    super.key,
    required this.qualifications,
    required this.preferredRoles,
    required this.onQualificationChanged,
    required this.onPreferredChanged,
    this.title = 'Volunteer Roles & Preferences',
    this.onOpenGuide,
    this.onOpenCertificationCourse,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final accentGreen = isDark ? AppTheme.brandGreenLight : AppTheme.brandGreen;
    final blurbTextColor =
        isDark ? const Color(0xFFE2E8F0) : Colors.grey[800]!;
    final secondaryTextColor =
        isDark ? const Color(0xFFCBD5E1) : Colors.grey[600]!;
    final chipUnselectedTextColor =
        isDark ? const Color(0xFFE2E8F0) : Colors.grey[800]!;
    final chipUnselectedIconColor =
        isDark ? const Color(0xFFCBD5E1) : Colors.grey[600]!;
    final chipUnselectedBorderColor =
        isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1);
    final cardUnselectedBorderColor =
        isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    final selectableRoles =
        VolunteerRole.values.where((r) => r != VolunteerRole.other).toList();
    final selectableIds = selectableRoles.map((r) => r.id).toSet();
    final activeQualifiedCount =
        qualifications.where(selectableIds.contains).length;
    final activePreferredCount = preferredRoles
        .where((r) => selectableIds.contains(r) && qualifications.contains(r))
        .length;
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.4);
    final columnWidth = (_baseChipColumnWidth * textScale).ceilToDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Qualified: $activeQualifiedCount • Favourite: $activePreferredCount',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: secondaryTextColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accentGreen.withValues(alpha: isDark ? 0.12 : 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: accentGreen.withValues(alpha: isDark ? 0.30 : 0.18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '• Qualified: Roles you are qualified or experienced to fill on your profile.',
                style: TextStyle(fontSize: 12, color: blurbTextColor),
              ),
              const SizedBox(height: 4),
              Text(
                '• Favourite: Roles you prefer — these will be pre-selected by default for each event.',
                style: TextStyle(fontSize: 12, color: blurbTextColor),
              ),
              const SizedBox(height: 6),
              Tooltip(
                message: UrlUtils.certificationCourseUrl,
                child: InkWell(
                  key: const Key('certification_course_link'),
                  onTap: onOpenCertificationCourse ??
                      () => UrlUtils.openCertificationCourse(),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                    child: Text.rich(
                      TextSpan(
                        text:
                            'Remember for Head Referee and Judge Advisor you must be qualified by doing the certification course found here: ',
                        style: TextStyle(fontSize: 12, color: blurbTextColor),
                        children: [
                          TextSpan(
                            text: UrlUtils.certificationCourseUrl,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: accentGreen,
                              decoration: TextDecoration.underline,
                              decorationColor: accentGreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              RoleDetailsLink(onTap: onOpenGuide),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final useSideBySideColumns =
                constraints.maxWidth >= _sideBySideBreakpoint;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: selectableRoles.map((role) {
                final isQualified = qualifications.contains(role.id);
                final isPreferred =
                    isQualified && preferredRoles.contains(role.id);

                final qualifiedChip = SizedBox(
                  width: columnWidth,
                  child: FilterChip(
                    key: Key('role_qualified_${role.id}'),
                    avatar: Icon(
                      isQualified
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      size: 16,
                      color: isQualified ? role.color : chipUnselectedIconColor,
                    ),
                    label: const Text('Qualified'),
                    selected: isQualified,
                    showCheckmark: false,
                    selectedColor:
                        role.color.withValues(alpha: isDark ? 0.24 : 0.16),
                    side: BorderSide(
                      color: isQualified
                          ? role.color
                          : chipUnselectedBorderColor,
                    ),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isQualified ? FontWeight.bold : FontWeight.w500,
                      color:
                          isQualified ? role.color : chipUnselectedTextColor,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    labelPadding: const EdgeInsets.only(right: 4),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (selected) =>
                        onQualificationChanged(role.id, selected),
                  ),
                );

                final favouriteChip = SizedBox(
                  width: columnWidth,
                  child: FilterChip(
                    key: Key('role_wanted_${role.id}'),
                    avatar: Icon(
                      isPreferred ? Icons.star : Icons.star_border,
                      size: 16,
                      color: isPreferred
                          ? accentGreen
                          : chipUnselectedIconColor,
                    ),
                    label: const Text('Favourite'),
                    selected: isPreferred,
                    showCheckmark: false,
                    selectedColor:
                        accentGreen.withValues(alpha: isDark ? 0.22 : 0.16),
                    side: BorderSide(
                      color: isPreferred
                          ? accentGreen
                          : chipUnselectedBorderColor,
                    ),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          isPreferred ? FontWeight.bold : FontWeight.w500,
                      color:
                          isPreferred ? accentGreen : chipUnselectedTextColor,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    labelPadding: const EdgeInsets.only(right: 4),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (selected) =>
                        onPreferredChanged(role.id, selected),
                  ),
                );

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    key: Key('role_card_${role.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isPreferred
                          ? role.color.withValues(alpha: isDark ? 0.16 : 0.09)
                          : isQualified
                              ? role.color
                                  .withValues(alpha: isDark ? 0.09 : 0.04)
                              : colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isPreferred
                            ? role.color
                            : isQualified
                                ? role.color.withValues(alpha: 0.55)
                                : cardUnselectedBorderColor,
                        width: isPreferred ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(role.icon, color: role.color, size: 22),
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
                                  color: secondaryTextColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (useSideBySideColumns) ...[
                          qualifiedChip,
                          const SizedBox(width: _columnSpacing),
                          favouriteChip,
                        ] else
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              qualifiedChip,
                              const SizedBox(height: 6),
                              favouriteChip,
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
