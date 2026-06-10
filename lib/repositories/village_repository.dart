import 'package:flutter/foundation.dart';

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

/// Fixed deposit added to a member's savings balance on every check-in.
/// Single source of truth for both the UI and the queued offline write.
const int kCheckInDeposit = 195000;

/// Description stored for a payment — mirrors the backend's wording so the
/// offline history shows the same text the server records.
String paymentDescriptionFor(PaymentMethodType pm) =>
    pm == PaymentMethodType.bankTransfer
        ? 'disbursement money for member by Bank Transfer'
        : 'disbursement money for member by Cash';

/// Result of a check-in attempt.
class CheckInOutcome {
  final bool synced;     // reached the server (vbc_arrangement row created)
  final int newBalance;  // savings balance after the deposit
  CheckInOutcome({required this.synced, required this.newBalance});
}

/// Local today's date as 'YYYY-MM-DD' (device-local, matches backend's
/// per-day check-in semantics).
String _todayStr() {
  final n = DateTime.now();
  final mm = n.month.toString().padLeft(2, '0');
  final dd = n.day.toString().padLeft(2, '0');
  return '${n.year}-$mm-$dd';
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

  /// Find an account owner by ID-document number.
  /// Online  → server (and caches the owner into SQLite).
  /// Offline → resolves via the mirrored id_documents → account_owners tables,
  ///           so document lookup keeps working with no internet.
  /// Returns null when no matching account is found anywhere.
  Future<AccountOwner?> findOwnerByDocument({
    required String token,
    required String idNumber,
    String? vbCode,
  }) async {
    if (await connectivity.isOnline() && token.isNotEmpty) {
      try {
        final owner = await api.findByDocumentId(
          token: token,
          idNumber: idNumber,
          vbCode: vbCode,
        );
        if (owner != null) await db.upsertAccountOwners([owner]);
        return owner;
      } catch (_) {
        // Network/server failure — fall through to the offline mirror.
      }
    }
    final clientId = await db.clientIdByDocument(idNumber, vbCode: vbCode);
    if (clientId == null) return null;
    return db.getAccountOwnerByClientId(clientId, vbCode: vbCode);
  }

  /// Check in a member. Online → inserts a vbc_arrangement row on the server.
  /// Offline (or server unreachable) → enforces the same guards locally and
  /// queues the check-in for sync. Throws [ApiException] (with an error `code`)
  /// when a guard fails, so the UI can show a localized message.
  Future<CheckInOutcome> checkInAccount({
    required String token,
    required AccountOwner owner,
    int amount = kCheckInDeposit,
  }) async {
    final online = await connectivity.isOnline() && token.isNotEmpty;
    final today = _todayStr();

    if (online) {
      try {
        final serverBalance = await api.checkIn(
          token: token,
          accNumber: owner.accNumber,
          vbCode: owner.vbCode,
          amount: amount,
        );
        // Server accepted → mirror the state locally (checked in + new balance).
        await db.upsertCheckinStatus(
          bankbookNumber: owner.bankbookNumber,
          vbCode: owner.vbCode,
          date: today,
          points: 1,
          needSync: 'i',
        );
        await db.applyLocalSavingsEdit(
          accNumber: owner.accNumber,
          clientId: owner.clientId,
          bankbookNumber: owner.bankbookNumber,
          newBalance: serverBalance,
          pending: false,
        );
        return CheckInOutcome(synced: true, newBalance: serverBalance);
      } on ApiException {
        // Real server rejection (e.g. already checked in) — show the error.
        rethrow;
      } catch (_) {
        // Network-level failure (timeout, unreachable host) — go offline.
      }
    }

    // ── Offline path: enforce the same guards the backend does ────────────────
    _guardLossStatus(owner); // status_id == '4'

    final st = await db.getCheckinStatus(owner.bankbookNumber, owner.vbCode, today);
    if (kDebugMode) {
      final allToday = await db.debugCheckinsForDate(today);
      debugPrint('[CHECKIN] offline guard acc=${owner.accNumber} '
          'bankbook="${owner.bankbookNumber}" vb="${owner.vbCode}" today=$today '
          'matchedStatus=$st | allTodayRows=$allToday');
    }
    if (st != null) {
      final points = (st['points'] ?? -1) as int;
      final needSync = st['need_sync'] as String?;
      // Already checked in AND out today.
      if (points == 0 && needSync == 'u') {
        throw ApiException(
            'Already checked in and out today', 409, 'ALREADY_CHECKED_IN_OUT_TODAY');
      }
      // Already checked in (not yet paid).
      if (points == 1 && needSync == 'i') {
        throw ApiException('Already checked in today', 409, 'ALREADY_CHECKED_IN');
      }
    }

    // Deposit the fixed amount locally (optimistic) and queue both the check-in
    // and the deposit so the server applies them once we're back online.
    final newBalance = owner.currentBalance + amount;
    await db.upsertCheckinStatus(
      bankbookNumber: owner.bankbookNumber,
      vbCode: owner.vbCode,
      date: today,
      points: 1,
      needSync: 'i',
    );
    await db.applyLocalSavingsEdit(
      accNumber: owner.accNumber,
      clientId: owner.clientId,
      bankbookNumber: owner.bankbookNumber,
      newBalance: newBalance,
      pending: true,
    );
    await db.enqueueCheckin(
      accNumber: owner.accNumber,
      vbCode: owner.vbCode,
      bankbookNumber: owner.bankbookNumber,
      clientId: owner.clientId,
      amount: amount,
      newBalance: newBalance,
      createdAtIso: DateTime.now().toIso8601String(),
    );
    return CheckInOutcome(synced: false, newBalance: newBalance);
  }

  /// Throws an [ApiException] with code 'LOSS_STATUS' if the account is on the
  /// loss status (status_id == '4') — mirrors the backend check-in guard.
  void _guardLossStatus(AccountOwner owner) {
    if (owner.statusId?.trim() == '4') {
      throw ApiException('Account is inactive (loss status)', 400, 'LOSS_STATUS');
    }
  }

  /// Throws 'NOT_ACTIVE' unless the account is active (status_id == '2') —
  /// mirrors the backend checkout guard.
  void _guardActiveForCheckout(AccountOwner owner) {
    if (owner.statusId?.trim() != '2') {
      throw ApiException('Account is not active', 400, 'NOT_ACTIVE');
    }
  }

  /// Build the debit/credit account shown for a payment: vbCode prefixed onto the
  /// cached tx-code (6607) base. Returns null when the base hasn't synced yet
  /// (the display then falls back to the member account number).
  Future<String?> _displayAcc(String vbCode) async {
    final base = await db.getMeta('withdraw_debit_base');
    if (base == null || base.trim().isEmpty) return null;
    return vbCode.trim() + base.trim();
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
    final today = _todayStr();

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
        // Server marked the member checked-out — mirror it locally.
        await db.upsertCheckinStatus(
          bankbookNumber: owner.bankbookNumber,
          vbCode: owner.vbCode,
          date: today,
          points: 0,
          needSync: 'u',
          lastUpdate: nowIso,
        );
        // Cache the server transaction so it shows in the history even offline.
        await db.insertLocalWithdrawal(Withdrawal(
          txId: r.transactionId.isNotEmpty ? r.transactionId : 'srv-$nowIso',
          accNumber: owner.accNumber,
          vbCode: owner.vbCode,
          bankbookNumber: owner.bankbookNumber,
          amount: amount,
          date: r.date.isNotEmpty ? r.date : nowIso,
          description: note ?? paymentDescriptionFor(paymentMethod),
          paymentMethod: r.paymentMethod,
          pending: false,
          displayAccNumber: await _displayAcc(owner.vbCode),
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

    // ── Offline (or push failed): enforce the same guards the backend does ─────
    _guardActiveForCheckout(owner); // status_id must be '2' (active)

    // No cash on hand for this village bank → block (best-effort offline guard;
    // the backend re-validates authoritatively when the queued op is flushed).
    final cash = await db.getVbCashBalance(owner.vbCode);
    if (cash != null && cash <= 0) {
      throw ApiException('No cash available', 400, 'NO_CASH');
    }

    final st = await db.getCheckinStatus(owner.bankbookNumber, owner.vbCode, today);
    final points = st == null ? null : (st['points'] ?? -1) as int;
    final needSync = st == null ? null : st['need_sync'] as String?;
    // Already checked out today.
    if (points == 0 && needSync == 'u') {
      throw ApiException('Already checked out today', 400, 'ALREADY_CHECKED_OUT');
    }
    // Must check in before paying.
    if (!(points == 1 && needSync == 'i')) {
      throw ApiException('Must check in before paying', 400, 'MUST_CHECK_IN_FIRST');
    }
    // Insufficient balance.
    if (currentBalance < amount) {
      throw ApiException('Insufficient savings balance', 400, 'INSUFFICIENT_BALANCE');
    }

    // Offline (or push failed): keep locally + queue.
    final newBalance = currentBalance - amount;
    // Mark the member checked-out locally so the guards above stay consistent.
    await db.upsertCheckinStatus(
      bankbookNumber: owner.bankbookNumber,
      vbCode: owner.vbCode,
      date: today,
      points: 0,
      needSync: 'u',
      lastUpdate: nowIso,
    );
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
      description: note ?? paymentDescriptionFor(paymentMethod),
      paymentMethod: paymentMethod,
      pending: true,
      displayAccNumber: await _displayAcc(owner.vbCode),
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
    // Offline fallback: prefer the full mirrored history (tx_all) that the sync
    // pulls for EVERY account; fall back to the per-account JSON cache only if
    // the mirror is empty. Then merge any locally-queued (pending) withdrawals.
    var serverItems = await db.queryTxAll(accNumber);
    if (serverItems.isEmpty) {
      final cached = await db.loadTxCache(accNumber);
      serverItems = cached.map(TransactionItem.fromJson).toList();
    }

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
