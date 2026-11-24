import 'package:flutter/foundation.dart';
import '../../../core/utils/invite_link_utils.dart';

enum InviteCodeStatus {
  active('active', 'Active'),
  used('used', 'Used'),
  revoked('revoked', 'Revoked'),
  expired('expired', 'Expired');

  final String wireValue;
  final String label;

  const InviteCodeStatus(this.wireValue, this.label);

  static InviteCodeStatus fromWireValue(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'active':
        return InviteCodeStatus.active;
      case 'used':
        return InviteCodeStatus.used;
      case 'revoked':
        return InviteCodeStatus.revoked;
      case 'expired':
        return InviteCodeStatus.expired;
      default:
        return InviteCodeStatus.revoked;
    }
  }
}

@immutable
class InviteCodeModel {
  final String id;
  final String? code;
  final String codeHint;
  final String? inviteUrl;
  final String? label;
  final InviteCodeStatus status;
  final DateTime createdAt;
  final String createdByUid;
  final String createdByEmail;
  final DateTime? expiresAt;
  final DateTime? usedAt;
  final String? usedByUid;
  final String? usedByEmail;
  final DateTime? revokedAt;
  final String? revokedByUid;
  final String? revokedByEmail;

  const InviteCodeModel({
    required this.id,
    this.code,
    required this.codeHint,
    this.inviteUrl,
    this.label,
    required this.status,
    required this.createdAt,
    required this.createdByUid,
    required this.createdByEmail,
    this.expiresAt,
    this.usedAt,
    this.usedByUid,
    this.usedByEmail,
    this.revokedAt,
    this.revokedByUid,
    this.revokedByEmail,
  });

  bool get isActive => status == InviteCodeStatus.active && code != null;
  bool get isUsed => status == InviteCodeStatus.used;
  bool get isRevoked => status == InviteCodeStatus.revoked;
  bool get isExpired => status == InviteCodeStatus.expired;

  String get displayCode =>
      (code != null && code!.isNotEmpty) ? code! : codeHint;

  /// Returns a shareable registration hyperlink for active invites (or `null` if inactive).
  String? resolveInviteUrl({String? appBaseUrl}) {
    if (!isActive || code == null || code!.isEmpty) return null;
    if (appBaseUrl != null && appBaseUrl.trim().isNotEmpty) {
      return InviteLinkUtils.buildInviteUrl(code!, baseUrl: appBaseUrl);
    }
    if (inviteUrl != null && inviteUrl!.trim().isNotEmpty) {
      return inviteUrl!.trim();
    }
    return InviteLinkUtils.buildInviteUrl(code!);
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  factory InviteCodeModel.fromJson(Map<String, dynamic> json) {
    final rawCode = json['code'] as String?;
    final cleanCode =
        (rawCode != null && rawCode.trim().isNotEmpty) ? rawCode.trim() : null;
    final rawUrl = json['inviteUrl'] as String?;
    final cleanUrl =
        (rawUrl != null && rawUrl.trim().isNotEmpty) ? rawUrl.trim() : null;
    final rawLabel = json['label'] as String?;
    final cleanLabel = (rawLabel != null && rawLabel.trim().isNotEmpty)
        ? rawLabel.trim()
        : null;

    return InviteCodeModel(
      id: json['id'] as String? ?? '',
      code: cleanCode,
      codeHint: json['codeHint'] as String? ?? cleanCode ?? '••••',
      inviteUrl: cleanUrl,
      label: cleanLabel,
      status: InviteCodeStatus.fromWireValue(json['status'] as String?),
      createdAt: _parseDate(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      createdByUid: json['createdByUid'] as String? ?? '',
      createdByEmail: json['createdByEmail'] as String? ?? '',
      expiresAt: _parseDate(json['expiresAt']),
      usedAt: _parseDate(json['usedAt']),
      usedByUid: json['usedByUid'] as String?,
      usedByEmail: json['usedByEmail'] as String?,
      revokedAt: _parseDate(json['revokedAt']),
      revokedByUid: json['revokedByUid'] as String?,
      revokedByEmail: json['revokedByEmail'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'codeHint': codeHint,
        'inviteUrl': inviteUrl,
        'label': label,
        'status': status.wireValue,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'createdByUid': createdByUid,
        'createdByEmail': createdByEmail,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'usedAt': usedAt?.toUtc().toIso8601String(),
        'usedByUid': usedByUid,
        'usedByEmail': usedByEmail,
        'revokedAt': revokedAt?.toUtc().toIso8601String(),
        'revokedByUid': revokedByUid,
        'revokedByEmail': revokedByEmail,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InviteCodeModel &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          status == other.status &&
          code == other.code;

  @override
  int get hashCode => Object.hash(id, status, code);
}
