import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admin/screens/admin_portal_screen.dart';
import '../../features/auth_invites/screens/login_screen.dart';
import '../../features/auth_invites/screens/signup_screen.dart';
import '../../features/auth_invites/state/auth_provider.dart';
import '../../features/events/models/event_model.dart';
import '../../features/events/screens/events_list_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/volunteering/screens/event_roster_screen.dart';
import '../utils/invite_link_utils.dart';

/// Canonical web and in-app path routes for RoboVolunteers.
abstract final class AppRoutes {
  static const String home = '/';
  static const String profile = '/profile';
  static const String admin = '/admin';
  static const String eventPrefix = '/event';

  /// Builds a canonical path for an event volunteer roster, e.g.
  /// `/event/RE-V5RC-26-9102`.
  static String eventPath(String sku) {
    final cleanSku = sku.trim().toUpperCase();
    if (cleanSku.isEmpty) return home;
    final encodedSku = Uri.encodeComponent(cleanSku);
    return '$eventPrefix/$encodedSku';
  }
}

enum AppRouteKind {
  home,
  eventRoster,
  profile,
  admin,
}

@immutable
class ParsedAppRoute {
  final AppRouteKind kind;
  final String canonicalPath;
  final String? sku;
  final String? inviteCode;

  const ParsedAppRoute({
    required this.kind,
    required this.canonicalPath,
    this.sku,
    this.inviteCode,
  });
}

/// Centralized path-based router for RoboVolunteers across Web, Android, and iOS.
abstract final class AppRouter {
  /// Parses a raw route string (e.g. `/profile`, `/admin`, `/event/RE-V5RC-26-9102`,
  /// `/?invite=RV-...`) into a normalized [ParsedAppRoute].
  /// Unknown paths fall back to [AppRoutes.home].
  static ParsedAppRoute parseRoute(String? rawRouteName) {
    final raw = (rawRouteName == null || rawRouteName.trim().isEmpty)
        ? AppRoutes.home
        : rawRouteName.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return const ParsedAppRoute(
        kind: AppRouteKind.home,
        canonicalPath: AppRoutes.home,
      );
    }

    final inviteCode = InviteLinkUtils.extractInviteCodeFromUri(uri);
    final segments = uri.pathSegments
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (segments.isEmpty) {
      return ParsedAppRoute(
        kind: AppRouteKind.home,
        canonicalPath: AppRoutes.home,
        inviteCode: inviteCode,
      );
    }

