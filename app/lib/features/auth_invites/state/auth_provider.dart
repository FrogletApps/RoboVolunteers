import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/invite_link_utils.dart';
import '../../profile/models/volunteer_model.dart';
import '../services/auth_service.dart';
import '../services/otp_auth_api_client.dart';

enum AuthGateStatus {
  loading,
  unauthenticated,
  needsOnboarding,
  authenticated,
}

@immutable
class AuthGateState {
  final AuthGateStatus status;
  final AuthSession? session;
  final VolunteerModel? volunteer;

  const AuthGateState({
    required this.status,
    this.session,
    this.volunteer,
  });

  const AuthGateState.loading()
      : status = AuthGateStatus.loading,
        session = null,
        volunteer = null;

  const AuthGateState.unauthenticated()
      : status = AuthGateStatus.unauthenticated,
        session = null,
        volunteer = null;

  const AuthGateState.needsOnboarding(AuthSession this.session)
      : status = AuthGateStatus.needsOnboarding,
        volunteer = null;

  const AuthGateState.authenticated({
    required AuthSession this.session,
    required VolunteerModel this.volunteer,
  }) : status = AuthGateStatus.authenticated;
}

final otpAuthApiClientProvider = Provider<OtpAuthApiClient>((ref) {
  return OtpAuthApiClient();
});

final authBackendProvider = Provider<AuthBackend>((ref) {
  return FirebaseAuthBackend();
});

final authServiceProvider = Provider<AuthService>((ref) {
  final apiClient = ref.watch(otpAuthApiClientProvider);
  final backend = ref.watch(authBackendProvider);
  return AuthService(apiClient: apiClient, backend: backend);
});

class PendingInviteCodeNotifier extends Notifier<String?> {
  static String? _readDefaultRouteName() {
    try {
      return PlatformDispatcher.instance.defaultRouteName;
    } catch (_) {
      return null;
    }
  }

  @override
  String? build() {
    return InviteLinkUtils.extractInitialInviteCode(
      defaultRouteName: _readDefaultRouteName(),
    );
  }

  void setCode(String? rawCode) {
    if (rawCode == null || rawCode.trim().isEmpty) {
      state = null;
      return;
    }
    final normalized = InviteLinkUtils.normalizeInviteCode(rawCode);
    state = InviteLinkUtils.isValidInviteCodeFormat(normalized)
        ? normalized
        : null;
  }

  void clear() {
    state = null;
  }
}

final pendingInviteCodeProvider =
    NotifierProvider<PendingInviteCodeNotifier, String?>(
  PendingInviteCodeNotifier.new,
);

class AuthController extends Notifier<AuthGateState> {
  late AuthService _authService;
  StreamSubscription<AuthSession?>? _subscription;
  int _sessionGeneration = 0;

  @override
  AuthGateState build() {
    _authService = ref.watch(authServiceProvider);
    _subscription = _authService.authSessionChanges().listen(
      _handleSessionChanged,
      onError: (_) {
        if (ref.mounted) {
          state = const AuthGateState.unauthenticated();
        }
      },
    );
    ref.onDispose(() {
      ++_sessionGeneration;
      _subscription?.cancel();
      _subscription = null;
    });
    return const AuthGateState.loading();
  }

  Future<void> _handleSessionChanged(AuthSession? session) async {
    final generation = ++_sessionGeneration;
    if (session == null || !session.inviteVerified) {
      if (ref.mounted) {
        state = const AuthGateState.unauthenticated();
      }
      return;
    }

    try {
      final results = await Future.wait<Object?>([
        _authService.fetchCurrentVolunteerProfile(session),
        _authService.resolveAdminStatus(session),
      ]);
      if (!ref.mounted || generation != _sessionGeneration) return;

      final profile = results[0] as VolunteerModel?;
      final isAdmin = (results[1] as bool?) ?? session.isAdmin;
      final resolvedSession = session.copyWith(isAdmin: isAdmin);

      ref.read(pendingInviteCodeProvider.notifier).clear();

      if (profile == null) {
        state = AuthGateState.needsOnboarding(resolvedSession);
      } else {
        state = AuthGateState.authenticated(
          session: resolvedSession,
          volunteer: profile.withDisabledPrivacyAndEpSettings(),
        );
      }
    } catch (_) {
      if (!ref.mounted || generation != _sessionGeneration) return;
      final isAdmin = await _authService.resolveAdminStatus(session);
      if (!ref.mounted || generation != _sessionGeneration) return;
      state = AuthGateState.needsOnboarding(session.copyWith(isAdmin: isAdmin));
    }
  }

  Future<OtpRequestResult> requestSignInOtp({
    required String email,
    String? turnstileToken,
  }) {
    return _authService.requestSignInOtp(
      email: email,
      turnstileToken: turnstileToken,
    );
  }

  Future<OtpRequestResult> requestInviteOtp({
    required String email,
    required String inviteCode,
    String? turnstileToken,
  }) {
    return _authService.requestInviteOtp(
      email: email,
      inviteCode: inviteCode,
      turnstileToken: turnstileToken,
    );
  }

  Future<void> verifyOtpAndSignIn({
    required String email,
    required String code,
  }) async {
    final session = await _authService.verifyOtpAndSignIn(
      email: email,
      code: code,
    );
    await _handleSessionChanged(session);
  }

  Future<void> signInWithGoogle() async {
    final session = await _authService.signInWithGoogle();
    await _handleSessionChanged(session);
  }

  Future<void> joinWithGoogle({
    required String inviteCode,
    String? turnstileToken,
  }) async {
    final session = await _authService.joinWithGoogle(
      inviteCode: inviteCode,
      turnstileToken: turnstileToken,
    );
    await _handleSessionChanged(session);
  }

  Future<VolunteerModel> completeOnboarding({
    required String name,
    String? phone,
    required List<String> qualifications,
  }) async {
    final session = state.session ?? _authService.currentSession;
    if (session == null) {
      throw const AuthApiException(
        code: 'unauthenticated',
        message: 'Please verify your email before completing registration.',
      );
    }

    final saved = await _authService.completeOnboarding(
      session: session,
      name: name,
      phone: phone,
      qualifications: qualifications,
    );
    state = AuthGateState.authenticated(session: session, volunteer: saved);
    return saved;
  }

  Future<void> updateProfile(VolunteerModel updated) async {
    final saved = await _authService.updateProfile(updated);
    final session = state.session ?? _authService.currentSession;
    if (session != null) {
      state = AuthGateState.authenticated(session: session, volunteer: saved);
    }
  }

  Future<void> logout() async {
    ++_sessionGeneration;
    await _authService.logout();
    if (ref.mounted) {
      state = const AuthGateState.unauthenticated();
    }
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthGateState>(AuthController.new);

/// Reactive read-only view of the currently signed-in volunteer profile (or null).
final currentVolunteerProvider = Provider<VolunteerModel?>((ref) {
  final gate = ref.watch(authControllerProvider);
  return gate.volunteer;
});

/// Whether the currently authenticated user has administrator privileges.
final isAdminProvider = Provider<bool>((ref) {
  final gate = ref.watch(authControllerProvider);
  return gate.session?.isAdmin ?? false;
});

/// Locked off (`false`) in v1 since all users are volunteers.
final isEpModeProvider = Provider<bool>((ref) {
  return false;
});
