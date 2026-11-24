import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../../profile/models/volunteer_model.dart';
import 'otp_auth_api_client.dart';

@immutable
class AuthSession {
  final String uid;
  final String email;
  final String? displayName;
  final bool inviteVerified;
  final bool isAdmin;

  const AuthSession({
    required this.uid,
    required this.email,
    this.displayName,
    this.inviteVerified = true,
    this.isAdmin = false,
  });

  AuthSession copyWith({
    String? uid,
    String? email,
    String? displayName,
    bool? inviteVerified,
    bool? isAdmin,
  }) {
    return AuthSession(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      inviteVerified: inviteVerified ?? this.inviteVerified,
      isAdmin: isAdmin ?? this.isAdmin,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthSession &&
          runtimeType == other.runtimeType &&
          uid == other.uid &&
          email == other.email &&
          displayName == other.displayName &&
          inviteVerified == other.inviteVerified &&
          isAdmin == other.isAdmin;

  @override
  int get hashCode =>
      Object.hash(uid, email, displayName, inviteVerified, isAdmin);
}

@immutable
class GoogleAuthResult {
  final AuthSession session;
  final String idToken;

  const GoogleAuthResult({
    required this.session,
    required this.idToken,
  });
}

/// Abstract backend persistence & identity contract for Firebase Auth + Firestore.
abstract class AuthBackend {
  AuthSession? get currentSession;

  Stream<AuthSession?> authSessionChanges();

  Future<AuthSession> signInWithCustomToken(
    String customToken, {
    String fallbackEmail = '',
  });

  Future<GoogleAuthResult> signInWithGoogle();

  Future<AuthSession> refreshInviteClaims();

  Future<String?> getIdToken({bool forceRefresh = false});

  Future<VolunteerModel?> fetchVolunteerProfile(AuthSession session);

  Future<VolunteerModel> saveVolunteerProfile(
    AuthSession session,
    VolunteerModel volunteer,
  );

  Future<void> signOut();
}

/// Production backend backed by `FirebaseAuth` (persistent device session) and
/// `Cloud Firestore` (`volunteers/{uid}` + owner-only `volunteer_private/{uid}`).
class FirebaseAuthBackend implements AuthBackend {
  final FirebaseAuth _firebaseAuth;
  final FirebaseFirestore _firestore;
  AuthSession? _lastKnownSession;

  FirebaseAuthBackend({
    FirebaseAuth? firebaseAuth,
    FirebaseFirestore? firestore,
  })  : _firebaseAuth = firebaseAuth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  static Future<AuthSession?> _userToSessionAsync(
    User? user, {
    String fallbackEmail = '',
    bool forceRefresh = false,
  }) async {
    if (user == null) return null;
    final tokenResult = await user.getIdTokenResult(forceRefresh);
    final inviteVerified = tokenResult.claims?['inviteVerified'] == true;
    final isAdmin = tokenResult.claims?['admin'] == true;
    final cleanDisplayName = user.displayName?.trim();
    return AuthSession(
      uid: user.uid,
      email: (user.email ?? fallbackEmail).trim().toLowerCase(),
      displayName: (cleanDisplayName != null && cleanDisplayName.isNotEmpty)
          ? cleanDisplayName
          : null,
      inviteVerified: inviteVerified,
      isAdmin: isAdmin,
    );
  }

  @override
  AuthSession? get currentSession {
    final user = _firebaseAuth.currentUser;
    if (user == null) return null;
    if (_lastKnownSession != null && _lastKnownSession!.uid == user.uid) {
      return _lastKnownSession;
    }
    return AuthSession(
      uid: user.uid,
      email: (user.email ?? '').trim().toLowerCase(),
      displayName: user.displayName,
      inviteVerified: false,
    );
  }

  @override
  Stream<AuthSession?> authSessionChanges() {
    return _firebaseAuth.idTokenChanges().asyncMap((user) async {
      final session = await _userToSessionAsync(user);
      _lastKnownSession = session;
      return session;
    });
  }

  @override
  Future<AuthSession> signInWithCustomToken(
    String customToken, {
    String fallbackEmail = '',
  }) async {
    final cred = await _firebaseAuth.signInWithCustomToken(customToken);
    final session = await _userToSessionAsync(
      cred.user,
      fallbackEmail: fallbackEmail,
    );
    if (session == null) {
      throw const AuthApiException(
        code: 'firebase_signin_failed',
        message: 'Unable to establish a device session. Please try again.',
      );
    }
    _lastKnownSession = session;
    return session;
  }

  /// Maps a [FirebaseAuthException] from Google Sign-In into a user-friendly
  /// [AuthApiException], surfacing actionable guidance for `CODE_EXCHANGE` errors.
  static AuthApiException mapFirebaseAuthException(FirebaseAuthException e) {
    if (e.code == 'popup-closed-by-user' ||
        e.code == 'cancelled-popup-request' ||
        e.code == 'web-context-canceled') {
      return const AuthApiException(
        code: 'google_signin_cancelled',
        message: 'Google sign-in was cancelled.',
      );
    }
    if (e.code == 'popup-blocked') {
      return const AuthApiException(
        code: 'popup_blocked',
        message:
            'The Google sign-in popup was blocked by your browser. Please allow popups for this site and try again.',
      );
    }
    if (e.code == 'unauthorized-domain') {
      return const AuthApiException(
        code: 'unauthorized_domain',
        message:
            'This domain is not authorized for Google Sign-In in Firebase Authentication -> Settings -> Authorized domains.',
      );
    }

    final normalizedMessage = (e.message ?? '').toLowerCase();
    if (normalizedMessage.contains('code_exchange') ||
        normalizedMessage.contains('malformed reponse') ||
        normalizedMessage.contains('malformed response') ||
        normalizedMessage.contains('invalid_idp_response')) {
      debugPrint('FirebaseAuth Google CODE_EXCHANGE error [${e.code}]: ${e.message}');
      return const AuthApiException(
        code: 'google_code_exchange_failed',
        message:
            'Google Sign-In could not complete the OAuth token exchange (CODE_EXCHANGE). Please try again in a moment, check that the Web client secret in Firebase Console -> Authentication -> Sign-in method -> Google matches Google Cloud Console, or sign in with a 6-digit email code below.',
      );
    }

    return AuthApiException(
      code: e.code,
      message: e.message ?? 'Google sign-in failed. Please try again.',
    );
  }

  @override
  Future<GoogleAuthResult> signInWithGoogle() async {
    final provider = GoogleAuthProvider()
      ..addScope('email')
      ..addScope('profile')
      ..setCustomParameters(const {'prompt': 'select_account'});

    try {
      if (_firebaseAuth.currentUser != null &&
          _lastKnownSession?.inviteVerified != true) {
        await _firebaseAuth.signOut();
      }

      final UserCredential cred = kIsWeb
          ? await _firebaseAuth.signInWithPopup(provider)
          : await _firebaseAuth.signInWithProvider(provider);

      final user = cred.user;
      if (user == null) {
        throw const AuthApiException(
          code: 'google_signin_failed',
          message: 'Unable to sign in with Google right now. Please try again.',
        );
      }

      final tokenResult = await user.getIdTokenResult(false);
      final idToken = tokenResult.token ?? await user.getIdToken() ?? '';
      final inviteVerified = tokenResult.claims?['inviteVerified'] == true;
      final isAdmin = tokenResult.claims?['admin'] == true;
      final cleanDisplayName = user.displayName?.trim();

      final session = AuthSession(
        uid: user.uid,
        email: (user.email ?? '').trim().toLowerCase(),
        displayName: (cleanDisplayName != null && cleanDisplayName.isNotEmpty)
            ? cleanDisplayName
            : null,
        inviteVerified: inviteVerified,
        isAdmin: isAdmin,
      );
      _lastKnownSession = session;

      return GoogleAuthResult(session: session, idToken: idToken);
    } on FirebaseAuthException catch (e) {
      throw mapFirebaseAuthException(e);
    }
  }

  @override
  Future<AuthSession> refreshInviteClaims() async {
    final session = await _userToSessionAsync(
      _firebaseAuth.currentUser,
      forceRefresh: true,
    );
    if (session == null) {
      throw const AuthApiException(
        code: 'unauthenticated',
        message: 'Your session expired while verifying your invite code.',
      );
    }
    _lastKnownSession = session;
    return session;
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return _firebaseAuth.currentUser?.getIdToken(forceRefresh);
  }

  @override
  Future<VolunteerModel?> fetchVolunteerProfile(AuthSession session) async {
    final publicRef = _firestore.collection('volunteers').doc(session.uid);
    final privateRef =
        _firestore.collection('volunteer_private').doc(session.uid);

    final results = await Future.wait([
      publicRef.get(),
      privateRef.get(),
    ]);

    final publicSnap = results[0];
    if (!publicSnap.exists || publicSnap.data() == null) {
      return null;
    }

    final privateSnap = results[1];
    return VolunteerModel.fromFirestoreMaps(
      uid: session.uid,
      publicData: publicSnap.data()!,
      privateData: privateSnap.data(),
      fallbackEmail: session.email,
    ).withDisabledPrivacyAndEpSettings();
  }

  @override
  Future<VolunteerModel> saveVolunteerProfile(
    AuthSession session,
    VolunteerModel volunteer,
  ) async {
    final sanitized = volunteer
        .copyWith(
          id: session.uid,
          email: volunteer.email.trim().isNotEmpty
              ? volunteer.email.trim().toLowerCase()
              : session.email,
          forwardingAddress: volunteer.forwardingAddress.isNotEmpty
              ? volunteer.forwardingAddress
              : VolunteerModel.generateForwardingAddress(session.uid),
        )
        .withDisabledPrivacyAndEpSettings();

    final publicRef = _firestore.collection('volunteers').doc(session.uid);
    final privateRef =
        _firestore.collection('volunteer_private').doc(session.uid);

    final batch = _firestore.batch();
    batch.set(publicRef, sanitized.toPublicFirestoreMap());
    batch.set(privateRef, sanitized.toPrivateFirestoreMap());
    await batch.commit();

    return sanitized;
  }

  @override
  Future<void> signOut() async {
    _lastKnownSession = null;
    await _firebaseAuth.signOut();
  }
}

/// Deterministic in-memory backend for unit and widget tests (verifies exact
/// separation of `volunteers/{uid}` and `volunteer_private/{uid}` without network).
class InMemoryAuthBackend implements AuthBackend {
  AuthSession? _session;
  final Map<String, Map<String, dynamic>> _publicDocs = {};
  final Map<String, Map<String, dynamic>> _privateDocs = {};
  final StreamController<AuthSession?> _controller =
      StreamController<AuthSession?>.broadcast();

  String mockGoogleUid;
  String mockGoogleEmail;
  String? mockGoogleDisplayName;
  bool mockGoogleInviteVerified;
  bool mockGoogleIsAdmin;
  String mockGoogleIdToken;
  String mockIdToken;

  InMemoryAuthBackend({
    AuthSession? initialSession,
    VolunteerModel? initialProfile,
    this.mockGoogleUid = 'google-uid-test',
    this.mockGoogleEmail = 'google.volunteer@example.co.uk',
    this.mockGoogleDisplayName = 'Google Volunteer',
    this.mockGoogleInviteVerified = false,
    this.mockGoogleIsAdmin = false,
    this.mockGoogleIdToken = 'mock-google-firebase-id-token',
    this.mockIdToken = 'mock-firebase-id-token',
  }) : _session = initialSession {
    if (initialSession != null && initialProfile != null) {
      final sanitized = initialProfile.withDisabledPrivacyAndEpSettings();
      _publicDocs[initialSession.uid] =
          sanitized.toPublicFirestoreMap(updatedAtTimestamp: DateTime.now());
      _privateDocs[initialSession.uid] =
          sanitized.toPrivateFirestoreMap(updatedAtTimestamp: DateTime.now());
    }
  }

  Map<String, dynamic>? getStoredPublicDoc(String uid) => _publicDocs[uid];
  Map<String, dynamic>? getStoredPrivateDoc(String uid) => _privateDocs[uid];

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> authSessionChanges() async* {
    yield _session;
    yield* _controller.stream;
  }

  @override
  Future<AuthSession> signInWithCustomToken(
    String customToken, {
    String fallbackEmail = '',
  }) async {
    var uid = 'vol-${fallbackEmail.hashCode.abs()}';
    var email = fallbackEmail;
    final parts = customToken.split(':');
    if (parts.length >= 3 && parts[0] == 'test-token') {
      uid = parts[1];
      email = parts.sublist(2).join(':');
    }

    final session = AuthSession(
      uid: uid,
      email: email.trim().toLowerCase(),
      inviteVerified: true,
    );
    _session = session;
    _controller.add(session);
    return session;
  }

  @override
  Future<GoogleAuthResult> signInWithGoogle() async {
    final session = AuthSession(
      uid: mockGoogleUid,
      email: mockGoogleEmail.trim().toLowerCase(),
      displayName: mockGoogleDisplayName,
      inviteVerified: mockGoogleInviteVerified,
      isAdmin: mockGoogleIsAdmin,
    );
    _session = session;
    _controller.add(session);
    return GoogleAuthResult(session: session, idToken: mockGoogleIdToken);
  }

  @override
  Future<AuthSession> refreshInviteClaims() async {
    if (_session == null) {
      throw const AuthApiException(
        code: 'unauthenticated',
        message: 'No active session to refresh.',
      );
    }
    mockGoogleInviteVerified = true;
    final updated = _session!.copyWith(inviteVerified: true);
    _session = updated;
    _controller.add(updated);
    return updated;
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    return _session != null ? mockIdToken : null;
  }

  @override
  Future<VolunteerModel?> fetchVolunteerProfile(AuthSession session) async {
    final pub = _publicDocs[session.uid];
    if (pub == null) return null;
    final priv = _privateDocs[session.uid];
    return VolunteerModel.fromFirestoreMaps(
      uid: session.uid,
      publicData: pub,
      privateData: priv,
      fallbackEmail: session.email,
    ).withDisabledPrivacyAndEpSettings();
  }

  @override
  Future<VolunteerModel> saveVolunteerProfile(
    AuthSession session,
    VolunteerModel volunteer,
  ) async {
    final sanitized = volunteer
        .copyWith(
          id: session.uid,
          email: volunteer.email.trim().isNotEmpty
              ? volunteer.email.trim().toLowerCase()
              : session.email,
          forwardingAddress: volunteer.forwardingAddress.isNotEmpty
              ? volunteer.forwardingAddress
              : VolunteerModel.generateForwardingAddress(session.uid),
        )
        .withDisabledPrivacyAndEpSettings();

    final now = DateTime.now();
    _publicDocs[session.uid] =
        sanitized.toPublicFirestoreMap(updatedAtTimestamp: now);
    _privateDocs[session.uid] =
        sanitized.toPrivateFirestoreMap(updatedAtTimestamp: now);
    return sanitized;
  }

  @override
  Future<void> signOut() async {
    _session = null;
    _controller.add(null);
  }

  void dispose() {
    _controller.close();
  }
}

/// High-level authentication & profile orchestration service.
class AuthService {
  static final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
  static final RegExp _otpRegex = RegExp(r'^\d{6}$');

  final OtpAuthApiClient _apiClient;
  final AuthBackend _backend;

  AuthService({
    required OtpAuthApiClient apiClient,
    required AuthBackend backend,
  })  : _apiClient = apiClient,
        _backend = backend;

  AuthSession? get currentSession => _backend.currentSession;

  Stream<AuthSession?> authSessionChanges() => _backend.authSessionChanges();

  Future<VolunteerModel?> fetchCurrentVolunteerProfile(AuthSession session) {
    return _backend.fetchVolunteerProfile(session);
  }

  Future<String?> getIdToken({bool forceRefresh = false}) {
    return _backend.getIdToken(forceRefresh: forceRefresh);
  }

  /// Resolves administrator status from the Cloudflare Worker (`/api/auth/me`),
  /// gracefully falling back to [session.isAdmin] if offline or unavailable.
  Future<bool> resolveAdminStatus(AuthSession session) async {
    if (!session.inviteVerified) return false;
    try {
      final idToken = await _backend.getIdToken();
      if (idToken == null || idToken.trim().isEmpty) {
        return session.isAdmin;
      }
      final status = await _apiClient.fetchAuthStatus(idToken: idToken);
      return status.isAdmin;
    } catch (_) {
      return session.isAdmin;
    }
  }

  static String normalizeAndValidateEmail(String rawEmail) {
    final clean = rawEmail.trim().toLowerCase();
    if (clean.isEmpty || clean.length > 254 || !_emailRegex.hasMatch(clean)) {
      throw const AuthApiException(
        code: 'invalid_email',
        message: 'Please enter a valid email address.',
      );
    }
    return clean;
  }

  /// Returning Volunteer Google Sign-In: succeeds immediately if the account
  /// already carries `inviteVerified == true`; otherwise signs out and prompts
  /// for an invitation code.
  Future<AuthSession> signInWithGoogle() async {
    final google = await _backend.signInWithGoogle();
    if (!google.session.inviteVerified) {
      final accountLabel = google.session.email.isNotEmpty
          ? google.session.email
          : 'that Google account';
      await _backend.signOut();
      throw AuthApiException(
        code: 'invite_required',
        message:
            'No verified volunteer account was found for $accountLabel. Enter your invitation code under "New Volunteer" and tap Continue with Google.',
      );
    }
    return google.session;
  }

  /// New Volunteer Google Sign-In: validates the invitation code on the
  /// Cloudflare Worker before granting `inviteVerified: true` on Firebase Auth.
  Future<AuthSession> joinWithGoogle({
    required String inviteCode,
    String? turnstileToken,
  }) async {
    final cleanCode = inviteCode.trim().toUpperCase();
    if (cleanCode.isEmpty) {
      throw const AuthApiException(
        code: 'missing_invite_code',
        message: 'Please enter your invitation code first.',
      );
    }

    final google = await _backend.signInWithGoogle();
    if (google.session.inviteVerified) {
      return google.session;
    }

    try {
      await _apiClient.claimInvite(
        idToken: google.idToken,
        inviteCode: cleanCode,
        turnstileToken: turnstileToken,
      );
      return await _backend.refreshInviteClaims();
    } catch (_) {
      await _backend.signOut();
      rethrow;
    }
  }

  /// Step 1a (Returning Volunteer): Request a 6-digit OTP email.
  Future<OtpRequestResult> requestSignInOtp({
    required String email,
    String? turnstileToken,
  }) async {
    final cleanEmail = normalizeAndValidateEmail(email);
    return _apiClient.requestOtp(
      mode: AuthOtpMode.login,
      email: cleanEmail,
      turnstileToken: turnstileToken,
    );
  }

  /// Step 1b (New Volunteer): Verify invite code on the Cloudflare Worker and send a 6-digit OTP email.
  Future<OtpRequestResult> requestInviteOtp({
    required String email,
    required String inviteCode,
    String? turnstileToken,
  }) async {
    final cleanCode = inviteCode.trim().toUpperCase();
    if (cleanCode.isEmpty) {
      throw const AuthApiException(
        code: 'missing_invite_code',
        message: 'Please enter your invitation code.',
      );
    }
    final cleanEmail = normalizeAndValidateEmail(email);
    return _apiClient.requestOtp(
      mode: AuthOtpMode.join,
      email: cleanEmail,
      inviteCode: cleanCode,
      turnstileToken: turnstileToken,
    );
  }

  /// Step 2: Verify the 6-digit OTP and sign into Firebase Auth (persisting session on device).
  Future<AuthSession> verifyOtpAndSignIn({
    required String email,
    required String code,
  }) async {
    final cleanEmail = normalizeAndValidateEmail(email);
    final cleanCode = code.trim();
    if (!_otpRegex.hasMatch(cleanCode)) {
      throw const AuthApiException(
        code: 'invalid_code_format',
        message: 'Please enter the 6-digit numeric verification code.',
      );
    }

    final verified = await _apiClient.verifyOtp(
      email: cleanEmail,
      code: cleanCode,
    );

    return _backend.signInWithCustomToken(
      verified.customToken,
      fallbackEmail: verified.email,
    );
  }

  /// Step 3 (New Volunteer): Create initial `volunteers/{uid}` and `volunteer_private/{uid}` profile.
  Future<VolunteerModel> completeOnboarding({
    required AuthSession session,
    required String name,
    String? phone,
    required List<String> qualifications,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const AuthApiException(
        code: 'invalid_name',
        message: 'Please enter your full name.',
      );
    }
    if (qualifications.isEmpty) {
      throw const AuthApiException(
        code: 'missing_qualifications',
        message: 'Please select at least one qualification.',
      );
    }

    final initialProfile = VolunteerModel(
      id: session.uid,
      name: trimmedName,
      email: session.email,
      phone: phone?.trim(),
      qualifications: qualifications,
      isEmailPublic: false,
      isPhonePublic: false,
      forwardingEnabled: false,
      forwardingAddress: VolunteerModel.generateForwardingAddress(session.uid),
      isEventPartner: false,
    );

    return _backend.saveVolunteerProfile(session, initialProfile);
  }

  /// Update the authenticated volunteer's profile and private contact record.
  Future<VolunteerModel> updateProfile(VolunteerModel updated) async {
    final session = _backend.currentSession;
    if (session == null) {
      throw const AuthApiException(
        code: 'unauthenticated',
        message: 'Your session has expired. Please sign in again.',
      );
    }
    return _backend.saveVolunteerProfile(
      session,
      updated.withDisabledPrivacyAndEpSettings(),
    );
  }

  /// Sign out and clear the remembered device session.
  Future<void> logout() async {
    await _backend.signOut();
  }
}
