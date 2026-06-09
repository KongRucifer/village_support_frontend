import 'package:flutter/foundation.dart';

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

/// Live sync phase for the UI (status bar spinner + "last synced" time).
enum SyncPhase { idle, syncing, success, error }

/// Snapshot of the current sync state. The [SyncService] publishes this via a
/// [ValueNotifier] so the dashboard can show real-time progress and the time of
/// the last successful pull.
class SyncStatus {
  final SyncPhase phase;
  final DateTime? lastSuccess; // local time of the last successful pull
  final int villages;
  final int accounts;
  final String? message;
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccess,
    this.villages = 0,
    this.accounts = 0,
    this.message,
  });

  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastSuccess,
    int? villages,
    int? accounts,
    String? message,
  }) =>
      SyncStatus(
        phase: phase ?? this.phase,
        lastSuccess: lastSuccess ?? this.lastSuccess,
        villages: villages ?? this.villages,
        accounts: accounts ?? this.accounts,
        message: message ?? this.message,
      );
}

/// Pulls data from the backend and mirrors it into SQLite.
/// Called after login and whenever connectivity is regained.
class SyncService {
  final ApiClient api;
  final LocalDb db;
  final ConnectivityService connectivity;

  SyncService({required this.api, required this.db, required this.connectivity});

  // Tag for all sync logs so you can filter the device console:
  //   flutter run         → look for lines starting with [SYNC]
  //   adb logcat | findstr SYNC   (Android, app already installed)
  void _log(String msg) => debugPrint('[SYNC] $msg');

  static const _kLastSync = 'last_sync';
  // Set to '1' only after a FULL pull (since=null) finishes writing every table.
  // Until then we keep forcing a full pull so the offline mirror is guaranteed
  // to hold the complete server set, not just the few accounts cached one-by-one
  // from online scans.
  static const _kFullMirror = 'full_mirror_done';

  // Reentrancy guard so overlapping triggers (connectivity + timer + lifecycle)
  // don't run concurrent syncs.
  bool _syncing = false;

  /// Live status for the UI. Listen to this to show a spinner while syncing and
  /// the time of the last successful pull. Updated on every sync attempt.
  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  bool get isSyncing => _syncing;

