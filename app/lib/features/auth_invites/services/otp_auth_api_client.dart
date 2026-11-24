import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

enum AuthOtpMode {
  login('login'),
  join('join');

  final String wireValue;
  const AuthOtpMode(this.wireValue);
}

@immutable
class OtpRequestResult {
  final String message;
  final int cooldownSeconds;

  const OtpRequestResult({
    required this.message,
    required this.cooldownSeconds,
  });
}

@immutable
class OtpVerifyResult {
  final String uid;
  final String email;
  final String customToken;

  const OtpVerifyResult({
    required this.uid,
    required this.email,
    required this.customToken,
  });
}

@immutable
class AuthStatusResult {
  final String uid;
  final String email;
  final bool inviteVerified;
  final bool isAdmin;

  const AuthStatusResult({
    required this.uid,
    required this.email,
    required this.inviteVerified,
    required this.isAdmin,
  });
}

class AuthApiException implements Exception {
  final String code;
  final String message;
  final int? retryAfterSeconds;

  const AuthApiException({
    required this.code,
    required this.message,
    this.retryAfterSeconds,
  });

  @override
  String toString() => message;
}

/// Client for the RoboVolunteers Cloudflare Auth OTP Worker (`/api/auth/request-otp`
/// and `/api/auth/verify-otp`).
class OtpAuthApiClient {
  static const String defaultBaseUrl = String.fromEnvironment(
    'AUTH_WORKER_BASE_URL',
    defaultValue: 'https://roboref-volunteer-auth-otp.james-pearson.workers.dev',
  );

  final http.Client _httpClient;
  final String baseUrl;

  OtpAuthApiClient({
    http.Client? httpClient,
    this.baseUrl = defaultBaseUrl,
  }) : _httpClient = httpClient ?? http.Client();

  /// Enforces HTTPS in release builds (allowing localhost HTTP only in dev/tests).
  static void assertSecureEndpoint(Uri uri) {
    final isLocalDev = !kReleaseMode &&
        uri.isScheme('http') &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
    if (isLocalDev) return;

    if (!uri.isScheme('https')) {
      throw StateError(
        'Insecure auth endpoint rejected: must use HTTPS. Received: ${uri.scheme}',
      );
    }
  }

  Uri _buildUri(String path) {
    final trimmedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$trimmedBase$path');
    assertSecureEndpoint(uri);
    return uri;
  }

  Future<OtpRequestResult> requestOtp({
    required AuthOtpMode mode,
    required String email,
    String? inviteCode,
    String? turnstileToken,
  }) async {
    final uri = _buildUri('/api/auth/request-otp');
    final payload = <String, dynamic>{
      'mode': mode.wireValue,
      'email': email.trim().toLowerCase(),
      if (inviteCode != null && inviteCode.trim().isNotEmpty)
        'inviteCode': inviteCode.trim().toUpperCase(),
      if (turnstileToken != null && turnstileToken.trim().isNotEmpty)
        'turnstileToken': turnstileToken.trim(),
    };

    final response = await _httpClient.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );

    final data = _decodeJsonMap(response.body);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'request_otp_failed',
        message: data['message'] as String? ??
            'Unable to send verification code right now. Please try again.',
        retryAfterSeconds: data['retryAfterSeconds'] as int?,
      );
    }

    return OtpRequestResult(
      message: data['message'] as String? ??
          'Check your email for a 6-digit verification code.',
      cooldownSeconds: (data['cooldownSeconds'] as num?)?.toInt() ?? 60,
    );
  }

  Future<OtpVerifyResult> verifyOtp({
    required String email,
    required String code,
  }) async {
    final uri = _buildUri('/api/auth/verify-otp');
    final response = await _httpClient.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim().toLowerCase(),
        'code': code.trim(),
      }),
    );

    final data = _decodeJsonMap(response.body);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'verify_otp_failed',
        message: data['message'] as String? ??
            'Invalid or expired verification code.',
        retryAfterSeconds: data['retryAfterSeconds'] as int?,
      );
    }

    final customToken = data['customToken'] as String?;
    final uid = data['uid'] as String?;
    if (customToken == null ||
        customToken.isEmpty ||
        uid == null ||
        uid.isEmpty) {
      throw const AuthApiException(
        code: 'invalid_server_response',
        message: 'Authentication server returned an incomplete session response.',
      );
    }

    return OtpVerifyResult(
      uid: uid,
      email: data['email'] as String? ?? email.trim().toLowerCase(),
      customToken: customToken,
    );
  }

  /// Verifies an invitation code on the Cloudflare Worker for a federated
  /// (Google Sign-In) user and stamps `inviteVerified: true` on their Firebase UID.
  Future<void> claimInvite({
    required String idToken,
    required String inviteCode,
    String? turnstileToken,
  }) async {
    final uri = _buildUri('/api/auth/claim-invite');
    final payload = <String, dynamic>{
      'inviteCode': inviteCode.trim().toUpperCase(),
      if (turnstileToken != null && turnstileToken.trim().isNotEmpty)
        'turnstileToken': turnstileToken.trim(),
    };

    final response = await _httpClient.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${idToken.trim()}',
      },
      body: jsonEncode(payload),
    );

    final data = _decodeJsonMap(response.body);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'claim_invite_failed',
        message: data['message'] as String? ??
            'Unable to verify invitation code right now. Please try again.',
        retryAfterSeconds: data['retryAfterSeconds'] as int?,
      );
    }
  }

  /// Queries the Cloudflare Worker for the caller's verified identity and admin status.
  Future<AuthStatusResult> fetchAuthStatus({
    required String idToken,
  }) async {
    final uri = _buildUri('/api/auth/me');
    final response = await _httpClient.get(
      uri,
      headers: {
        'Authorization': 'Bearer ${idToken.trim()}',
      },
    );

    final data = _decodeJsonMap(response.body);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'auth_status_failed',
        message: data['message'] as String? ??
            'Unable to verify account permissions right now.',
        retryAfterSeconds: (data['retryAfterSeconds'] as num?)?.toInt(),
      );
    }

    return AuthStatusResult(
      uid: data['uid'] as String? ?? '',
      email: data['email'] as String? ?? '',
      inviteVerified: data['inviteVerified'] == true,
      isAdmin: data['isAdmin'] == true,
    );
  }

  Map<String, dynamic> _decodeJsonMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Fall through to empty map on non-JSON error pages
    }
    return const {};
  }
}
