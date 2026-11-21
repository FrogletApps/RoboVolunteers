import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'features/auth_invites/screens/login_screen.dart';
import 'features/auth_invites/screens/signup_screen.dart';
import 'features/auth_invites/state/auth_provider.dart';
import 'features/events/screens/events_list_screen.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  var firebaseInitialized = false;
  if (DefaultFirebaseOptions.isConfigured) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (kIsWeb) {
      // Ensure web sessions persist across browser restarts
      await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
    }
    firebaseInitialized = true;
  }

  runApp(
    ProviderScope(
      child: RoboVolunteersApp(firebaseReady: firebaseInitialized),
    ),
  );
}

class RoboVolunteersApp extends ConsumerWidget {
  final bool firebaseReady;

  const RoboVolunteersApp({
    super.key,
    this.firebaseReady = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'RoboVolunteers',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: firebaseReady
          ? const _AuthGateRouter()
          : const _FirebaseSetupRequiredScreen(),
    );
  }
}

class _AuthGateRouter extends ConsumerWidget {
  const _AuthGateRouter();

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
        return const LoginScreen();
      case AuthGateStatus.needsOnboarding:
        return SignupScreen(
          verifiedEmail: gate.session?.email ?? '',
          initialName: gate.session?.displayName,
        );
      case AuthGateStatus.authenticated:
        return const EventsListScreen();
    }
  }
}

class _FirebaseSetupRequiredScreen extends StatelessWidget {
  const _FirebaseSetupRequiredScreen();

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
