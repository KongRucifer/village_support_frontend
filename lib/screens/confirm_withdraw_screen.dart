import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/providers/app_settings.dart';
import '../core/widgets/settings_button.dart';
import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../models/withdrawal.dart';
import '../services/app_services.dart';
import '../services/api_client.dart';
import '../widgets/top_toast.dart';

/// Default per-payment amount when the dashboard hasn't configured one yet.
const int kDefaultPaymentAmount = 0;

/// shared_preferences key holding the configurable per-payment amount.
const String kPaymentAmountKey = 'payment_amount';

/// Confirmation page shown after a successful QR scan or document lookup.
/// The per-payment amount is configured on the dashboard (shared_preferences);
/// when a member has unpaid check-ins, the full overdue total is paid instead.
class ConfirmWithdrawScreen extends StatefulWidget {
  final SystemUser user;
  final AccountOwner owner;

  const ConfirmWithdrawScreen({
    super.key,
    required this.user,
    required this.owner,
  });

  @override
  State<ConfirmWithdrawScreen> createState() => _ConfirmWithdrawScreenState();
}

class _ConfirmWithdrawScreenState extends State<ConfirmWithdrawScreen> {
  final _services = AppServices.instance;

  PaymentMethodType _paymentMethod = PaymentMethodType.cash;
  bool _processing = false;
  late final int _balance = widget.owner.currentBalance;

  /// Configurable per-payment amount (set on the dashboard, shared_preferences).
  int _paymentAmount = kDefaultPaymentAmount;

  /// Overdue summary (loaded from the server / offline cache when the page opens).
  int _overduePayment = 0;
  int _overdueCount = 0;

  // Bank Transfer recipient fields
  final _reqNameCtrl   = TextEditingController();
  final _reqAccCtrl    = TextEditingController();

  /// Amount actually sent to the withdraw API: the full overdue total when known,
  /// otherwise the configured per-payment amount.
  int get _amountToSend => _overduePayment > 0 ? _overduePayment : _paymentAmount;

