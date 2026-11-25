import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../../core/constants/roles.dart';

@immutable
class VolunteerModel {
  final String id;
  final String name;
  final String email;
  final String? phone;
  final List<String> qualifications;
  final List<String> preferredRoles;
  final bool isEmailPublic;
  final bool isPhonePublic;
  final bool forwardingEnabled;
  final String forwardingAddress;
  final bool isEventPartner;
  final String? certifications;

  const VolunteerModel({
    required this.id,
    required this.name,
    required this.email,
    this.phone,
    this.qualifications = const [],
    this.preferredRoles = const [],
    this.isEmailPublic = false,
    this.isPhonePublic = false,
    this.forwardingEnabled = false,
    required this.forwardingAddress,
    this.isEventPartner = false,
    this.certifications,
  });

  /// Returns a copy with all Contact Privacy, Email Forwarding, and EP Mode settings turned off.
  VolunteerModel withDisabledPrivacyAndEpSettings() {
    if (!isEmailPublic &&
        !isPhonePublic &&
        !forwardingEnabled &&
        !isEventPartner) {
      return this;
    }
    return copyWith(
      isEmailPublic: false,
      isPhonePublic: false,
      forwardingEnabled: false,
      isEventPartner: false,
    );
  }

  /// Generate a clean email forwarding alias from volunteer ID
  static String generateForwardingAddress(String id) {
    final cleanId = id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    final prefix = cleanId.length >= 8
        ? cleanId.substring(0, 8)
        : cleanId.padRight(8, '0');
    return 'vol-$prefix@volunteer.roboref.app';
  }

  bool hasQualification(String roleId) {
    return qualifications.contains(roleId);
  }

  bool prefersRole(String roleId) {
    return preferredRoles.contains(roleId);
  }

  List<VolunteerRole> get qualifiedRoles {
    return qualifications.map((q) => VolunteerRole.fromId(q)).toList();
  }

  List<VolunteerRole> get preferredRoleEnums {
    return preferredRoles.map((r) => VolunteerRole.fromId(r)).toList();
  }

  /// Returns the normalized "Favourite" roles that are also in [qualifications]
  /// (used as the pre-selected defaults when signing up for a new event).
  List<String> get defaultEventRoles {
    final qualifiedSet = qualifications.toSet();
    return preferredRoles
        .where((r) => qualifiedSet.contains(r))
        .toSet()
        .toList();
  }

  VolunteerModel copyWith({
    String? id,
    String? name,
    String? email,
    String? phone,
    List<String>? qualifications,
    List<String>? preferredRoles,
    bool? isEmailPublic,
    bool? isPhonePublic,
    bool? forwardingEnabled,
    String? forwardingAddress,
    bool? isEventPartner,
    String? certifications,
  }) {
    return VolunteerModel(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      qualifications: qualifications ?? this.qualifications,
      preferredRoles: preferredRoles ?? this.preferredRoles,
      isEmailPublic: isEmailPublic ?? this.isEmailPublic,
      isPhonePublic: isPhonePublic ?? this.isPhonePublic,
      forwardingEnabled: forwardingEnabled ?? this.forwardingEnabled,
      forwardingAddress: forwardingAddress ?? this.forwardingAddress,
      isEventPartner: isEventPartner ?? this.isEventPartner,
      certifications: certifications ?? this.certifications,
    );
  }

  /// Roster-visible Firestore document (`volunteers/{uid}`) — strictly zero PII.
  /// Matches `isValidVolunteerProfile(uid)` in `firestore.rules`.
  Map<String, dynamic> toPublicFirestoreMap({Object? updatedAtTimestamp}) {
    final cleanQualifications = qualifications.toSet().toList();
    final qualifiedSet = cleanQualifications.toSet();
    final cleanPreferredRoles = preferredRoles
        .where((r) => qualifiedSet.contains(r))
        .toSet()
        .toList();

    return {
      'id': id,
      'name': name.trim(),
      'qualifications': cleanQualifications,
      'preferredRoles': cleanPreferredRoles,
      'forwardingAddress': forwardingAddress,
      'isEmailPublic': false,
      'isPhonePublic': false,
      'forwardingEnabled': false,
      'isEventPartner': false,
      if (certifications != null) 'certifications': certifications,
      'updatedAt': updatedAtTimestamp ?? FieldValue.serverTimestamp(),
    };
  }

  /// Strictly owner-only Firestore document (`volunteer_private/{uid}`).
  /// Matches `isValidVolunteerPrivate()` in `firestore.rules`.
  Map<String, dynamic> toPrivateFirestoreMap({Object? updatedAtTimestamp}) {
    final cleanPhone = phone?.trim();
    return {
      'email': email.trim().toLowerCase(),
      'phone': (cleanPhone != null && cleanPhone.isNotEmpty) ? cleanPhone : null,
      'updatedAt': updatedAtTimestamp ?? FieldValue.serverTimestamp(),
    };
  }

  /// Reconstructs a `VolunteerModel` from `volunteers/{uid}` and optional
  /// owner-only `volunteer_private/{uid}` data.
  factory VolunteerModel.fromFirestoreMaps({
    required String uid,
    required Map<String, dynamic> publicData,
    Map<String, dynamic>? privateData,
    String fallbackEmail = '',
  }) {
    final resolvedEmail =
        (privateData?['email'] as String?)?.trim() ?? fallbackEmail;
    final resolvedPhone = privateData?['phone'] as String?;
    final parsedQualifications = (publicData['qualifications'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];
    final hasPreferredRolesField =
        publicData.containsKey('preferredRoles') &&
            publicData['preferredRoles'] != null;
    final parsedPreferredRoles = hasPreferredRolesField
        ? (publicData['preferredRoles'] as List<dynamic>)
            .map((e) => e.toString())
            .where((r) => parsedQualifications.contains(r))
            .toSet()
            .toList()
        : List<String>.from(parsedQualifications);

    return VolunteerModel(
      id: uid,
      name: publicData['name'] as String? ?? '',
      email: resolvedEmail,
      phone: (resolvedPhone != null && resolvedPhone.trim().isNotEmpty)
          ? resolvedPhone.trim()
          : null,
      qualifications: parsedQualifications,
      preferredRoles: parsedPreferredRoles,
      isEmailPublic: false,
      isPhonePublic: false,
      forwardingEnabled: false,
      forwardingAddress: publicData['forwardingAddress'] as String? ??
          generateForwardingAddress(uid),
      isEventPartner: false,
      certifications: publicData['certifications'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'qualifications': qualifications,
        'preferredRoles': preferredRoles,
        'isEmailPublic': isEmailPublic,
        'isPhonePublic': isPhonePublic,
        'forwardingEnabled': forwardingEnabled,
        'forwardingAddress': forwardingAddress,
        'isEventPartner': isEventPartner,
        'certifications': certifications,
      };

  factory VolunteerModel.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] as String? ?? 'vol-unknown';
    final parsedQualifications = (json['qualifications'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];
    final hasPreferredRoles =
        json.containsKey('preferredRoles') && json['preferredRoles'] != null;
    final parsedPreferredRoles = hasPreferredRoles
        ? (json['preferredRoles'] as List<dynamic>)
            .map((e) => e.toString())
            .toList()
        : const <String>[];

    return VolunteerModel(
      id: rawId,
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      qualifications: parsedQualifications,
      preferredRoles: parsedPreferredRoles,
      isEmailPublic: false,
      isPhonePublic: false,
      forwardingEnabled: false,
      forwardingAddress: json['forwardingAddress'] as String? ??
          generateForwardingAddress(rawId),
      isEventPartner: false,
      certifications: json['certifications'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VolunteerModel &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
