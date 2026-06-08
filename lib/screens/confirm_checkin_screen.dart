import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/app_settings.dart';
import '../core/widgets/settings_button.dart';
import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../services/app_services.dart';
import '../services/api_client.dart';
import '../widgets/top_toast.dart';

/// Confirmation screen for the check-in (ສະແກນເຂົ້າ) flow.
/// Shows account details and lets staff confirm presence before payment.
/// On confirm → calls POST /village-data/accounts/:accNumber/checkin
///            → sets status_scan = 1 on the server + local cache.
class ConfirmCheckInScreen extends StatefulWidget {
  final SystemUser user;
  final AccountOwner owner;

  const ConfirmCheckInScreen({
    super.key,
    required this.user,
    required this.owner,
  });

  @override
  State<ConfirmCheckInScreen> createState() => _ConfirmCheckInScreenState();
}

class _ConfirmCheckInScreenState extends State<ConfirmCheckInScreen> {
  final _services = AppServices.instance;
  bool _processing = false;

  String _money(int v) {
    final s = v.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return (v < 0 ? '-' : '') + buf.toString();
  }

  Future<void> _confirm() async {
    final s = context.read<AppSettings>().s;
    setState(() => _processing = true);
    try {
      await _services.village.checkInAccount(
        token: widget.user.token,
        owner: widget.owner,
      );
      if (!mounted) return;
      TopToast.success(context, s.checkInSuccess(widget.owner.clientName));
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      // Show the localized message that matches the backend error code.
      TopToast.error(context, s.scanError(e.code, e.message));
    } catch (e) {
      if (!mounted) return;
      TopToast.error(context, '${s.error}: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.owner;
    final s = context.watch<AppSettings>().s;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ສະແກນເຂົ້າ'),
        actions: const [SettingsButton()],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Account detail card ─────────────────────────────────────────
            _DetailCard(owner: o, balance: o.currentBalance, money: _money),
            const SizedBox(height: 24),

            // ── Confirm check-in button ─────────────────────────────────────
            FilledButton.icon(
              onPressed: _processing ? null : _confirm,
              icon: _processing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.login),
              label: Text(
                _processing ? s.loading : 'ຢືນຢັນເຂົ້າ (Check In)',
                style: const TextStyle(fontSize: 16),
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.green,
              ),
            ),
            const SizedBox(height: 12),

            // ── Cancel button ───────────────────────────────────────────────
            OutlinedButton.icon(
              onPressed: _processing ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.cancel_outlined),
              label: Text(s.btnCancel, style: const TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Detail card (same layout as confirm_withdraw_screen) ───────────────────────

class _DetailCard extends StatelessWidget {
  final AccountOwner owner;
  final int balance;
  final String Function(int) money;

  const _DetailCard({
    required this.owner,
    required this.balance,
    required this.money,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  owner.clientName,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              if (owner.pending)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('ລໍຖ້າ sync',
                      style: TextStyle(fontSize: 10, color: Colors.deepOrange)),
                ),
            ],
          ),
          const Divider(height: 16),
          _Row('Bankbook', owner.bankbookNumber),
          _Row('VbCode', owner.vbCode),
          _Row('Account No', owner.accNumber),
          if (owner.accNameLao != null || owner.accNameEng != null)
            _Row('Account', owner.accNameLao ?? owner.accNameEng ?? ''),
          if (owner.accountType != null) _Row('Type', owner.accountType!),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('ເງິນຝາກ (Savings)',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
              Text(
                '${money(balance)} ₭',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  )),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );
}