    final first = segments.first.toLowerCase();
    switch (first) {
      case 'profile':
        return ParsedAppRoute(
          kind: AppRouteKind.profile,
          canonicalPath: AppRoutes.profile,
          inviteCode: inviteCode,
        );
      case 'admin':
        return ParsedAppRoute(
          kind: AppRouteKind.admin,
          canonicalPath: AppRoutes.admin,
          inviteCode: inviteCode,
        );
      case 'event':
      case 'events':
        if (segments.length >= 2) {
          final sku = Uri.decodeComponent(segments[1]).trim().toUpperCase();
          if (sku.isNotEmpty) {
            return ParsedAppRoute(
              kind: AppRouteKind.eventRoster,
              canonicalPath: AppRoutes.eventPath(sku),
              sku: sku,
              inviteCode: inviteCode,
            );
          }
        }
        return ParsedAppRoute(
          kind: AppRouteKind.home,
          canonicalPath: AppRoutes.home,
          inviteCode: inviteCode,
        );
      default:
        return ParsedAppRoute(
          kind: AppRouteKind.home,
          canonicalPath: AppRoutes.home,
          inviteCode: inviteCode,
        );
    }
  }

  static Widget _buildAuthenticatedScreen(
    ParsedAppRoute parsed, {
    EventModel? event,
  }) {
    switch (parsed.kind) {
      case AppRouteKind.home:
        return const EventsListScreen();
      case AppRouteKind.profile:
        return const ProfileScreen();
      case AppRouteKind.admin:
        return const AdminPortalScreen();
      case AppRouteKind.eventRoster:
        return EventRosterScreen(
          event: event,
          sku: parsed.sku,
        );
    }
  }

  static Widget _wrapWithGate(
    ParsedAppRoute parsed, {
    required bool firebaseReady,
    EventModel? event,
  }) {
    if (!firebaseReady) {
      return const FirebaseSetupRequiredScreen();
    }
    return AuthGate(
      initialInviteCode: parsed.inviteCode,
      child: _buildAuthenticatedScreen(parsed, event: event),
    );
  }

  /// Builds a [MaterialPageRoute] for a path string, preserving [RouteSettings.name]
  /// so Flutter Web updates the browser address bar automatically.
  static Route<dynamic> routeForPath(
    String path, {
    bool firebaseReady = true,
    EventModel? event,
  }) {
    final parsed = parseRoute(path);
    return MaterialPageRoute<void>(
      settings: RouteSettings(name: parsed.canonicalPath),
      builder: (_) => _wrapWithGate(
        parsed,
        firebaseReady: firebaseReady,
        event: event,
      ),
    );
  }

  /// Passed to [MaterialApp.onGenerateRoute].
  static Route<dynamic> onGenerateRoute(
    RouteSettings settings, {
    bool firebaseReady = true,
  }) {
    final event = settings.arguments is EventModel
        ? settings.arguments as EventModel
        : null;
    return routeForPath(
      settings.name ?? AppRoutes.home,
      firebaseReady: firebaseReady,
      event: event,
    );
  }

  /// Passed to [MaterialApp.onGenerateInitialRoutes].
  /// Deep links (e.g. `/event/RE-V5RC-26-9102`, `/profile`, `/admin`) are stacked
  /// on top of [AppRoutes.home] so the AppBar back button returns cleanly to Events.
  static List<Route<dynamic>> onGenerateInitialRoutes(
    String initialRouteName, {
    bool firebaseReady = true,
  }) {
    final parsed = parseRoute(initialRouteName);
    if (parsed.kind == AppRouteKind.home) {
      return [
        routeForPath(
          initialRouteName,
          firebaseReady: firebaseReady,
        ),
      ];
    }
    return [
      routeForPath(
        AppRoutes.home,
        firebaseReady: firebaseReady,
      ),
      routeForPath(
        initialRouteName,
        firebaseReady: firebaseReady,
      ),
    ];
  }

  /// Pushes a canonical path route onto the nearest [Navigator].
  /// Works in both the full app (updating browser URLs on Web) and isolated widget tests.
  static Future<T?> push<T>(
    BuildContext context,
    String path, {
    EventModel? event,
  }) {
    final parsed = parseRoute(path);
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(
        settings: RouteSettings(name: parsed.canonicalPath),
        builder: (_) => _wrapWithGate(
          parsed,
          firebaseReady: true,
          event: event,
        ),
      ),
    );
  }

  /// Pushes an event roster route for [event], passing the loaded [EventModel]
  /// so the screen renders immediately while updating the browser URL to `/event/<SKU>`.
  static Future<T?> pushEvent<T>(BuildContext context, EventModel event) {
    return push<T>(
      context,
      AppRoutes.eventPath(event.sku),
      event: event,
    );
  }

  /// Replaces the current route with a canonical path route on the nearest [Navigator].
  static Future<T?> pushReplacement<T, TO>(
    BuildContext context,
    String path, {
    EventModel? event,
  }) {
    final parsed = parseRoute(path);
    return Navigator.of(context).pushReplacement<T, TO>(
      MaterialPageRoute<T>(
        settings: RouteSettings(name: parsed.canonicalPath),
        builder: (_) => _wrapWithGate(
          parsed,
          firebaseReady: true,
          event: event,
        ),
      ),
    );
  }

  /// Replaces the current browser URL on Flutter Web without pushing an extra
  /// browser history entry.
  static void updateBrowserUrl(String path) {
    if (!kIsWeb) return;
    final parsed = parseRoute(path);
    try {
      SystemNavigator.routeInformationUpdated(
        uri: Uri.parse(parsed.canonicalPath),
        replace: true,
      );
    } catch (_) {}
  }
}

/// Guards any routed screen behind the reactive authentication & onboarding state.
class AuthGate extends ConsumerWidget {
  final Widget child;
  final String? initialInviteCode;

  const AuthGate({
    super.key,
    required this.child,
    this.initialInviteCode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = ref.watch(authControllerProvider);

    switch (gate.status) {
      case AuthGateStatus.loading:
        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        );
      case AuthGateStatus.unauthenticated:
        return LoginScreen(initialInviteCode: initialInviteCode);
      case AuthGateStatus.needsOnboarding:
        return SignupScreen(
          verifiedEmail: gate.session?.email ?? '',
          initialName: gate.session?.displayName,
        );
      case AuthGateStatus.authenticated:
        return child;
    }
  }
}

class FirebaseSetupRequiredScreen extends StatelessWidget {
  const FirebaseSetupRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off, size: 48, color: Colors.orange),
                    SizedBox(height: 16),
                    Text(
                      'Firebase Configuration Required',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Run `flutterfire configure` in `app/` or pass FIREBASE_API_KEY, FIREBASE_PROJECT_ID, and FIREBASE_APP_ID via `--dart-define`.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
