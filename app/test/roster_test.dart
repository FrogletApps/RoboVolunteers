import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/events/models/event_model.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/volunteering/models/signup_model.dart';
import 'package:robovolunteers/features/volunteering/screens/event_roster_screen.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';

void main() {
  group('Volunteer Repository & Roster Tests', () {
    late InMemorySignupStore store;
    late VolunteerRepository repo;

    const testVolunteer = VolunteerModel(
      id: 'vol-test-1',
      name: 'Sam Ref',
      email: 'sam@example.com',
      phone: '+44 7700 900111',
      qualifications: ['head_ref', 'ref'],
      forwardingAddress: 'vol-test1@volunteer.roboref.app',
    );

    setUp(() {
      store = InMemorySignupStore();
      repo = VolunteerRepository(store);
    });

    test(
        'Volunteer can sign up as Available then Confirmed with composite ID and zero embedded PII',
        () async {
      const sku = 'RE-V5RC-26-9102';

      final signupAvailable = await repo.saveSignup(
        sku: sku,
        volunteer: testVolunteer,
        status: SignupStatus.available,
        offeredRoles: ['head_ref', 'ref'],
        notes: 'Can referee all day',
      );

      expect(signupAvailable.id, equals('RE-V5RC-26-9102_vol-test-1'));
      expect(signupAvailable.status, equals(SignupStatus.available));
      expect(signupAvailable.epVerified, isFalse);

      // Ensure raw stored Firestore map contains NO embedded volunteer PII
      final rawDoc = store.getRawDoc('RE-V5RC-26-9102_vol-test-1')!;
      expect(rawDoc.containsKey('volunteer'), isFalse);
      expect(rawDoc.containsKey('email'), isFalse);
      expect(rawDoc.containsKey('phone'), isFalse);

      // Update to Confirmed
      final signupConfirmed = await repo.saveSignup(
        sku: sku,
        volunteer: testVolunteer,
        status: SignupStatus.confirmed,
        offeredRoles: ['head_ref'],
      );

      expect(signupConfirmed.status, equals(SignupStatus.confirmed));
      final updatedUserSignup = await repo.getUserSignupForEvent(
        sku: sku,
        volunteerId: testVolunteer.id,
      );
      expect(updatedUserSignup!.status, equals(SignupStatus.confirmed));
    });

    test('EP verification toggle is locked disabled in v1 volunteer-only mode',
        () async {
      await expectLater(
        () => repo.toggleEpVerification(signupId: 'RE-V5RC-26-9102_vol-test-1'),
        throwsUnsupportedError,
      );
    });

    test('Volunteer can pull out / withdraw from an event at any time',
        () async {
      const sku = 'RE-V5RC-26-9102';

      await repo.saveSignup(
        sku: sku,
        volunteer: testVolunteer,
        status: SignupStatus.available,
        offeredRoles: ['ref'],
      );

      var userSignup = await repo.getUserSignupForEvent(
        sku: sku,
        volunteerId: testVolunteer.id,
      );
      expect(userSignup, isNotNull);

      final withdrawn = await repo.withdrawSignup(
        sku: sku,
        volunteerId: testVolunteer.id,
      );
      expect(withdrawn, isTrue);

      userSignup = await repo.getUserSignupForEvent(
        sku: sku,
        volunteerId: testVolunteer.id,
      );
      expect(userSignup, isNull);
    });

    testWidgets(
        'Volunteer Roster displays real signups and hides all contact details',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const event = EventModel(
        id: 1,
        sku: 'RE-V5RC-26-9102',
        name: 'UK VEX V5RC National Championship 2026-2027',
        program: 'V5RC',
        season: '2026-2027',
        startDate: '2026-11-14',
        endDate: '2026-11-15',
        venue: 'Telford International Centre',
        city: 'Telford',
        region: 'Midlands',
        country: 'United Kingdom',
      );

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
          EventSignupModel(
            id: 'RE-V5RC-26-9102_vol-sarah',
            sku: 'RE-V5RC-26-9102',
            volunteerId: 'vol-sarah',
            volunteerName: 'Sarah Jenkins',
            status: SignupStatus.available,
            offeredRoles: const ['judge_advisor'],
            updatedAt: DateTime(2026, 11, 2),
          ),
        ],
      );

      final authBackend = InMemoryAuthBackend(
        initialSession: const AuthSession(
          uid: 'vol-test-1',
          email: 'sam@example.com',
        ),
        initialProfile: testVolunteer,
      );
      addTearDown(authBackend.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient:
                    MockClient((_) async => http.Response('Unused', 500)),
              ),
            ),
            signupStoreProvider.overrideWithValue(seededStore),
          ],
          child: const MaterialApp(
            home: EventRosterScreen(event: event),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alex Turner'), findsOneWidget);
      expect(find.text('Sarah Jenkins'), findsOneWidget);

      expect(find.text('+44 7700 900111'), findsNothing);
      expect(find.text('sam@example.com'), findsNothing);
      expect(find.text('Email via Relay'), findsNothing);
      expect(find.text('Private Contact'), findsNothing);
      expect(find.byIcon(Icons.phone), findsNothing);
      expect(find.byIcon(Icons.email), findsNothing);
    });
  });
}
