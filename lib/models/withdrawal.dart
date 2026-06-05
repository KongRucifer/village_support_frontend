enum PaymentMethodType {
  cash,
  bankTransfer;

  /// Human-readable Lao/English label shown in the UI.
  String get label {
    switch (this) {
      case PaymentMethodType.cash:        return 'ເງິນສົດ (Cash)';
      case PaymentMethodType.bankTransfer: return 'ໂອນທະນາຄານ (Bank Transfer)';
    }
  }

  /// Short label for chips/badges.
  String get shortLabel {
    switch (this) {
      case PaymentMethodType.cash:        return 'Cash';
      case PaymentMethodType.bankTransfer: return 'Bank Transfer';
    }
  }

  /// Value sent to / received from the backend.
  String get apiValue {
    switch (this) {
      case PaymentMethodType.cash:        return 'Cash';
      case PaymentMethodType.bankTransfer: return 'BankTransfer';
    }
  }

  static PaymentMethodType fromApi(String? value) {
    if (value == 'BankTransfer') return PaymentMethodType.bankTransfer;
    return PaymentMethodType.cash; // default / null → Cash
  }
}

class Withdrawal {
  final String txId;
  final String accNumber;
  final String vbCode;
  final String? bankbookNumber;
  final int amount;
  final String? date; // ISO string
  final String? description;
  final String? txName;
  final PaymentMethodType paymentMethod;
  final bool pending; // queued locally, not yet on the server

  Withdrawal({
    required this.txId,
    required this.accNumber,
    required this.vbCode,
    this.bankbookNumber,
    required this.amount,
    this.date,
    this.description,
    this.txName,
    this.paymentMethod = PaymentMethodType.cash,
    this.pending = false,
  });

  factory Withdrawal.fromJson(Map<String, dynamic> j) => Withdrawal(
        txId: (j['id'] ?? '') as String,
        accNumber: (j['accNumber'] ?? '') as String,
        vbCode: (j['vbCode'] ?? '') as String,
        bankbookNumber: j['bankbookNumber'] as String?,
        amount: (j['amount'] ?? 0) as int,
        date: j['date']?.toString(),
        description: j['description'] as String?,
        txName: j['txName'] as String?,
        paymentMethod: PaymentMethodType.fromApi(j['paymentMethod'] as String?),
        pending: false,
      );

  Map<String, dynamic> toDb() => {
        'tx_id': txId,
        'acc_number': accNumber,
        'vb_code': vbCode,
        'bankbook_number': bankbookNumber,
        'amount': amount,
        'date': date,
        'description': description,
        'tx_name': txName,
        'payment_method': paymentMethod.apiValue,
        'pending': pending ? 1 : 0,
      };

  factory Withdrawal.fromDb(Map<String, dynamic> r) => Withdrawal(
        txId: (r['tx_id'] ?? '') as String,
        accNumber: (r['acc_number'] ?? '') as String,
        vbCode: (r['vb_code'] ?? '') as String,
        bankbookNumber: r['bankbook_number'] as String?,
        amount: (r['amount'] ?? 0) as int,
        date: r['date'] as String?,
        description: r['description'] as String?,
        txName: r['tx_name'] as String?,
        paymentMethod: PaymentMethodType.fromApi(r['payment_method'] as String?),
        pending: ((r['pending'] ?? 0) as int) == 1,
      );
}
