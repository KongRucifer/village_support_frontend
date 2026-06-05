import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/account_owner.dart';
import '../models/qr_payload.dart';
import '../models/system_user.dart';
import '../models/withdrawal.dart';
import '../services/app_services.dart';
import '../widgets/top_toast.dart';
import 'withdrawals_screen.dart';

// ── Scan state machine ───────────────────────────────────────────────────────
enum _ScanState { ready, processing, cooldown }

class SavingsWithdrawScreen extends StatefulWidget {
  final SystemUser user;
  final AccountOwner owner;
  const SavingsWithdrawScreen({super.key, required this.user, required this.owner});

  @override
  State<SavingsWithdrawScreen> createState() => _SavingsWithdrawScreenState();
}

class _SavingsWithdrawScreenState extends State<SavingsWithdrawScreen> {
  final _services = AppServices.instance;
  final _amountCtrl = TextEditingController();
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    autoStart: true,
  );

  late int _balance = widget.owner.currentBalance;
  _ScanState _scanState = _ScanState.ready;
  int _cooldownLeft = 0;
  Timer? _cooldownTimer;

  // ── Payment method selection ─────────────────────────────────────────────
  PaymentMethodType _paymentMethod = PaymentMethodType.cash;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _scanner.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  // ── Cooldown ──────────────────────────────────────────────────────────────
  static const int _cooldownSeconds = 3;

  void _startCooldown() {
    _cooldownTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _scanState = _ScanState.cooldown;
      _cooldownLeft = _cooldownSeconds;
    });
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _cooldownLeft--);
      if (_cooldownLeft <= 0) {
        t.cancel();
        if (mounted) setState(() => _scanState = _ScanState.ready);
      }
    });
  }

  // ── QR detection ──────────────────────────────────────────────────────────
  void _onDetect(BarcodeCapture capture) {
    if (_scanState != _ScanState.ready) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    setState(() => _scanState = _ScanState.processing);
    _handleScan(raw);
  }

  Future<void> _handleScan(String raw) async {
    try {
      // 1. Validate amount
      final amount = int.tryParse(_amountCtrl.text.trim().replaceAll(',', ''));
      if (amount == null || amount <= 0) {
        _err('ກະລຸນາປ້ອນຈຳນວນເງິນທີ່ຈ່າຍກ່ອນ');
        return;
      }
      if (amount > _balance) {
        _err('ຈຳນວນເກີນຍອດ (exceeds balance ${_money(_balance)} ₭)');
        return;
      }

      // 2. Parse QR
      final payload = QrPayload.tryParse(raw);
      if (payload == null) {
        _err('QR ບໍ່ຖືກຕ້ອງ — ບໍ່ພົບ bankbook/vbCode');
        return;
      }

      // 3. Match check
      if (!payload.matches(
        vbCode: widget.owner.vbCode,
        bankbookNumber: widget.owner.bankbookNumber,
      )) {
        _err('QR ບໍ່ກົງ — QR: ${payload.bankbookNumber}/${payload.vbCode} '
            '≠ ${widget.owner.bankbookNumber}/${widget.owner.vbCode}');
        return;
      }

      // 4. Withdraw (with selected payment method)
      final outcome = await _services.village.withdrawSavings(
        token: widget.user.token,
        owner: widget.owner,
        amount: amount,
        currentBalance: _balance,
        paymentMethod: _paymentMethod,
        note: 'QR withdraw • ${_paymentMethod.shortLabel}',
      );
      if (!mounted) return;
      setState(() => _balance = outcome.newBalance);
      _amountCtrl.clear();
      final tail = outcome.synced ? '' : ' • offline, ລໍຖ້າ sync';
      _ok('ຈ່າຍ ${_money(amount)} ₭ [${_paymentMethod.shortLabel}] ✓  '
          'ຍອດ ${_money(outcome.newBalance)} ₭$tail');
    } catch (e) {
      if (!mounted) return;
      _err('ຈ່າຍເງິນລົ້ມເຫຼວ: ${e.toString().replaceFirst('ApiException: ', '')}');
    } finally {
      _startCooldown();
    }
  }

  void _ok(String m) => TopToast.success(context, m);
  void _err(String m) => TopToast.error(context, m);

  void _showTestQr() {
    final data = QrPayload.encode(
      vbCode: widget.owner.vbCode,
      bankbookNumber: widget.owner.bankbookNumber,
    );
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Test QR for this account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: data, size: 220),
            const SizedBox(height: 8),
            SelectableText(data, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final o = widget.owner;
    return Scaffold(
      appBar: AppBar(
        title: Text('ຈ່າຍເງິນ • ${o.bankbookNumber}'),
        actions: [
          IconButton(
            tooltip: 'ປະຫວັດການຈ່າຍ',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => WithdrawalsScreen(user: widget.user, owner: o)),
            ),
          ),
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flash_on),
            onPressed: () => _scanner.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _scanner.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          _balanceCard(o),
          Expanded(child: _scannerArea()),
          _bottomPanel(),
        ],
      ),
    );
  }

  Widget _scannerArea() {
    return Stack(
      alignment: Alignment.center,
      children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        _AimingFrame(state: _scanState, cooldownLeft: _cooldownLeft),
        if (_scanState == _ScanState.processing)
          const _ProcessingOverlay()
        else if (_scanState == _ScanState.cooldown)
          _CooldownOverlay(seconds: _cooldownLeft),
        Positioned(
          bottom: 12,
          child: _ScanHint(state: _scanState, cooldownLeft: _cooldownLeft),
        ),
      ],
    );
  }

  Widget _balanceCard(AccountOwner o) {
    return Container(
      width: double.infinity,
      color: Colors.deepPurple.shade50,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(o.clientName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              if (o.pending) const _MiniPending(),
            ],
          ),
          Text('Bankbook ${o.bankbookNumber} • VbCode ${o.vbCode}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          const Text('ເງິນຝາກ (savings balance)',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          Text('${_money(_balance)} ₭',
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
        ],
      ),
    );
  }

  /// Amount input + payment method selector + test-QR button.
  Widget _bottomPanel() {
    return Material(
      elevation: 10,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Payment method selector ─────────────────────────────────────
            const Text('ວິທີຈ່າຍເງິນ (Payment Method)',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 6),
            _PaymentMethodSelector(
              selected: _paymentMethod,
              onChanged: (v) => setState(() => _paymentMethod = v),
            ),
            const SizedBox(height: 10),
            // ── Amount input ─────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'ຈຳນວນເງິນທີ່ຈ່າຍ (amount)',
                      prefixIcon: Icon(Icons.payments),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Show test QR',
                  icon: const Icon(Icons.qr_code_2),
                  onPressed: _showTestQr,
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'scan QR → ຖ້າກົງ → ຢືນຢັນຈ່າຍ 250,000 ₭',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Payment method selector widget ────────────────────────────────────────────

class _PaymentMethodSelector extends StatelessWidget {
  final PaymentMethodType selected;
  final ValueChanged<PaymentMethodType> onChanged;
  const _PaymentMethodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _Tile(
          icon: Icons.money,
          label: 'ເງິນສົດ',
          sublabel: 'Cash',
          isSelected: selected == PaymentMethodType.cash,
          color: Colors.green,
          onTap: () => onChanged(PaymentMethodType.cash),
        )),
        const SizedBox(width: 8),
        Expanded(child: _Tile(
          icon: Icons.account_balance,
          label: 'ໂອນທະນາຄານ',
          sublabel: 'Bank Transfer',
          isSelected: selected == PaymentMethodType.bankTransfer,
          color: Colors.blue,
          onTap: () => onChanged(PaymentMethodType.bankTransfer),
        )),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;
  const _Tile({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.isSelected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.12) : Colors.grey.shade100,
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? color : Colors.grey, size: 20),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? color : Colors.black87,
                    )),
                Text(sublabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: isSelected ? color : Colors.grey,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Scanner sub-widgets ───────────────────────────────────────────────────────

class _AimingFrame extends StatelessWidget {
  final _ScanState state;
  final int cooldownLeft;
  const _AimingFrame({required this.state, required this.cooldownLeft});
  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _ScanState.ready      => Colors.white,
      _ScanState.processing => Colors.amber,
      _ScanState.cooldown   => cooldownLeft <= 1 ? Colors.greenAccent : Colors.orangeAccent,
    };
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 3),
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();
  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black54,
    alignment: Alignment.center,
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: Colors.white),
        SizedBox(height: 12),
        Text('ກຳລັງດຳເນີນການ…',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

class _CooldownOverlay extends StatelessWidget {
  final int seconds;
  const _CooldownOverlay({required this.seconds});
  @override
  Widget build(BuildContext context) => Container(
    width: 220,
    height: 220,
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(16),
    ),
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$seconds',
            style: const TextStyle(
                fontSize: 64, fontWeight: FontWeight.bold, color: Colors.white)),
        const Text('ລໍຖ້າ…', style: TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    ),
  );
}

class _ScanHint extends StatelessWidget {
  final _ScanState state;
  final int cooldownLeft;
  const _ScanHint({required this.state, required this.cooldownLeft});
  @override
  Widget build(BuildContext context) {
    final text = switch (state) {
      _ScanState.ready      => 'ເລັງ QR ໃສ່ກອບ — ຈ່າຍ 250,000 ₭ ເມື່ອກົງ',
      _ScanState.processing => 'ກຳລັງດຳເນີນການ…',
      _ScanState.cooldown   => 'ພ້ອມ scan ໃໝ່ໃນ $cooldownLeft ວິ',
    };
    return Text(text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        ));
  }
}

class _MiniPending extends StatelessWidget {
  const _MiniPending();
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
