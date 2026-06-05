import '../models/withdrawal.dart'; // PaymentMethodType
import 'api_client.dart';
import 'connectivity_service.dart';
import 'local_db.dart';

class SyncResult {
  final bool ran;
  final int vbCount;
  final int ownerCount;
  final int pushed; // offline edits flushed to the server
  final String? message;
  SyncResult({
    required this.ran,
    this.vbCount = 0,
    this.ownerCount = 0,
    this.pushed = 0,
    this.message,
  });
}

/// Pulls data from the backend and mirrors it into SQLite.
/// Called after login and whenever connectivity is regained.
class SyncService {
  final ApiClient api;
  final LocalDb db;
  final ConnectivityService connectivity;

  SyncService({required this.api, required this.db, required this.connectivity});

  static const _kLastSync = 'last_sync';

  /// Two-way sync: PUSH queued offline edits first, then PULL the latest snapshot.
  /// Push-before-pull ensures the server has our edits before we overwrite the
  /// local cache with server data.
  Future<SyncResult> sync(String token, {bool full = false}) async {
    if (!await connectivity.isOnline()) {
      return SyncResult(ran: false, message: 'Offline — using cached data');
    }
    if (token.isEmpty) {
      return SyncResult(ran: false, message: 'No server token — re-login online to sync');
    }
    try {
      final pushed = await flushOutbox(token);

      final since = full ? null : await db.getMeta(_kLastSync);
      final snapshot = await api.getSync(token: token, since: since);

      await db.upsertVbCodes(snapshot.vbCodes);
      await db.upsertAccountOwners(snapshot.accountOwners);

      if (snapshot.serverTime.isNotEmpty) {
        await db.setMeta(_kLastSync, snapshot.serverTime);
      }

      final pushNote = pushed > 0 ? 'Pushed $pushed edit(s) • ' : '';
      return SyncResult(
        ran: true,
        pushed: pushed,
        vbCount: snapshot.vbCodes.length,
        ownerCount: snapshot.accountOwners.length,
        message: '${pushNote}Synced ${snapshot.vbCodes.length} villages, '
            '${snapshot.accountOwners.length} accounts',
      );
    } on ApiException catch (e) {
      return SyncResult(ran: false, message: 'Sync error: ${e.message}');
    } catch (e) {
      return SyncResult(ran: false, message: 'Sync error: $e');
    }
  }

  /// Push every queued offline edit to the server. Returns how many succeeded.
  /// A failed item is left in the queue to retry on the next sync.
  Future<int> flushOutbox(String token) async {
    if (token.isEmpty || !await connectivity.isOnline()) return 0;

    final items = await db.pendingOutbox();
    var pushed = 0;
    for (final row in items) {
      final id = row['id'] as int;
      final op = (row['op'] ?? 'update_savings') as String;
      try {
        if (op == 'withdraw') {
          await api.withdraw(
            token: token,
            accNumber: row['acc_number'] as String,
            vbCode: row['vb_code'] as String,
            amount: (row['amount'] ?? 0) as int,
            paymentMethod: PaymentMethodType.fromApi(row['payment_method'] as String?),
            note: row['note'] as String?,
            requestName: row['request_name'] as String?,
            requestAccNumber: row['request_acc_number'] as String?,
          );
        } else {
          await api.updateSavings(
            token: token,
            accNumber: row['acc_number'] as String,
            vbCode: row['vb_code'] as String,
            currentBalance: (row['new_balance'] ?? 0) as int,
            note: row['note'] as String?,
          );
        }
        await db.deleteOutbox(id);
        await db.clearPendingFlag(
          row['acc_number'] as String,
          row['client_id'] as String,
        );
        pushed++;
      } catch (_) {
        // Keep it queued; stop on first failure (likely offline again).
        break;
      }
    }
    return pushed;
  }

  Future<String?> lastSyncedAt() => db.getMeta(_kLastSync);
}
