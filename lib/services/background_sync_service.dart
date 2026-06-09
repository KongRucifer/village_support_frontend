import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../models/system_user.dart';
import '../repositories/auth_repository.dart';
import 'api_client.dart';
import 'connectivity_service.dart';
import 'local_db.dart';
import 'secure_storage_service.dart';
import 'sync_service.dart';

/// Unique name (WorkManager identity) + task name for the periodic OS-level sync.
const String _kBgUnique = 'village-support-bg-sync';
const String _kBgTask = 'village-support-bg-sync-task';

/// Background sync that runs even when the app is fully closed/killed.
///
/// Android → WorkManager schedules [callbackDispatcher] roughly every 15 min
///           (the OS-enforced minimum) when a network is available.
/// iOS     → BGTaskScheduler runs it opportunistically (needs Info.plist +
///           AppDelegate setup — see the notes at the bottom of this file).
///
/// The task spins up FRESH service instances (the background isolate has no
/// access to the app's in-memory [AppServices]), reads the last logged-in
/// user's token from secure storage, refreshes it if expired, and runs a full
/// two-way sync (push outbox → pull everything). It reuses the exact same
/// [SyncService] the foreground uses, so the offline mirror stays current.
class BackgroundSync {
  BackgroundSync._();

  /// Wire up the WorkManager callback. Call once in `main()` before runApp.
  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher);
  }

  /// Schedule the recurring background pull. Safe to call repeatedly — the
  /// [ExistingPeriodicWorkPolicy.update] keeps a single task and refreshes its
  /// config without restarting the timer. Requires a network connection.
  static Future<void> registerPeriodic() async {
    await Workmanager().registerPeriodicTask(
      _kBgUnique,
      _kBgTask,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// Stop background sync (call on logout).
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_kBgUnique);
  }
}

/// WorkManager background isolate entry point. MUST be a top-level function and
/// annotated so AOT compilation keeps it reachable.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      // Fresh instances — statics in the main isolate are NOT shared here.
      final db = LocalDb.instance;
      final api = ApiClient();
      final connectivity = ConnectivityService();
      final secure = SecureStorageService();
      final auth = AuthRepository(
        api: api,
        db: db,
        connectivity: connectivity,
        secureStorage: secure,
      );
      final sync = SyncService(api: api, db: db, connectivity: connectivity);

      // No network → let the next scheduled window try again.
      if (!await connectivity.isOnline()) return true;

      final userName = await secure.getLastUser();
      if (userName == null || userName.isEmpty) return true;

      final token = await secure.getToken(userName) ?? '';
      if (token.isEmpty) return true;

      final user = SystemUser(
        id: 0,
        userName: userName,
        roles: const [],
        token: token,
      );

      // Silent re-auth if the token is near/after expiry (uses the password
      // kept in the OS keychain for refresh).
      await auth.refreshIfExpired(user);
      if (user.token.isEmpty) return true;

      // Incremental two-way sync: push queued offline edits, pull changed rows +
      // today's check-ins (always full) + key lists for delete-aware pruning.
      // Lighter than a full pull, so it finishes inside the OS background window.
      // SyncService auto-forces a full pull only when the mirror is empty.
      await sync.sync(user.token);
      return true;
    } catch (_) {
      // Never throw out of the isolate — just succeed so we don't thrash; the
      // next periodic window will retry.
      return true;
    }
  });
}

// ── iOS setup (BGTaskScheduler) — required only for iOS builds ────────────────
// 1. ios/Runner/Info.plist:
//      <key>BGTaskSchedulerPermittedIdentifiers</key>
//      <array>
//        <string>village-support-bg-sync</string>
//      </array>
//      <key>UIBackgroundModes</key>
//      <array>
//        <string>fetch</string>
//        <string>processing</string>
//      </array>
// 2. ios/Runner/AppDelegate.swift — inside didFinishLaunchingWithOptions:
//      WorkmanagerPlugin.registerTask(withIdentifier: "village-support-bg-sync")
// Android needs no native changes (WorkManager auto-registers via the plugin).
