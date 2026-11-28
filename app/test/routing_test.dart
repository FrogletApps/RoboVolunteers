import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/core/routing/app_router.dart';
import 'package:robovolunteers/features/admin/screens/admin_portal_screen.dart';
import 'package:robovolunteers/features/admin/services/admin_invite_api_client.dart';
import 'package:robovolunteers/features/admin/state/admin_invites_provider.dart';
import 'package:robovolunteers/features/auth_invites/screens/login_screen.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/events/screens/events_list_screen.dart';
import 'package:robovolunteers/features/events/services/vex_events_service.dart';
import 'package:robovolunteers/features/events/state/events_provider.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/profile/screens/profile_screen.dart';
import 'package:robovolunteers/features/volunteering/models/signup_model.dart';
import 'package:robovolunteers/features/volunteering/screens/event_roster_screen.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';
import 'package:robovolunteers/main.dart';

void main() {
  group('AppRoutes & AppRouter.parseRoute', () {
    test('parses root and top-level static routes cleanly', () {
      expect(AppRouter.parseRoute('/').kind, AppRouteKind.home);
      expect(AppRouter.parseRoute('/').canonicalPath, '/');
      expect(AppRouter.parseRoute('').kind, AppRouteKind.home);
      expect(AppRouter.parseRoute(null).kind, AppRouteKind.home);
      expect(AppRouter.parseRoute('/events').kind, AppRouteKind.home);
      expect(AppRouter.parseRoute('/events/').canonicalPath, '/');

      expect(AppRouter.parseRoute('/profile').kind, AppRouteKind.profile);
      expect(AppRouter.parseRoute('/PROFILE/').canonicalPath, '/profile');

      expect(AppRouter.parseRoute('/admin').kind, AppRouteKind.admin);
      expect(AppRouter.parseRoute('/Admin/').canonicalPath, '/admin');
    });

    test('parses event roster routes with normalized SKU', () {
      final single = AppRouter.parseRoute('/event/re-v5rc-26-9102');
      expect(single.kind, AppRouteKind.eventRoster);
      expect(single.sku, 'RE-V5RC-26-9102');
      expect(single.canonicalPath, '/event/RE-V5RC-26-9102');

      final pluralAlias = AppRouter.parseRoute('/events/re-viqrc-26-8821/');
      expect(pluralAlias.kind, AppRouteKind.eventRoster);
      expect(pluralAlias.sku, 'RE-VIQRC-26-8821');
      expect(pluralAlias.canonicalPath, '/event/RE-VIQRC-26-8821');
    });

    test('extracts invite query params while normalizing canonical paths', () {
      final rootInvite = AppRouter.parseRoute('/?invite=rv-7k4m-9p2x-3n8q');
      expect(rootInvite.kind, AppRouteKind.home);
      expect(rootInvite.canonicalPath, '/');
      expect(rootInvite.inviteCode, 'RV-7K4M-9P2X-3N8Q');

      final joinInvite =
          AppRouter.parseRoute('/join?code=rv-1111-2222-3333');
      expect(joinInvite.kind, AppRouteKind.home);
      expect(joinInvite.canonicalPath, '/');
      expect(joinInvite.inviteCode, 'RV-1111-2222-3333');

      final eventInvite = AppRouter.parseRoute(
        '/event/re-v5rc-26-9102?invite=rv-aaaa-bbbb-cccc',
      );
      expect(eventInvite.kind, AppRouteKind.eventRoster);
      expect(eventInvite.sku, 'RE-V5RC-26-9102');
      expect(eventInvite.canonicalPath, '/event/RE-V5RC-26-9102');
      expect(eventInvite.inviteCode, 'RV-AAAA-BBBB-CCCC');
    });

    test('falls back to home for unknown paths or missing event SKU', () {
      expect(AppRouter.parseRoute('/does-not-exist').kind, AppRouteKind.home);
      expect(AppRouter.parseRoute('/event').kind, AppRouteKind.home);
      expect(AppRouter.parseRoute('/event/').kind, AppRouteKind.home);
      expect(AppRoutes.eventPath(''), '/');
      expect(AppRoutes.eventPath('re-v5rc-26-9102'), '/event/RE-V5RC-26-9102');
    });

    test(
        'onGenerateInitialRoutes returns single home route for / and stacked routes for deep paths',
        () {
      final rootRoutes = AppRouter.onGenerateInitialRoutes('/');
      expect(rootRoutes.length, 1);
      expect(rootRoutes.first.settings.name, '/');

      final inviteRoutes =
          AppRouter.onGenerateInitialRoutes('/?invite=RV-7K4M-9P2X-3N8Q');
      expect(inviteRoutes.length, 1);
      expect(inviteRoutes.first.settings.name, '/');

      final eventRoutes =
          AppRouter.onGenerateInitialRoutes('/event/RE-V5RC-26-9102');
      expect(eventRoutes.length, 2);
      expect(eventRoutes[0].settings.name, '/');
      expect(eventRoutes[1].settings.name, '/event/RE-V5RC-26-9102');

      final profileRoutes = AppRouter.onGenerateInitialRoutes('/profile');
      expect(profileRoutes.length, 2);
      expect(profileRoutes[0].settings.name, '/');
      expect(profileRoutes[1].settings.name, '/profile');

      final adminRoutes = AppRouter.onGenerateInitialRoutes('/admin');
      expect(adminRoutes.length, 2);
      expect(adminRoutes[0].settings.name, '/');
      expect(adminRoutes[1].settings.name, '/admin');
    });
  });

  group('AppRouter Widget & Browser URL Navigation', () {
    const adminSession = AuthSession(
      uid: 'uid-admin',
      email: 'james@robovolunteers.link',
      inviteVerified: true,
      isAdmin: true,
    );
    const adminProfile = VolunteerModel(
      id: 'uid-admin',
      name: 'James Admin',
      email: 'james@robovolunteers.link',
      qualifications: ['head_ref'],
      forwardingAddress: 'vol-uidadmin@volunteer.roboref.app',
    );

    MockClient buildMockEventsClient() {
      final fixtures = [
        {
          'id': 54101,
          'sku': 'RE-V5RC-26-9102',
          'name': 'UK VEX V5RC National Championship 2026-2027',
          'program': {'id': 1, 'code': 'V5RC'},
          'season': {'id': 204, 'name': '2026-2027'},
          'start': '2026-11-14T09:00:00Z',
          'end': '2026-11-15T17:00:00Z',
          'location': {
            'venue': 'Telford International Centre',
            'city': 'Telford',
            'region': 'Midlands',
            'country': 'United Kingdom',
          },
        },
        {
          'id': 54102,
          'sku': 'RE-VIQRC-26-8821',
          'name': 'London South VEX IQ Robotics Challenge',
          'program': {'id': 41, 'code': 'VIQRC'},
          'season': {'id': 203, 'name': '2026-2027'},
          'start': '2026-11-07T09:00:00Z',
          'end': '2026-11-07T17:00:00Z',
          'location': {
            'venue': 'Queen Elizabeth Olympic Park',
            'city': 'London',
            'region': 'Greater London',
            'country': 'United Kingdom',
          },
        },
      ];

      return MockClient((request) async {
        if (request.url.path == '/api/auth/me') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'uid': 'uid-admin',
              'email': 'james@robovolunteers.link',
              'inviteVerified': true,
              'isAdmin': true,
            }),
            200,
          );
        }
        if (request.url.path == '/api/admin/invites') {
          return http.Response(
            jsonEncode({'ok': true, 'invites': const []}),
            200,
          );
        }
        final skuFilters = request.url.queryParametersAll['sku[]'] ?? const [];
        final matched = fixtures.where((item) {
          if (skuFilters.isNotEmpty && !skuFilters.contains(item['sku'])) {
            return false;
          }
          return true;
        }).toList();
        return http.Response(jsonEncode({'data': matched}), 200);
      });
    }

    List<String> captureReportedBrowserLocations() {
      final locations = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.navigation, (call) async {
        if (call.method == 'routeInformationUpdated') {
          final args = call.arguments as Map<dynamic, dynamic>;
          final uri = args['uri'] as String?;
          final location = args['location'] as String?;
          final value = uri ?? location;
          if (value != null) {
            locations.add(value);
          }
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.navigation, null);
      });
      return locations;
    }

    testWidgets(
        'Navigating to an event, profile, admin portal, and back updates browser URL',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final reportedUrls = captureReportedBrowserLocations();
      final authBackend = InMemoryAuthBackend(
        initialSession: adminSession,
        initialProfile: adminProfile,
      );
      addTearDown(authBackend.dispose);

      final mockClient = buildMockEventsClient();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            adminInviteApiClientProvider.overrideWithValue(
              AdminInviteApiClient(httpClient: mockClient),
            ),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EventsListScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/'));

      // Tap event card -> opens EventRosterScreen and updates URL to /event/RE-V5RC-26-9102
      await tester.tap(find.text('UK VEX V5RC National Championship 2026-2027'));
      await tester.pumpAndSettle();

      expect(find.byType(EventRosterScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/event/RE-V5RC-26-9102'));

      // Back -> returns to EventsListScreen and updates URL back to /
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(EventsListScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/'));

      // Tap Profile -> updates URL to /profile
      await tester.tap(find.byKey(const Key('profile_button')));
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/profile'));

      // From Profile tap Admin Portal -> updates URL to /admin
      await tester.tap(find.byKey(const Key('profile_admin_portal_tile')));
      await tester.pumpAndSettle();

      expect(find.byType(AdminPortalScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/admin'));

      // Back to Profile -> /profile, Back to Events -> /
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(reportedUrls.last, equals('/profile'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(reportedUrls.last, equals('/'));
    });

    testWidgets(
        'Deep linking directly to /event/<SKU> loads the event by SKU and stacks Home underneath',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final reportedUrls = captureReportedBrowserLocations();
      final authBackend = InMemoryAuthBackend(
        initialSession: adminSession,
        initialProfile: adminProfile,
      );
      addTearDown(authBackend.dispose);

      final seededStore = InMemorySignupStore(
        initialSignups: [
          EventSignupModel(
            id: 'RE-V5RC-26-9102_vol-alex',
            sku: 'RE-V5RC-26-9102',
            volunteerId: 'vol-alex',
            volunteerName: 'Alex Turner',
            status: SignupStatus.confirmed,
            offeredRoles: const ['head_ref'],
            updatedAt: DateTime(2026, 11, 1),
          ),
        ],
      );

      final mockClient = buildMockEventsClient();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            signupStoreProvider.overrideWithValue(seededStore),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(
            initialRoute: '/event/re-v5rc-26-9102',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(EventRosterScreen), findsOneWidget);
      expect(
        find.text('UK VEX V5RC National Championship 2026-2027'),
        findsOneWidget,
      );
      expect(find.text('Alex Turner'), findsOneWidget);
      expect(reportedUrls.last, equals('/event/RE-V5RC-26-9102'));

      // AppBar Back button navigates cleanly to EventsListScreen at /
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(EventsListScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/'));
    });

    testWidgets(
        'Deep linking to an unknown event SKU shows Event not found with Back to Events action',
        (WidgetTester tester) async {
      final authBackend = InMemoryAuthBackend(
        initialSession: adminSession,
        initialProfile: adminProfile,
      );
      addTearDown(authBackend.dispose);

      final mockClient = buildMockEventsClient();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(
            initialRoute: '/event/RE-V5RC-99-0000',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Event not found'), findsOneWidget);
      expect(find.textContaining('RE-V5RC-99-0000'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Back to Events'));
      await tester.pumpAndSettle();

      expect(find.byType(EventsListScreen), findsOneWidget);
    });

    testWidgets(
        'Deep linking to /event/<SKU> while signed out gates behind LoginScreen and lands on event after login',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final authBackend = InMemoryAuthBackend();
      await authBackend.saveVolunteerProfile(adminSession, adminProfile);
      addTearDown(authBackend.dispose);

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/auth/request-otp') {
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
          return http.Response(
            jsonEncode({
              'ok': true,
              'uid': adminSession.uid,
              'email': adminSession.email,
              'customToken':
                  'test-token:${adminSession.uid}:${adminSession.email}',
            }),
            200,
          );
        }
        if (request.url.path == '/api/auth/me') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'uid': adminSession.uid,
              'email': adminSession.email,
              'inviteVerified': true,
              'isAdmin': true,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 54101,
                'sku': 'RE-V5RC-26-9102',
                'name': 'UK VEX V5RC National Championship 2026-2027',
                'program': {'id': 1, 'code': 'V5RC'},
                'season': {'id': 204, 'name': '2026-2027'},
                'start': '2026-11-14T09:00:00Z',
                'end': '2026-11-15T17:00:00Z',
                'location': {
                  'venue': 'Telford International Centre',
                  'city': 'Telford',
                  'region': 'Midlands',
                  'country': 'United Kingdom',
                },
              },
            ],
          }),
          200,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(
            initialRoute: '/event/RE-V5RC-26-9102',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Protected by LoginScreen before signing in
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(EventRosterScreen), findsNothing);

      // Sign in via Email OTP
      await tester.enterText(
        find.byKey(const Key('login_email_input')),
        adminSession.email,
      );
      await tester.tap(find.byKey(const Key('request_otp_button')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('otp_code_input')), '123456');
      await tester.tap(find.byKey(const Key('verify_otp_button')));
      await tester.pumpAndSettle();

      // Lands directly on the deep-linked EventRosterScreen
      expect(find.byType(EventRosterScreen), findsOneWidget);
      expect(
        find.text('UK VEX V5RC National Championship 2026-2027'),
        findsOneWidget,
      );
    });

    testWidgets(
        'Opening /?invite=<code> directly pre-fills New Volunteer invite code',
        (WidgetTester tester) async {
      final authBackend = InMemoryAuthBackend();
      addTearDown(authBackend.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient: MockClient((_) async => http.Response('', 404)),
              ),
            ),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
          ],
          child: const RoboVolunteersApp(
            initialRoute: '/?invite=RV-7K4M-9P2X-3N8Q',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final inviteInput = find.byKey(const Key('invite_code_input'));
      expect(inviteInput, findsOneWidget);
      expect(
        tester.widget<TextField>(inviteInput).controller?.text,
        equals('RV-7K4M-9P2X-3N8Q'),
      );
    });

    testWidgets('Deep linking directly to /profile works and returns to /',
        (WidgetTester tester) async {
      final reportedUrls = captureReportedBrowserLocations();
      final authBackend = InMemoryAuthBackend(
        initialSession: adminSession,
        initialProfile: adminProfile,
      );
      addTearDown(authBackend.dispose);

      final mockClient = buildMockEventsClient();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            adminInviteApiClientProvider.overrideWithValue(
              AdminInviteApiClient(httpClient: mockClient),
            ),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(initialRoute: '/profile'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/profile'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventsListScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/'));
    });

    testWidgets('Deep linking directly to /admin works and returns to /',
        (WidgetTester tester) async {
      final reportedUrls = captureReportedBrowserLocations();
      final authBackend = InMemoryAuthBackend(
        initialSession: adminSession,
        initialProfile: adminProfile,
      );
      addTearDown(authBackend.dispose);

      final mockClient = buildMockEventsClient();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider
                .overrideWithValue(OtpAuthApiClient(httpClient: mockClient)),
            adminInviteApiClientProvider.overrideWithValue(
              AdminInviteApiClient(httpClient: mockClient),
            ),
            signupStoreProvider.overrideWithValue(InMemorySignupStore()),
            vexEventsServiceProvider
                .overrideWithValue(VexEventsService(client: mockClient)),
          ],
          child: const RoboVolunteersApp(initialRoute: '/admin'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdminPortalScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/admin'));

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventsListScreen), findsOneWidget);
      expect(reportedUrls.last, equals('/'));
    });
  });
}
