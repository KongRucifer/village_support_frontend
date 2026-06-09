import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'dart:convert';
import '../models/account_owner.dart';
import '../models/transaction_item.dart';
import '../models/vb_code.dart';
import '../models/withdrawal.dart';

/// SQLite mirror of the backend data, so the app keeps working with no internet.
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'village_support.db');
    return openDatabase(
      path,
      version: 10,
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE account_owners ADD COLUMN pending INTEGER DEFAULT 0');
          await db.execute(_createOutboxSql);
        }
        if (oldV < 3) {
          if (oldV == 2) await db.execute('ALTER TABLE outbox ADD COLUMN amount INTEGER');
          await db.execute(_createWithdrawalsSql);
        }
        if (oldV < 4) {
          for (final sql in [
            "ALTER TABLE withdrawals ADD COLUMN payment_method TEXT DEFAULT 'Cash'",
            "ALTER TABLE outbox ADD COLUMN payment_method TEXT DEFAULT 'Cash'",
          ]) {
            try { await db.execute(sql); } catch (_) {}
          }
        }
        if (oldV < 5) {
          await db.execute(_createTxCacheSql);
        }
        if (oldV < 6) {
          // Security upgrade: replace the insecure cached_users table.
          await db.execute('DROP TABLE IF EXISTS cached_users');
          await db.execute(_createCachedUsersSql);
        }
        if (oldV < 7) {
          // Bank Transfer recipient fields in the offline outbox.
          for (final sql in [
            'ALTER TABLE outbox ADD COLUMN request_name TEXT',
            'ALTER TABLE outbox ADD COLUMN request_acc_number TEXT',
          ]) {
            try { await db.execute(sql); } catch (_) {}
          }
        }
        if (oldV < 8) {
          // Offline check-in / check-out status (mirrors backend vbc_arrangement).
          await db.execute(_createCheckinStatusSql);
        }
        if (oldV < 9) {
          // Re-key checkin_status by (bankbook, vbcode, date) to match the
          // server's vbc_arrangement so it can be synced. It's only a cache,
          // so dropping and recreating is safe.
          await db.execute('DROP TABLE IF EXISTS checkin_status');
          await db.execute(_createCheckinStatusSql);
        }
        if (oldV < 10) {
          // Full offline mirror: id_document lookups + all payment history.
          await db.execute(_createIdDocumentsSql);
          await db.execute(_createTxAllSql);
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE vb_codes (
            vb_code TEXT PRIMARY KEY,
            name_lao TEXT,
            name_eng TEXT,
            province_id TEXT,
            province_name TEXT,
            district_id TEXT,
            district_name TEXT,
            village_bank_name TEXT,
            founding_date TEXT,
            status_id TEXT,
            client_count INTEGER DEFAULT 0,
            account_owner_count INTEGER DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE account_owners (
            bankbook_number TEXT,
            acc_number TEXT,
            vb_code TEXT,
            client_id TEXT,
            client_name TEXT,
            acc_name_lao TEXT,
            acc_name_eng TEXT,
            current_balance INTEGER DEFAULT 0,
            account_type TEXT,
            status_id TEXT,
            pending INTEGER DEFAULT 0,
            PRIMARY KEY (bankbook_number, acc_number, client_id)
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_owner_vb ON account_owners (vb_code, bankbook_number)
        ''');
        await db.execute(_createOutboxSql);
        await db.execute(_createWithdrawalsSql);
        await db.execute(_createTxCacheSql);
        await db.execute(_createCachedUsersSql);
        await db.execute(_createCheckinStatusSql);
        await db.execute(_createIdDocumentsSql);
        await db.execute(_createTxAllSql);
        await db.execute('''
          CREATE TABLE sync_meta (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');
      },
    );
  }

  // ── Sync meta ───────────────────────────────────────────────────────────────
  Future<String?> getMeta(String key) async {
    final db = await database;
    final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await database;
    await db.insert('sync_meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ── Cached users (offline login) ─────────────────────────────────────────────
  // Security model:
  //   • password is NEVER stored. Only SHA-256(password:salt) hash is kept.
  //   • JWT token is NOT stored here — it lives in OS secure storage (Keychain/Keystore).
  //   • salt is random (32 bytes) and unique per user, preventing rainbow-table attacks.

  static const String _createCachedUsersSql = '''
    CREATE TABLE IF NOT EXISTS cached_users (
      user_name     TEXT PRIMARY KEY,
      password_hash TEXT NOT NULL,
      password_salt TEXT NOT NULL,
      id            INTEGER,
      roles         TEXT
    )
  ''';

  /// ບັນທຶກ user credentials ໂດຍ hash password ກ່ອນ. Token ຖືກເກັບໃນ SecureStorage.
  Future<void> saveCachedUser({
    required String userName,
    required String passwordHash,  // SHA-256(password:salt) — NOT plaintext
    required String passwordSalt,
    required int id,
    required List<String> roles,
  }) async {
    final db = await database;
    await db.insert(
      'cached_users',
      {
        'user_name': userName,
        'password_hash': passwordHash,
        'password_salt': passwordSalt,
        'id': id,
        'roles': roles.join(','),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// ດຶງ row ຂອງ user ເພື່ອ verify password ໂດຍ caller (ບໍ່ compare ໃນ SQL).
  Future<Map<String, dynamic>?> getCachedUserRow(String userName) async {
    final db = await database;
    final rows = await db.query(
      'cached_users',
      where: 'user_name = ?',
      whereArgs: [userName],
    );
    return rows.isEmpty ? null : rows.first;
  }

  // ── VbCodes ───────────────────────────────────────────────────────────────
  Future<void> upsertVbCodes(List<VbCode> items) async {
    if (items.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final v in items) {
      batch.insert('vb_codes', v.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<PagedResult<VbCode>> queryVbCodes({
    String? search,
    int page = 1,
    int limit = 12,
  }) async {
    final db = await database;
    final term = search?.trim();
    final where = (term != null && term.isNotEmpty)
        ? 'vb_code LIKE ? OR name_lao LIKE ? OR name_eng LIKE ?'
        : null;
    final args = (term != null && term.isNotEmpty)
        ? ['%$term%', '%$term%', '%$term%']
        : null;

    final countRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM vb_codes${where != null ? ' WHERE $where' : ''}',
      args,
    );
    final total = (countRows.first['c'] as int?) ?? 0;

    final rows = await db.query(
      'vb_codes',
      where: where,
      whereArgs: args,
      orderBy: 'vb_code ASC',
      limit: limit,
      offset: (page - 1) * limit,
    );

    return PagedResult<VbCode>(
      items: rows.map(VbCode.fromDb).toList(),
      total: total,
      page: page,
      limit: limit,
      fromCache: true,
    );
  }

  /// Look up a single account-owner row by its account number.
  Future<AccountOwner?> getAccountOwnerByAccNumber(String accNumber) async {
    final db = await database;
    final rows = await db.query(
      'account_owners',
      where: 'acc_number = ?',
      whereArgs: [accNumber.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : AccountOwner.fromDb(rows.first);
  }

  Future<VbCode?> getVbCode(String vbCode) async {
    final db = await database;
    final rows = await db.query('vb_codes', where: 'vb_code = ?', whereArgs: [vbCode]);
    return rows.isEmpty ? null : VbCode.fromDb(rows.first);
  }

  // ── Account owners ──────────────────────────────────────────────────────────
  Future<void> upsertAccountOwners(List<AccountOwner> items) async {
    if (items.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final o in items) {
      batch.insert('account_owners', o.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<PagedResult<AccountOwner>> queryAccountOwners({
    String? vbCode,
    String? bankbookNumber,
    int page = 1,
    int limit = 12,
  }) async {
    final db = await database;
    final clauses = <String>[];
    final args = <Object>[];
    if (vbCode != null && vbCode.trim().isNotEmpty) {
      clauses.add('vb_code = ?');
      args.add(vbCode.trim());
    }
    if (bankbookNumber != null && bankbookNumber.trim().isNotEmpty) {
      clauses.add('bankbook_number = ?');
      args.add(bankbookNumber.trim());
    }
    final where = clauses.isEmpty ? null : clauses.join(' AND ');

    final countRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM account_owners${where != null ? ' WHERE $where' : ''}',
      args.isEmpty ? null : args,
    );
    final total = (countRows.first['c'] as int?) ?? 0;

    final rows = await db.query(
      'account_owners',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'bankbook_number ASC, acc_number ASC',
      limit: limit,
      offset: (page - 1) * limit,
    );

    return PagedResult<AccountOwner>(
      items: rows.map(AccountOwner.fromDb).toList(),
      total: total,
      page: page,
      limit: limit,
      fromCache: true,
    );
  }

  Future<int> countAll(String table) async {
    final db = await database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (rows.first['c'] as int?) ?? 0;
  }

  // ── Offline write queue (outbox) ────────────────────────────────────────────
  static const String _createOutboxSql = '''
    CREATE TABLE IF NOT EXISTS outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      op TEXT,
      acc_number TEXT,
      vb_code TEXT,
      bankbook_number TEXT,
      client_id TEXT,
      new_balance INTEGER,
      amount INTEGER,
      payment_method TEXT DEFAULT 'Cash',
      request_name TEXT,
      request_acc_number TEXT,
      note TEXT,
      created_at TEXT
    )
  ''';

  // ── Withdrawal transactions cache (tx code 3101) ────────────────────────────
  static const String _createWithdrawalsSql = '''
    CREATE TABLE IF NOT EXISTS withdrawals (
      tx_id TEXT PRIMARY KEY,
      acc_number TEXT,
      vb_code TEXT,
      bankbook_number TEXT,
      amount INTEGER,
      date TEXT,
      description TEXT,
      tx_name TEXT,
      payment_method TEXT DEFAULT 'Cash',
      pending INTEGER DEFAULT 0
    )
  ''';

  /// Apply a savings edit to the local cache immediately and (if queued) mark
  /// the row as pending so the UI can show it hasn't reached the server yet.
  Future<void> applyLocalSavingsEdit({
    required String accNumber,
    required String clientId,
    required String bankbookNumber,
    required int newBalance,
    required bool pending,
  }) async {
    final db = await database;
    await db.update(
      'account_owners',
      {'current_balance': newBalance, 'pending': pending ? 1 : 0},
      where: 'acc_number = ? AND client_id = ? AND bankbook_number = ?',
      whereArgs: [accNumber, clientId, bankbookNumber],
    );
  }

  Future<void> enqueueSavingsEdit({
    required String accNumber,
    required String vbCode,
    required String bankbookNumber,
    required String clientId,
    required int newBalance,
    String? note,
    required String createdAtIso,
  }) async {
    final db = await database;
    await db.insert('outbox', {
      'op': 'update_savings',
      'acc_number': accNumber,
      'vb_code': vbCode,
      'bankbook_number': bankbookNumber,
      'client_id': clientId,
      'new_balance': newBalance,
      'note': note,
      'created_at': createdAtIso,
    });
  }

  // ── Check-in / check-out status (mirrors backend vbc_arrangement) ───────────
  // Keyed by (bankbook_number, vb_code, date) — same as the server.
  // points: 1 = checked in, 0 = checked out.
  // need_sync: 'i' = checked in, 'u' = checked out (same meaning as backend).
  static const String _createCheckinStatusSql = '''
    CREATE TABLE IF NOT EXISTS checkin_status (
      bankbook_number TEXT,
      vb_code         TEXT,
      date            TEXT,
      points          INTEGER,
      need_sync       TEXT,
      last_update     TEXT,
      PRIMARY KEY (bankbook_number, vb_code, date)
    )
  ''';

  /// Returns the check-in row for a member (bankbook + vbCode) on a given date
  /// ('YYYY-MM-DD'), or null if there is none.
  Future<Map<String, dynamic>?> getCheckinStatus(
    String bankbookNumber,
    String vbCode,
    String date,
  ) async {
    final db = await database;
    final rows = await db.query(
      'checkin_status',
      where: 'bankbook_number = ? AND vb_code = ? AND date = ?',
      whereArgs: [bankbookNumber.trim(), vbCode.trim(), date],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Insert or update the local check-in status for a member on a date.
  Future<void> upsertCheckinStatus({
    required String bankbookNumber,
    required String vbCode,
    required String date,
    required int points,
    required String needSync,
    String? lastUpdate,
  }) async {
    final db = await database;
    await db.insert(
      'checkin_status',
      {
        'bankbook_number': bankbookNumber.trim(),
        'vb_code': vbCode.trim(),
        'date': date,
        'points': points,
        'need_sync': needSync,
        'last_update': lastUpdate,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Merge server check-in rows into the local cache (upsert by primary key).
  /// We upsert rather than delete-all so a locally-queued offline check-in that
  /// hasn't been pushed yet is never wiped. Old rows are cleaned separately via
  /// [deleteCheckinsBefore].
  Future<void> bulkUpsertCheckins(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('checkin_status', r,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Delete check-in rows older than [date] ('YYYY-MM-DD') — keeps the table
  /// small since only today's rows matter for the guards.
  Future<void> deleteCheckinsBefore(String date) async {
    final db = await database;
    await db.delete('checkin_status', where: 'date < ?', whereArgs: [date]);
  }

  /// Reconcile today's check-in rows with the fresh server snapshot.
  ///
  /// Unlike a plain upsert, this also **deletes** today's local rows the server
  /// no longer has — so an admin editing/deleting a `vbc_arrangement` row (e.g.
  /// moving it to another day, or resetting it back to check-in) is reflected
  /// locally on the next sync. Without this, a stale "checked out today" row
  /// would survive and the guard would keep saying "already checked in and out".
  ///
  /// [pendingKeys] are 'bankbook|vbcode' of offline check-in/withdraw ops still
  /// waiting in the outbox; their local state is preserved (never deleted or
  /// overwritten) so an unsynced edit is never lost.
  Future<void> replaceTodayCheckins({
    required String today,
    required List<Map<String, Object?>> serverRows,
    required Set<String> pendingKeys,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      // 1. Drop today's non-pending local rows (server is the source of truth).
      final existing = await txn.query('checkin_status',
          where: 'date = ?', whereArgs: [today]);
      for (final row in existing) {
        final bb = (row['bankbook_number'] ?? '').toString().trim();
        final vb = (row['vb_code'] ?? '').toString().trim();
        if (pendingKeys.contains('$bb|$vb')) continue; // keep unsynced offline edit
        await txn.delete(
          'checkin_status',
          where: 'bankbook_number = ? AND vb_code = ? AND date = ?',
          whereArgs: [row['bankbook_number'], row['vb_code'], today],
        );
      }
      // 2. Upsert the server's rows (pending keys keep their local state).
      for (final r in serverRows) {
        final bb = (r['bankbook_number'] ?? '').toString().trim();
        final vb = (r['vb_code'] ?? '').toString().trim();
        if (pendingKeys.contains('$bb|$vb')) continue; // local pending wins
        await txn.insert('checkin_status', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Queue an offline check-in for later sync (outbox op = 'checkin').
  Future<void> enqueueCheckin({
    required String accNumber,
    required String vbCode,
    required String bankbookNumber,
    required String clientId,
    required String createdAtIso,
  }) async {
    final db = await database;
    await db.insert('outbox', {
      'op': 'checkin',
      'acc_number': accNumber,
      'vb_code': vbCode,
      'bankbook_number': bankbookNumber,
      'client_id': clientId,
      'created_at': createdAtIso,
    });
  }

  Future<void> enqueueWithdraw({
    required String accNumber,
    required String vbCode,
    required String bankbookNumber,
    required String clientId,
    required int amount,
    required String paymentMethod, // 'Cash' or 'BankTransfer'
    String? requestName,
    String? requestAccNumber,
    String? note,
    required String createdAtIso,
  }) async {
    final db = await database;
    await db.insert('outbox', {
      'op': 'withdraw',
      'acc_number': accNumber,
      'vb_code': vbCode,
      'bankbook_number': bankbookNumber,
      'client_id': clientId,
      'amount': amount,
      'payment_method': paymentMethod,
      'request_name': requestName,
      'request_acc_number': requestAccNumber,
      'note': note,
      'created_at': createdAtIso,
    });
  }

  Future<List<Map<String, dynamic>>> pendingOutbox() async {
    final db = await database;
    return db.query('outbox', orderBy: 'id ASC');
  }

  // ── Withdrawals cache (tx 3101) ─────────────────────────────────────────────
  /// Replace the cached withdrawals for one account with a fresh server list.
  Future<void> replaceWithdrawalsForAccount(
    String accNumber,
    List<Withdrawal> items,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('withdrawals', where: 'acc_number = ?', whereArgs: [accNumber]);
      for (final w in items) {
        await txn.insert('withdrawals', w.toDb(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Insert a locally-made (offline) withdrawal so it shows immediately.
  Future<void> insertLocalWithdrawal(Withdrawal w) async {
    final db = await database;
    await db.insert('withdrawals', w.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PagedResult<Withdrawal>> queryWithdrawals({
    required String accNumber,
    int page = 1,
    int limit = 15,
  }) async {
    final db = await database;
    final countRows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM withdrawals WHERE acc_number = ?',
      [accNumber],
    );
    final total = (countRows.first['c'] as int?) ?? 0;
    final rows = await db.query(
      'withdrawals',
      where: 'acc_number = ?',
      whereArgs: [accNumber],
      orderBy: 'date DESC',
      limit: limit,
      offset: (page - 1) * limit,
    );
    return PagedResult<Withdrawal>(
      items: rows.map(Withdrawal.fromDb).toList(),
      total: total,
      page: page,
      limit: limit,
      fromCache: true,
    );
  }

  Future<int> pendingOutboxCount() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> deleteOutbox(int id) async {
    final db = await database;
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearPendingFlag(String accNumber, String clientId) async {
    final db = await database;
    await db.update(
      'account_owners',
      {'pending': 0},
      where: 'acc_number = ? AND client_id = ?',
      whereArgs: [accNumber, clientId],
    );
  }


  // ── Delete-aware prune for account_owners ───────────────────────────────────
  /// Remove locally-cached account_owner rows the server no longer has.
  /// [keepKeys] is the full server key set ('bankbook|acc|client'). Rows still
  /// marked pending (unsynced offline edits) are always kept so nothing is lost.
  Future<void> pruneAccountOwners(Set<String> keepKeys) async {
    if (keepKeys.isEmpty) return; // never wipe everything on an empty snapshot
    final db = await database;
    final rows = await db.query('account_owners',
        columns: ['bankbook_number', 'acc_number', 'client_id', 'pending']);
    final batch = db.batch();
    for (final r in rows) {
      if (((r['pending'] ?? 0) as int) == 1) continue; // keep unsynced edits
      final key =
          '${r['bankbook_number']}|${r['acc_number']}|${r['client_id']}';
      if (!keepKeys.contains(key)) {
        batch.delete('account_owners',
            where: 'bankbook_number = ? AND acc_number = ? AND client_id = ?',
            whereArgs: [r['bankbook_number'], r['acc_number'], r['client_id']]);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Prune vb_codes down to the server's current set (vbCodes always come in full).
  Future<void> pruneVbCodes(Set<String> keepCodes) async {
    if (keepCodes.isEmpty) return;
    final db = await database;
    final rows = await db.query('vb_codes', columns: ['vb_code']);
    final batch = db.batch();
    for (final r in rows) {
      final code = (r['vb_code'] ?? '').toString();
      if (!keepCodes.contains(code)) {
        batch.delete('vb_codes', where: 'vb_code = ?', whereArgs: [code]);
      }
    }
    await batch.commit(noResult: true);
  }

  // ── id_document mirror (offline lookup by document number) ───────────────────
  static const String _createIdDocumentsSql = '''
    CREATE TABLE IF NOT EXISTS id_documents (
      id                 TEXT PRIMARY KEY,
      id_document_number TEXT,
      client_id          TEXT,
      vb_code            TEXT,
      name_lao           TEXT,
      name_eng           TEXT
    )
  ''';

  Future<void> bulkUpsertIdDocuments(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('id_documents', r,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Delete locally-cached id_document rows the server no longer has.
  Future<void> pruneIdDocuments(Set<String> keepIds) async {
    if (keepIds.isEmpty) return;
    final db = await database;
    final rows = await db.query('id_documents', columns: ['id']);
    final batch = db.batch();
    for (final r in rows) {
      final id = (r['id'] ?? '').toString();
      if (!keepIds.contains(id)) {
        batch.delete('id_documents', where: 'id = ?', whereArgs: [id]);
      }
    }
    await batch.commit(noResult: true);
  }

  /// Resolve a document number (optionally scoped to a vbCode) to its clientId,
  /// mirroring the backend's id_document lookup. Returns null if not found.
  Future<String?> clientIdByDocument(String idNumber, {String? vbCode}) async {
    final db = await database;
    final clauses = <String>['id_document_number = ?'];
    final args = <Object>[idNumber.trim()];
    if (vbCode != null && vbCode.trim().isNotEmpty) {
      clauses.add('vb_code = ?');
      args.add(vbCode.trim());
    }
    final rows = await db.query(
      'id_documents',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['client_id'] as String?;
  }

  /// Find the account_owner for a client (optionally scoped to a vbCode).
  Future<AccountOwner?> getAccountOwnerByClientId(String clientId,
      {String? vbCode}) async {
    final db = await database;
    final clauses = <String>['client_id = ?'];
    final args = <Object>[clientId];
    if (vbCode != null && vbCode.trim().isNotEmpty) {
      clauses.add('vb_code = ?');
      args.add(vbCode.trim());
    }
    final rows = await db.query(
      'account_owners',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'acc_number ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : AccountOwner.fromDb(rows.first);
  }

  // ── Full payment-history mirror (tx 3101 for ALL accounts) ──────────────────
  // A transaction links to an account via debit_acc_number OR credit_acc_number,
  // so history for account X queries both sides.
  static const String _createTxAllSql = '''
    CREATE TABLE IF NOT EXISTS tx_all (
      id                 TEXT PRIMARY KEY,
      date               TEXT,
      bankbook_number    TEXT,
      tx_code            TEXT,
      tx_name_lao        TEXT,
      tx_name_eng        TEXT,
      amount             INTEGER,
      debit_acc_number   TEXT,
      debit_acc_name_lao TEXT,
      credit_acc_number  TEXT,
      description        TEXT,
      payment_method     TEXT
    )
  ''';

  Future<void> bulkUpsertTransactions(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('tx_all', r, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Read mirrored payment history for one account (matches either acc side).
  Future<List<TransactionItem>> queryTxAll(String accNumber,
      {int limit = 1000}) async {
    final db = await database;
    final acc = accNumber.trim();
    final rows = await db.query(
      'tx_all',
      where: 'debit_acc_number = ? OR credit_acc_number = ?',
      whereArgs: [acc, acc],
      orderBy: 'date DESC',
      limit: limit,
    );
    return rows
        .map((r) => TransactionItem(
              id: (r['id'] ?? '') as String,
              date: r['date'] as String?,
              bankbookNumber: r['bankbook_number'] as String?,
              txCode: (r['tx_code'] ?? '') as String,
              txNameLao: r['tx_name_lao'] as String?,
              txNameEng: r['tx_name_eng'] as String?,
              amount: (r['amount'] ?? 0) as num,
              debitAccNumber: (r['debit_acc_number'] ?? '') as String,
              debitAccNameLao: r['debit_acc_name_lao'] as String?,
              creditAccNumber: (r['credit_acc_number'] ?? '') as String,
              description: r['description'] as String?,
              paymentMethod: r['payment_method'] as String?,
            ))
        .toList();
  }

  // ── Transaction JSON-blob cache ──────────────────────────────────────────────
  // Stores the last fetched transactions per account as a JSON blob so the
  // list screen can show something meaningful while offline.

  static const String _createTxCacheSql = '''
    CREATE TABLE IF NOT EXISTS tx_cache (
      acc_number TEXT PRIMARY KEY,
      data       TEXT,
      fetched_at TEXT
    )
  ''';

  Future<void> saveTxCache(String accNumber, List<Map<String, dynamic>> rows) async {
    final db = await database;
    await db.insert(
      'tx_cache',
      {
        'acc_number': accNumber,
        'data': jsonEncode(rows),
        'fetched_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns cached rows (already decoded), or an empty list if nothing cached.
  Future<List<Map<String, dynamic>>> loadTxCache(String accNumber) async {
    final db = await database;
    final rows = await db.query('tx_cache',
        where: 'acc_number = ?', whereArgs: [accNumber]);
    if (rows.isEmpty) return [];
    try {
      final decoded = jsonDecode(rows.first['data'] as String);
      if (decoded is List) return decoded.cast<Map<String, dynamic>>();
    } catch (_) {}
    return [];
  }
}
