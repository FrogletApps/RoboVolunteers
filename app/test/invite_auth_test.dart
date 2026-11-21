import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';

void main() {
  group('Passwordless 6-Digit Email OTP & Invite Gate Auth Tests', () {
    late InMemoryAuthBackend backend;
    late Map<String, String> issuedOtps;
    late Set<String> validInviteCodes;
    late int requestCountForEmail;

    AuthService buildAuthService({int maxDailyPerUser = 12}) {
      final mockClient = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        if (request.url.path == '/api/auth/request-otp') {
          final mode = body['mode'] as String;
          final email = (body['email'] as String).trim().toLowerCase();

          if (mode == 'join') {
            final code = (body['inviteCode'] as String? ?? '').toUpperCase();
            if (!validInviteCodes.contains(code)) {
              return http.Response(
                jsonEncode({
                  'ok': false,
                  'error': 'invalid_invite_code',
                  'message':
                      'Invalid invitation code. Access to RoboVolunteers is invite-only.',
                }),
                403,
              );
            }
          }

          requestCountForEmail += 1;
          if (requestCountForEmail > maxDailyPerUser) {
            return http.Response(
              jsonEncode({
                'ok': false,
                'error': 'rate_limit_user_daily',
                'message':
                    'You have reached the daily limit of $maxDailyPerUser verification emails. Please try again tomorrow.',
                'retryAfterSeconds': 3600,
              }),
              429,
            );
          }

          issuedOtps[email] = '482910';
          return http.Response(
            jsonEncode({
              'ok': true,
              'cooldownSeconds': 60,
              'message': 'Check your email for a 6-digit verification code.',
            }),
            200,
          );
        }

        if (request.url.path == '/api/auth/verify-otp') {
          final email = (body['email'] as String).trim().toLowerCase();
          final submitted = body['code'] as String;
          final expected = issuedOtps[email];
          if (expected == null || expected != submitted) {
            return http.Response(
              jsonEncode({
                'ok': false,
                'error': 'invalid_or_expired_code',
                'message': 'Invalid or expired verification code.',
              }),
              401,
            );
          }
          issuedOtps.remove(email); // Single-use OTP
          final uid = 'uid-${email.split('@').first}';
          return http.Response(
            jsonEncode({
              'ok': true,
              'uid': uid,
              'email': email,
              'customToken': 'test-token:$uid:$email',
            }),
            200,
          );
        }

        if (request.url.path == '/api/auth/claim-invite') {
          final authHeader = request.headers['authorization'] ??
              request.headers['Authorization'] ??
              '';
          if (!authHeader.startsWith('Bearer ') ||
              authHeader.substring(7).trim().isEmpty) {
            return http.Response(
              jsonEncode({
                'ok': false,
                'error': 'missing_id_token',
                'message': 'Missing Firebase authentication token.',
              }),
              401,
            );
          }
          final code = (body['inviteCode'] as String? ?? '').toUpperCase();
          if (!validInviteCodes.contains(code)) {
            return http.Response(
              jsonEncode({
                'ok': false,
                'error': 'invalid_invite_code',
                'message':
                    'Invalid invitation code. Access to RoboVolunteers is invite-only.',
              }),
              403,
            );
          }
          return http.Response(
            jsonEncode({
              'ok': true,
              'uid': backend.mockGoogleUid,
              'email': backend.mockGoogleEmail,
            }),
            200,
          );
        }

        return http.Response('Not Found', 404);
      });

      return AuthService(
        apiClient: OtpAuthApiClient(
          httpClient: mockClient,
          baseUrl: 'https://roboref.app',
        ),
        backend: backend,
      );
    }

    setUp(() {
      backend = InMemoryAuthBackend();
      issuedOtps = {};
      validInviteCodes = {'UKVEX-2026', 'VEX-REF-UK'};
      requestCountForEmail = 0;
    });

    tearDown(() {
      backend.dispose();
    });

    test('Rejects invalid invite codes on server before sending OTP', () async {
      final authService = buildAuthService();

      await expectLater(
        () => authService.requestInviteOtp(
          email: 'newref@example.co.uk',
          inviteCode: 'WRONG-CODE',
        ),
        throwsA(
          isA<AuthApiException>().having(
            (e) => e.code,
            'code',
            'invalid_invite_code',
          ),
        ),
      );
      expect(issuedOtps, isEmpty);
    });

    test(
        'Completes invite + 6-digit OTP + onboarding and strictly isolates PII from public Firestore doc',
        () async {
      final authService = buildAuthService();

      await authService.requestInviteOtp(
        email: 'Jane.Doe@example.co.uk',
        inviteCode: 'ukvex-2026',
      );

      final session = await authService.verifyOtpAndSignIn(
        email: 'Jane.Doe@example.co.uk',
        code: '482910',
      );
      expect(session.email, equals('jane.doe@example.co.uk'));
      expect(authService.currentSession, equals(session));

      final profile = await authService.completeOnboarding(
        session: session,
        name: 'Jane Doe',
        phone: '+44 7700 900888',
        qualifications: ['head_ref', 'ref'],
      );

      expect(profile.name, equals('Jane Doe'));
      expect(profile.email, equals('jane.doe@example.co.uk'));
      expect(profile.phone, equals('+44 7700 900888'));
      expect(profile.isEmailPublic, isFalse);
      expect(profile.isPhonePublic, isFalse);
      expect(profile.forwardingEnabled, isFalse);
      expect(profile.isEventPartner, isFalse);

      // Verify public Firestore payload contains ZERO PII (`email`, `phone`)
      final publicDoc = backend.getStoredPublicDoc(session.uid)!;
      expect(publicDoc.containsKey('email'), isFalse);
      expect(publicDoc.containsKey('phone'), isFalse);
      expect(publicDoc['isEmailPublic'], isFalse);
      expect(publicDoc['isPhonePublic'], isFalse);
      expect(publicDoc['forwardingEnabled'], isFalse);
      expect(publicDoc['isEventPartner'], isFalse);

      // Verify private owner-only Firestore payload holds email & phone
      final privateDoc = backend.getStoredPrivateDoc(session.uid)!;
      expect(privateDoc['email'], equals('jane.doe@example.co.uk'));
      expect(privateDoc['phone'], equals('+44 7700 900888'));
    });

    test('Surfaces 12/day per-person rate limit error from Worker', () async {
      final authService = buildAuthService(maxDailyPerUser: 12);

      for (var i = 0; i < 12; i++) {
        await authService.requestSignInOtp(email: 'alex@example.org');
      }

      await expectLater(
        () => authService.requestSignInOtp(email: 'alex@example.org'),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.code, 'code', 'rate_limit_user_daily')
              .having((e) => e.message, 'message', contains('12')),
        ),
      );
    });

    test(
        'Remembered device session automatically authenticates without re-entering OTP',
        () async {
      const rememberedSession = AuthSession(
        uid: 'uid-remembered',
        email: 'sam@example.co.uk',
      );
      const rememberedProfile = VolunteerModel(
        id: 'uid-remembered',
        name: 'Sam Referee',
        email: 'sam@example.co.uk',
        qualifications: ['head_ref'],
        forwardingAddress: 'vol-uidremem@volunteer.roboref.app',
      );

      final persistedBackend = InMemoryAuthBackend(
        initialSession: rememberedSession,
        initialProfile: rememberedProfile,
      );
      addTearDown(persistedBackend.dispose);

      final service = AuthService(
        apiClient: OtpAuthApiClient(
          httpClient: MockClient((_) async => http.Response('Unused', 500)),
        ),
        backend: persistedBackend,
      );
      final controller = AuthController(service);
      addTearDown(controller.dispose);

      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, equals(AuthGateStatus.authenticated));
      expect(controller.state.volunteer?.name, equals('Sam Referee'));

      // Explicit logout clears remembered session
      await controller.logout();
      expect(controller.state.status, equals(AuthGateStatus.unauthenticated));
      expect(persistedBackend.currentSession, isNull);
    });

    test('OtpAuthApiClient rejects cleartext non-localhost HTTP endpoints', () {
      expect(
        () => OtpAuthApiClient.assertSecureEndpoint(
          Uri.parse('http://insecure-api.roboref.app/api/auth/request-otp'),
        ),
        throwsStateError,
      );

      expect(
        () => OtpAuthApiClient.assertSecureEndpoint(
          Uri.parse('https://roboref.app/api/auth/request-otp'),
        ),
        returnsNormally,
      );
    });

    test(
        'Google Sign-In blocks uninvited accounts on Sign In and grants access after valid invite claim',
        () async {
      final authService = buildAuthService();

      // 1. Unverified Google user on Sign In tab is signed out & prompted for invite code
      await expectLater(
        () => authService.signInWithGoogle(),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.code, 'code', 'invite_required'),
        ),
      );
      expect(authService.currentSession, isNull);

      // 2. Wrong invite code on joinWithGoogle is rejected and cleans up session
      await expectLater(
        () => authService.joinWithGoogle(inviteCode: 'BAD-INVITE'),
        throwsA(
          isA<AuthApiException>()
              .having((e) => e.code, 'code', 'invalid_invite_code'),
        ),
      );
      expect(authService.currentSession, isNull);

      // 3. Valid invite code stamps inviteVerified == true and establishes session with 0 OTP emails
      final session =
          await authService.joinWithGoogle(inviteCode: 'ukvex-2026');
      expect(session.inviteVerified, isTrue);
      expect(session.email, equals('google.volunteer@example.co.uk'));
      expect(session.displayName, equals('Google Volunteer'));
      expect(issuedOtps, isEmpty);
    });

    test(
        'Maps CODE_EXCHANGE malformed response FirebaseAuthException to actionable message',
        () {
      final mapped = FirebaseAuthBackend.mapFirebaseAuthException(
        FirebaseAuthException(
          code: 'invalid-credential',
          message:
              'Remote site returned malformed reponse that cannot be parsed for google.com for CODE_EXCHANGE',
        ),
      );

      expect(mapped.code, equals('google_code_exchange_failed'));
      expect(mapped.message, contains('CODE_EXCHANGE'));
      expect(mapped.message, isNot(contains('malformed reponse')));
    });
  });
}
