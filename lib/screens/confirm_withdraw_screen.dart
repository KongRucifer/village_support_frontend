import 'package:flutter/material.dart';

import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../models/withdrawal.dart';
import '../services/app_services.dart';
import '../services/api_client.dart';
import '../widgets/top_toast.dart';

/// Fixed payment amount (per business rule — cannot be changed by the user).
const int kPaymentAmount = 250000;

/// Confirmation page shown after a successful QR scan or document lookup.
/// Payment amount is fixed at [kPaymentAmount] ₭. User chooses payment method
/// and confirms (or cancels).
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
  late int _balance = widget.owner.currentBalance;

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
    // Guard: balance must cover the fixed amount.
    if (_balance < kPaymentAmount) {
      TopToast.error(context, 'ຍອດຝາກບໍ່ພໍ (balance ${_money(_balance)} ₭ < ${_money(kPaymentAmount)} ₭)');
      return;
    }

    setState(() => _processing = true);
    try {
      final outcome = await _services.village.withdrawSavings(
        token: widget.user.token,
        owner: widget.owner,
        amount: kPaymentAmount,
        currentBalance: _balance,
        paymentMethod: _paymentMethod,
        note: 'ຈ່າຍເງິນ • ${_paymentMethod.shortLabel}',
      );

      if (!mounted) return;

      final tail = outcome.synced ? '' : ' • offline, ລໍຖ້າ sync';
      TopToast.success(
        context,
        'ຈ່າຍ ${_money(kPaymentAmount)} ₭ [${_paymentMethod.shortLabel}] ✓  '
        'ຍອດ ${_money(outcome.newBalance)} ₭$tail',
      );

      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.error(context, 'ຈ່າຍເງິນລົ້ມເຫຼວ: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      TopToast.error(context, 'ຜິດພາດ: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.owner;
    final canPay = _balance >= kPaymentAmount;

    return Scaffold(
      appBar: AppBar(title: const Text('ຢືນຢັນການຈ່າຍ (Confirm Payment)')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Account detail card ─────────────────────────────────────────
            _DetailCard(owner: o, balance: _balance, money: _money),
            const SizedBox(height: 20),

            // ── Fixed payment amount display (read-only) ────────────────────
            const Text('ຈຳນວນເງິນທີ່ຈ່າຍ (Payment Amount)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.deepPurple.shade200, width: 2),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('ຈຳນວນ (Amount)',
                      style: TextStyle(color: Colors.black54, fontSize: 14)),
                  Row(
                    children: [
                      Text(
                        '${_money(kPaymentAmount)} ₭',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepPurple,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Tooltip(
                        message: 'ຈຳນວນຄົງທີ່ — ບໍ່ສາມາດປ່ຽນໄດ້',
                        child: Icon(Icons.lock, size: 16, color: Colors.deepPurple),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!canPay)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'ຍອດຝາກບໍ່ພໍ (need ${_money(kPaymentAmount)} ₭, have ${_money(_balance)} ₭)',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 20),

            // ── Payment method ──────────────────────────────────────────────
            const Text('ວິທີຈ່າຍ (Payment Method)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _PaymentSelector(
              selected: _paymentMethod,
              onChanged: (v) => setState(() => _paymentMethod = v),
            ),
            const SizedBox(height: 32),

            // ── Confirm button ──────────────────────────────────────────────
            FilledButton.icon(
              onPressed: (_processing || !canPay) ? null : _confirm,
              icon: _processing
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.payments),
              label: const Text('ຢືນຢັນຈ່າຍ (Confirm Payment)',
                  style: TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 12),

            // ── Cancel button ───────────────────────────────────────────────
            OutlinedButton.icon(
              onPressed: _processing ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('ຍົກເລີກ (Cancel)', style: TextStyle(fontSize: 16)),
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.deepPurple.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person, color: Colors.deepPurple),
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
              const Text('ເງິນຝາກ (Savings)', style: TextStyle(color: Colors.black54)),
              Text(
                '${money(balance)} ₭',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurple,
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
                  style: const TextStyle(color: Colors.black54, fontSize: 13)),
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
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.1) : Colors.grey.shade100,
            border: Border.all(
              color: selected ? color : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? color : Colors.grey, size: 22),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold,
                        color: selected ? color : Colors.black87)),
                  Text(sublabel,
                      style: TextStyle(
                        fontSize: 10,
                        color: selected ? color : Colors.grey)),
                ],
              ),
            ],
          ),
        ),
      );
}
