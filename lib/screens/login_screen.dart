import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/app_settings.dart';
import '../core/widgets/settings_button.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../services/background_sync_service.dart';
import 'dashboard_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey  = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  bool _online  = true;
  String? _error;

  final _services = AppServices.instance;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    _loadLastUser();
    _services.connectivity.onStatusChange.listen((online) {
      if (mounted) setState(() => _online = online);
    });
  }

  /// Pre-fill the username field with whoever logged in last.
  Future<void> _loadLastUser() async {
    final last = await _services.secureStorage.getLastUser();
    if (last != null && last.isNotEmpty && mounted) {
      _userCtrl.text = last;
    }
  }

  Future<void> _refreshStatus() async {
    final online = await _services.connectivity.isOnline();
    if (mounted) setState(() => _online = online);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });
    final s = context.read<AppSettings>().s;

    try {
      final result = await _services.auth.login(
        _userCtrl.text.trim(),
        _passCtrl.text,
      );
      if (!result.offline) {
        _services.sync.sync(result.user.token);
      }
      // Ensure OS-level background sync is active for this user (keeps the
      // offline mirror fresh even after the app is killed).
      await BackgroundSync.registerPeriodic();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => DashboardScreen(
            user: result.user,
            loggedInOffline: result.offline,
          ),
        ),
      );
    } on ApiException catch (e) {
      String msg = e.message;
      if (msg.contains('Username is incorrect')) {
        msg = s.errLoginUsername;
      } else if (msg.contains('Password is incorrect')) {
        msg = s.errLoginPassword;
      } else {
        msg = s.errLoginOther(e.message);
      }
      setState(() => _error = msg);
    } catch (_) {
      setState(() => _error = s.errLoginNetwork);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>().s;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(''),
        actions: const [SettingsButton()],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.account_balance, size: 64, color: scheme.primary),
                    const SizedBox(height: 12),
                    Text(s.appName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                    Text(s.loginSubtitle,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    _ConnectivityChip(online: _online),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _userCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: s.fieldUsername,
                        prefixIcon: const Icon(Icons.person_outline),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? s.validateUsername : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passCtrl,
                      obscureText: _obscure,
                      onFieldSubmitted: (_) => _login(),
                      decoration: InputDecoration(
                        labelText: s.fieldPassword,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? s.validatePassword : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!,
                                  style: TextStyle(color: scheme.onErrorContainer)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _loading ? null : _login,
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: _loading
                          ? const SizedBox(
                              height: 20, width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(s.btnLogin),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _online ? s.hintOnlineLogin : s.hintOfflineLogin,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectivityChip extends StatelessWidget {
  final bool online;
  const _ConnectivityChip({required this.online});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>().s;
    return Center(
      child: Chip(
        avatar: Icon(online ? Icons.wifi : Icons.wifi_off,
            size: 18, color: online ? Colors.green : Colors.orange),
        label: Text(online ? s.online : s.offline),
        backgroundColor: online ? Colors.green.shade50 : Colors.orange.shade50,
      ),
    );
  }
}
