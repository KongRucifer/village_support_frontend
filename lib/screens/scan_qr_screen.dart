import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../core/providers/app_settings.dart';
import '../models/account_owner.dart';
import '../models/system_user.dart';
import '../services/app_services.dart';
import '../services/qr_crypto.dart';
import '../widgets/top_toast.dart';
import 'confirm_checkin_screen.dart';
import 'confirm_withdraw_screen.dart';

// ── Input mode ────────────────────────────────────────────────────────────────
enum _InputMode { qr, document }

// ── QR scan state ─────────────────────────────────────────────────────────────
enum _ScanState { ready, checking, cooldown }

// ── Scan mode (chosen before opening this screen) ────────────────────────────
enum ScanMode { checkIn, checkOut }

/// Show a bottom-sheet to let the user pick check-in or check-out mode.
/// Returns null if dismissed without choosing. Follows the app theme (light/dark)
/// and language (Lao/English).
Future<ScanMode?> showScanModePicker(BuildContext context) {
  return showModalBottomSheet<ScanMode>(
    context: context,
    // null → uses the theme's bottom-sheet surface (works in light & dark).
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final s  = ctx.read<AppSettings>().s;
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                s.scanModePickTitle,
                style: Theme.of(ctx).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              _ScanOptionButton(
                icon: Icons.login,
                label: s.scanModeCheckIn,
                subtitle: s.scanModeCheckInSub,
                color: Colors.green.shade600,
                onTap: () => Navigator.of(ctx).pop(ScanMode.checkIn),
              ),
              const SizedBox(height: 12),
              _ScanOptionButton(
                icon: Icons.payments_outlined,
                label: s.scanModeCheckOut,
                subtitle: s.scanModeCheckOutSub,
                color: Colors.deepPurple.shade400,
                onTap: () => Navigator.of(ctx).pop(ScanMode.checkOut),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ScanOptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ScanOptionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16, color: color)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

/// Two-mode lookup screen:
///   • QR mode  – scan the member's QR code (vbCode + bankbook + accNumber)
///   • Doc mode – type the ID-document number to look up the account
///
/// AppBar: torch + camera switch only.
/// On success: auto-navigates to [ConfirmWithdrawScreen] then pops itself.
class ScanQrScreen extends StatefulWidget {
  final SystemUser user;
  final ScanMode mode;
  /// When set, the scanned account must belong to this village.
  /// Leave empty (default) when opening from the Dashboard — any village is allowed.
  final String vbCode;
  final String? bankbookNumber;

  const ScanQrScreen({
    super.key,
    required this.user,
    required this.mode,
    this.vbCode = '',        // empty = no village constraint
    this.bankbookNumber,
  });

  @override
  State<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends State<ScanQrScreen> {
  final _services = AppServices.instance;
  final _docCtrl  = TextEditingController();

  // Camera controller — kept alive even in document mode so switching is instant.
  final MobileScannerController _scanner = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    autoStart: true,
  );

  _InputMode _mode       = _InputMode.qr;
  _ScanState _state      = _ScanState.ready;
  int _cooldownLeft = 0;
  Timer? _cooldownTimer;
  bool _docSearching = false;

  static const int _cooldownSec = 3;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _scanner.dispose();
    _docCtrl.dispose();
    super.dispose();
  }

  // ── Mode switch ───────────────────────────────────────────────────────────
  void _setMode(_InputMode m) {
    if (_mode == m) return;
    setState(() {
      _mode = m;
      // Reset scan state so the QR scanner is ready immediately on switch-back.
      _state = _ScanState.ready;
      _cooldownTimer?.cancel();
      _cooldownLeft = 0;
    });
  }

  // ── Cooldown ──────────────────────────────────────────────────────────────
  void _startCooldown() {
    _cooldownTimer?.cancel();
    if (!mounted) return;
    setState(() { _state = _ScanState.cooldown; _cooldownLeft = _cooldownSec; });
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _cooldownLeft--);
      if (_cooldownLeft <= 0) {
        t.cancel();
        if (mounted) setState(() => _state = _ScanState.ready);
      }
    });
  }

  // ── Navigate to confirm, then pop this screen on return ───────────────────
  Future<void> _goConfirm(AccountOwner owner) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => widget.mode == ScanMode.checkIn
            ? ConfirmCheckInScreen(user: widget.user, owner: owner)
            : ConfirmWithdrawScreen(user: widget.user, owner: owner),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  // ── QR path ───────────────────────────────────────────────────────────────
  void _onDetect(BarcodeCapture capture) {
    if (_mode != _InputMode.qr)          return;
    if (_state != _ScanState.ready)      return;

    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;

    setState(() => _state = _ScanState.checking);
    _handleQrScan(raw);
  }

  Future<void> _handleQrScan(String raw) async {
    // Capture strings BEFORE async gaps (avoid BuildContext across async warning).
    final s = context.read<AppSettings>().s;
    try {
      final accNumber = _extractAccNumber(raw.trim());
      if (accNumber == null || accNumber.isEmpty) {
        _err(s.errQrInvalid);
        return;
      }

      await _services.auth.refreshIfExpired(widget.user);

      AccountOwner? owner;
      if (widget.user.token.isNotEmpty &&
          await _services.connectivity.isOnline()) {
        owner = await _services.api.findByAccount(
          token: widget.user.token,
          accNumber: accNumber,
        );
        if (owner != null) {
          await _services.db.upsertAccountOwners([owner]);
        }
      }
      owner ??= await _services.db.getAccountOwnerByAccNumber(accNumber);

      if (owner == null) {
        _err(s.errAccNotFound(accNumber));
        return;
      }

      if (widget.vbCode.isNotEmpty &&
          owner.vbCode.trim() != widget.vbCode.trim()) {
        _err(s.errVbMismatch(accNumber, owner.vbCode, widget.vbCode));
        return;
      }

      await _goConfirm(owner);
    } finally {
      if (mounted) _startCooldown();
    }
  }

  /// The QR must carry the account number AES-encrypted (Base64) by the
  /// backoffice `EncryptAES`. Returns null (invalid scan) if decryption fails.
  String? _extractAccNumber(String text) {
    if (text.isEmpty) return null;
    final decrypted = QrCrypto.tryDecrypt(text);
    if (decrypted != null && decrypted.trim().isNotEmpty) {
      if (kDebugMode) debugPrint('[QR] decrypted → "${decrypted.trim()}"');
      return decrypted.trim();
    }
        // Not an encrypted payload — treat as a legacy plain account-number QR.
    // if (kDebugMode) debugPrint('[QR] raw (not encrypted) → "$text"');
    // return text;

    // Decryption failed — reject plain-text / unrecognised QR codes.
    if (kDebugMode) debugPrint('[QR] rejected (not encrypted) → "$text"');
    return null;
  }

  // ── Document ID path ──────────────────────────────────────────────────────
  Future<void> _searchByDocument() async {
    final idNumber = _docCtrl.text.trim();
    // Capture strings BEFORE any async gap.
    final s = context.read<AppSettings>().s;

    if (idNumber.isEmpty) { _err(s.errQrInvalid); return; }

    setState(() => _docSearching = true);
    try {
      // Offline-capable: online hits the server, offline resolves via the
      // mirrored id_documents → account_owners tables in SQLite.
      final owner = await _services.village.findOwnerByDocument(
        token: widget.user.token,
        idNumber: idNumber,
        vbCode: widget.vbCode,
      );
      if (owner == null) {
        _err(s.errDocNotFound(idNumber, widget.vbCode));
        return;
      }
      await _goConfirm(owner);
    } catch (e) {
      _err('${s.error}: ${e.toString().replaceFirst('ApiException: ', '')}');
    } finally {
      if (mounted) setState(() => _docSearching = false);
    }
  }

  void _err(String msg) { if (mounted) TopToast.error(context, msg); }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>().s;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(s.scanTitle, style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            tooltip: 'Torch on/off',
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
          // ── Camera area (always rendered so switching is instant) ─────────
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Camera preview always live.
                MobileScanner(controller: _scanner, onDetect: _onDetect),

                // Dim overlay in document mode.
                if (_mode == _InputMode.document)
                  Container(color: Colors.black.withValues(alpha: 0.65)),

                // Aiming frame (hidden in doc mode).
                if (_mode == _InputMode.qr)
                  _ScanMask(state: _state, cooldownLeft: _cooldownLeft),

                // Status hint.
                Positioned(
                  bottom: 14,
                  left: 16,
                  right: 16,
                  child: _mode == _InputMode.qr
                      ? _StatusText(state: _state, cooldownLeft: _cooldownLeft)
                      : const Text(
                          'ໂໝດ Document ID — ປ້ອນເລກຂ້າງລຸ່ມ',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                          ),
                        ),
                ),

                // Bankbook hint badge.
                if (widget.bankbookNumber != null &&
                    widget.bankbookNumber!.isNotEmpty &&
                    _mode == _InputMode.qr)
                  Positioned(
                    top: 14,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'ກຳລັງຊອກ bankbook ${widget.bankbookNumber}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Bottom panel ──────────────────────────────────────────────────
          _BottomPanel(
            scanMode: widget.mode,
            inputMode: _mode,
            onInputModeChange: _setMode,
            docCtrl: _docCtrl,
            docSearching: _docSearching,
            onSearch: _searchByDocument,
          ),
        ],
      ),
    );
  }
}

