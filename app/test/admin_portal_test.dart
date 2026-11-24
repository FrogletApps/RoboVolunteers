import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:robovolunteers/core/utils/invite_link_utils.dart';
import 'package:robovolunteers/features/admin/models/invite_code_model.dart';
import 'package:robovolunteers/features/admin/screens/admin_portal_screen.dart';
import 'package:robovolunteers/features/admin/services/admin_invite_api_client.dart';
import 'package:robovolunteers/features/admin/state/admin_invites_provider.dart';
import 'package:robovolunteers/features/auth_invites/services/auth_service.dart';
import 'package:robovolunteers/features/auth_invites/services/otp_auth_api_client.dart';
import 'package:robovolunteers/features/auth_invites/state/auth_provider.dart';
import 'package:robovolunteers/features/events/services/vex_events_service.dart';
import 'package:robovolunteers/features/events/state/events_provider.dart';
import 'package:robovolunteers/features/profile/models/volunteer_model.dart';
import 'package:robovolunteers/features/volunteering/services/volunteer_repository.dart';
import 'package:robovolunteers/features/volunteering/state/volunteering_provider.dart';
import 'package:robovolunteers/main.dart';

class _TestPendingInviteCodeNotifier extends PendingInviteCodeNotifier {
  final String? _initialCode;
  _TestPendingInviteCodeNotifier(this._initialCode);

  @override
  String? build() => _initialCode;
}

