import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../constants/roles.dart';

class UrlUtils {
  /// Official Global Robotics Library article explaining local event volunteer roles
  static const String volunteerRolesGuideUrl =
      VolunteerRole.roleDetailsGuideUrl;

  /// Official VEX PD+ competition certification courses (Head Referee & Judge Advisor)
  static const String certificationCourseUrl =
      'https://pd.vex.com/training/competition';

  /// Launch the Volunteer Roles guide page in the user's browser
  static Future<bool> openVolunteerRolesGuide() async {
    final uri = Uri.parse(volunteerRolesGuideUrl);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching Volunteer Roles guide URL: $e');
    }
    return false;
  }

  /// Launch the VEX competition certification course page in the user's browser
  static Future<bool> openCertificationCourse() async {
    final uri = Uri.parse(certificationCourseUrl);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching VEX certification course URL: $e');
    }
    return false;
  }

  /// Builds official VEX Events / RobotEvents web URL for an event SKU
  static String getVexEventsUrl(String sku) {
    final cleanSku = sku.trim().toUpperCase();
    return 'https://events.vex.com/events/$cleanSku';
  }

  /// Launch the official VEX Events page in the user's browser
  static Future<bool> openVexEventsPage(String sku) async {
    final urlStr = getVexEventsUrl(sku);
    final uri = Uri.parse(urlStr);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error launching VEX Events URL: $e');
    }
    return false;
  }

  /// Launch email client for public contact or forwarding relay
  static Future<bool> openEmail({
    required String recipientEmail,
    String? subject,
    String? body,
  }) async {
    final uri = Uri(
      scheme: 'mailto',
      path: recipientEmail.trim(),
      queryParameters: {
        if (subject != null && subject.isNotEmpty) 'subject': subject,
        if (body != null && body.isNotEmpty) 'body': body,
      },
    );
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri);
      }
    } catch (e) {
      debugPrint('Error launching mailto: $e');
    }
    return false;
  }

  /// Launch telephone dialer for public phone contact
  static Future<bool> openPhone(String phoneNumber) async {
    final clean = phoneNumber.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri(scheme: 'tel', path: clean);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri);
      }
    } catch (e) {
      debugPrint('Error launching tel: $e');
    }
    return false;
  }
}
