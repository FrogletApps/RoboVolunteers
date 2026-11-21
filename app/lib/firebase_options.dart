import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Firebase configuration options for RoboVolunteers.
///
/// Configured for the `volunteer-wrangler` Firebase project by default, while
/// still allowing `--dart-define=FIREBASE_API_KEY=...`, `FIREBASE_PROJECT_ID=...`,
/// `FIREBASE_APP_ID=...`, `FIREBASE_MESSAGING_SENDER_ID=...`, and
/// `FIREBASE_AUTH_DOMAIN=...` overrides at build time (`flutter build web`).
class DefaultFirebaseOptions {
  static const String _apiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: 'AIzaSyCmpXK8jBBI33iZlomSqQlR7gsps8qhg_A',
  );
  static const String _projectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'volunteer-wrangler',
  );
  static const String _appId = String.fromEnvironment(
    'FIREBASE_APP_ID',
    defaultValue: '1:279608062017:web:9bd435760200377b1596c0',
  );
  static const String _messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '279608062017',
  );
  static const String _authDomain = String.fromEnvironment(
    'FIREBASE_AUTH_DOMAIN',
    defaultValue: 'volunteer-wrangler.firebaseapp.com',
  );
  static const String _storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
    defaultValue: 'volunteer-wrangler.firebasestorage.app',
  );
  static const String _measurementId = String.fromEnvironment(
    'FIREBASE_MEASUREMENT_ID',
    defaultValue: 'G-Q9024562TL',
  );
  static const String _iosBundleId = String.fromEnvironment(
    'FIREBASE_IOS_BUNDLE_ID',
    defaultValue: 'link.robovolunteers',
  );

  /// Returns true when Firebase project credentials have been configured.
  static bool get isConfigured =>
      _apiKey.isNotEmpty && _projectId.isNotEmpty && _appId.isNotEmpty;

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform.',
        );
    }
  }

  static FirebaseOptions get web => FirebaseOptions(
        apiKey: _apiKey,
        appId: _appId,
        messagingSenderId: _messagingSenderId,
        projectId: _projectId,
        authDomain: _authDomain.isNotEmpty
            ? _authDomain
            : '$_projectId.firebaseapp.com',
        storageBucket: _storageBucket.isNotEmpty ? _storageBucket : null,
        measurementId: _measurementId.isNotEmpty ? _measurementId : null,
      );

  static FirebaseOptions get android => FirebaseOptions(
        apiKey: _apiKey,
        appId: _appId,
        messagingSenderId: _messagingSenderId,
        projectId: _projectId,
        storageBucket: _storageBucket.isNotEmpty ? _storageBucket : null,
      );

  static FirebaseOptions get ios => FirebaseOptions(
        apiKey: _apiKey,
        appId: _appId,
        messagingSenderId: _messagingSenderId,
        projectId: _projectId,
        storageBucket: _storageBucket.isNotEmpty ? _storageBucket : null,
        iosBundleId: _iosBundleId,
      );
}
