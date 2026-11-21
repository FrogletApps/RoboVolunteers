import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/main.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/events/services/vex_events_service.dart';
import 'package:robovolunteers/features/events/state/events_provider.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';

void main() {
  MockClient buildMockOtpApi({required Map<String, String> otpStore}) {
    return MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/api/auth/request-otp') {
        final mode = body['mode'] as String;
        final email = (body['email'] as String).trim().toLowerCase();
        if (mode == 'join' && body['inviteCode'] != 'UKVEX-2026') {
          return http.Response(
            jsonEncode({
              'ok': false,
              'error': 'invalid_invite_code',
              'message': 'Invalid invitation code.',
            }),
            403,
          );
        }
        otpStore[email] = '123456';
        return http.Response(
          jsonEncode({
            'ok': true,
            'cooldownSeconds': 60,
            'message': '6-digit verification code sent.',
          }),
          200,
        );
      }

      if (request.url.path == '/api/auth/verify-otp') {
        final email = (body['email'] as String).trim().toLowerCase();
        final code = body['code'] as String;
        if (otpStore[email] != code) {
          return http.Response(
            jsonEncode({
              'ok': false,
              'error': 'invalid_or_expired_code',
              'message': 'Invalid verification code.',
            }),
            401,
          );
        }
        otpStore.remove(email);
        final uid = email == 'alex.turner@example.org'
            ? 'vol-alex-turner'
            : 'vol-new-user';
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
        if (body['inviteCode'] != 'UKVEX-2026') {
          return http.Response(
            jsonEncode({
              'ok': false,
              'error': 'invalid_invite_code',
              'message': 'Invalid invitation code.',
            }),
            403,
          );
        }
        return http.Response(
          jsonEncode({
            'ok': true,
            'uid': 'google-uid-test',
            'email': 'google.volunteer@example.co.uk',
          }),
          200,
        );
      }

      return http.Response('Not Found', 404);
    });
  }

  testWidgets(
      'App renders passwordless LoginScreen with Sign In / New Volunteer toggle and zero demo credentials',
      (WidgetTester tester) async {
    final authBackend = InMemoryAuthBackend();
    addTearDown(authBackend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authBackendProvider.overrideWithValue(authBackend),
          otpAuthApiClientProvider.overrideWithValue(
            OtpAuthApiClient(httpClient: buildMockOtpApi(otpStore: {})),
          ),
          signupStoreProvider.overrideWithValue(InMemorySignupStore()),
        ],
        child: const RoboVolunteersApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('RoboVolunteers'), findsOneWidget);
    expect(find.byKey(const Key('auth_mode_selector')), findsOneWidget);
    expect(find.byKey(const Key('google_signin_button')), findsOneWidget);
    expect(find.byKey(const Key('login_email_input')), findsOneWidget);
    expect(find.byKey(const Key('request_otp_button')), findsOneWidget);

    // Ensure legacy password field and demo quick-fill chips are completely removed
    expect(find.byKey(const Key('login_password_input')), findsNothing);
    expect(find.textContaining('Demo Quick Fill'), findsNothing);
  });

  testWidgets(
      'Returning volunteer signs in with 6-digit Email OTP, views profile, and logs out; new volunteer completes invite + OTP + onboarding',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final otpStore = <String, String>{};
    final offlineEventsClient =
        MockClient((_) async => http.Response('Offline', 503));

    // Seed existing profile for returning volunteer Alex (with no active session yet)
    const alexSession = AuthSession(
      uid: 'vol-alex-turner',
      email: 'alex.turner@example.org',
    );
    const alexProfile = VolunteerModel(
      id: 'vol-alex-turner',
      name: 'Alex Turner',
      email: 'alex.turner@example.org',
      qualifications: ['head_ref', 'ref'],
      forwardingAddress: 'vol-alex102@volunteer.roboref.app',
    );
    final authBackend = InMemoryAuthBackend();
    await authBackend.saveVolunteerProfile(alexSession, alexProfile);
    addTearDown(authBackend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authBackendProvider.overrideWithValue(authBackend),
          otpAuthApiClientProvider.overrideWithValue(
            OtpAuthApiClient(httpClient: buildMockOtpApi(otpStore: otpStore)),
          ),
          signupStoreProvider.overrideWithValue(InMemorySignupStore()),
          vexEventsServiceProvider.overrideWithValue(
            VexEventsService(client: offlineEventsClient),
          ),
        ],
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Returning volunteer requests 6-digit OTP
    await tester.enterText(
      find.byKey(const Key('login_email_input')),
      'alex.turner@example.org',
    );
    await tester.tap(find.byKey(const Key('request_otp_button')));
    await tester.pumpAndSettle();

    // 2. Enter 6-digit code and sign in
    expect(find.byKey(const Key('otp_code_input')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('otp_code_input')), '123456');
    await tester.tap(find.byKey(const Key('verify_otp_button')));
    await tester.pumpAndSettle();

    // Verify user is inside EventsListScreen
    expect(
      find.widgetWithText(AppBar, 'RoboVolunteers'),
      findsOneWidget,
    );

    final profileButton = find.byKey(const Key('profile_button'));
    final logoutButton = find.byKey(const Key('logout_button'));
    expect(profileButton, findsOneWidget);
    expect(logoutButton, findsOneWidget);

    // Open ProfileScreen and verify all 4 privacy/EP switches are off and disabled
    await tester.tap(profileButton);
    await tester.pumpAndSettle();

    expect(find.text('Volunteer Profile'), findsOneWidget);
    expect(find.text('Alex Turner'), findsWidgets);
    expect(find.text('vol-alex102@volunteer.roboref.app'), findsOneWidget);

    final profileSwitches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(profileSwitches.length, equals(4));
    for (final tile in profileSwitches) {
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
    }

    // Return and log out
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(logoutButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log Out'));
    await tester.pumpAndSettle();

    // Returned to LoginScreen
    expect(find.byKey(const Key('auth_mode_selector')), findsOneWidget);

    // 3. New volunteer switches to "New Volunteer", enters Invite Code + Email + OTP
    await tester.tap(find.text('New Volunteer'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite_code_input')),
      'UKVEX-2026',
    );
    await tester.enterText(
      find.byKey(const Key('login_email_input')),
      'new.ref@example.co.uk',
    );
    await tester.tap(find.byKey(const Key('request_otp_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('otp_code_input')), '123456');
    await tester.tap(find.byKey(const Key('verify_otp_button')));
    await tester.pumpAndSettle();

    // Routed automatically to passwordless Volunteer Registration onboarding
    expect(find.text('Volunteer Registration'), findsOneWidget);
    expect(
      find.text('Verified Email: new.ref@example.co.uk'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('signup_password_input')), findsNothing);

    final signupSwitches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(signupSwitches.length, equals(3));
    for (final tile in signupSwitches) {
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
    }

    await tester.enterText(
      find.byKey(const Key('signup_name_input')),
      'New Referee',
    );
    await tester.ensureVisible(
      find.byKey(const Key('complete_onboarding_button')),
    );
    await tester.tap(find.byKey(const Key('complete_onboarding_button')));
    await tester.pumpAndSettle();

    // Onboarding complete -> EventsListScreen
    expect(
      find.widgetWithText(AppBar, 'RoboVolunteers'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Uninvited Google Sign-In switches to New Volunteer tab, then valid invite + Google pre-fills onboarding',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final authBackend = InMemoryAuthBackend(
      mockGoogleUid: 'google-uid-test',
      mockGoogleEmail: 'priya@example.co.uk',
      mockGoogleDisplayName: 'Priya Patel',
      mockGoogleInviteVerified: false,
    );
    addTearDown(authBackend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authBackendProvider.overrideWithValue(authBackend),
          otpAuthApiClientProvider.overrideWithValue(
            OtpAuthApiClient(httpClient: buildMockOtpApi(otpStore: {})),
          ),
          signupStoreProvider.overrideWithValue(InMemorySignupStore()),
          vexEventsServiceProvider.overrideWithValue(
            VexEventsService(
              client: MockClient((_) async => http.Response('Offline', 503)),
            ),
          ),
        ],
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tapping Continue with Google on Sign In tab without an invite redirects to New Volunteer tab
    await tester.tap(find.byKey(const Key('google_signin_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite_code_input')), findsOneWidget);

    // Enter invite code and tap Verify Invite & Continue with Google
    await tester.enterText(
      find.byKey(const Key('invite_code_input')),
      'UKVEX-2026',
    );
    await tester.tap(find.byKey(const Key('google_signin_button')));
    await tester.pumpAndSettle();

    // Routed to Volunteer Registration with Google email & displayName pre-filled
    expect(find.text('Volunteer Registration'), findsOneWidget);
    expect(find.text('Verified Email: priya@example.co.uk'), findsOneWidget);
    expect(find.text('Priya Patel'), findsOneWidget);
  });
}
