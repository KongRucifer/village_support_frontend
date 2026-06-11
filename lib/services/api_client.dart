import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../models/transaction_item.dart';
import '../models/vb_code.dart';
import '../models/withdrawal.dart'; // PaymentMethodType

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  /// Machine-readable error code from the backend (e.g. 'ALREADY_CHECKED_IN').
  /// Used by the UI to show a localized message. Null when the backend
  /// did not send a code.
  final String? code;
  ApiException(this.message, [this.statusCode, this.code]);
  @override
  String toString() => message;
}

class ApiClient {
  final http.Client _http;
  ApiClient([http.Client? client]) : _http = client ?? http.Client();

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final qp = query?.map((k, v) => MapEntry(k, '$v'))
      ?..removeWhere((_, v) => v.isEmpty);
    return Uri.parse('${AppConfig.apiBaseUrl}$path')
        .replace(queryParameters: (qp != null && qp.isNotEmpty) ? qp : null);
  }

  Map<String, String> _headers([String? token]) => {
        'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  // ── Auth: system user login (/auth/login-test) ───────────────────────────────
  Future<SystemUser> loginTest(String userName, String password) async {
    final res = await _http
        .post(
          _uri('/auth/login-test'),
          headers: _headers(),
          body: jsonEncode({'userName': userName, 'password': password}),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode == 200 || res.statusCode == 201) {
      return SystemUser.fromLoginResponse(body);
    }
    throw ApiException(_errorMessage(body, 'Login failed'), res.statusCode);
  }

  // ── VbCodes list (paginated, searchable) ─────────────────────────────────────
  Future<PagedResult<VbCode>> getVbCodes({
    required String token,
    String? search,
    int page = 1,
    int limit = 12,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/vbcodes', {
            'page': page,
            'limit': limit,
            if (search != null) 'search': search,
          }),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Failed to load vbcodes'), res.statusCode);
    }
    final results = ((body['results'] ?? []) as List)
        .map((e) => VbCode.fromJson(e as Map<String, dynamic>))
        .toList();
    final pg = (body['pagination'] ?? {}) as Map<String, dynamic>;
    return PagedResult<VbCode>(
      items: results,
      total: (pg['total'] ?? results.length) as int,
      page: (pg['page'] ?? page) as int,
      limit: (pg['limit'] ?? limit) as int,
    );
  }

  Future<VbCode> getVbCode({required String token, required String vbCode}) async {
    final res = await _http
        .get(_uri('/village-data/vbcodes/$vbCode'), headers: _headers(token))
        .timeout(AppConfig.apiTimeout);
    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'VbCode not found'), res.statusCode);
    }
    return VbCode.fromJson(body);
  }

  // ── Account owners (by vbCode + optional bankbookNumber) ─────────────────────
  Future<PagedResult<AccountOwner>> getAccountOwners({
    required String token,
    String? vbCode,
    String? bankbookNumber,
    int page = 1,
    int limit = 12,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/account-owners', {
            'page': page,
            'limit': limit,
            if (vbCode != null) 'vbCode': vbCode,
            if (bankbookNumber != null) 'bankbookNumber': bankbookNumber,
          }),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Failed to load account owners'), res.statusCode);
    }
    final results = ((body['results'] ?? []) as List)
        .map((e) => AccountOwner.fromJson(e as Map<String, dynamic>))
        .toList();
    final pg = (body['pagination'] ?? {}) as Map<String, dynamic>;
    return PagedResult<AccountOwner>(
      items: results,
      total: (pg['total'] ?? results.length) as int,
      page: (pg['page'] ?? page) as int,
      limit: (pg['limit'] ?? limit) as int,
    );
  }

  // ── Edit savings balance (write path) ───────────────────────────────────────
  Future<void> updateSavings({
    required String token,
    required String accNumber,
    required String vbCode,
    required int currentBalance,
    String? note,
  }) async {
    final res = await _http
        .patch(
          _uri('/village-data/accounts/$accNumber/savings'),
          headers: _headers(token),
          body: jsonEncode({
            'currentBalance': currentBalance,
            'vbCode': vbCode,
            if (note != null) 'note': note,
          }),
        )
        .timeout(AppConfig.apiTimeout);

    if (res.statusCode != 200) {
      final body = _decode(res);
      throw ApiException(_errorMessage(body, 'Failed to update savings'), res.statusCode);
    }
  }

  // ── Withdraw from savings (creates a 3101 transaction) ──────────────────────
  Future<WithdrawResult> withdraw({
    required String token,
    required String accNumber,
    required String vbCode,
    required int amount,
    required PaymentMethodType paymentMethod,
    String? note,
    String? requestName,       // Bank Transfer: ຊື່ຜູ້ຮັບ
    String? requestAccNumber,  // Bank Transfer: ເລກບັນຊີຜູ້ຮັບ
  }) async {
    final res = await _http
        .post(
          _uri('/village-data/accounts/$accNumber/withdraw'),
          headers: _headers(token),
          body: jsonEncode({
            'amount': amount,
            'vbCode': vbCode,
            'paymentMethod': paymentMethod.apiValue,
            if (note != null) 'note': note,
            if (requestName != null && requestName.isNotEmpty)
              'requestName': requestName,
            if (requestAccNumber != null && requestAccNumber.isNotEmpty)
              'requestAccNumber': requestAccNumber,
          }),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(
        _errorMessage(body, 'Withdraw failed'),
        res.statusCode,
        _errorCode(body),
      );
    }
    return WithdrawResult(
      newBalance: (body['currentBalance'] ?? 0) as int,
      transactionId: (body['transactionId'] ?? '') as String,
      paymentMethod: PaymentMethodType.fromApi(body['paymentMethod'] as String?),
      date: (body['date'] ?? '').toString(),
    );
  }

  // ── Overdue payment summary for an account ──────────────────────────────────
  /// Returns the accumulated unpaid equity-saving balance (overduePayment) and
  /// the number of unpaid check-ins (countOverduePayment).
  Future<OverdueInfo> getOverdue({
    required String token,
    required String accNumber,
    String? vbCode,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/accounts/${accNumber.trim()}/overdue', {
            if (vbCode != null && vbCode.isNotEmpty) 'vbCode': vbCode,
          }),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(
        _errorMessage(body, 'Failed to load overdue'),
        res.statusCode,
        _errorCode(body),
      );
    }
    return OverdueInfo(
      overduePayment: (body['overduePayment'] ?? 0) as int,
      overdueCount: (body['countOverduePayment'] ?? 0) as int,
    );
  }

  // ── Check in (records vbc_arrangement + deposits the fixed amount) ───────────
  /// Throws [ApiException] with statusCode 409 if already checked in.
  /// Returns the account's new savings balance after the deposit.
  Future<int> checkIn({
    required String token,
    required String accNumber,
    String? vbCode,
    required int amount,
  }) async {
    final res = await _http
        .post(
          _uri('/village-data/accounts/${accNumber.trim()}/checkin'),
          headers: _headers(token),
          body: jsonEncode({
            if (vbCode?.isNotEmpty == true) 'vbCode': vbCode,
            'amount': amount,
          }),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(
        _errorMessage(body, 'Check-in failed'),
        res.statusCode,
        _errorCode(body),
      );
    }
    return (body['currentBalance'] ?? 0) as int;
  }

  // ── List withdrawal transactions (tx 3101) for an account ───────────────────
  Future<PagedResult<Withdrawal>> getWithdrawals({
    required String token,
    required String accNumber,
    int page = 1,
    int limit = 15,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/accounts/$accNumber/withdrawals', {
            'page': page,
            'limit': limit,
          }),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Failed to load withdrawals'), res.statusCode);
    }
    final results = ((body['results'] ?? []) as List)
        .map((e) => Withdrawal.fromJson(e as Map<String, dynamic>))
        .toList();
    final pg = (body['pagination'] ?? {}) as Map<String, dynamic>;
    return PagedResult<Withdrawal>(
      items: results,
      total: (pg['total'] ?? results.length) as int,
      page: (pg['page'] ?? page) as int,
      limit: (pg['limit'] ?? limit) as int,
    );
  }

  // ── Find account owner by account number (QR contains only accNumber) ───────
  /// Backend resolves bankbookNumber + vbCode automatically.
  /// Returns null on 404 (not found), throws [ApiException] on other errors.
  Future<AccountOwner?> findByAccount({
    required String token,
    required String accNumber,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/find-by-account', {'accNumber': accNumber.trim()}),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    if (res.statusCode == 404) return null;
    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Account lookup failed'), res.statusCode);
    }
    return AccountOwner.fromJson(body);
  }

  // ── Find account owner by ID document number ─────────────────────────────
  /// Returns null if not found (404), throws [ApiException] for other errors.
  Future<AccountOwner?> findByDocumentId({
    required String token,
    required String idNumber,
    String? vbCode,
  }) async {
    final res = await _http
        .get(
          _uri('/village-data/find-by-document', {
            'idNumber': idNumber.trim(),
            if (vbCode != null && vbCode.isNotEmpty) 'vbCode': vbCode,
          }),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    if (res.statusCode == 404) return null;
    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Document lookup failed'), res.statusCode);
    }
    return AccountOwner.fromJson(body);
  }

  // ── Payment transactions list for an account (tx code 3101 only) ────────────
  /// Calls GET /transactions/account/:accNumber/payments (paginated, only 3101).
  Future<PagedResult<TransactionItem>> getTransactions({
    required String token,
    required String accNumber,
    int page = 1,
    int limit = 15,
  }) async {
    final res = await _http
        .get(
          _uri('/transactions/account/$accNumber/payments', {'page': page, 'limit': limit}),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Failed to load transactions'), res.statusCode);
    }
    final results = ((body['results'] ?? []) as List)
        .map((e) => TransactionItem.fromJson(e as Map<String, dynamic>))
        .toList();
    final pg = (body['pagination'] ?? {}) as Map<String, dynamic>;
    return PagedResult<TransactionItem>(
      items: results,
      total: (pg['total'] ?? results.length) as int,
      page: (pg['page'] ?? page) as int,
      limit: (pg['limit'] ?? limit) as int,
    );
  }

  // ── Sync snapshot ─────────────────────────────────────────────────────────
  Future<SyncSnapshot> getSync({required String token, String? since}) async {
    final sw = Stopwatch()..start();
    final res = await _http
        .get(
          _uri('/village-data/sync', {if (since != null) 'since': since}),
          headers: _headers(token),
        )
        // Full pull can be large (all accounts + transactions). The server gzips
        // the response (~10x smaller) and the dart http client auto-decompresses,
        // but allow generous headroom so a big first sync isn't cut off.
        .timeout(const Duration(seconds: 120));
    final kb = (res.bodyBytes.length / 1024).toStringAsFixed(1);
    debugPrint('[API] GET /sync since=${since ?? '-'} → '
        'status=${res.statusCode} decoded=${kb}KB in ${sw.elapsedMilliseconds}ms');
    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Sync failed'), res.statusCode);
    }
    return SyncSnapshot(
      serverTime: (body['serverTime'] ?? '') as String,
      vbCodes: ((body['vbCodes'] ?? []) as List)
          .map((e) => VbCode.fromJson(e as Map<String, dynamic>))
          .toList(),
      accountOwners: ((body['accountOwners'] ?? []) as List)
          .map((e) => AccountOwner.fromJson(e as Map<String, dynamic>))
          .toList(),
      checkins: ((body['checkins'] ?? []) as List)
          .map((e) => CheckinSync.fromJson(e as Map<String, dynamic>))
          .toList(),
      idDocuments: ((body['idDocuments'] ?? []) as List)
          .map((e) => IdDocumentSync.fromJson(e as Map<String, dynamic>))
          .toList(),
      transactions: ((body['transactions'] ?? []) as List)
          .map((e) => TransactionItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      accountOwnerKeys: ((body['accountOwnerKeys'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
      idDocumentIds: ((body['idDocumentIds'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
      withdrawDebitBase: (body['withdrawDebitBase'] ?? '') as String,
      withdrawCreditBase: (body['withdrawCreditBase'] ?? '') as String,
    );
  }

  /// Lightweight check-in reconcile: only today's vbc_arrangement rows.
  /// Tiny payload (uses the normal short timeout) so it finishes fast even when
  /// the full [getSync] snapshot is too big to download on a brief connection.
  Future<CheckinsResult> getCheckins({required String token}) async {
    final res = await _http
        .get(
          _uri('/village-data/sync/checkins'),
          headers: _headers(token),
        )
        .timeout(AppConfig.apiTimeout);
    final body = _decode(res);
    if (res.statusCode != 200) {
      throw ApiException(_errorMessage(body, 'Check-in sync failed'), res.statusCode);
    }
    return CheckinsResult(
      serverTime: (body['serverTime'] ?? '') as String,
      checkins: ((body['checkins'] ?? []) as List)
          .map((e) => CheckinSync.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.body.isEmpty) return {};
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }

  String _errorMessage(Map<String, dynamic> body, String fallback) {
    final msg = body['message'];
    if (msg is String) return msg;
    if (msg is List && msg.isNotEmpty) return msg.first.toString();
    if (msg is Map && msg['message'] is String) return msg['message'] as String;
    return fallback;
  }

  /// Extracts the machine-readable error code from a NestJS error body.
  /// Returns null when the backend didn't send one.
  String? _errorCode(Map<String, dynamic> body) {
    final code = body['code'];
    return code is String ? code : null;
  }
}

/// Overdue payment summary for an account ([ApiClient.getOverdue]).
class OverdueInfo {
  /// Accumulated unpaid equity-saving balance (the amount that will be paid out).
  final int overduePayment;
  /// Number of unpaid check-ins.
  final int overdueCount;
  const OverdueInfo({this.overduePayment = 0, this.overdueCount = 0});
}

class WithdrawResult {
  final int newBalance;
  final String transactionId;
  final String date;
  final PaymentMethodType paymentMethod;
  WithdrawResult({
    required this.newBalance,
    required this.transactionId,
    required this.date,
    this.paymentMethod = PaymentMethodType.cash,
  });
}

/// Result of the lightweight check-ins-only sync ([ApiClient.getCheckins]).
class CheckinsResult {
  final String serverTime;
  final List<CheckinSync> checkins;
  CheckinsResult({required this.serverTime, this.checkins = const []});
}

class SyncSnapshot {
  final String serverTime;
  final List<VbCode> vbCodes;
  final List<AccountOwner> accountOwners;
  final List<CheckinSync> checkins;
  final List<IdDocumentSync> idDocuments;
  final List<TransactionItem> transactions;
  /// Full key set of current account_owner rows ('bankbook|acc|client') so the
  /// client can prune locally-cached rows the server deleted.
  final List<String> accountOwnerKeys;
  /// Full id set of current id_document rows for the same delete-aware pruning.
  final List<String> idDocumentIds;
  /// Account base configured on the withdrawal tx code (6607). The client prefixes
  /// the vbCode onto these to build debit/credit numbers for pending offline rows.
  final String withdrawDebitBase;
  final String withdrawCreditBase;
  SyncSnapshot({
    required this.serverTime,
    required this.vbCodes,
    required this.accountOwners,
    this.checkins = const [],
    this.idDocuments = const [],
    this.transactions = const [],
    this.accountOwnerKeys = const [],
    this.idDocumentIds = const [],
    this.withdrawDebitBase = '',
    this.withdrawCreditBase = '',
  });
}

/// An id_document row pulled from the server (for offline lookup by document #).
class IdDocumentSync {
  final String id;
  final String idDocumentNumber;
  final String clientId;
  final String? vbCode;
  final String? documentNameLao;
  final String? documentNameEng;

  IdDocumentSync({
    required this.id,
    required this.idDocumentNumber,
    required this.clientId,
    this.vbCode,
    this.documentNameLao,
    this.documentNameEng,
  });

  factory IdDocumentSync.fromJson(Map<String, dynamic> j) => IdDocumentSync(
        id: (j['id'] ?? '').toString(),
        idDocumentNumber: (j['idDocumentNumber'] ?? '') as String,
        clientId: (j['clientId'] ?? '') as String,
        vbCode: j['vbCode'] as String?,
        documentNameLao: j['documentNameLao'] as String?,
        documentNameEng: j['documentNameEng'] as String?,
      );
}

/// A check-in / check-out row pulled from the server's vbc_arrangement table.
class CheckinSync {
  final String? bankbookNumber;
  final String vbCode;
  final String date;       // 'YYYY-MM-DD'
  final int? points;       // 1 = checked in, 0 = checked out
  final String? needSync;  // 'i' = checked in, 'u' = checked out
  final String? lastUpdate;

  CheckinSync({
    required this.bankbookNumber,
    required this.vbCode,
    required this.date,
    required this.points,
    required this.needSync,
    required this.lastUpdate,
  });

  factory CheckinSync.fromJson(Map<String, dynamic> j) => CheckinSync(
        bankbookNumber: j['bankbookNumber'] as String?,
        vbCode: (j['vbCode'] ?? '') as String,
        date: (j['date'] ?? '') as String,
        points: j['points'] as int?,
        needSync: j['needSync'] as String?,
        lastUpdate: j['lastUpdate'] as String?,
      );
}