  /// Whether to surface the overdue UI. [_overdueCount] is the backlog count the
  /// server already decremented by one, so anything > 0 means there's a backlog.
  bool get _showOverdue => _overdueCount > 0 && _overduePayment > 0;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final v = prefs.getInt(kPaymentAmountKey);
      if (v != null && v > 0 && mounted) setState(() => _paymentAmount = v);
    });
    _loadOverdue();
  }

  Future<void> _loadOverdue() async {
    try {
      final info = await _services.village.overdueFor(
        token: widget.user.token,
        owner: widget.owner,
      );
      if (!mounted) return;
      setState(() {
        _overduePayment = info.overduePayment;
        _overdueCount = info.overdueCount;
      });
    } catch (_) {
      // Leave the defaults (0/0) → the screen behaves like a normal single payment.
    }
  }

  @override
  void dispose() {
    _reqNameCtrl.dispose();
    _reqAccCtrl.dispose();
    super.dispose();
  }

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
    final payAmount = _amountToSend;
    if (_balance < payAmount) {
      TopToast.error(context, s.insufficientBalance(_money(payAmount), _money(_balance)));
      return;
    }
    if (_paymentMethod == PaymentMethodType.bankTransfer) {
      if (_reqNameCtrl.text.trim().isEmpty) { TopToast.error(context, s.validReqName); return; }
      if (_reqAccCtrl.text.trim().isEmpty)  { TopToast.error(context, s.validReqAcc);  return; }
    }

    setState(() => _processing = true);
    try {
      final outcome = await _services.village.withdrawSavings(
        token: widget.user.token,
        owner: widget.owner,
        amount: payAmount,
        currentBalance: _balance,
        paymentMethod: _paymentMethod,
        // No note → the backend fills the UNDP disbursement description itself.
        requestName: _paymentMethod == PaymentMethodType.bankTransfer ? _reqNameCtrl.text.trim() : null,
        requestAccNumber: _paymentMethod == PaymentMethodType.bankTransfer ? _reqAccCtrl.text.trim() : null,
      );
      if (!mounted) return;
      final tail = outcome.synced ? '' : ' ${s.paySuccessOffline}';
      TopToast.success(context, s.paySuccess(_money(payAmount), _paymentMethod.shortLabel, _money(outcome.newBalance)) + tail);
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      // Map the backend error code to a localized message; fall back to payFailed.
      final msg = e.code != null
          ? s.scanError(e.code, e.message)
          : s.payFailed(e.message);
      TopToast.error(context, msg);
    } catch (e) {
      if (!mounted) return;
      TopToast.error(context, '${s.error}: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o   = widget.owner;
    final s   = context.watch<AppSettings>().s;
    final cs  = Theme.of(context).colorScheme;
    final canPay = _balance >= _amountToSend;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.confirmTitle),
        actions: const [SettingsButton()],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Account detail card ─────────────────────────────────────────
            _DetailCard(owner: o, balance: _balance, money: _money),
            const SizedBox(height: 20),

            // ── Overdue summary (only when there's a backlog of unpaid check-ins) ─
            if (_showOverdue) ...[
              _OverdueCard(
                total: _overduePayment - _paymentAmount,
                count: _overdueCount,
                money: _money,
              ),
              const SizedBox(height: 16),
            ],

            // ── Payment amount display (read-only) ──────────────────────────
            Text(s.confirmAmountLabel,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.primary.withValues(alpha: 0.4), width: 2),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.confirmAmountSub,
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                      Row(
                        children: [
                          Text('${_money(_paymentAmount)} ₭',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: cs.primary,
                              )),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: s.confirmAmountTooltip,
                            child: Icon(Icons.lock, size: 16, color: cs.primary),
                          ),
                        ],
                      ),
                    ],
                  ),
                  // Full amount actually paid (= overdue total) when there's a backlog.
                  if (_showOverdue) ...[
                    Divider(height: 16, color: cs.outlineVariant),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(s.totalPaymentAmount,
                            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                        Text('${_money(_overduePayment)} ₭',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: cs.primary,
                            )),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (!canPay)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  s.insufficientBalance(_money(_amountToSend), _money(_balance)),
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 20),

            // ── Payment method ──────────────────────────────────────────────
            Text(s.confirmPayMethod,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _PaymentSelector(
              selected: _paymentMethod,
              onChanged: (v) => setState(() => _paymentMethod = v),
            ),

            // ── Bank Transfer recipient fields (ສະແດງສະເພາະ Bank Transfer) ───
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              child: _paymentMethod == PaymentMethodType.bankTransfer
                  ? Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: Theme.of(context).colorScheme.outlineVariant),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.account_balance,
                                        color: Theme.of(context).colorScheme.primary, size: 18),
                                    const SizedBox(width: 6),
                                    Text(s.recipientTitle,
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(context).colorScheme.primary)),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _reqNameCtrl,
                                  textCapitalization: TextCapitalization.words,
                                  decoration: InputDecoration(
                                    labelText: s.fieldReqName,
                                    hintText: s.hintReqName,
                                    prefixIcon: const Icon(Icons.person_outline),
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _reqAccCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: s.fieldReqAcc,
                                    hintText: '010100100000001',
                                    prefixIcon: const Icon(Icons.credit_card),
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),

            // ── Confirm button ──────────────────────────────────────────────
            FilledButton.icon(
              onPressed: (_processing || !canPay) ? null : _confirm,
              icon: _processing
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.payments),
              label: Text(s.btnConfirmPay,
                  style: const TextStyle(fontSize: 16, color: Colors.white)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
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

// ── Overdue summary card (dark/light aware) ─────────────────────────────────────

class _OverdueCard extends StatelessWidget {
  /// Backlog amount = overdue total minus the current period's payment amount.
  final int total;
  final int count;
  final String Function(int) money;
  const _OverdueCard({required this.total, required this.count, required this.money});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? Colors.orange.shade300 : Colors.orange.shade800;
    final s = context.watch<AppSettings>().s;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: isDark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.45)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: accent),
                  const SizedBox(width: 6),
                  Text(s.overdueTotal, style: TextStyle(color: cs.onSurfaceVariant)),
                ],
              ),
              Text('${money(total)} ₭',
                  style: TextStyle(fontWeight: FontWeight.bold, color: accent)),
            ],
          ),
          Divider(height: 16, color: cs.outlineVariant),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(s.overdueCountLabel, style: TextStyle(color: cs.onSurfaceVariant)),
              Text('$count ${s.overdueTimesUnit}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Detail card ────────────────────────────────────────────────────────────────

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
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              if (owner.pending)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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

// ── Payment method selector ─────────────────────────────────────────────────

class _PaymentSelector extends StatelessWidget {
  final PaymentMethodType selected;
  final ValueChanged<PaymentMethodType> onChanged;
  const _PaymentSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: _Tile(
            icon: Icons.money,
            label: 'ເງິນສົດ',
            sublabel: 'Cash',
            selected: selected == PaymentMethodType.cash,
            color: Colors.green,
            onTap: () => onChanged(PaymentMethodType.cash),
          )),
          const SizedBox(width: 10),
          Expanded(child: _Tile(
            icon: Icons.account_balance,
            label: 'ໂອນທະນາຄານ',
            sublabel: 'Bank Transfer',
            selected: selected == PaymentMethodType.bankTransfer,
            color: Colors.blue,
            onTap: () => onChanged(PaymentMethodType.bankTransfer),
          )),
        ],
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _Tile({
    required this.icon, required this.label, required this.sublabel,
    required this.selected, required this.color, required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unselectedBg = cs.surfaceContainerHighest;
    final unselectedBorder = cs.outlineVariant;
    final unselectedText = cs.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : unselectedBg,
          border: Border.all(
            color: selected ? color : unselectedBorder,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: selected ? color : unselectedText, size: 22),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold,
                      color: selected ? color : unselectedText)),
                Text(sublabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: selected ? color : unselectedText)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
