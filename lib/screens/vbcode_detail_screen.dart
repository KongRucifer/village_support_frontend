import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/app_settings.dart';
import '../core/widgets/settings_button.dart';
import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../models/vb_code.dart';
import '../services/app_services.dart';
import 'account_transactions_screen.dart';

class VbCodeDetailScreen extends StatefulWidget {
  final SystemUser user;
  final String vbCode;
  const VbCodeDetailScreen({super.key, required this.user, required this.vbCode});

  @override
  State<VbCodeDetailScreen> createState() => _VbCodeDetailScreenState();
}

class _VbCodeDetailScreenState extends State<VbCodeDetailScreen> {
  final _services = AppServices.instance;
  final _bankbookCtrl = TextEditingController();

  static const int _limit = 12;
  int _page = 1;
  bool _loadingDetail = true;
  bool _loadingOwners = false;
  VbCode? _detail;
  PagedResult<AccountOwner>? _owners;
  String _bankbook = '';
  Timer? _debounce;
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    _loadDetail();
    _loadOwners();
    _connSub = _services.connectivity.onStatusChange.listen((online) async {
      if (!mounted || !online || widget.user.token.isEmpty) return;
      final pushed = await _services.sync.flushOutbox(widget.user.token);
      if (pushed > 0 && mounted) {
        final s = context.read<AppSettings>().s;
        _showSnack(s.syncedN(pushed));
        _loadOwners();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _connSub?.cancel();
    _bankbookCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadDetail() async {
    setState(() => _loadingDetail = true);
    final d = await _services.village
        .vbCodeDetail(token: widget.user.token, vbCode: widget.vbCode);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _loadingDetail = false;
    });
  }

  Future<void> _loadOwners() async {
    setState(() => _loadingOwners = true);
    try {
      final r = await _services.village.accountOwners(
        token: widget.user.token,
        vbCode: widget.vbCode,
        bankbookNumber: _bankbook,
        page: _page,
        limit: _limit,
      );
      if (!mounted) return;
      setState(() => _owners = r);
    } finally {
      if (mounted) setState(() => _loadingOwners = false);
    }
  }

  void _onBankbookChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      setState(() {
        _bankbook = value.trim();
        _page = 1;
      });
      _loadOwners();
    });
  }

  Future<void> _openTransactions(AccountOwner o) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountTransactionsScreen(user: widget.user, owner: o),
      ),
    );
    // Refresh list in case a withdrawal was recorded while viewing transactions.
    if (mounted) _loadOwners();
  }

  String _money(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final owners = _owners;
    final s = context.watch<AppSettings>().s;
    return Scaffold(
      appBar: AppBar(
        title: Text('VbCode ${widget.vbCode}'),
        actions: const [SettingsButton()],
      ),
      body: Column(
        children: [
          _buildDetailCard(),
          const Divider(height: 1),

          // ── Bankbook filter ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _bankbookCtrl,
              keyboardType: TextInputType.number,
              onChanged: _onBankbookChanged,
              decoration: InputDecoration(
                labelText: s.fieldBankbook,
                hintText: s.hintBankbook,
                prefixIcon: const Icon(Icons.menu_book),
                suffixIcon: _bankbookCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _bankbookCtrl.clear();
                          _onBankbookChanged('');
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),

          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Text(
                _bankbook.isEmpty ? s.allOwners : s.ownersFor(_bankbook),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),

          // ── Account owner list ───────────────────────────────────────────
          Expanded(
            child: _loadingOwners && owners == null
                ? const Center(child: CircularProgressIndicator())
                : owners == null || owners.items.isEmpty
                    ? Center(child: Text(s.noOwners))
                    : RefreshIndicator(
                        onRefresh: _loadOwners,
                        child: ListView.separated(
                          itemCount: owners.items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final o = owners.items[i];
                            return _OwnerTile(
                              owner: o,
                              money: _money,
                              onTap: () => _openTransactions(o),
                            );
                          },
                        ),
                      ),
          ),

          if (owners != null && owners.total > 0)
            _Pager(
              page: owners.page,
              totalPages: owners.totalPages,
              total: owners.total,
              onPrev: owners.hasPrev
                  ? () {
                      setState(() => _page = owners.page - 1);
                      _loadOwners();
                    }
                  : null,
              onNext: owners.hasNext
                  ? () {
                      setState(() => _page = owners.page + 1);
                      _loadOwners();
                    }
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildDetailCard() {
    if (_loadingDetail) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final d = _detail;
    if (d == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(context.read<AppSettings>().s.villageNotOffline),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            d.nameLao.isNotEmpty ? d.nameLao : d.nameEng,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          _kv(context, 'VbCode', d.vbCode),
          _kv(context, 'Village Bank', d.villageBankName ?? '-'),
          _kv(context, 'District', d.districtName ?? d.districtId),
          _kv(context, 'Province', d.provinceName ?? d.provinceId),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text('${d.clientCount} clients')),
              Chip(label: Text('${d.accountOwnerCount} accounts')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Text.rich(TextSpan(children: [
          TextSpan(
              text: '$k: ',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          TextSpan(
              text: v, style: const TextStyle(fontWeight: FontWeight.w500)),
        ])),
      );
}

// ── Owner list tile ───────────────────────────────────────────────────────────

class _OwnerTile extends StatelessWidget {
  final AccountOwner owner;
  final String Function(int) money;
  final VoidCallback onTap;

  const _OwnerTile({
    required this.owner,
    required this.money,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final o = owner;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(Icons.person,
            color: Theme.of(context).colorScheme.onSecondaryContainer),
      ),
      title: Row(
        children: [
          Flexible(child: Text(o.clientName)),
          if (o.pending) ...[
            const SizedBox(width: 6),
            const _PendingBadge(),
          ],
        ],
      ),
      subtitle: Text(
        'Bankbook: ${o.bankbookNumber}  •  Acc: ${o.accNumber}\n'
        '${o.accNameLao ?? o.accNameEng ?? o.accountType ?? ''}',
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${money(o.currentBalance)} ₭',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
        ],
      ),
    );
  }
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.orange.shade100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('ລໍຖ້າ sync',
            style: TextStyle(fontSize: 10, color: Colors.deepOrange)),
      );
}

// ── Pagination bar ────────────────────────────────────────────────────────────

class _Pager extends StatelessWidget {
  final int page;
  final int totalPages;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const _Pager({
    required this.page,
    required this.totalPages,
    required this.total,
    this.onPrev,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) => Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton.outlined(
                  onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
              Column(
                children: [
                  Text('Page $page / $totalPages',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('$total total',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                ],
              ),
              IconButton.outlined(
                  onPressed: onNext, icon: const Icon(Icons.chevron_right)),
            ],
          ),
        ),
      );
}
