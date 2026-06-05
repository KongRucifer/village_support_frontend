import 'package:flutter/material.dart';

import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../models/transaction_item.dart';
import '../services/app_services.dart';

/// Shows the transaction history for one account (savings, loan, etc.).
/// Calls GET /transactions/account/:accNumber via the offline-first repository.
class AccountTransactionsScreen extends StatefulWidget {
  final SystemUser user;
  final AccountOwner owner;

  const AccountTransactionsScreen({
    super.key,
    required this.user,
    required this.owner,
  });

  @override
  State<AccountTransactionsScreen> createState() => _AccountTransactionsScreenState();
}

class _AccountTransactionsScreenState extends State<AccountTransactionsScreen> {
  final _services = AppServices.instance;

  static const int _limit = 15;
  int _page = 1;
  bool _loading = false;
  bool _fromCache = false;
  PagedResult<TransactionItem>? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _services.village.transactions(
        token: widget.user.token,
        accNumber: widget.owner.accNumber,
        page: _page,
        limit: _limit,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _fromCache = r.fromCache;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _money(num v) {
    final s = v.abs().toStringAsFixed(0);
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final o = widget.owner;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ລາຍການ (Transactions)'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Container(
            width: double.infinity,
            color: Colors.deepPurple.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${o.clientName}  •  Bankbook ${o.bankbookNumber}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  'Acc: ${o.accNumber}'
                  '${o.accNameLao != null ? "  •  ${o.accNameLao}" : ""}'
                  '${_fromCache ? "  • (cached)" : ""}',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading && result == null
                ? const Center(child: CircularProgressIndicator())
                : result == null || result.items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.receipt_long,
                                size: 56, color: Colors.black12),
                            const SizedBox(height: 12),
                            Text(
                              _fromCache
                                  ? 'ບໍ່ມີຂໍ້ມູນ cache\nConnect to the internet to load'
                                  : 'No transactions found',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.black45),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: result.items.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 16, endIndent: 16),
                          itemBuilder: (_, i) => _TxTile(
                            tx: result.items[i],
                            accNumber: o.accNumber,
                            money: _money,
                          ),
                        ),
                      ),
          ),
          if (result != null && result.total > 0) _Pager(
            page: result.page,
            totalPages: result.totalPages,
            total: result.total,
            loading: _loading,
            onPrev: result.hasPrev
                ? () { setState(() => _page = result.page - 1); _load(); }
                : null,
            onNext: result.hasNext
                ? () { setState(() => _page = result.page + 1); _load(); }
                : null,
          ),
        ],
      ),
    );
  }
}

// ── Transaction tile ────────────────────────────────────────────────────────

class _TxTile extends StatelessWidget {
  final TransactionItem tx;
  final String accNumber; // to determine debit vs credit
  final String Function(num) money;

  const _TxTile({
    required this.tx,
    required this.accNumber,
    required this.money,
  });

  @override
  Widget build(BuildContext context) {
    // Determine if this is a debit (money going out) or credit (money coming in).
    final isDebit = tx.debitAccNumber.trim() == accNumber.trim();
    final sign   = isDebit ? '-' : '+';
    final color  = isDebit ? Colors.red.shade700 : Colors.green.shade700;
    final bgColor = isDebit ? Colors.red.shade50  : Colors.green.shade50;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: bgColor,
        child: Icon(
          isDebit ? Icons.arrow_upward : Icons.arrow_downward,
          color: color,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              tx.txLabel,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
          Text(
            '$sign ${money(tx.amount)} ₭',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: color,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tx.fmtDate,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          if (tx.description != null && tx.description!.isNotEmpty)
            Text(
              tx.description!,
              style: const TextStyle(fontSize: 11, color: Colors.black45),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (tx.paymentMethod != null)
            _PaymentChip(method: tx.paymentMethod!),
        ],
      ),
      isThreeLine: false,
    );
  }
}

class _PaymentChip extends StatelessWidget {
  final String method; // 'Cash' or 'BankTransfer'
  const _PaymentChip({required this.method});

  @override
  Widget build(BuildContext context) {
    final isCash = method == 'Cash';
    return Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isCash ? Colors.green.shade50 : Colors.blue.shade50,
        border: Border.all(
          color: isCash ? Colors.green.shade200 : Colors.blue.shade200,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isCash ? '💵 Cash' : '🏦 Bank Transfer',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: isCash ? Colors.green.shade700 : Colors.blue.shade700,
        ),
      ),
    );
  }
}

// ── Pagination bar ────────────────────────────────────────────────────────────

class _Pager extends StatelessWidget {
  final int page;
  final int totalPages;
  final int total;
  final bool loading;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _Pager({
    required this.page,
    required this.totalPages,
    required this.total,
    required this.loading,
    this.onPrev,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) => Material(
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton.outlined(
                onPressed: loading ? null : onPrev,
                icon: const Icon(Icons.chevron_left),
              ),
              Column(
                children: [
                  Text('Page $page / $totalPages',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('$total total',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
              IconButton.outlined(
                onPressed: loading ? null : onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      );
}
