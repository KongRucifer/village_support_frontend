import 'dart:async';
import 'package:flutter/material.dart';

import '../models/account_owner.dart'; // AccountOwner + PagedResult
import '../models/system_user.dart';
import '../models/withdrawal.dart'; // Withdrawal + PaymentMethodType
import '../services/app_services.dart';

/// History of withdrawal transactions (tx code 3101) for one account.
class WithdrawalsScreen extends StatefulWidget {
  final SystemUser user;
  final AccountOwner owner;
  const WithdrawalsScreen({super.key, required this.user, required this.owner});

  @override
  State<WithdrawalsScreen> createState() => _WithdrawalsScreenState();
}

class _PaymentBadge extends StatelessWidget {
  final PaymentMethodType method;
  const _PaymentBadge({required this.method});

  @override
  Widget build(BuildContext context) {
    final isCash = method == PaymentMethodType.cash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isCash ? Colors.green.shade50 : Colors.blue.shade50,
        border: Border.all(
          color: isCash ? Colors.green.shade200 : Colors.blue.shade200,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCash ? Icons.money : Icons.account_balance,
            size: 11,
            color: isCash ? Colors.green : Colors.blue,
          ),
          const SizedBox(width: 3),
          Text(
            method.shortLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: isCash ? Colors.green.shade700 : Colors.blue.shade700,
            ),
          ),
        ],
      ),
    );
  }
}

class _WithdrawalsScreenState extends State<WithdrawalsScreen> {
  final _services = AppServices.instance;
  static const int _limit = 15;
  int _page = 1;
  bool _loading = false;
  bool _fromCache = false;
  PagedResult<Withdrawal>? _result;
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    _load();
    _connSub = _services.connectivity.onStatusChange.listen((online) async {
      if (!mounted || !online || widget.user.token.isEmpty) return;
      // Push any queued offline withdraws, then refresh the list.
      await _services.sync.flushOutbox(widget.user.token);
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Make sure queued withdraws are on the server before we read the list.
      if (_page == 1 && widget.user.token.isNotEmpty) {
        await _services.sync.flushOutbox(widget.user.token);
      }
      final r = await _services.village.withdrawals(
        token: widget.user.token,
        owner: widget.owner,
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

  String _money(int v) {
    final s = v.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = iso.length >= 16 ? iso.substring(0, 16) : iso;
    return t.replaceFirst('T', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ປະຫວັດການຈ່າຍ (Payment History)'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Container(
            width: double.infinity,
            color: Colors.teal.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              'Acc ${widget.owner.accNumber} • ${widget.owner.clientName}'
              '${_fromCache ? '  • cached' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
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
                    ? const Center(child: Text('ຍັງບໍ່ມີການຈ່າຍ (no payments yet)'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: result.items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final w = result.items[i];
                            final isCash = w.paymentMethod == PaymentMethodType.cash;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.red.shade50,
                                child: Icon(
                                  isCash ? Icons.money : Icons.account_balance,
                                  color: Colors.red,
                                ),
                              ),
                              title: Text('- ${_money(w.amount)} ₭',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: Colors.red)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_fmtDate(w.date)),
                                  Row(
                                    children: [
                                      _PaymentBadge(method: w.paymentMethod),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          w.txName ?? w.description ?? 'Savings withdrawal',
                                          style: const TextStyle(fontSize: 12),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              isThreeLine: true,
                              trailing: w.pending
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text('ລໍຖ້າ sync',
                                          style: TextStyle(
                                              fontSize: 10, color: Colors.deepOrange)),
                                    )
                                  : const Icon(Icons.check_circle,
                                      color: Colors.green, size: 18),
                            );
                          },
                        ),
                      ),
          ),
          if (result != null && result.total > 0)
            Material(
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton.outlined(
                      onPressed: result.hasPrev
                          ? () {
                              setState(() => _page = result.page - 1);
                              _load();
                            }
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Column(
                      children: [
                        Text('Page ${result.page} / ${result.totalPages}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('${result.total} total',
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                    IconButton.outlined(
                      onPressed: result.hasNext
                          ? () {
                              setState(() => _page = result.page + 1);
                              _load();
                            }
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
