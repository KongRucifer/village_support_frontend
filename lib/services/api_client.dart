import 'dart:convert';
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
  ApiException(this.message, [this.statusCode]);
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
          }),
        )
        .timeout(AppConfig.apiTimeout);

    final body = _decode(res);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(_errorMessage(body, 'Withdraw failed'), res.statusCode);
    }
    return WithdrawResult(
      newBalance: (body['currentBalance'] ?? 0) as int,
      transactionId: (body['transactionId'] ?? '') as String,
      paymentMethod: PaymentMethodType.fromApi(body['paymentMethod'] as String?),
      date: (body['date'] ?? '').toString(),
    );
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
    final res = await _http
        .get(
          _uri('/village-data/sync', {if (since != null) 'since': since}),
          headers: _headers(token),
        )
        .timeout(const Duration(seconds: 30));
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

class SyncSnapshot {
  final String serverTime;
  final List<VbCode> vbCodes;
  final List<AccountOwner> accountOwners;
  SyncSnapshot({
    required this.serverTime,
    required this.vbCodes,
    required this.accountOwners,
  });
}
