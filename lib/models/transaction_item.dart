class TransactionItem {
  final String id;
  final String? date;      // ISO timestamp string
  final String? bankbookNumber;
  final String txCode;     // transactionCodeId
  final String? txNameLao;
  final String? txNameEng;
  final num amount;        // BigInt arrives as a Number
  final String debitAccNumber;
  final String? debitAccNameLao;
  final String creditAccNumber;
  final String? description;
  final String? paymentMethod; // 'Cash' | 'BankTransfer' | null

  TransactionItem({
    required this.id,
    this.date,
    this.bankbookNumber,
    required this.txCode,
    this.txNameLao,
    this.txNameEng,
    required this.amount,
    required this.debitAccNumber,
    this.debitAccNameLao,
    required this.creditAccNumber,
    this.description,
    this.paymentMethod,
  });

  String get txLabel => txNameLao ?? txNameEng ?? txCode;

  /// Formats 2024-03-15T08:30:00.000Z → '2024-03-15 08:30'
  String get fmtDate {
    if (date == null || date!.isEmpty) return '';
    final t = date!.length >= 16 ? date!.substring(0, 16) : date!;
    return t.replaceFirst('T', ' ');
  }

  factory TransactionItem.fromJson(Map<String, dynamic> j) {
    final debit = (j['debitAccount'] ?? {}) as Map<String, dynamic>;
    final txCode = (j['transactionCode'] ?? {}) as Map<String, dynamic>;
    return TransactionItem(
      id: (j['id'] ?? '') as String,
      date: j['date']?.toString(),
      bankbookNumber: j['bankbookNumber'] as String?,
      txCode: (j['transactionCodeId'] ?? '') as String,
      txNameLao: (txCode['nameLao'] ?? txCode['name_lao']) as String?,
      txNameEng: (txCode['nameEng'] ?? txCode['name_eng']) as String?,
      amount: (j['amount'] ?? 0) as num,
      debitAccNumber: (j['debitAccNumber'] ?? j['debit_acc_number'] ?? '') as String,
      debitAccNameLao: (debit['accNameLao'] ?? debit['acc_name_lao']) as String?,
      creditAccNumber: (j['creditAccNumber'] ?? j['credit_acc_number'] ?? '') as String,
      description: j['description'] as String?,
      paymentMethod: j['paymentMethod'] as String?,
    );
  }
}
