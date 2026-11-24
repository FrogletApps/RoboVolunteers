import 'package:flutter/foundation.dart' show kIsWeb;

/// Pure-Dart helpers for constructing and parsing RoboVolunteers one-time invite hyperlinks.
/// Uses `Uri` only (no `dart:html`), keeping Flutter Web Wasm, CanvasKit, Android, and iOS compatible.
class InviteLinkUtils {
  static const String defaultAppBaseUrl = String.fromEnvironment(
    'APP_BASE_URL',
    defaultValue: 'https://robovolunteers.link',
  );

  static final RegExp _safeCodePattern = RegExp(r'^[A-Z0-9_-]{3,64}$');

  static String normalizeInviteCode(String raw) {
    return raw.trim().toUpperCase();
  }

  static bool isValidInviteCodeFormat(String code) {
    return _safeCodePattern.hasMatch(normalizeInviteCode(code));
  }

  /// Resolves the canonical web origin for shareable invite links.
  /// On Flutter Web (`http`/`https`), uses the current browser origin (e.g.
  /// `https://robovolunteers.link` or `https://test.robovolunteers.link`);
  /// on native mobile or test environments, falls back to [defaultAppBaseUrl].
  static String resolveAppBaseUrl({
    Uri? currentUri,
    bool isWeb = kIsWeb,
  }) {
    if (isWeb) {
      final uri = currentUri ?? Uri.base;
      if ((uri.isScheme('https') || uri.isScheme('http')) &&
          uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.authority}';
      }
    }
    return defaultAppBaseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  /// Builds a shareable registration hyperlink that pre-fills the invite code.
  static String buildInviteUrl(
    String inviteCode, {
    String? baseUrl,
  }) {
    final cleanCode = normalizeInviteCode(inviteCode);
    final resolvedBase = (baseUrl ?? resolveAppBaseUrl())
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
    return '$resolvedBase/?invite=${Uri.encodeQueryComponent(cleanCode)}';
  }

  /// Extracts a normalized invite code from query parameters (`?invite=...` or `?code=...`)
  /// or fragment parameters (`#/?invite=...`, `#/join?invite=...`, `#invite=...`).
  static String? extractInviteCodeFromUri(Uri uri) {
    final direct =
        uri.queryParameters['invite'] ?? uri.queryParameters['code'];
    final validatedDirect = _validateCandidate(direct);
    if (validatedDirect != null) {
      return validatedDirect;
    }

    final fragment = uri.fragment.trim();
    if (fragment.isEmpty) return null;

    final queryIdx = fragment.indexOf('?');
    if (queryIdx != -1 && queryIdx < fragment.length - 1) {
      try {
        final fragParams = Uri.splitQueryString(fragment.substring(queryIdx + 1));
        final fromFrag = fragParams['invite'] ?? fragParams['code'];
        final validated = _validateCandidate(fromFrag);
        if (validated != null) return validated;
      } catch (_) {
        // Ignore malformed fragment query string
      }
    } else if (fragment.contains('=')) {
      try {
        final fragParams = Uri.splitQueryString(fragment);
        final fromFrag = fragParams['invite'] ?? fragParams['code'];
        final validated = _validateCandidate(fromFrag);
        if (validated != null) return validated;
      } catch (_) {
        // Ignore malformed fragment query string
      }
    }

    return null;
  }

  /// Inspects both [baseUri] (defaulting to [Uri.base]) and an optional
  /// platform [defaultRouteName] (e.g. `/?invite=RV-...` or `/join?invite=RV-...`).
  static String? extractInitialInviteCode({
    Uri? baseUri,
    String? defaultRouteName,
  }) {
    final fromBase = extractInviteCodeFromUri(baseUri ?? Uri.base);
    if (fromBase != null) return fromBase;

    if (defaultRouteName != null && defaultRouteName.trim().isNotEmpty) {
      final parsed = Uri.tryParse(defaultRouteName.trim());
      if (parsed != null) {
        return extractInviteCodeFromUri(parsed);
      }
    }
    return null;
  }

  /// Formats a ready-to-send volunteer invitation message containing the hyperlink and fallback code.
  static String buildShareMessage({
    required String inviteUrl,
    required String inviteCode,
    String? recipientLabel,
  }) {
    final buffer = StringBuffer();
    if (recipientLabel != null && recipientLabel.trim().isNotEmpty) {
      buffer.writeln('Hi ${recipientLabel.trim()},');
      buffer.writeln();
    }
    buffer.writeln("You've been invited to join RoboVolunteers!");
    buffer.writeln();
    buffer.writeln('Use this one-time invite link to register:');
    buffer.writeln(inviteUrl);
    buffer.writeln();
    buffer.write(
      'Or open RoboVolunteers, select "New Volunteer", and enter code: ${normalizeInviteCode(inviteCode)}',
    );
    return buffer.toString();
  }

  static String? _validateCandidate(String? raw) {
    if (raw == null) return null;
    final normalized = normalizeInviteCode(raw);
    if (normalized.isEmpty || !_safeCodePattern.hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }
}
