import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/core/constants/roles.dart';
import 'package:robovolunteers/core/theme/app_theme.dart';
import 'package:robovolunteers/core/utils/url_utils.dart';
import 'package:robovolunteers/features/auth_invites/screens/signup_screen.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/profile/screens/profile_screen.dart';
import 'package:robovolunteers/features/profile/widgets/role_preferences_selector.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';
import 'package:robovolunteers/features/volunteering/widgets/event_signup_dialog.dart';

void main() {
  group('Volunteer Roles Catalog & Guide URL (Issue #14)', () {
    test('Includes all 12 official local event roles including Emcee', () {
      final roleIds = VolunteerRole.values.map((r) => r.id).toList();
      expect(
        roleIds,
        equals([
          'head_ref',
          'ref',
          'robot_inspector',
          'judge_advisor',
          'judge',
          'tm_operator',
          'emcee',
          'field_resetter',
          'queuer',
          'pit_admin',
          'hospitality',
          'other',
        ]),
      );

      expect(VolunteerRole.fromId('emcee'), equals(VolunteerRole.emcee));
      expect(VolunteerRole.emcee.label, equals('Emcee'));
      expect(
        VolunteerRole.fromId('tm_operator'),
        equals(VolunteerRole.tmOperator),
      );
      expect(
        VolunteerRole.fromId('robot_inspector'),
        equals(VolunteerRole.robotInspector),
      );
      expect(
        UrlUtils.volunteerRolesGuideUrl,
        equals(
          'https://library.globalrobotics.org/hc/en-us/articles/51905218620820-Volunteer-Roles-at-a-Local-Event',
        ),
      );
      expect(
        UrlUtils.certificationCourseUrl,
        equals('https://pd.vex.com/training/competition'),
      );
    });
  });

  group('VolunteerModel Qualified & Preferred Roles Serialization (Issue #25)', () {
    test(
        'Serializes preferredRoles as a subset of qualifications and preserves explicit empty list',
        () {
      const volunteer = VolunteerModel(
        id: 'vol-pref-1',
        name: 'Jordan Emcee',
        email: 'jordan@example.org',
        qualifications: ['head_ref', 'ref', 'emcee'],
        preferredRoles: ['emcee', 'queuer'], // queuer not qualified -> filtered out
        forwardingAddress: 'vol-pref1000@volunteer.roboref.app',
      );

      expect(volunteer.defaultEventRoles, equals(['emcee']));

      final publicMap = volunteer.toPublicFirestoreMap(
        updatedAtTimestamp: DateTime(2026, 11, 25),
      );
      expect(publicMap['qualifications'], equals(['head_ref', 'ref', 'emcee']));
      expect(publicMap['preferredRoles'], equals(['emcee']));

      final restored = VolunteerModel.fromFirestoreMaps(
        uid: 'vol-pref-1',
        publicData: publicMap,
        privateData: const {'email': 'jordan@example.org'},
      );
      expect(restored.qualifications, equals(['head_ref', 'ref', 'emcee']));
      expect(restored.preferredRoles, equals(['emcee']));

      // Explicit empty preferredRoles stays empty on round-trip
      final emptyPref = volunteer.copyWith(preferredRoles: const []);
      final emptyMap = emptyPref.toPublicFirestoreMap(
        updatedAtTimestamp: DateTime(2026, 11, 25),
      );
      final restoredEmpty = VolunteerModel.fromFirestoreMaps(
        uid: 'vol-pref-1',
        publicData: emptyMap,
        privateData: const {'email': 'jordan@example.org'},
      );
      expect(restoredEmpty.preferredRoles, isEmpty);
    });

    test(
        'Legacy Firestore volunteer doc without preferredRoles defaults to qualifications',
        () {
      final restored = VolunteerModel.fromFirestoreMaps(
        uid: 'vol-legacy',
        publicData: const {
          'id': 'vol-legacy',
          'name': 'Legacy Ref',
          'qualifications': ['head_ref', 'ref'],
          'forwardingAddress': 'vol-legacy00@volunteer.roboref.app',
        },
        privateData: const {'email': 'legacy@example.org'},
      );

      expect(restored.qualifications, equals(['head_ref', 'ref']));
      expect(restored.preferredRoles, equals(['head_ref', 'ref']));
    });
  });

  group('Dual Role Selectors & Event Signup Pre-Selection Widget Tests', () {
    testWidgets(
        'ProfileScreen shows all roles, guide & certification links, and aligned Qualified / Favourite columns on the right',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const session = AuthSession(
        uid: 'vol-profile-1',
        email: 'sam@example.org',
      );
      const profile = VolunteerModel(
        id: 'vol-profile-1',
        name: 'Sam Volunteer',
        email: 'sam@example.org',
        qualifications: ['head_ref', 'ref'],
        preferredRoles: ['ref'],
        forwardingAddress: 'vol-prof1000@volunteer.roboref.app',
      );

      final authBackend = InMemoryAuthBackend(
        initialSession: session,
        initialProfile: profile,
      );
      addTearDown(authBackend.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient: MockClient((_) async => http.Response('Offline', 503)),
              ),
            ),
          ],
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Guide link with requested text is rendered
      expect(find.byKey(const Key('volunteer_roles_guide_link')), findsOneWidget);
      expect(
        find.text('For details on what each role does click here', findRichText: true),
        findsOneWidget,
      );

      // Blurb uses "Favourite" with the original "Roles you prefer..." text,
      // does not contain "I want to do this", and includes the certification reminder link
      expect(find.textContaining('I want to do this'), findsNothing);
      expect(
        find.text(
          '• Favourite: Roles you prefer — these will be pre-selected by default for each event.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('certification_course_link')), findsOneWidget);
      expect(
        find.text(
          'Remember for Head Referee and Judge Advisor you must be qualified by doing the certification course found here: https://pd.vex.com/training/competition',
          findRichText: true,
        ),
        findsOneWidget,
      );

      // New roles including Emcee are rendered, while Other is per-event only
      expect(find.text('Emcee'), findsOneWidget);
      expect(find.text('Robot Inspector'), findsOneWidget);
      expect(find.text('Tournament Manager Operator'), findsOneWidget);
      expect(find.text('Field Resetter'), findsOneWidget);
      expect(find.text('Queuer'), findsOneWidget);
      expect(find.byKey(const Key('role_card_other')), findsNothing);
      expect(find.text('Other'), findsNothing);

      // Verify Qualified and Favourite sit on the right of each role element and
      // line up vertically as columns across all selectable roles
      final selectableRoles =
          VolunteerRole.values.where((r) => r != VolunteerRole.other).toList();
      final firstQualifiedRect = tester.getRect(
        find.byKey(Key('role_qualified_${selectableRoles.first.id}')),
      );
      final firstFavouriteRect = tester.getRect(
        find.byKey(Key('role_wanted_${selectableRoles.first.id}')),
      );
      expect(firstFavouriteRect.left, greaterThan(firstQualifiedRect.right));

      for (final role in selectableRoles) {
        final labelRect = tester.getRect(find.text(role.label));
        final qualifiedRect =
            tester.getRect(find.byKey(Key('role_qualified_${role.id}')));
        final favouriteRect =
            tester.getRect(find.byKey(Key('role_wanted_${role.id}')));

        // Both columns are to the right of the role label
        expect(qualifiedRect.left, greaterThan(labelRect.right));
        expect(favouriteRect.left, greaterThan(qualifiedRect.right));

        // Columns align horizontally across every role card
        expect(qualifiedRect.left, closeTo(firstQualifiedRect.left, 0.5));
        expect(qualifiedRect.right, closeTo(firstQualifiedRect.right, 0.5));
        expect(favouriteRect.left, closeTo(firstFavouriteRect.left, 0.5));
        expect(favouriteRect.right, closeTo(firstFavouriteRect.right, 0.5));
      }

      // Selecting "Favourite" on Emcee also selects "Qualified" on Emcee
      final emceeWantedChip = find.byKey(const Key('role_wanted_emcee'));
      await tester.ensureVisible(emceeWantedChip);
      await tester.tap(emceeWantedChip);
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(find.byKey(const Key('role_qualified_emcee'))).selected,
        isTrue,
      );
      expect(
        tester.widget<FilterChip>(emceeWantedChip).selected,
        isTrue,
      );

      // Deselecting "Qualified" on ref also deselects "Favourite" on ref
      final refQualifiedChip = find.byKey(const Key('role_qualified_ref'));
      await tester.ensureVisible(refQualifiedChip);
      await tester.tap(refQualifiedChip);
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(refQualifiedChip).selected,
        isFalse,
      );
      expect(
        tester.widget<FilterChip>(find.byKey(const Key('role_wanted_ref'))).selected,
        isFalse,
      );

      // Save profile and verify stored Firestore document
      final saveBtn = find.widgetWithText(ElevatedButton, 'Save Profile & Settings');
      await tester.ensureVisible(saveBtn);
      await tester.tap(saveBtn);
      await tester.pumpAndSettle();

      final savedDoc = authBackend.getStoredPublicDoc('vol-profile-1')!;
      expect(
        (savedDoc['qualifications'] as List).toSet(),
        equals({'head_ref', 'emcee'}),
      );
      expect(
        (savedDoc['preferredRoles'] as List).toSet(),
        equals({'emcee'}),
      );
    });

    testWidgets(
        'ProfileScreen role columns render without overflow on narrow mobile screens',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const session = AuthSession(
        uid: 'vol-mobile-1',
        email: 'mobile@example.org',
      );
      const profile = VolunteerModel(
        id: 'vol-mobile-1',
        name: 'Mobile Volunteer',
        email: 'mobile@example.org',
        qualifications: ['head_ref'],
        preferredRoles: ['head_ref'],
        forwardingAddress: 'vol-mob1000@volunteer.roboref.app',
      );

      final authBackend = InMemoryAuthBackend(
        initialSession: session,
        initialProfile: profile,
      );
      addTearDown(authBackend.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient: MockClient((_) async => http.Response('Offline', 503)),
              ),
            ),
          ],
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(find.byKey(const Key('role_qualified_head_ref'))).selected,
        isTrue,
      );
      final headRefQ = tester.getRect(find.byKey(const Key('role_qualified_head_ref')));
      final emceeQ = tester.getRect(find.byKey(const Key('role_qualified_emcee')));
      final headRefFav = tester.getRect(find.byKey(const Key('role_wanted_head_ref')));
      final emceeFav = tester.getRect(find.byKey(const Key('role_wanted_emcee')));
      expect(headRefQ.left, closeTo(emceeQ.left, 0.5));
      expect(headRefFav.left, closeTo(emceeFav.left, 0.5));
    });

    testWidgets(
        'RolePreferencesSelector certification course link invokes callback on tap',
        (WidgetTester tester) async {
      var openedCertification = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RolePreferencesSelector(
                qualifications: const {'head_ref'},
                preferredRoles: const {'head_ref'},
                onQualificationChanged: (_, __) {},
                onPreferredChanged: (_, __) {},
                onOpenCertificationCourse: () => openedCertification = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('certification_course_link')));
      await tester.pumpAndSettle();

      expect(openedCertification, isTrue);
    });

    testWidgets(
        'RolePreferencesSelector blurb text uses high-contrast light color in dark theme',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: RolePreferencesSelector(
                qualifications: const {'head_ref'},
                preferredRoles: const {'head_ref'},
                onQualificationChanged: (_, __) {},
                onPreferredChanged: (_, __) {},
              ),
            ),
          ),
        ),
      );

      final qualifiedBlurb = tester.widget<Text>(
        find.text(
          '• Qualified: Roles you are qualified or experienced to fill on your profile.',
        ),
      );
      final favouriteBlurb = tester.widget<Text>(
        find.text(
          '• Favourite: Roles you prefer — these will be pre-selected by default for each event.',
        ),
      );

      expect(qualifiedBlurb.style?.color?.computeLuminance(), greaterThan(0.5));
      expect(favouriteBlurb.style?.color?.computeLuminance(), greaterThan(0.5));
    });

    testWidgets(
        'EventSignupDialog offers all roles as options, pre-selects preferred roles, and does not show "Favourite" or "I want to do this"',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const session = AuthSession(
        uid: 'vol-event-1',
        email: 'casey@example.org',
      );
      const profile = VolunteerModel(
        id: 'vol-event-1',
        name: 'Casey Official',
        email: 'casey@example.org',
        qualifications: ['head_ref', 'ref', 'emcee', 'queuer'],
        preferredRoles: ['emcee'],
        forwardingAddress: 'vol-casey000@volunteer.roboref.app',
      );

      final authBackend = InMemoryAuthBackend(
        initialSession: session,
        initialProfile: profile,
      );
      addTearDown(authBackend.dispose);

      final signupStore = InMemorySignupStore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient: MockClient((_) async => http.Response('Offline', 503)),
              ),
            ),
            signupStoreProvider.overrideWithValue(signupStore),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: EventSignupDialog(
                sku: 'RE-V5RC-26-9102',
                eventName: 'UK VEX National Championship',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Guide link appears inside the signup dialog
      expect(
        find.text('For details on what each role does click here', findRichText: true),
        findsOneWidget,
      );

      // "I want to do this" and "Favourite" do not appear anywhere in the event signup dialog
      expect(find.textContaining('I want to do this'), findsNothing);
      expect(find.textContaining('Favourite'), findsNothing);

      // Every official role (including all new roles & Other) is offered as an option
      for (final role in VolunteerRole.values) {
        expect(
          find.byKey(Key('event_signup_role_${role.id}')),
          findsOneWidget,
          reason: 'Expected ${role.id} to be offered in EventSignupDialog',
        );
      }

      // ONLY preferred role (emcee) is pre-selected by default
      for (final role in VolunteerRole.values) {
        final tile = tester.widget<CheckboxListTile>(
          find.byKey(Key('event_signup_role_${role.id}')),
        );
        expect(
          tile.value,
          equals(role == VolunteerRole.emcee),
          reason: 'Unexpected initial selection state for ${role.id}',
        );
      }

      // Volunteer can select a new role not previously in profile qualifications
      final robotInspectorTile =
          find.byKey(const Key('event_signup_role_robot_inspector'));
      await tester.ensureVisible(robotInspectorTile);
      await tester.tap(robotInspectorTile);
      await tester.pumpAndSettle();

      // Submitting saves both the pre-selected role and newly selected role cleanly
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up as Volunteer'));
      await tester.pumpAndSettle();

      final saved = await signupStore.getUserSignupForEvent(
        cleanSku: 'RE-V5RC-26-9102',
        volunteerId: 'vol-event-1',
      );
      expect(saved, isNotNull);
      expect(saved!.offeredRoles.toSet(), equals({'emcee', 'robot_inspector'}));
    });

    testWidgets(
        'SignupScreen onboarding saves both Qualified and Favourite preferences',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const session = AuthSession(
        uid: 'vol-onboard-1',
        email: 'newvol@example.org',
      );
      final authBackend = InMemoryAuthBackend(initialSession: session);
      addTearDown(authBackend.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authBackendProvider.overrideWithValue(authBackend),
            otpAuthApiClientProvider.overrideWithValue(
              OtpAuthApiClient(
                httpClient: MockClient((_) async => http.Response('Offline', 503)),
              ),
            ),
          ],
          child: const MaterialApp(
            home: SignupScreen(
              verifiedEmail: 'newvol@example.org',
              initialName: 'Taylor Queue',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Add Queuer as Qualified only, and Emcee as both Qualified + I want to do this
      final queuerQualified = find.byKey(const Key('role_qualified_queuer'));
      await tester.ensureVisible(queuerQualified);
      await tester.tap(queuerQualified);
      await tester.pumpAndSettle();

      final emceeWanted = find.byKey(const Key('role_wanted_emcee'));
      await tester.ensureVisible(emceeWanted);
      await tester.tap(emceeWanted);
      await tester.pumpAndSettle();

      // Uncheck "I want to do this" on head_ref (remains Qualified)
      final headRefWanted = find.byKey(const Key('role_wanted_head_ref'));
      await tester.ensureVisible(headRefWanted);
      await tester.tap(headRefWanted);
      await tester.pumpAndSettle();

      final submitBtn = find.byKey(const Key('complete_onboarding_button'));
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn);
      await tester.pumpAndSettle();

      final savedDoc = authBackend.getStoredPublicDoc('vol-onboard-1')!;
      expect(
        (savedDoc['qualifications'] as List).toSet(),
        equals({'head_ref', 'ref', 'queuer', 'emcee'}),
      );
      expect(
        (savedDoc['preferredRoles'] as List).toSet(),
        equals({'ref', 'emcee'}),
      );
    });
  });
}
