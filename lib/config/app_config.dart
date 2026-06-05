class AppConfig {
  /// Backend base URL (includes the global `api/v1` prefix from main.ts).
  ///
  /// Supplied from `.env` at build/run time via:
  ///     flutter run        --dart-define-from-file=.env
  ///     flutter build apk  --dart-define-from-file=.env
  ///
  /// The `defaultValue` below is used when no .env is passed, so a plain
  /// `flutter build apk` still produces a working production APK.
  ///
  /// URL per target:
  /// • Production server -> http://183.182.104.202:8080/api/v1
  /// • Android emulator  -> http://10.0.2.2:4000/api/v1   (host's localhost)
  /// • iOS sim / desktop -> http://localhost:4000/api/v1
  /// • Physical (Wi-Fi)  -> `http://<your-PC-LAN-IP>:4000/api/v1`
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://183.182.104.202:8080/api/v1',
  );

  /// Network timeout for API calls.
  static const Duration apiTimeout = Duration(seconds: 10);
}
