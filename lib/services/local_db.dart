import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'dart:convert';
import '../models/account_owner.dart';
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
      version: 7,
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
