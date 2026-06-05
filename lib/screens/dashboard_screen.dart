import 'dart:async';
import 'package:flutter/material.dart';

import '../models/system_user.dart';
import '../models/vb_code.dart';
import '../models/account_owner.dart';
import '../services/app_services.dart';
import 'login_screen.dart';
import 'scan_qr_screen.dart';
import 'vbcode_detail_screen.dart';

class DashboardScreen extends StatefulWidget {
  final SystemUser user;
  final bool loggedInOffline;
  const DashboardScreen({super.key, required this.user, this.loggedInOffline = false});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _services = AppServices.instance;
  final _searchCtrl = TextEditingController();

  static const int _limit = 12;
  int _page = 1;
  bool _loading = false;
  bool _online = true;
  bool _fromCache = false;
  String _search = '';
  PagedResult<VbCode>? _result;
  Timer? _debounce;
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    _online = !widget.loggedInOffline;
    _connSub = _services.connectivity.onStatusChange.listen((online) async {
      if (!mounted) return;
      setState(() => _online = online);
      if (online && widget.user.token.isNotEmpty) {
        // Refresh token first (ຖ້າຈະໝົດ/ໝົດ) ຈາກນັ້ນ sync.
        await _services.auth.refreshIfExpired(widget.user);
        final r = await _services.sync.sync(widget.user.token);
        if (mounted && r.ran) {
          _showSnack(r.message ?? 'Synced');
          _load();
        }
      }
    });
    // Proactive refresh on startup (token ອາດໝົດ ຖ້າ app ຢູ່ background ດົນ).
    _services.auth.refreshIfExpired(widget.user).then((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _connSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final result = await _services.village.vbCodes(
        token: widget.user.token,
        search: _search,
        page: _page,
        limit: _limit,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _fromCache = result.fromCache;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      setState(() {
        _search = value.trim();
        _page = 1;
      });
      _load();
    });
  }

  Future<void> _manualSync() async {
    if (widget.user.token.isEmpty) {
      _showSnack('No server token (offline session) — connect and re-login to sync.');
      return;
    }
    _showSnack('Syncing…');
    final r = await _services.sync.sync(widget.user.token, full: true);
    _showSnack(r.message ?? 'Done');
    if (r.ran) _load();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _logout() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Village Banks'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            icon: const Icon(Icons.sync),
            onPressed: _manualSync,
          ),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: _StatusBar(
            online: _online,
            fromCache: _fromCache,
            userName: widget.user.userName,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search by VbCode or name…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                _onSearchChanged('');
                              },
                            ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: 'ສະແກນ QR / ຈ່າຍເງິນ',
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ScanQrScreen(user: widget.user),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.teal.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.teal.shade200),
                      ),
                      child: const Icon(
                        Icons.qr_code_scanner,
                        color: Colors.teal,
                        size: 26,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading && result == null
                ? const Center(child: CircularProgressIndicator())
                : result == null || result.items.isEmpty
                    ? const Center(child: Text('No village banks found'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: result.items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) => _VbCodeTile(
                            vb: result.items[i],
                            onTap: () => _openDetail(result.items[i]),
                          ),
                        ),
                      ),
          ),
          if (result != null && result.total > 0)
            _Pager(
              page: result.page,
              totalPages: result.totalPages,
              total: result.total,
              loading: _loading,
              onPrev: result.hasPrev
                  ? () {
                      setState(() => _page = result.page - 1);
                      _load();
                    }
                  : null,
              onNext: result.hasNext
                  ? () {
                      setState(() => _page = result.page + 1);
                      _load();
                    }
                  : null,
            ),
        ],
      ),
    );
  }

  void _openDetail(VbCode vb) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VbCodeDetailScreen(user: widget.user, vbCode: vb.vbCode),
      ),
    );
  }
}

class _VbCodeTile extends StatelessWidget {
  final VbCode vb;
  final VoidCallback onTap;
  const _VbCodeTile({required this.vb, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.deepPurple.shade50,
        child: const Icon(Icons.location_city, color: Colors.deepPurple),
      ),
      title: Text(vb.nameLao.isNotEmpty ? vb.nameLao : vb.nameEng),
      subtitle: Text(
        'VbCode: ${vb.vbCode}\n'
        '${vb.districtName ?? vb.districtId}, ${vb.provinceName ?? vb.provinceId}',
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Chip(
            label: Text('${vb.accountOwnerCount} acc'),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

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
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton.outlined(
              onPressed: onPrev,
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
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final bool online;
  final bool fromCache;
  final String userName;
  const _StatusBar({
    required this.online,
    required this.fromCache,
    required this.userName,
  });

  @override
  Widget build(BuildContext context) {
    final color = online ? Colors.green : Colors.orange;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(online ? Icons.cloud_done : Icons.cloud_off, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            online ? 'Online' : 'Offline',
            style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          if (fromCache) ...[
            const SizedBox(width: 8),
            const Text('• showing cached data',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ],
          const Spacer(),
          Text('@$userName', style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    );
  }
}
