import '../models/account_owner.dart';
import '../models/transaction_item.dart';
import '../models/vb_code.dart';
import '../models/withdrawal.dart'; // Withdrawal + PaymentMethodType
import '../services/api_client.dart';
import '../services/connectivity_service.dart';
import '../services/local_db.dart';

/// Result of a withdraw attempt.
class WithdrawOutcome {
  final bool synced; // reached the server (a 3101 transaction was created)
  final int newBalance;
  WithdrawOutcome({required this.synced, required this.newBalance});
}

/// Offline-first data access. Tries the API when online (and caches the
/// results into SQLite); falls back to SQLite when offline or on error.
class VillageRepository {
  final ApiClient api;
  final LocalDb db;
  final ConnectivityService connectivity;

  VillageRepository({required this.api, required this.db, required this.connectivity});

  Future<PagedResult<VbCode>> vbCodes({
    required String token,
    String? search,
    int page = 1,
    int limit = 12,
  }) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final result =
            await api.getVbCodes(token: token, search: search, page: page, limit: limit);
        await db.upsertVbCodes(result.items); // opportunistic cache
        return result;
      } catch (_) {
        // fall through to cache
      }
    }
    return db.queryVbCodes(search: search, page: page, limit: limit);
  }

  Future<VbCode?> vbCodeDetail({required String token, required String vbCode}) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final v = await api.getVbCode(token: token, vbCode: vbCode);
        await db.upsertVbCodes([v]);
        return v;
      } catch (_) {
        // fall through to cache
      }
    }
    return db.getVbCode(vbCode);
  }

  /// Edit a savings balance. Updates the local cache immediately, then either
  /// pushes to the server (online) or queues it in the outbox (offline).
  /// Returns true if it reached the server, false if it was queued.
  Future<bool> editSavings({
    required String token,
    required AccountOwner owner,
    required int newBalance,
    String? note,
  }) async {
    final online = await connectivity.isOnline() && token.isNotEmpty;

    if (online) {
      try {
        await api.updateSavings(
          token: token,
          accNumber: owner.accNumber,
          vbCode: owner.vbCode,
          currentBalance: newBalance,
          note: note,
        );
        // Server accepted it — update cache, not pending.
        await db.applyLocalSavingsEdit(
          accNumber: owner.accNumber,
          clientId: owner.clientId,
          bankbookNumber: owner.bankbookNumber,
          newBalance: newBalance,
          pending: false,
        );
        return true;
      } catch (_) {
        // Network hiccup — fall through and queue it.
      }
    }

    // Offline (or push failed): keep it locally and mark pending.
    await db.applyLocalSavingsEdit(
      accNumber: owner.accNumber,
      clientId: owner.clientId,
      bankbookNumber: owner.bankbookNumber,
      newBalance: newBalance,
      pending: true,
    );
    await db.enqueueSavingsEdit(
      accNumber: owner.accNumber,
      vbCode: owner.vbCode,
      bankbookNumber: owner.bankbookNumber,
      clientId: owner.clientId,
      newBalance: newBalance,
      note: note,
      createdAtIso: DateTime.now().toIso8601String(),
    );
    return false;
  }

  Future<int> pendingCount() => db.pendingOutboxCount();

  /// Check in a member (online-only — real-time presence action).
  /// Inserts a row in vbc_arrangement on the server (points=1, need_sync='i').
  /// Throws [ApiException] with statusCode 409 if already checked in today.
  Future<void> checkInAccount({
    required String token,
    required AccountOwner owner,
  }) async {
    await api.checkIn(
      token: token,
      accNumber: owner.accNumber,
      vbCode: owner.vbCode,
    );
  }

  /// Withdraw (cut) money from savings. Online → creates a 3101 transaction on
  /// the server; offline → queues the withdraw and records it locally as pending.
  Future<WithdrawOutcome> withdrawSavings({
    required String token,
    required AccountOwner owner,
    required int amount,
    required int currentBalance,
    required PaymentMethodType paymentMethod,
    String? note,
    String? requestName,       // Bank Transfer only
    String? requestAccNumber,  // Bank Transfer only
  }) async {
    final online = await connectivity.isOnline() && token.isNotEmpty;
    final nowIso = DateTime.now().toIso8601String();

    if (online) {
      try {
        final r = await api.withdraw(
          token: token,
          accNumber: owner.accNumber,
          vbCode: owner.vbCode,
          amount: amount,
          paymentMethod: paymentMethod,
          note: note,
          requestName: requestName,
          requestAccNumber: requestAccNumber,
        );
        await db.applyLocalSavingsEdit(
          accNumber: owner.accNumber,
          clientId: owner.clientId,
          bankbookNumber: owner.bankbookNumber,
          newBalance: r.newBalance,
          pending: false,
        );
        // Cache the server transaction so it shows in the history even offline.
        await db.insertLocalWithdrawal(Withdrawal(
          txId: r.transactionId.isNotEmpty ? r.transactionId : 'srv-$nowIso',
          accNumber: owner.accNumber,
          vbCode: owner.vbCode,
          bankbookNumber: owner.bankbookNumber,
          amount: amount,
          date: r.date.isNotEmpty ? r.date : nowIso,
          description: note ?? 'Savings withdrawal',
          paymentMethod: r.paymentMethod,
          pending: false,
        ));
        return WithdrawOutcome(synced: true, newBalance: r.newBalance);
      } on ApiException {
        // The server explicitly rejected the request (4xx/5xx).
        // Rethrow so the screen shows the real error — do NOT treat as offline.
        rethrow;
      } catch (_) {
        // Network-level failure (timeout, no route). Fall through to offline queue.
      }
    }

    // Offline (or push failed): keep locally + queue.
    final newBalance = currentBalance - amount;
    await db.applyLocalSavingsEdit(
      accNumber: owner.accNumber,
      clientId: owner.clientId,
      bankbookNumber: owner.bankbookNumber,
      newBalance: newBalance,
      pending: true,
    );
    await db.enqueueWithdraw(
      accNumber: owner.accNumber,
      vbCode: owner.vbCode,
      bankbookNumber: owner.bankbookNumber,
      clientId: owner.clientId,
      amount: amount,
      paymentMethod: paymentMethod.apiValue,
      note: note,
      requestName: requestName,
      requestAccNumber: requestAccNumber,
      createdAtIso: nowIso,
    );
    await db.insertLocalWithdrawal(Withdrawal(
      txId: 'local-${DateTime.now().microsecondsSinceEpoch}',
      accNumber: owner.accNumber,
      vbCode: owner.vbCode,
      bankbookNumber: owner.bankbookNumber,
      amount: amount,
      date: nowIso,
      description: note ?? 'Savings withdrawal (offline)',
      paymentMethod: paymentMethod,
      pending: true,
    ));
    return WithdrawOutcome(synced: false, newBalance: newBalance);
  }

  /// List withdrawals (tx 3101) for an account. Online fetches from the server
  /// (and refreshes the cache on page 1); offline reads the local cache.
  Future<PagedResult<Withdrawal>> withdrawals({
    required String token,
    required AccountOwner owner,
    int page = 1,
    int limit = 15,
  }) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final result = await api.getWithdrawals(
          token: token,
          accNumber: owner.accNumber,
          page: page,
          limit: limit,
        );
        if (page == 1) {
          await db.replaceWithdrawalsForAccount(owner.accNumber, result.items);
        }
        return result;
      } catch (_) {
        // fall through to cache
      }
    }
    return db.queryWithdrawals(accNumber: owner.accNumber, page: page, limit: limit);
  }

  /// Fetch transactions for an account.
  /// Online  → calls the API (page 1 result is also written to the JSON cache).
  /// Offline → reads the JSON-blob cache; returns an empty list if nothing cached.
  Future<PagedResult<TransactionItem>> transactions({
    required String token,
    required String accNumber,
    int page = 1,
    int limit = 15,
  }) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final result = await api.getTransactions(
          token: token,
          accNumber: accNumber,
          page: page,
          limit: limit,
        );
        if (page == 1) {
          // Cache the first page as raw JSON maps so we can restore offline.
          final raw = result.items
              .map((t) => {
                    'id': t.id,
                    'date': t.date,
                    'bankbookNumber': t.bankbookNumber,
                    'transactionCodeId': t.txCode,
                    'transactionCode': {'nameLao': t.txNameLao, 'nameEng': t.txNameEng},
                    'amount': t.amount,
                    'debitAccNumber': t.debitAccNumber,
                    'debitAccount': {'accNameLao': t.debitAccNameLao},
                    'creditAccNumber': t.creditAccNumber,
                    'description': t.description,
                    'paymentMethod': t.paymentMethod,
                  })
              .toList();
          await db.saveTxCache(accNumber, raw);
        }
        return result;
      } catch (_) {
        // fall through to cache
      }
    }
    // Offline fallback: merge the cached server transactions with any locally
    // queued (pending) withdrawals so the user can see them immediately.
    final cached = await db.loadTxCache(accNumber);
    final serverItems = cached.map(TransactionItem.fromJson).toList();

    // Load ALL rows from the local withdrawals table for this account — both
    // pending (offline-created) and previously synced rows cached on page 1.
    final localWithdrawals = await db.queryWithdrawals(
      accNumber: accNumber,
      page: 1,
      limit: 1000, // large enough to capture all local rows
    );

    // Convert local withdrawal rows to TransactionItems.
    // Only include rows whose id is NOT already in the server cache, to avoid
    // duplicates when the server has already returned the same transaction.
    final serverIds = serverItems.map((t) => t.id).toSet();
    final pendingItems = localWithdrawals.items
        .where((w) => !serverIds.contains(w.txId))
        .map((w) => w.toTransactionItem())
        .toList();

    // Merge: pending items first (newest action), then server cache.
    // Sort by date descending so the list order is always newest-first.
    final all = [...pendingItems, ...serverItems];
    all.sort((a, b) {
      final da = a.date ?? '';
      final db2 = b.date ?? '';
      return db2.compareTo(da); // descending
    });

    return PagedResult<TransactionItem>(
      items: all,
      total: all.length,
      page: 1,
      limit: limit,
      fromCache: true,
    );
  }

  Future<PagedResult<AccountOwner>> accountOwners({
    required String token,
    String? vbCode,
    String? bankbookNumber,
    int page = 1,
    int limit = 12,
  }) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final result = await api.getAccountOwners(
          token: token,
          vbCode: vbCode,
          bankbookNumber: bankbookNumber,
          page: page,
          limit: limit,
        );
        await db.upsertAccountOwners(result.items);
        return result;
      } catch (_) {
        // fall through to cache
      }
    }
    return db.queryAccountOwners(
      vbCode: vbCode,
      bankbookNumber: bankbookNumber,
      page: page,
      limit: limit,
    );
  }
}
