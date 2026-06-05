class AccountOwner {
  final String bankbookNumber;
  final String accNumber;
  final String vbCode;
  final String clientId;
  final String clientName; // resolved name (not the raw client id)
  final String? accNameLao;
  final String? accNameEng;
  final int currentBalance;
  final String? accountType;
  final String? statusId;

  /// True when a local edit hasn't been pushed to the server yet (offline queue).
  final bool pending;

  AccountOwner({
    required this.bankbookNumber,
    required this.accNumber,
    required this.vbCode,
    required this.clientId,
    required this.clientName,
    this.accNameLao,
    this.accNameEng,
    this.currentBalance = 0,
    this.accountType,
    this.statusId,
    this.pending = false,
  });

  factory AccountOwner.fromJson(Map<String, dynamic> j) => AccountOwner(
        bankbookNumber: (j['bankbookNumber'] ?? '') as String,
        accNumber: (j['accNumber'] ?? '') as String,
        vbCode: (j['vbCode'] ?? '') as String,
        clientId: (j['clientId'] ?? '') as String,
        clientName: (j['clientName'] ?? '') as String,
        accNameLao: j['accNameLao'] as String?,
        accNameEng: j['accNameEng'] as String?,
        currentBalance: (j['currentBalance'] ?? 0) as int,
        accountType: j['accountType'] as String?,
        statusId: j['statusId']?.toString(),
      );

  Map<String, dynamic> toDb() => {
        'bankbook_number': bankbookNumber,
        'acc_number': accNumber,
        'vb_code': vbCode,
        'client_id': clientId,
        'client_name': clientName,
        'acc_name_lao': accNameLao,
        'acc_name_eng': accNameEng,
        'current_balance': currentBalance,
        'account_type': accountType,
        'status_id': statusId,
      };

  factory AccountOwner.fromDb(Map<String, dynamic> r) => AccountOwner(
        bankbookNumber: (r['bankbook_number'] ?? '') as String,
        accNumber: (r['acc_number'] ?? '') as String,
        vbCode: (r['vb_code'] ?? '') as String,
        clientId: (r['client_id'] ?? '') as String,
        clientName: (r['client_name'] ?? '') as String,
        accNameLao: r['acc_name_lao'] as String?,
        accNameEng: r['acc_name_eng'] as String?,
        currentBalance: (r['current_balance'] ?? 0) as int,
        accountType: r['account_type'] as String?,
        statusId: r['status_id'] as String?,
        pending: ((r['pending'] ?? 0) as int) == 1,
      );
}

/// Generic paged result used across repositories.
class PagedResult<T> {
  final List<T> items;
  final int total;
  final int page;
  final int limit;
  final bool fromCache;

  PagedResult({
    required this.items,
    required this.total,
    required this.page,
    required this.limit,
    this.fromCache = false,
  });

  int get totalPages => limit == 0 ? 1 : (total + limit - 1) ~/ limit;
  bool get hasNext => page < totalPages;
  bool get hasPrev => page > 1;
}