// ── Bottom panel widget ───────────────────────────────────────────────────────

class _BottomPanel extends StatelessWidget {
  final ScanMode scanMode;
  final _InputMode inputMode;
  final ValueChanged<_InputMode> onInputModeChange;
  final TextEditingController docCtrl;
  final bool docSearching;
  final VoidCallback onSearch;

  const _BottomPanel({
    required this.scanMode,
    required this.inputMode,
    required this.onInputModeChange,
    required this.docCtrl,
    required this.docSearching,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade900,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Mode label (green = check-in, purple = check-out) ───────────
          _ModeLabelChip(mode: scanMode),

          // ── Check-out only: QR / Document input toggle ─────────────────
          if (scanMode == ScanMode.checkOut) ...[
            const SizedBox(height: 10),
            Builder(builder: (ctx) {
              final sl = ctx.watch<AppSettings>().s;
              return Row(
                children: [
                  Expanded(child: _ModeChip(
                    icon: Icons.qr_code_scanner,
                    label: sl.scanModeScan,
                    selected: inputMode == _InputMode.qr,
                    onTap: () => onInputModeChange(_InputMode.qr),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: _ModeChip(
                    icon: Icons.badge_outlined,
                    label: sl.scanModeDoc,
                    selected: inputMode == _InputMode.document,
                    onTap: () => onInputModeChange(_InputMode.document),
                  )),
                ],
              );
            }),

            // ── Document ID input (visible in doc mode only) ────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              child: inputMode == _InputMode.document
                  ? Builder(builder: (ctx) {
                      final sl = ctx.watch<AppSettings>().s;
                      return Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(sl.docFieldLabel,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: docCtrl,
                                    autofocus: true,
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: (_) => onSearch(),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      hintText: sl.docFieldHint,
                                      hintStyle: const TextStyle(
                                          color: Colors.white38),
                                      prefixIcon: const Icon(
                                          Icons.badge_outlined,
                                          color: Colors.white54),
                                      filled: true,
                                      fillColor: Colors.white12,
                                      border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        borderSide: BorderSide.none,
                                      ),
                                      isDense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 14),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                FilledButton(
                                  onPressed: docSearching ? null : onSearch,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Colors.teal,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 14),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                  ),
                                  child: docSearching
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              color: Colors.white,
                                              strokeWidth: 2))
                                      : const Icon(Icons.search,
                                          color: Colors.white),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(sl.docLookupHint,
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 10)),
                          ],
                        ),
                      );
                    })
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Mode label chip ───────────────────────────────────────────────────────────

