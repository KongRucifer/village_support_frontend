import '../models/transaction_item.dart';
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

  // Reentrancy guard so overlapping triggers (connectivity + timer + lifecycle)
  // don't run concurrent syncs.
  bool _syncing = false;

  /// Two-way sync: PUSH queued offline edits first, then PULL the latest snapshot.
  /// Push-before-pull ensures the server has our edits before we overwrite the
  /// local cache with server data.
  Future<SyncResult> sync(String token, {bool full = false}) async {
    if (_syncing) {
      return SyncResult(ran: false, message: 'Sync already in progress');
    }
    if (!await connectivity.isOnline()) {
      return SyncResult(ran: false, message: 'Offline — using cached data');
    }
    if (token.isEmpty) {
      return SyncResult(ran: false, message: 'No server token — re-login online to sync');
    }
    _syncing = true;
    try {
      final pushed = await flushOutbox(token);

      // Force a FULL pull when the local mirror is empty (fresh install / cleared
      // data) so offline scans can find ANY server account — not just the ones
      // previously scanned online.
      var effectiveFull = full;
      if (!effectiveFull && await db.countAll('account_owners') == 0) {
        effectiveFull = true;
      }

      final since = effectiveFull ? null : await db.getMeta(_kLastSync);
      final snapshot = await api.getSync(token: token, since: since);

      // ── Upsert changed rows ──────────────────────────────────────────────
      await db.upsertVbCodes(snapshot.vbCodes);
      await db.upsertAccountOwners(snapshot.accountOwners);
      await _persistIdDocuments(snapshot.idDocuments);
      await _persistTransactions(snapshot.transactions);

      // ── Delete-aware prune: drop local rows the server no longer has ──────
      // vbCodes always arrive in full, so prune against the returned set.
      await db.pruneVbCodes(snapshot.vbCodes.map((v) => v.vbCode).toSet());
      // account_owners / id_documents are incremental, so prune against the
      // server's full key lists (skipped when the snapshot didn't send them).
      if (snapshot.accountOwnerKeys.isNotEmpty) {
        await db.pruneAccountOwners(snapshot.accountOwnerKeys.toSet());
      }
      if (snapshot.idDocumentIds.isNotEmpty) {
        await db.pruneIdDocuments(snapshot.idDocumentIds.toSet());
      }

      // Mirror today's check-in / check-out rows (vbc_arrangement) into SQLite
      // so the scan flow reads fresh data with no API call, even offline.
      await _persistCheckins(snapshot.checkins);

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
    } finally {
      _syncing = false;
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
        // Check-in is pushed first (it's queued before the matching withdraw),
        // so the server has the check-in row before the withdraw validates it.
        if (op == 'checkin') {
          try {
            await api.checkIn(
              token: token,
              accNumber: row['acc_number'] as String,
              vbCode: row['vb_code'] as String,
            );
            await db.deleteOutbox(id);
            pushed++;
          } on ApiException {
            // Server permanently rejected (already checked in/out, loss status).
            // Drop it so it never blocks the rest of the queue. Local state is
            // already correct, so nothing else to do.
            await db.deleteOutbox(id);
          }
          continue; // network errors fall to the outer catch → break + retry
        }
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

  /// Reconcile the server's check-in rows into SQLite (delete-aware) and clean
  /// out old days. Unlike a plain upsert, this also drops today's local rows the
  /// server no longer has — so an admin editing/deleting a vbc_arrangement row
  /// (e.g. moving it to another day, or resetting it) is reflected locally.
  /// Offline check-ins still queued in the outbox are preserved.
  Future<void> _persistCheckins(List<CheckinSync> checkins) async {
    final today = _todayStr();
    final rows = checkins
        .map((c) => <String, Object?>{
              'bankbook_number': c.bankbookNumber ?? '',
              'vb_code': c.vbCode,
              'date': c.date,
              'points': c.points,
              'need_sync': c.needSync,
              'last_update': c.lastUpdate,
            })
        .toList();

    // Keys still waiting to be pushed — never overwrite/delete an unsynced edit.
    final pending = await db.pendingOutbox();
    final pendingKeys = pending
        .where((r) => r['op'] == 'checkin' || r['op'] == 'withdraw')
        .map((r) =>
            '${(r['bankbook_number'] ?? '').toString().trim()}|${(r['vb_code'] ?? '').toString().trim()}')
        .toSet();

    await db.replaceTodayCheckins(
      today: today,
      serverRows: rows,
      pendingKeys: pendingKeys,
    );
    await db.deleteCheckinsBefore(today);
  }

  /// Mirror id_document rows for offline lookup-by-document-number.
  Future<void> _persistIdDocuments(List<IdDocumentSync> docs) async {
    if (docs.isEmpty) return;
    final rows = docs
        .map((d) => <String, Object?>{
              'id': d.id,
              'id_document_number': d.idDocumentNumber,
              'client_id': d.clientId,
              'vb_code': d.vbCode,
              'name_lao': d.documentNameLao,
              'name_eng': d.documentNameEng,
            })
        .toList();
    await db.bulkUpsertIdDocuments(rows);
  }

  /// Mirror payment transactions (tx 3101) into the offline history table.
  Future<void> _persistTransactions(List<TransactionItem> txs) async {
    if (txs.isEmpty) return;
    final rows = txs
        .map((t) => <String, Object?>{
              'id': t.id,
              'date': t.date,
              'bankbook_number': t.bankbookNumber,
              'tx_code': t.txCode,
              'tx_name_lao': t.txNameLao,
              'tx_name_eng': t.txNameEng,
              'amount': t.amount.toInt(),
              'debit_acc_number': t.debitAccNumber,
              'debit_acc_name_lao': t.debitAccNameLao,
              'credit_acc_number': t.creditAccNumber,
              'description': t.description,
              'payment_method': t.paymentMethod,
            })
        .toList();
    await db.bulkUpsertTransactions(rows);
  }

  String _todayStr() {
    final n = DateTime.now();
    final mm = n.month.toString().padLeft(2, '0');
    final dd = n.day.toString().padLeft(2, '0');
    return '${n.year}-$mm-$dd';
  }

  Future<String?> lastSyncedAt() => db.getMeta(_kLastSync);
}
