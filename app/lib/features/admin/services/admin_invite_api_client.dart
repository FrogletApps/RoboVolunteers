import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../auth_invites/services/otp_auth_api_client.dart';
import '../models/invite_code_model.dart';

/// Authenticated client for the RoboVolunteers Admin Invite Portal endpoints
/// (`/api/admin/invites` on the Cloudflare Auth Worker).
class AdminInviteApiClient {
  final http.Client _httpClient;
  final String baseUrl;

  AdminInviteApiClient({
    http.Client? httpClient,
    this.baseUrl = OtpAuthApiClient.defaultBaseUrl,
  }) : _httpClient = httpClient ?? http.Client();

  Uri _buildUri(String path) {
    final trimmedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$trimmedBase$path');
    OtpAuthApiClient.assertSecureEndpoint(uri);
    return uri;
  }

  Map<String, String> _authHeaders(String idToken, {bool jsonBody = false}) => {
        'Authorization': 'Bearer ${idToken.trim()}',
        if (jsonBody) 'Content-Type': 'application/json',
      };

  Future<List<InviteCodeModel>> listInvites({
    required String idToken,
  }) async {
    final uri = _buildUri('/api/admin/invites');
    final response = await _httpClient.get(
      uri,
      headers: _authHeaders(idToken),
    );

    final data = _decodeJsonMap(response);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'list_invites_failed',
        message: data['message'] as String? ??
            'Unable to load invitation codes right now.',
        retryAfterSeconds: (data['retryAfterSeconds'] as num?)?.toInt(),
      );
    }

    final rawList = data['invites'] as List<dynamic>? ?? const [];
    return rawList
        .whereType<Map<String, dynamic>>()
        .map(InviteCodeModel.fromJson)
        .toList();
  }

  Future<List<InviteCodeModel>> createInvites({
    required String idToken,
    String? label,
    int? expiresInDays,
    bool neverExpires = false,
    int count = 1,
  }) async {
    final uri = _buildUri('/api/admin/invites');
    final payload = <String, dynamic>{
      'count': count,
      if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
      if (neverExpires)
        'expiresInDays': null
      else if (expiresInDays != null)
        'expiresInDays': expiresInDays,
    };

    final response = await _httpClient.post(
      uri,
      headers: _authHeaders(idToken, jsonBody: true),
      body: jsonEncode(payload),
    );

    final data = _decodeJsonMap(response);
    if ((response.statusCode != 201 && response.statusCode != 200) ||
        data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'create_invite_failed',
        message: data['message'] as String? ??
            'Unable to generate invitation code right now.',
        retryAfterSeconds: (data['retryAfterSeconds'] as num?)?.toInt(),
      );
    }

    final rawList = data['invites'] as List<dynamic>?;
    if (rawList != null) {
      return rawList
          .whereType<Map<String, dynamic>>()
          .map(InviteCodeModel.fromJson)
          .toList();
    }

    final single = data['invite'] as Map<String, dynamic>?;
    if (single != null) {
      return [InviteCodeModel.fromJson(single)];
    }

    throw const AuthApiException(
      code: 'invalid_server_response',
      message: 'Server returned an incomplete invite creation response.',
    );
  }

  Future<InviteCodeModel> revokeInvite({
    required String idToken,
    required String inviteId,
  }) async {
    final uri = _buildUri(
      '/api/admin/invites/${Uri.encodeComponent(inviteId.trim())}/revoke',
    );
    final response = await _httpClient.post(
      uri,
      headers: _authHeaders(idToken, jsonBody: true),
      body: '{}',
    );

    final data = _decodeJsonMap(response);
    if (response.statusCode != 200 || data['ok'] != true) {
      throw AuthApiException(
        code: data['error'] as String? ?? 'revoke_invite_failed',
        message: data['message'] as String? ??
            'Unable to revoke invitation code right now.',
        retryAfterSeconds: (data['retryAfterSeconds'] as num?)?.toInt(),
      );
    }

    final rawInvite = data['invite'] as Map<String, dynamic>?;
    if (rawInvite == null) {
      throw const AuthApiException(
        code: 'invalid_server_response',
        message: 'Server returned an incomplete revoke response.',
      );
    }
    return InviteCodeModel.fromJson(rawInvite);
  }

  Map<String, dynamic> _decodeJsonMap(http.Response response) {
    try {
      final raw = utf8.decode(response.bodyBytes, allowMalformed: true);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Non-JSON response fallback
    }
    return const {};
  }
}