  /// Seed [status.lastSuccess] from the persisted last-sync time so the UI can
  /// show "synced X ago" immediately on launch, before the first sync runs.
  Future<void> primeStatus() async {
    final iso = await db.getMeta(_kLastSync);
    final t = iso != null ? DateTime.tryParse(iso) : null;
    if (t != null) {
      status.value = status.value.copyWith(lastSuccess: t.toLocal());
    }
  }

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
    status.value = status.value.copyWith(phase: SyncPhase.syncing, message: 'Syncing…');
    final sw = Stopwatch()..start();
    _log('start (requested full=$full)');
    try {
      final pushed = await flushOutbox(token);
      _log('flushOutbox pushed=$pushed (${sw.elapsedMilliseconds}ms)');

      // ── Fast check-in reconcile FIRST (lightweight, independent path) ────────
      // Today's check-in rows are tiny; pulling them on their own guarantees the
      // check-in/out guards reflect the server even if the heavy snapshot below
      // is slow or times out on a brief connection. Best-effort: a failure here
      // is fine because the full snapshot also reconciles check-ins.
      try {
        final ckSw = Stopwatch()..start();
        final cks = await api.getCheckins(token: token);
        await _persistCheckins(cks.checkins);
        _log('checkins reconciled=${cks.checkins.length} (${ckSw.elapsedMilliseconds}ms)');
      } catch (e) {
        _log('checkins fast-path FAILED: $e (heavy pull will retry)');
      }

      // Force a FULL pull until one has fully succeeded at least once. The old
      // `count == 0` guard was defeated the moment a single account got cached
      // one-by-one from an online scan: after that the mirror was never
      // completed, so offline scans of never-seen accounts returned
      // "account not found". The `full_mirror_done` flag is set ONLY after a
      // full pull finishes writing, so we keep forcing full (and retrying on
      // timeout) until the whole server set is mirrored into SQLite.
      var effectiveFull = full;
      final mirrorDone = await db.getMeta(_kFullMirror) == '1';
      if (!effectiveFull && !mirrorDone) {
        effectiveFull = true;
      }

      final since = effectiveFull ? null : await db.getMeta(_kLastSync);
      _log('pull mode=${effectiveFull ? 'FULL' : 'incremental'} '
          'mirrorDone=$mirrorDone since=${since ?? '-'}');

      final pullSw = Stopwatch()..start();
      final snapshot = await api.getSync(token: token, since: since);
      _log('getSync OK in ${pullSw.elapsedMilliseconds}ms → '
          'vbCodes=${snapshot.vbCodes.length} '
          'accounts=${snapshot.accountOwners.length} '
          'idDocs=${snapshot.idDocuments.length} '
          'tx=${snapshot.transactions.length} '
          'ownerKeys=${snapshot.accountOwnerKeys.length} '
          'checkins=${snapshot.checkins.length}');

      // ── Upsert changed rows ──────────────────────────────────────────────
      await db.upsertVbCodes(snapshot.vbCodes);
      await db.upsertAccountOwners(snapshot.accountOwners);
      await _persistIdDocuments(snapshot.idDocuments);
      await _persistTransactions(snapshot.transactions);
      final ownerTotal = await db.countAll('account_owners');
      _log('written to SQLite → account_owners total now=$ownerTotal '
          '(${sw.elapsedMilliseconds}ms)');

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
      // Mark the mirror complete only after a full pull actually finished
      // writing every table — so a timed-out/partial full pull is retried next
      // time instead of silently leaving the mirror incomplete.
      if (effectiveFull) {
        await db.setMeta(_kFullMirror, '1');
        _log('full_mirror_done flag SET — next syncs will be incremental');
      }

      final pushNote = pushed > 0 ? 'Pushed $pushed edit(s) • ' : '';
      status.value = SyncStatus(
        phase: SyncPhase.success,
        lastSuccess: DateTime.now(),
        villages: snapshot.vbCodes.length,
        accounts: snapshot.accountOwners.length,
        message: 'Synced',
      );
      _log('DONE in ${sw.elapsedMilliseconds}ms ✓');
      return SyncResult(
        ran: true,
        pushed: pushed,
        vbCount: snapshot.vbCodes.length,
        ownerCount: snapshot.accountOwners.length,
        message: '${pushNote}Synced ${snapshot.vbCodes.length} villages, '
            '${snapshot.accountOwners.length} accounts',
      );
    } on ApiException catch (e) {
      _log('API ERROR after ${sw.elapsedMilliseconds}ms: ${e.statusCode} ${e.message}');
      status.value = status.value
          .copyWith(phase: SyncPhase.error, message: e.message);
      return SyncResult(ran: false, message: 'Sync error: ${e.message}');
    } catch (e) {
      _log('ERROR after ${sw.elapsedMilliseconds}ms (likely TIMEOUT): $e');
      status.value =
          status.value.copyWith(phase: SyncPhase.error, message: '$e');
      return SyncResult(ran: false, message: 'Sync error: $e');
    } finally {
      _syncing = false;
    }
  }

  /// Push every queued offline edit to the server. Returns how many succeeded.
  /// A failed item is left in the queue to retry on the next sync.
  Future<int> flushOutbox(String token) async {
    if (token.isEmpty || !await connectivity.isOnline()) {
      _log('flushOutbox skipped (token empty or offline)');
      return 0;
    }

    final items = await db.pendingOutbox();
    _log('flushOutbox: ${items.length} pending op(s)');
    var pushed = 0;
    for (final row in items) {
      final id = row['id'] as int;
      final op = (row['op'] ?? 'update_savings') as String;
      final acc = row['acc_number'] as String?;
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
            _log('  ✓ pushed checkin acc=$acc');
          } on ApiException catch (e) {
            // Server permanently rejected (already checked in/out, loss status).
            // Drop it so it never blocks the rest of the queue. Local state is
            // already correct, so nothing else to do.
            await db.deleteOutbox(id);
            _log('  ⚠ checkin acc=$acc rejected by server (dropped): '
                '${e.statusCode} ${e.code ?? ''} ${e.message}');
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
        _log('  ✓ pushed $op acc=$acc');
      } on ApiException catch (e) {
        // The server REJECTED this edit (4xx) — it will never succeed on retry
        // and would block everything behind it. Drop it so the rest of the queue
        // can flush. (Local state already reflects the user's action.)
        await db.deleteOutbox(id);
        _log('  ⚠ $op acc=$acc rejected by server (dropped): '
            '${e.statusCode} ${e.code ?? ''} ${e.message}');
      } catch (e) {
        // Network-level failure (timeout / unreachable) — keep it queued and
        // stop here so we retry the whole batch on the next sync.
        _log('  ✗ $op acc=$acc network error — kept for retry: $e');
        break;
      }
    }
    _log('flushOutbox done: pushed=$pushed');
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