class _ModeLabelChip extends StatelessWidget {
  final ScanMode mode;
  const _ModeLabelChip({required this.mode});

  @override
  Widget build(BuildContext context) {
    final isCheckIn = mode == ScanMode.checkIn;
    final s = context.watch<AppSettings>().s;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: isCheckIn ? Colors.green.shade700 : Colors.deepPurple.shade700,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isCheckIn ? Icons.login : Icons.payments_outlined,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Text(
            isCheckIn ? s.scanModeCheckIn : s.scanModeCheckOut,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Colors.teal;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? activeColor : Colors.white12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }
}

// ── Scanner overlay ───────────────────────────────────────────────────────────

class _ScanMask extends StatelessWidget {
  final _ScanState state;
  final int cooldownLeft;
  const _ScanMask({required this.state, required this.cooldownLeft});

  @override
  Widget build(BuildContext context) {
    final frameColor = switch (state) {
      _ScanState.ready    => Colors.white,
      _ScanState.checking => Colors.amber,
      _ScanState.cooldown => cooldownLeft <= 1 ? Colors.greenAccent : Colors.orangeAccent,
    };

    return Stack(
      alignment: Alignment.center,
      children: [
        ColorFiltered(
          colorFilter: ColorFilter.mode(
              Colors.black.withValues(alpha: 0.55), BlendMode.srcOut),
          child: Stack(
            children: [
              Container(color: Colors.transparent),
              Center(
                child: Container(
                  width: 240, height: 240,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 240, height: 240,
          child: CustomPaint(painter: _CornerPainter(color: frameColor)),
        ),
        if (state == _ScanState.cooldown)
          Text('$cooldownLeft',
              style: const TextStyle(
                  fontSize: 72, fontWeight: FontWeight.bold, color: Colors.white,
                  shadows: [Shadow(color: Colors.black, blurRadius: 8)])),
        if (state == _ScanState.checking)
          const SizedBox(
            width: 60, height: 60,
            child: CircularProgressIndicator(color: Colors.amber, strokeWidth: 4),
          ),
      ],
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  const _CornerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const r = 16.0;
    const L = 36.0;

    final corners = [
      [Offset(r, 0), Offset(L + r, 0), Offset(0, r), Offset(0, L + r)],
      [Offset(size.width - r, 0), Offset(size.width - L - r, 0),
       Offset(size.width, r), Offset(size.width, L + r)],
      [Offset(0, size.height - r), Offset(0, size.height - L - r),
       Offset(r, size.height), Offset(L + r, size.height)],
      [Offset(size.width, size.height - r), Offset(size.width, size.height - L - r),
       Offset(size.width - r, size.height), Offset(size.width - L - r, size.height)],
    ];
    for (final c in corners) {
      canvas.drawLine(c[0], c[1], p);
      canvas.drawLine(c[2], c[3], p);
    }
  }

  @override
  bool shouldRepaint(_CornerPainter old) => old.color != color;
}

class _StatusText extends StatelessWidget {
  final _ScanState state;
  final int cooldownLeft;
  const _StatusText({required this.state, required this.cooldownLeft});

  @override
  Widget build(BuildContext context) {
    final s    = context.watch<AppSettings>().s;
    final text = switch (state) {
      _ScanState.ready    => s.scanHintReady,
      _ScanState.checking => s.scanHintChecking,
      _ScanState.cooldown => s.scanHintCooldown(cooldownLeft),
    };
    return Text(text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold,
          shadows: [Shadow(color: Colors.black, blurRadius: 6)],
        ));
  }
}