http.Response _jsonResponse(Object payload, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(payload)),
    statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  group('InviteLinkUtils Tests', () {
    test('Builds clean shareable hyperlinks and extracts invite codes from all URL formats', () {
      final url = InviteLinkUtils.buildInviteUrl(
        'rv-7k4m-9p2x-3n8q',
        baseUrl: 'https://robovolunteers.link/',
      );
      expect(url, equals('https://robovolunteers.link/?invite=RV-7K4M-9P2X-3N8Q'));

      expect(
        InviteLinkUtils.extractInviteCodeFromUri(Uri.parse(url)),
        equals('RV-7K4M-9P2X-3N8Q'),
      );
      expect(
        InviteLinkUtils.extractInviteCodeFromUri(
          Uri.parse('https://robovolunteers.link/join?code=rv-abcd-efgh-jklm'),
        ),
        equals('RV-ABCD-EFGH-JKLM'),
      );
      expect(
        InviteLinkUtils.extractInviteCodeFromUri(
          Uri.parse('https://robovolunteers.link/#/?invite=RV-2222-3333-4444'),
        ),
        equals('RV-2222-3333-4444'),
      );
      expect(
        InviteLinkUtils.extractInviteCodeFromUri(
          Uri.parse('https://robovolunteers.link/#invite=RV-5555-6666-7777'),
        ),
        equals('RV-5555-6666-7777'),
      );
      expect(
        InviteLinkUtils.extractInitialInviteCode(
          baseUri: Uri.parse('https://robovolunteers.link/'),
          defaultRouteName: '/join?invite=RV-9999-8888-7777',
        ),
        equals('RV-9999-8888-7777'),
      );

      // Rejects unsafe or malformed invite params
      expect(
        InviteLinkUtils.extractInviteCodeFromUri(
          Uri.parse('https://robovolunteers.link/?invite=<script>alert(1)</script>'),
        ),
        isNull,
      );
      expect(
        InviteLinkUtils.extractInviteCodeFromUri(
          Uri.parse('https://robovolunteers.link/'),
        ),
        isNull,
      );
    });

    test('Formats ready-to-share volunteer invite message', () {
      final msg = InviteLinkUtils.buildShareMessage(
        inviteUrl: 'https://robovolunteers.link/?invite=RV-7K4M-9P2X-3N8Q',
        inviteCode: 'RV-7K4M-9P2X-3N8Q',
        recipientLabel: 'Jane Doe',
      );
      expect(msg, contains('Hi Jane Doe,'));
      expect(msg, contains('https://robovolunteers.link/?invite=RV-7K4M-9P2X-3N8Q'));
      expect(msg, contains('RV-7K4M-9P2X-3N8Q'));
    });
  });

  group('AdminInviteApiClient Unit Tests', () {
    test('Lists, generates, and revokes invites and surfaces 403 errors', () async {
      final createdPayload = {
        'id': 'inv_0001000100010001',
        'code': 'RV-AAAA-BBBB-CCCC',
        'codeHint': 'RV-AAAA-••••-••••',
        'inviteUrl': 'https://robovolunteers.link/?invite=RV-AAAA-BBBB-CCCC',
        'label': 'Test Volunteer',
        'status': 'active',
        'createdAt': '2026-11-24T10:00:00.000Z',
        'createdByUid': 'admin-1',
        'createdByEmail': 'admin@example.org',
        'expiresAt': '2026-12-24T10:00:00.000Z',
      };

      final client = AdminInviteApiClient(
        baseUrl: 'https://roboref.app',
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], equals('Bearer admin-jwt'));

          if (request.method == 'GET' && request.url.path == '/api/admin/invites') {
            return _jsonResponse({'ok': true, 'invites': [createdPayload]}, 200);
          }

          if (request.method == 'POST' && request.url.path == '/api/admin/invites') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['label'], equals('Test Volunteer'));
            expect(body['expiresInDays'], isNull);
            expect(body['count'], equals(1));
            return _jsonResponse(
              {
                'ok': true,
                'invite': createdPayload,
                'invites': [createdPayload],
              },
              201,
            );
          }

          if (request.method == 'POST' &&
              request.url.path == '/api/admin/invites/inv_0001000100010001/revoke') {
            return _jsonResponse(
              {
                'ok': true,
                'invite': {
                  ...createdPayload,
                  'code': null,
                  'inviteUrl': null,
                  'status': 'revoked',
                  'revokedAt': '2026-11-24T10:05:00.000Z',
                  'revokedByEmail': 'admin@example.org',
                },
              },
              200,
            );
          }

          return _jsonResponse(
            {
              'ok': false,
              'error': 'admin_required',
              'message': 'Administrator access is required.',
            },
            403,
          );
        }),
      );

      final listed = await client.listInvites(idToken: 'admin-jwt');
      expect(listed.length, equals(1));
      expect(listed.first.status, equals(InviteCodeStatus.active));
      expect(listed.first.code, equals('RV-AAAA-BBBB-CCCC'));

      final created = await client.createInvites(
        idToken: 'admin-jwt',
        label: 'Test Volunteer',
        neverExpires: true,
      );
      expect(created.length, equals(1));
      expect(
        created.first.resolveInviteUrl(),
        equals('https://robovolunteers.link/?invite=RV-AAAA-BBBB-CCCC'),
      );

      final revoked = await client.revokeInvite(
        idToken: 'admin-jwt',
        inviteId: 'inv_0001000100010001',
      );
      expect(revoked.status, equals(InviteCodeStatus.revoked));
      expect(revoked.code, isNull);
      expect(revoked.resolveInviteUrl(), isNull);
    });
  });

  group('Admin Portal & Invite Hyperlink Widget Tests', () {
    testWidgets(
      'Opening app with invite hyperlink auto-switches to New Volunteer mode and pre-fills invite code',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1000, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final authBackend = InMemoryAuthBackend();
        addTearDown(authBackend.dispose);

        String? submittedInviteCode;
        final mockOtpClient = MockClient((request) async {
          if (request.url.path == '/api/auth/request-otp') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            submittedInviteCode = body['inviteCode'] as String?;
            return _jsonResponse(
              {
                'ok': true,
                'cooldownSeconds': 60,
                'message': 'Invite verified! 6-digit code sent.',
              },
              200,
            );
          }
          return http.Response('Not found', 404);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authBackendProvider.overrideWithValue(authBackend),
              otpAuthApiClientProvider.overrideWithValue(
                OtpAuthApiClient(httpClient: mockOtpClient),
              ),
              signupStoreProvider.overrideWithValue(InMemorySignupStore()),
              pendingInviteCodeProvider.overrideWith(
                () => _TestPendingInviteCodeNotifier('RV-7K4M-9P2X-3N8Q'),
              ),
            ],
            child: const RoboVolunteersApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Automatically opened on "New Volunteer" tab with invite code pre-filled
        final inviteInput = find.byKey(const Key('invite_code_input'));
        expect(inviteInput, findsOneWidget);
        expect(
          tester.widget<TextField>(inviteInput).controller?.text,
          equals('RV-7K4M-9P2X-3N8Q'),
        );
        expect(find.textContaining('Invite link detected'), findsOneWidget);

        // User only needs to enter email and tap request button
        await tester.enterText(
          find.byKey(const Key('login_email_input')),
          'invited.vol@example.co.uk',
        );
        await tester.tap(find.byKey(const Key('request_otp_button')));
        await tester.pumpAndSettle();

        expect(submittedInviteCode, equals('RV-7K4M-9P2X-3N8Q'));
        expect(find.byKey(const Key('otp_code_input')), findsOneWidget);
      },
    );

    testWidgets(
      'Non-admin volunteers do not see Admin Portal buttons and are blocked from AdminPortalScreen',
      (WidgetTester tester) async {
        const regularSession = AuthSession(
          uid: 'vol-regular',
          email: 'vol@example.co.uk',
          inviteVerified: true,
          isAdmin: false,
        );
        const regularProfile = VolunteerModel(
          id: 'vol-regular',
          name: 'Regular Volunteer',
          email: 'vol@example.co.uk',
          qualifications: ['ref'],
          forwardingAddress: 'vol-regular0@volunteer.roboref.app',
        );
        final authBackend = InMemoryAuthBackend(
          initialSession: regularSession,
          initialProfile: regularProfile,
        );
        addTearDown(authBackend.dispose);

        final mockClient = MockClient((request) async {
          if (request.url.path == '/api/auth/me') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'uid': 'vol-regular',
                'email': 'vol@example.co.uk',
                'inviteVerified': true,
                'isAdmin': false,
              }),
              200,
            );
          }
          return http.Response('Offline', 503);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authBackendProvider.overrideWithValue(authBackend),
              otpAuthApiClientProvider.overrideWithValue(
                OtpAuthApiClient(httpClient: mockClient),
              ),
              signupStoreProvider.overrideWithValue(InMemorySignupStore()),
              vexEventsServiceProvider.overrideWithValue(
                VexEventsService(client: mockClient),
              ),
            ],
            child: const RoboVolunteersApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('admin_portal_button')), findsNothing);

        // Open Profile -> no Admin Portal tile
        await tester.tap(find.byKey(const Key('profile_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('profile_admin_portal_tile')), findsNothing);
      },
    );

    testWidgets(
      'Admin opens Admin Portal, generates one-time invite hyperlink, copies link, and revokes an invite',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1100, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        String? copiedClipboardText;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copiedClipboardText = args['text'] as String?;
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        const adminSession = AuthSession(
          uid: 'uid-admin',
          email: 'james@robovolunteers.link',
          inviteVerified: true,
        );
        const adminProfile = VolunteerModel(
          id: 'uid-admin',
          name: 'James Admin',
          email: 'james@robovolunteers.link',
          qualifications: ['head_ref'],
          forwardingAddress: 'vol-uidadmin@volunteer.roboref.app',
        );
        final authBackend = InMemoryAuthBackend(
          initialSession: adminSession,
          initialProfile: adminProfile,
        );
        addTearDown(authBackend.dispose);

        final serverInvites = <Map<String, dynamic>>[
          {
            'id': 'inv_existing00000001',
            'code': null,
            'codeHint': 'RV-OLD1-••••-••••',
            'inviteUrl': null,
            'label': 'Used Referee',
            'status': 'used',
            'createdAt': '2026-11-20T09:00:00.000Z',
            'createdByUid': 'uid-admin',
            'createdByEmail': 'james@robovolunteers.link',
            'expiresAt': '2026-12-20T09:00:00.000Z',
            'usedAt': '2026-11-21T14:30:00.000Z',
            'usedByUid': 'vol-10',
            'usedByEmail': 'alex@example.co.uk',
          },
        ];

        final mockApiClient = MockClient((request) async {
          if (request.url.path == '/api/auth/me') {
            return _jsonResponse(
              {
                'ok': true,
                'uid': 'uid-admin',
                'email': 'james@robovolunteers.link',
                'inviteVerified': true,
                'isAdmin': true,
              },
              200,
            );
          }

          if (request.method == 'GET' && request.url.path == '/api/admin/invites') {
            return _jsonResponse({'ok': true, 'invites': serverInvites}, 200);
          }

          if (request.method == 'POST' && request.url.path == '/api/admin/invites') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final created = {
              'id': 'inv_generated0000002',
              'code': 'RV-9W4K-2M8P-7Q3N',
              'codeHint': 'RV-9W4K-••••-••••',
              'inviteUrl': 'https://robovolunteers.link/?invite=RV-9W4K-2M8P-7Q3N',
              'label': body['label'],
              'status': 'active',
              'createdAt': '2026-11-24T21:00:00.000Z',
              'createdByUid': 'uid-admin',
              'createdByEmail': 'james@robovolunteers.link',
              'expiresAt': '2026-12-24T21:00:00.000Z',
            };
            serverInvites.insert(0, created);
            return _jsonResponse(
              {'ok': true, 'invite': created, 'invites': [created]},
              201,
            );
          }

          if (request.method == 'POST' &&
              request.url.path == '/api/admin/invites/inv_generated0000002/revoke') {
            final idx = serverInvites
                .indexWhere((i) => i['id'] == 'inv_generated0000002');
            final updated = {
              ...serverInvites[idx],
              'code': null,
              'inviteUrl': null,
              'status': 'revoked',
              'revokedAt': '2026-11-24T21:05:00.000Z',
              'revokedByUid': 'uid-admin',
              'revokedByEmail': 'james@robovolunteers.link',
            };
            serverInvites[idx] = updated;
            return _jsonResponse({'ok': true, 'invite': updated}, 200);
          }

          return http.Response('Offline', 503);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authBackendProvider.overrideWithValue(authBackend),
              otpAuthApiClientProvider.overrideWithValue(
                OtpAuthApiClient(httpClient: mockApiClient),
              ),
              adminInviteApiClientProvider.overrideWithValue(
                AdminInviteApiClient(httpClient: mockApiClient),
              ),
              signupStoreProvider.overrideWithValue(InMemorySignupStore()),
              vexEventsServiceProvider.overrideWithValue(
                VexEventsService(client: mockApiClient),
              ),
            ],
            child: const RoboVolunteersApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Admin Portal icon is visible in EventsListScreen AppBar
        final adminButton = find.byKey(const Key('admin_portal_button'));
        expect(adminButton, findsOneWidget);

        await tester.tap(adminButton);
        await tester.pumpAndSettle();

        expect(find.byType(AdminPortalScreen), findsOneWidget);
        expect(find.text('Used Referee'), findsOneWidget);
        expect(find.textContaining('alex@example.co.uk'), findsOneWidget);

        // Generate a new one-time invite code with recipient note
        await tester.enterText(
          find.byKey(const Key('admin_invite_label_input')),
          'Sam Judge',
        );
        await tester.tap(find.byKey(const Key('admin_generate_invite_button')));
        await tester.pumpAndSettle();

        // Recently generated hyperlink card appears with shareable URL
        expect(
          find.byKey(const Key('recently_generated_invites_card')),
          findsOneWidget,
        );
        expect(
          find.text('https://robovolunteers.link/?invite=RV-9W4K-2M8P-7Q3N'),
          findsWidgets,
        );

        // Copy Link copies exact hyperlink to clipboard
        await tester.tap(
          find.byKey(const Key('copy_generated_link_inv_generated0000002')),
        );
        await tester.pumpAndSettle();
        expect(
          copiedClipboardText,
          equals('https://robovolunteers.link/?invite=RV-9W4K-2M8P-7Q3N'),
        );

        // Revoke the newly generated invite code
        final revokeBtn =
            find.byKey(const Key('revoke_invite_inv_generated0000002'));
        await tester.ensureVisible(revokeBtn);
        await tester.tap(revokeBtn);
        await tester.pumpAndSettle();

        // Confirm dialog
        expect(find.text('Revoke Invitation Code?'), findsOneWidget);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Revoke'));
        await tester.pumpAndSettle();

        // Invite status changes to Revoked and raw URL disappears
        expect(find.text('Revoked'), findsOneWidget);
        expect(
          find.text('https://robovolunteers.link/?invite=RV-9W4K-2M8P-7Q3N'),
          findsNothing,
        );
        expect(find.text('RV-9W4K-••••-••••'), findsOneWidget);
      },
    );
  });
}
