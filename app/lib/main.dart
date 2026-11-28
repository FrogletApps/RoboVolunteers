import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();

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
  final String? initialRoute;

  const RoboVolunteersApp({
    super.key,
    this.firebaseReady = true,
    this.initialRoute,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'RoboVolunteers',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      initialRoute: initialRoute,
      onGenerateRoute: (settings) => AppRouter.onGenerateRoute(
        settings,
        firebaseReady: firebaseReady,
      ),
      onGenerateInitialRoutes: (initialRouteName) =>
          AppRouter.onGenerateInitialRoutes(
        initialRouteName,
        firebaseReady: firebaseReady,
      ),
      onUnknownRoute: (settings) => AppRouter.routeForPath(
        AppRoutes.home,
        firebaseReady: firebaseReady,
      ),
    );
  }
}
