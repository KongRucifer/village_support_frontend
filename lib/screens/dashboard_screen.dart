import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/l10n/app_strings.dart';
import '../core/providers/app_settings.dart';
import '../core/widgets/settings_button.dart';
import '../models/system_user.dart';
import '../models/vb_code.dart';
import '../models/account_owner.dart';
import '../services/app_services.dart';
import '../services/background_sync_service.dart';
import '../services/sync_service.dart';
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

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  final _services = AppServices.instance;
  final _searchCtrl = TextEditingController();

  static const int _limit = 12;
  // How often to refresh SQLite in the background while the app is alive.
  static const Duration _autoSyncInterval = Duration(minutes: 3);
  int _page = 1;
  bool _loading = false;
  bool _online = true;
  bool _fromCache = false;
  String _search = '';
  PagedResult<VbCode>? _result;
  Timer? _debounce;
  Timer? _autoSyncTimer;
  StreamSubscription<bool>? _connSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _online = !widget.loggedInOffline;
    // Seed the "last synced" indicator from the persisted sync time so the
    // status bar shows it immediately, before the first sync of this session.
    _services.sync.primeStatus();
    _connSub = _services.connectivity.onStatusChange.listen((online) async {
      if (!mounted) return;
      setState(() => _online = online);
      if (online && widget.user.token.isNotEmpty) {
        // Refresh token first (ຖ້າຈະໝົດ/ໝົດ) ຈາກນັ້ນ sync.
        await _services.auth.refreshIfExpired(widget.user);
        // Incremental pull on reconnect: small + fast so it completes even if the
        // connection is only briefly available. Today's check-ins are ALWAYS
        // returned in full, so the delete-aware reconcile still fixes stale rows;
        // the key lists still prune server-side deletions. (full sync only on a
        // cold/empty mirror, handled inside SyncService.)
        final r = await _services.sync.sync(widget.user.token);
        if (mounted && r.ran) {
          _showSnack(r.message ?? 'Synced');
          _load();
        }
      }
    });
    // Background heartbeat: keep SQLite fresh (vbcodes, accounts, check-ins)
    // regardless of which page is on top — DashboardScreen stays mounted under
    // pushed routes, so this timer runs the whole session.
    _autoSyncTimer = Timer.periodic(_autoSyncInterval, (_) => _backgroundSync());
    // Proactive refresh on startup (token ອາດໝົດ ຖ້າ app ຢູ່ background ດົນ).
    _services.auth.refreshIfExpired(widget.user).then((_) {
      _load();
      // Incremental on open (fast); SyncService auto-forces a full pull when the
      // local mirror is empty (first run), so cold start still loads everything.
      _backgroundSync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _autoSyncTimer?.cancel();
    _connSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the app returns to the foreground, pull the latest data so the next
    // scan is up to date without entering any page.
    if (state == AppLifecycleState.resumed) {
      // Incremental pull on resume (fast). Today's check-ins always come in full,
      // so this still reconciles check-in/out state correctly.
      _backgroundSync();
    }
  }

  /// Best-effort silent sync used by the timer and lifecycle resume. Refreshes
  /// the visible list if data changed; never shows a snackbar. [full] forces a
  /// complete re-pull (used on open/resume/reconnect); the periodic timer uses
  /// the lighter incremental pull.
  Future<void> _backgroundSync({bool full = false}) async {
    if (widget.user.token.isEmpty) return;
    if (!await _services.connectivity.isOnline()) return;
    await _services.auth.refreshIfExpired(widget.user);
    final r = await _services.sync.sync(widget.user.token, full: full);
    if (mounted && r.ran) _load();
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
    final s = context.read<AppSettings>().s;
    if (widget.user.token.isEmpty) {
      _showSnack(s.noTokenSync);
      return;
    }
    _showSnack(s.syncing);
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
    // Stop OS-level background sync; it re-registers on the next login.
    BackgroundSync.cancel();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final s = context.watch<AppSettings>().s;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.dashTitle),
        actions: [
          const SettingsButton(),
          IconButton(
            tooltip: s.tooltipSync,
            icon: const Icon(Icons.sync),
            onPressed: _manualSync,
          ),
          IconButton(
            tooltip: s.tooltipLogout,
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: _StatusBar(
            online: _online,
            fromCache: _fromCache,
            userName: widget.user.userName,
            sync: _services.sync,
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
                      hintText: s.searchVbCode,
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
                  message: s.tooltipScan,
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
                      child: const Icon(Icons.qr_code_scanner, color: Colors.teal, size: 26),
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
                    ? Center(child: Text(s.noVbCodes))
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
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Chip(
            label: Text('${vb.accountOwnerCount} acc'),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
            labelPadding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          const Icon(Icons.chevron_right, size: 18),
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

class _StatusBar extends StatefulWidget {
  final bool online;
  final bool fromCache;
  final String userName;
  final SyncService sync;
  const _StatusBar({
    required this.online,
    required this.fromCache,
    required this.userName,
    required this.sync,
  });

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  // Ticks every few seconds so the "synced X ago" label stays current even when
  // no sync is running (the relative time keeps growing).
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Localized "synced X ago" from the last successful pull time.
  String _agoLabel(AppStrings s, DateTime? last) {
    if (last == null) return s.syncNever;
    final secs = DateTime.now().difference(last).inSeconds;
    if (secs < 5) return s.syncJustNow;
    if (secs < 60) return s.syncSecondsAgo(secs);
    final mins = secs ~/ 60;
    if (mins < 60) return s.syncMinutesAgo(mins);
    return s.syncHoursAgo(mins ~/ 60);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>().s;
    final color = widget.online ? Colors.green : Colors.orange;
    final textStyle =
        TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(widget.online ? Icons.cloud_done : Icons.cloud_off, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            widget.online ? s.online : s.offline,
            style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(width: 10),
          // Real-time sync indicator (spinner while pulling, ✓ + time after).
          Expanded(
            child: ValueListenableBuilder<SyncStatus>(
              valueListenable: widget.sync.status,
              builder: (context, st, _) => _syncChip(s, st, textStyle),
            ),
          ),
          Text('@${widget.userName}', style: textStyle),
        ],
      ),
    );
  }

  Widget _syncChip(AppStrings s, SyncStatus st, TextStyle textStyle) {
    switch (st.phase) {
      case SyncPhase.syncing:
        return Row(
          children: [
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
            Flexible(child: Text(s.syncPulling, style: textStyle, overflow: TextOverflow.ellipsis)),
          ],
        );
      case SyncPhase.error:
        return Row(
          children: [
            const Icon(Icons.sync_problem, size: 14, color: Colors.red),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                st.lastSuccess != null ? _agoLabel(s, st.lastSuccess) : s.syncFailed,
                style: textStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      case SyncPhase.success:
      case SyncPhase.idle:
        return Row(
          children: [
            Icon(Icons.check_circle,
                size: 14,
                color: st.lastSuccess == null ? Colors.grey : Colors.green),
            const SizedBox(width: 4),
            Flexible(
              child: Text(_agoLabel(s, st.lastSuccess), style: textStyle, overflow: TextOverflow.ellipsis),
            ),
          ],
        );
    }
  }
}
