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
import 'package:robovolunteers/features/volunteering/models/signup_model.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';

void main() {
  late MockClient offlineClient;

  MockClient buildMockEventsClient() {
    final now = DateTime.now();
    final fixtures = [
      {
        'id': 54101,
        'sku': 'RE-V5RC-26-9102',
        'name': 'UK VEX V5RC National Championship 2026-2027',
        'program': {'id': 1, 'code': 'V5RC'},
        'season': {'id': 204, 'name': '2026-2027'},
        'start': now.add(const Duration(days: 14)).toIso8601String(),
        'end': now.add(const Duration(days: 16)).toIso8601String(),
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
        'start': now.add(const Duration(days: 7)).toIso8601String(),
        'end': now.add(const Duration(days: 7)).toIso8601String(),
        'location': {
          'venue': 'Queen Elizabeth Olympic Park',
          'city': 'London',
          'region': 'Greater London',
          'country': 'United Kingdom',
        },
      },
      {
        'id': 54103,
        'sku': 'RE-V5RC-26-7734',
        'name': 'Midlands Autumn V5RC Regional Qualifier',
        'program': {'id': 1, 'code': 'V5RC'},
        'season': {'id': 204, 'name': '2026-2027'},
        'start': now.add(const Duration(days: 21)).toIso8601String(),
        'end': now.add(const Duration(days: 21)).toIso8601String(),
        'location': {
          'venue': 'University of Warwick Sports Hub',
          'city': 'Coventry',
          'region': 'Midlands',
          'country': 'United Kingdom',
        },
      },
      {
        'id': 54104,
        'sku': 'RE-VIQRC-26-6643',
        'name': 'Manchester North West VIQRC Scrimmage',
        'program': {'id': 41, 'code': 'VIQRC'},
        'season': {'id': 203, 'name': '2026-2027'},
        'start': now.add(const Duration(days: 28)).toIso8601String(),
        'end': now.add(const Duration(days: 28)).toIso8601String(),
        'location': {
          'venue': 'Manchester Central Convention Complex',
          'city': 'Manchester',
          'region': 'North West',
          'country': 'United Kingdom',
        },
      },
      {
        'id': 54105,
        'sku': 'RE-VEXU-26-5512',
        'name': 'UK & Ireland VEX U University Invitational',
        'program': {'id': 4, 'code': 'VEX U'},
        'season': {'id': 205, 'name': '2026-2027'},
        'start': now.add(const Duration(days: 35)).toIso8601String(),
        'end': now.add(const Duration(days: 36)).toIso8601String(),
        'location': {
          'venue': 'Imperial College London',
          'city': 'London',
          'region': 'Greater London',
          'country': 'United Kingdom',
        },
      },
    ];

    return MockClient((request) async {
      final skuFilters = request.url.queryParametersAll['sku[]'] ?? const [];
      final programFilters =
          request.url.queryParametersAll['program[]'] ?? const [];

      final matched = fixtures.where((item) {
        if (skuFilters.isNotEmpty && !skuFilters.contains(item['sku'])) {
          return false;
        }
        if (programFilters.isNotEmpty) {
          final prog = item['program'] as Map<String, dynamic>;
          final progId = prog['id'].toString();
          if (!programFilters.contains(progId)) {
            return false;
          }
        }
        return true;
      }).toList();

      return http.Response(jsonEncode({'data': matched}), 200);
    });
  }

  const alexSession = AuthSession(
    uid: 'vol-alex-turner',
    email: 'alex.turner@example.org',
  );
  const alexVolunteer = VolunteerModel(
    id: 'vol-alex-turner',
    name: 'Alex Turner',
    email: 'alex.turner@example.org',
    qualifications: ['head_ref', 'ref'],
    forwardingAddress: 'vol-alex102@volunteer.roboref.app',
  );

  setUp(() {
    offlineClient = MockClient((_) async => http.Response('Offline', 503));
  });

  test('Filter option constants organize event types and signup statuses cleanly',
      () {
    expect(
      kEventTypeFilterOptions,
      equals(['All', 'VEX V5', 'VEX IQ', 'VEX U']),
    );
    expect(
      kSignupStatusFilterOptions,
      equals(['My Events', 'Confirmed', 'Available']),
    );
  });

  test('VexEventsService filters VEX V5, VEX IQ, and combined SKU+program+query',
      () async {
    final service = VexEventsService(client: buildMockEventsClient());

    final v5Events = await service.searchUkEvents(program: 'VEX V5');
    expect(v5Events, isNotEmpty);
    expect(v5Events.every((e) => e.program == 'V5RC'), isTrue);

    final iqEvents = await service.searchUkEvents(program: 'VEX IQ');
    expect(iqEvents, isNotEmpty);
    expect(iqEvents.every((e) => e.program == 'VIQRC'), isTrue);

    final myEvents = await service.searchEventsBySkus(
      skus: {'RE-V5RC-26-9102', 'RE-VIQRC-26-8821'},
    );
    expect(
      myEvents.map((e) => e.sku).toSet(),
      equals({'RE-V5RC-26-9102', 'RE-VIQRC-26-8821'}),
    );

    final combinedProgramEvents = await service.searchEventsBySkus(
      skus: {'RE-V5RC-26-9102', 'RE-VIQRC-26-8821'},
      program: 'VEX IQ',
    );
    expect(
      combinedProgramEvents.map((e) => e.sku).toList(),
      equals(['RE-VIQRC-26-8821']),
    );
  });

  test('VexEventsService passes program IDs for VEX V5 and VEX IQ to API',
      () async {
    final requestedUris = <Uri>[];
    final mockApiClient = MockClient((request) async {
      requestedUris.add(request.url);
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 1,
              'sku': 'RE-V5RC-26-1111',
              'name': 'Test V5 Event',
              'program': {'code': 'V5RC'},
              'season': {'name': '2026-2027'},
              'start': '2026-11-01T09:00:00Z',
              'end': '2026-11-01T17:00:00Z',
            }
          ],
        }),
        200,
      );
    });

    final service = VexEventsService(client: mockApiClient);
    await service.searchUkEvents(program: 'VEX V5');
    expect(requestedUris.last.queryParametersAll['program[]'], equals(['1']));
    expect(requestedUris.last.queryParametersAll['season[]'], equals(['204']));

    await service.searchUkEvents(program: 'VEX IQ');
    expect(requestedUris.last.queryParametersAll['program[]'], equals(['41']));
    expect(requestedUris.last.queryParametersAll['season[]'], equals(['203']));
  });

  testWidgets(
      'Wide screen shows single-row filters with vertical divider, combined filters, and far-right Clear button',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final authBackend = InMemoryAuthBackend(
      initialSession: alexSession,
      initialProfile: alexVolunteer,
    );
    addTearDown(authBackend.dispose);

    final signupStore = InMemorySignupStore(
      initialSignups: [
        EventSignupModel(
          id: 'RE-V5RC-26-9102_vol-alex-turner',
          sku: 'RE-V5RC-26-9102',
          volunteerId: alexVolunteer.id,
          volunteerName: alexVolunteer.name,
          status: SignupStatus.confirmed,
          offeredRoles: const ['head_ref'],
          updatedAt: DateTime(2026, 11, 1),
        ),
        EventSignupModel(
          id: 'RE-VIQRC-26-8821_vol-alex-turner',
          sku: 'RE-VIQRC-26-8821',
          volunteerId: alexVolunteer.id,
          volunteerName: alexVolunteer.name,
          status: SignupStatus.available,
          offeredRoles: const ['ref'],
          updatedAt: DateTime(2026, 11, 1),
        ),
        EventSignupModel(
          id: 'RE-V5RC-26-7734_vol-alex-turner',
          sku: 'RE-V5RC-26-7734',
          volunteerId: alexVolunteer.id,
          volunteerName: alexVolunteer.name,
          status: SignupStatus.available,
          offeredRoles: const ['ref'],
          updatedAt: DateTime(2026, 11, 1),
        ),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        authBackendProvider.overrideWithValue(authBackend),
        otpAuthApiClientProvider.overrideWithValue(
          OtpAuthApiClient(httpClient: offlineClient),
        ),
        signupStoreProvider.overrideWithValue(signupStore),
        vexEventsServiceProvider
            .overrideWithValue(VexEventsService(client: buildMockEventsClient())),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filters_single_line_layout')), findsOneWidget);
    expect(
      find.byKey(const Key('event_filters_vertical_divider')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('clear_filters_button')), findsOneWidget);

    final group1Rect =
        tester.getRect(find.byKey(const Key('filter_group_event_types')));
    final dividerRect =
        tester.getRect(find.byKey(const Key('event_filters_vertical_divider')));
    final group2Rect =
        tester.getRect(find.byKey(const Key('filter_group_signup_status')));
    final group3Rect =
        tester.getRect(find.byKey(const Key('filter_group_clear')));

    expect(dividerRect.left, greaterThanOrEqualTo(group1Rect.right));
    expect(group2Rect.left, greaterThanOrEqualTo(dividerRect.right));
    expect(group3Rect.left, greaterThan(group2Rect.right));

    expect((group1Rect.center.dy - group2Rect.center.dy).abs(), lessThan(4));
    expect((group2Rect.center.dy - group3Rect.center.dy).abs(), lessThan(4));

    // 1. Filter by Confirmed -> only RE-V5RC-26-9102
    await tester.tap(find.widgetWithText(FilterChip, 'Confirmed'));
    await tester.pumpAndSettle();
    expect(
      find.text('UK VEX V5RC National Championship 2026-2027'),
      findsOneWidget,
    );
    expect(find.text('Midlands Autumn V5RC Regional Qualifier'), findsNothing);
    expect(find.text('London South VEX IQ Robotics Challenge'), findsNothing);

    // 2. Filter by Available -> shows both Available signups (V5 + IQ)
    await tester.tap(find.widgetWithText(FilterChip, 'Available'));
    await tester.pumpAndSettle();
    expect(
      find.text('UK VEX V5RC National Championship 2026-2027'),
      findsNothing,
    );
    expect(
      find.text('Midlands Autumn V5RC Regional Qualifier'),
      findsOneWidget,
    );
    expect(find.text('London South VEX IQ Robotics Challenge'), findsOneWidget);

    // 3. Combine VEX V5 + Available -> narrows to only Midlands Autumn V5RC Regional Qualifier
    await tester.tap(find.widgetWithText(FilterChip, 'VEX V5'));
    await tester.pumpAndSettle();
    expect(
      find.text('Midlands Autumn V5RC Regional Qualifier'),
      findsOneWidget,
    );
    expect(find.text('London South VEX IQ Robotics Challenge'), findsNothing);

    // 4. Tap Clear -> resets all filters back to showing all 5 UK events
    await tester.tap(find.byKey(const Key('clear_filters_button')));
    await tester.pumpAndSettle();
    expect(container.read(selectedProgramFilterProvider), equals('All'));
    expect(container.read(selectedSignupFilterProvider), isNull);
    expect(
      find.text('UK VEX V5RC National Championship 2026-2027'),
      findsOneWidget,
    );
    expect(find.text('London South VEX IQ Robotics Challenge'), findsOneWidget);
    expect(
      find.text('Midlands Autumn V5RC Regional Qualifier'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Narrow screen centre-aligns the three filter groups with horizontal lines between them',
      (WidgetTester tester) async {
    const screenWidth = 500.0;
    tester.view.physicalSize = const Size(screenWidth, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final authBackend = InMemoryAuthBackend(
      initialSession: alexSession,
      initialProfile: alexVolunteer,
    );
    addTearDown(authBackend.dispose);

    final container = ProviderContainer(
      overrides: [
        authBackendProvider.overrideWithValue(authBackend),
        otpAuthApiClientProvider.overrideWithValue(
          OtpAuthApiClient(httpClient: offlineClient),
        ),
        signupStoreProvider.overrideWithValue(InMemorySignupStore()),
        vexEventsServiceProvider
            .overrideWithValue(VexEventsService(client: buildMockEventsClient())),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('filters_three_line_layout')), findsOneWidget);
    expect(
      find.byKey(const Key('event_filters_vertical_divider')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('event_filters_horizontal_divider_1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('event_filters_horizontal_divider_2')),
      findsOneWidget,
    );

    final group1Row = find.descendant(
      of: find.byKey(const Key('filter_group_event_types')),
      matching: find.byType(Row),
    );
    final group2Row = find.descendant(
      of: find.byKey(const Key('filter_group_signup_status')),
      matching: find.byType(Row),
    );
    final clearButton = find.byKey(const Key('clear_filters_button'));
    final divider1 =
        find.byKey(const Key('event_filters_horizontal_divider_1'));
    final divider2 =
        find.byKey(const Key('event_filters_horizontal_divider_2'));

    final group1Center = tester.getCenter(group1Row);
    final divider1Center = tester.getCenter(divider1);
    final group2Center = tester.getCenter(group2Row);
    final divider2Center = tester.getCenter(divider2);
    final clearCenter = tester.getCenter(clearButton);

    expect(group1Center.dy, lessThan(divider1Center.dy));
    expect(divider1Center.dy, lessThan(group2Center.dy));
    expect(group2Center.dy, lessThan(divider2Center.dy));
    expect(divider2Center.dy, lessThan(clearCenter.dy));

    const midpoint = screenWidth / 2;
    expect((group1Center.dx - midpoint).abs(), lessThan(2.0));
    expect((divider1Center.dx - midpoint).abs(), lessThan(2.0));
    expect((group2Center.dx - midpoint).abs(), lessThan(2.0));
    expect((divider2Center.dx - midpoint).abs(), lessThan(2.0));
    expect((clearCenter.dx - midpoint).abs(), lessThan(2.0));
  });

  testWidgets('Signup filters show helpful empty state when user has no signups',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    const newSession = AuthSession(
      uid: 'vol-new-user',
      email: 'new@example.org',
    );
    const newUser = VolunteerModel(
      id: 'vol-new-user',
      name: 'New Volunteer',
      email: 'new@example.org',
      qualifications: ['ref'],
      forwardingAddress: 'vol-new00000@volunteer.roboref.app',
    );

    final authBackend = InMemoryAuthBackend(
      initialSession: newSession,
      initialProfile: newUser,
    );
    addTearDown(authBackend.dispose);

    final container = ProviderContainer(
      overrides: [
        authBackendProvider.overrideWithValue(authBackend),
        otpAuthApiClientProvider.overrideWithValue(
          OtpAuthApiClient(httpClient: offlineClient),
        ),
        signupStoreProvider.overrideWithValue(InMemorySignupStore()),
        vexEventsServiceProvider
            .overrideWithValue(VexEventsService(client: buildMockEventsClient())),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'My Events'));
    await tester.pumpAndSettle();
    expect(
      find.text('You are not signed up for any events yet.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilterChip, 'Confirmed'));
    await tester.pumpAndSettle();
    expect(
      find.text('You have no confirmed events yet.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilterChip, 'Available'));
    await tester.pumpAndSettle();
    expect(
      find.text('You have no events marked as Available.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'VexEventsService throws and EventsListScreen shows error message with Retry when API cannot be reached',
      (WidgetTester tester) async {
    final failingService = VexEventsService(client: offlineClient);

    await expectLater(
      () => failingService.searchUkEvents(),
      throwsA(isA<VexEventsException>()),
    );
    await expectLater(
      () => failingService.searchEventsBySkus(skus: {'RE-V5RC-26-9102'}),
      throwsA(isA<VexEventsException>()),
    );

    final authBackend = InMemoryAuthBackend(
      initialSession: alexSession,
      initialProfile: alexVolunteer,
    );
    addTearDown(authBackend.dispose);

    final container = ProviderContainer(
      overrides: [
        authBackendProvider.overrideWithValue(authBackend),
        otpAuthApiClientProvider.overrideWithValue(
          OtpAuthApiClient(httpClient: offlineClient),
        ),
        signupStoreProvider.overrideWithValue(InMemorySignupStore()),
        vexEventsServiceProvider.overrideWithValue(failingService),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const RoboVolunteersApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Error loading events: Unable to load event data from VEX Events. Please check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
    expect(
      find.text('UK VEX V5RC National Championship 2026-2027'),
      findsNothing,
    );
  });
}
