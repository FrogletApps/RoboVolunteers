import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/url_utils.dart';

/// Clickable link to the Global Robotics Library guide explaining each local event volunteer role.
class RoleDetailsLink extends StatelessWidget {
  final VoidCallback? onTap;

  const RoleDetailsLink({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: UrlUtils.volunteerRolesGuideUrl,
      child: InkWell(
        key: const Key('volunteer_roles_guide_link'),
        onTap: onTap ?? () => UrlUtils.openVolunteerRolesGuide(),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.info_outline,
                size: 15,
                color: AppTheme.brandGreen,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    text: 'For details on what each role does ',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[700],
                    ),
                    children: const [
                      TextSpan(
                        text: 'click here',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppTheme.brandGreen,
                          decoration: TextDecoration.underline,
                          decorationColor: AppTheme.brandGreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.open_in_new,
                size: 13,
                color: AppTheme.brandGreen,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
