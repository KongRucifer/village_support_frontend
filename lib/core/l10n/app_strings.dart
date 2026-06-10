/// ຄັງຄຳສັບ 2 ພາສາ: ລາວ (lo) + ອັງກິດ (en).
/// ການໃຊ້ງານ: `context.watch<AppSettings>().s.pageTitle`
class AppStrings {
  final String langCode;
  const AppStrings._(this.langCode);

  static const AppStrings en = AppStrings._('en');
  static const AppStrings lo = AppStrings._('lo');

  bool get isLao => langCode == 'lo';
  String _s(String en, String lo) => isLao ? lo : en;

  // ── App ───────────────────────────────────────────────────────────────────
  String get appName        => _s('Village Support', 'Village Support');
  String get loading        => _s('Loading…', 'ກຳລັງໂຫລດ…');
  String get btnCancel      => _s('Cancel', 'ຍົກເລີກ');
  String get btnSave        => _s('Save', 'ບັນທຶກ');
  String get btnConfirm     => _s('Confirm', 'ຢືນຢັນ');
  String get btnRetry       => _s('Retry', 'ລອງໃໝ່');
  String get online         => _s('Online', 'ອອນລາຍ');
  String get offline        => _s('Offline', 'ອອຟລາຍ');
  String get pendingSync    => _s('Pending sync', 'ລໍຖ້າ sync');
  String get cachedData     => _s('Cached data', 'ຂໍ້ມູນ cache');
  String get error          => _s('Error', 'ຜິດພາດ');

  // ── Settings popup ────────────────────────────────────────────────────────
  String get language       => _s('Language', 'ພາສາ');
  String get langLao        => _s('ລາວ (Lao)', 'ລາວ');
  String get langEng        => _s('English', 'ອັງກິດ');
  String get theme          => _s('Theme', 'ຮູບລັກສະນາ');
  String get themeLight     => _s('Light', 'ສະຫວ່າງ');
  String get themeDark      => _s('Dark', 'ມືດ');
  String get themeSystem    => _s('System', 'ລະບົບ');

  // ── Login ─────────────────────────────────────────────────────────────────
  String get loginSubtitle      => _s('System user login', 'ເຂົ້າສູ່ລະບົບຜູ້ໃຊ້');
  String get fieldUsername      => _s('Username', 'ຊື່ຜູ້ໃຊ້');
  String get validateUsername   => _s('Enter username', 'ກະລຸນາປ້ອນຊື່ຜູ້ໃຊ້');
  String get fieldPassword      => _s('Password', 'ລະຫັດຜ່ານ');
  String get validatePassword   => _s('Enter password', 'ກະລຸນາປ້ອນລະຫັດຜ່ານ');
  String get btnLogin           => _s('Login', 'ເຂົ້າສູ່ລະບົບ');
  String get hintOnlineLogin    => _s('Online — credentials verified with the server.', 'ອອນລາຍ — ກວດສອບຂໍ້ມູນກັບ server.');
  String get hintOfflineLogin   => _s('Offline — login uses your last cached credentials.', 'ອອຟລາຍ — ໃຊ້ຂໍ້ມູນ cache ທີ່ຈັດໄວ້ລ່ວງໜ້າ.');
  String get errLoginUsername   => _s('Username is incorrect', 'ຊື່ຜູ້ໃຊ້ບໍ່ຖືກຕ້ອງ');
  String get errLoginPassword   => _s('Password is incorrect', 'ລະຫັດຜ່ານບໍ່ຖືກຕ້ອງ');
  String get errLoginNetwork    => _s('Network error — check your connection', 'ຂໍ້ຜິດພາດເຄືອຂ່າຍ — ກວດສອບການເຊື່ອມຕໍ່');
  String errLoginOther(String m) => _s('Login failed: $m', 'ເຂົ້າສູ່ລະບົບລົ້ມເຫຼວ: $m');

  // ── Dashboard ─────────────────────────────────────────────────────────────
  String get dashTitle          => _s('Village Banks', 'ທະນາຄານບ້ານ');
  String get tooltipScan        => _s('Scan QR / Pay', 'ສະແກນ QR / ຈ່າຍເງິນ');
  String get tooltipSync        => _s('Sync', 'ຊິງຂໍ້ມູນ');
  String get tooltipLogout      => _s('Logout', 'ອອກຈາກລະບົບ');
  String get searchVbCode       => _s('Search by VbCode or name…', 'ຄົ້ນຫາ VbCode ຫຼື ຊື່…');
  String get noVbCodes          => _s('No village banks found', 'ບໍ່ພົບທະນາຄານບ້ານ');
  String get syncing            => _s('Syncing…', 'ກຳລັງຊິງ…');
  String get noTokenSync        => _s('No server token — please re-login online to sync.', 'ບໍ່ມີ token — ກະລຸນາ login ໃໝ່ເພື່ອ sync.');
  String get fromCache          => _s('showing cached data', 'ສະແດງຂໍ້ມູນ cache');
  // ── Sync status indicator ───────────────────────────────────────────────────
  String get syncPulling        => _s('Pulling data…', 'ກຳລັງດຶງຂໍ້ມູນ…');
  String get syncFailed         => _s('Sync failed', 'ດຶງຂໍ້ມູນລົ້ມເຫຼວ');
  String get syncNever          => _s('Not synced yet', 'ຍັງບໍ່ໄດ້ດຶງຂໍ້ມູນ');
  String get syncJustNow        => _s('synced just now', 'ຫາກໍດືງຂໍ້ມູນເເລ້ວ');
  String syncSecondsAgo(int n)  => _s('synced ${n}s ago', 'ດຶງຂໍ້ມູນ $n ວິ ກ່ອນ');
  String syncMinutesAgo(int n)  => _s('synced ${n}m ago', 'ດຶງຂໍ້ມູນ $n ນທ ກ່ອນ');
  String syncHoursAgo(int n)    => _s('synced ${n}h ago', 'ດຶງຂໍ້ມູນ $n ຊມ ກ່ອນ');
  String syncedCounts(int v, int a) =>
      _s('$v villages • $a accounts', '$v ບ້ານ • $a ບັນຊີ');

  // ── VbCode detail ─────────────────────────────────────────────────────────
  String get fieldBankbook      => _s('Bankbook Number', 'ເລກສໍ຋');
  String get hintBankbook       => _s('e.g. 00001', 'ຕົວຢ່າງ: 00001');
  String get allOwners          => _s('All account owners in this village', 'ເຈົ້າຂອງບັນຊີທັງໝົດ');
  String ownersFor(String bb)   => _s('Owners for bankbook $bb', 'ເຈົ້າຂອງ bankbook $bb');
  String get noOwners           => _s('No account owners found', 'ບໍ່ພົບເຈົ້າຂອງບັນຊີ');
  String get editSavingsTitle   => _s('Edit savings', 'ແກ້ໄຂເງິນຝາກ');
  String get editSavingsField   => _s('New balance (₭)', 'ຍອດໃໝ່ (₭)');
  String get savedOnline        => _s('✅ Saved to server', '✅ ບັນທຶກຂຶ້ນ server ແລ້ວ');
  String get savedOffline       => _s('📥 Saved offline — will auto-sync', '📥 ບັນທຶກ offline — ຈະ sync ອັດຕະໂນມັດ');
  String syncedN(int n)         => _s('Synced $n offline edit(s)', 'ດໍາເນີນ sync $n ລາຍການ offline');
  String get villageBankStr     => _s('Village Bank', 'ທະນາຄານບ້ານ');
  String get villageNotOffline  => _s('Village detail not available offline.', 'ຂໍ້ມູນຊຸມຊົນບໍ່ມີໃນ offline.');
  String get clients            => _s('clients', 'ສະມາຊິກ');
  String get accounts           => _s('accounts', 'ບັນຊີ');

  // ── Scan QR ───────────────────────────────────────────────────────────────
  String get scanTitle          => _s('Scan / Search', 'ສະແກນ / ຄົ້ນຫາ');
  String get scanModeScan       => _s('Scan QR', 'ສະແກນ QR');
  String get scanModeDoc        => _s('Document ID', 'ເລກໄອດີ');
  String get scanHintReady      => _s('Aim member\'s QR at the frame', 'ເລັງ QR ຂອງສະມາຊິກໃສ່ກອບ');
  String get scanHintChecking   => _s('Checking…', 'ກຳລັງກວດສອບ…');
  String scanHintCooldown(int s) => isLao ? 'ພ້ອມ scan ໃໝ່ໃນ $s ວິ' : 'Ready in $s s';
  String get scanDocModeHint    => _s('Document ID mode — enter number below', 'ໂໝດ ID — ປ້ອນເລກຂ້າງລຸ່ມ');
  String scanSearchingBb(String bb) => _s('Searching bankbook $bb', 'ກຳລັງຊອກ bankbook $bb');
  String get docFieldLabel      => _s('ID Document Number', 'ເລກໄອດີ / ເລກສຳມະໂນ');
  String get docFieldHint       => _s('e.g. 0101001234', '0101001234');
  String get docLookupHint      => _s('Lookup: id_document → account_owner', 'ຄົ້ນຫາ: id_document → account_owner');
  String get errQrInvalid       => _s('Invalid QR — account number not found', 'QR ບໍ່ຖືກຕ້ອງ — ບໍ່ພົບເລກບັນຊີ');
  String errAccNotFound(String a) => _s('Account $a not found', 'ບໍ່ພົບບັນຊີ $a');
  String errVbMismatch(String a, String got, String exp) =>
      _s('Account $a is VbCode $got ≠ $exp', 'ບັນຊີ $a ຢູ່ VbCode $got ≠ $exp');
  String get errNoToken         => _s('No token — please login again', 'ບໍ່ມີ token — ກະລຸນາ login ໃໝ່');
  String errDocNotFound(String id, String vb) =>
      _s('Document "$id" not found in VbCode $vb', 'ບໍ່ພົບ document "$id" ໃນ VbCode $vb');

  // ── Check-in / Check-out scan ──────────────────────────────────────────────
  String get checkInTitle        => _s('Check In', 'ສະແກນເຂົ້າ');
  String get scanModeCheckIn     => _s('Check In', 'ສະແກນເຂົ້າ');
  String get scanModeCheckOut    => _s('Scan to pay', 'ສະແກນຈ່າຍ');
  String get btnConfirmCheckIn   => _s('Confirm Check In', 'ຢືນຢັນເຂົ້າ');
  String checkInSuccess(String name) =>
      _s('Checked in ✓  $name', 'ສະແກນເຂົ້າສຳເລັດ ✓  $name');

  // ── Scan-mode picker (modal) ────────────────────────────────────────────────
  String get scanModePickTitle    => _s('Select scan mode', 'ເລືອກໂໝດສະແກນ');
  String get scanModeCheckInSub   => _s('Scan a member QR to check in', 'ສະແກນ QR ເພື່ອເຊັກອິນສະມາຊິກ');
  String get scanModeCheckOutSub  => _s('Scan QR or enter Document ID to pay', 'ສະແກນ QR ຫຼື ປ້ອນເລກໄອດີ ເພື່ອຈ່າຍເງິນ');

  // ── Check-in deposit card ───────────────────────────────────────────────────
  String get checkInPaymentAmount => _s('Payment amount', 'ຊຳລະຈຳນວນເງີນ');
  String get checkInNewBalance    => _s('New balance', 'ຍອດໃໝ່');

  /// Maps a backend error `code` to a localized message. Falls back to the
  /// raw server message when the code is unknown/null.
  String scanError(String? code, String serverMsg) {
    switch (code) {
      case 'LOSS_STATUS':
        return _s('This account is closed (loss status) — action not allowed.',
            'ບັນຊີນີ້ຖືກປິດ (ສະຖານະສູນເສຍ) — ບໍ່ສາມາດດຳເນີນການໄດ້');
      case 'ALREADY_CHECKED_IN_OUT_TODAY':
        return _s('Already checked in and  pay out today. Please check in next day.',
            'ສະແກນເຂົ້າ ແລະ ສະເເກນຈ່າຍເງີນແລ້ວໃນມື້ນີ້, ກະລຸນາສະແກນເຂົ້າໃໝ່ໃນມື້ຕໍ່ໄປ');
      case 'ALREADY_CHECKED_IN':
        return _s('Already checked in today. Must Scan to (pay) first.',
            'ສະແກນເຂົ້າແລ້ວ, ຕ້ອງສະແກນຈ່າຍ (ຈ່າຍເງິນ) ກ່ອນ');
      case 'ALREADY_CHECKED_OUT':
        return _s('Already paid today. Must check in again first.',
            'ຈ່າຍເງິນແລ້ວໃນມື້ນີ້, ຕ້ອງສະແກນເຂົ້າໃໝ່ກ່ອນ');
      case 'MUST_CHECK_IN_FIRST':
        return _s('Must check in before paying.',
            'ຕ້ອງສະແກນເຂົ້າກ່ອນຈ່າຍເງິນ');
      case 'INSUFFICIENT_BALANCE':
        return _s('Insufficient savings balance.',
            'ຍອດເງິນຝາກບໍ່ພໍ');
      case 'VB_MISMATCH':
        return _s('Account does not belong to this village.',
            'ບັນຊີບໍ່ກົງກັບໝູ່ບ້ານນີ້');
      case 'ACCOUNT_NOT_FOUND':
        return _s('Account not found.', 'ບໍ່ພົບບັນຊີ');
      case 'NOT_ACTIVE':
        return _s('This account is not active.',
            'ບັນຊີນີ້ບໍ່ໄດ້ເປີດໃຊ້ງານ (ບໍ່ Active)');
      case 'NO_CASH':
        return _s('This account has no cash.', 'ບັນຊີນີ້ບໍ່ມີເງີນສົດ');
      default:
        return serverMsg;
    }
  }

  // ── Confirm payment ───────────────────────────────────────────────────────
  String get confirmTitle        => _s('Confirm Payment', 'ຢືນຢັນການຈ່າຍ');
  String get confirmAmountLabel  => _s('Payment Amount', 'ຈຳນວນເງິນທີ່ຈ່າຍ');
  String get confirmAmountSub    => _s('Amount', 'ຈຳນວນ');
  String get confirmAmountTooltip => _s('Fixed amount — cannot be changed', 'ຈຳນວນຄົງທີ່ — ບໍ່ສາມາດປ່ຽນໄດ້');
  String insufficientBalance(String need, String have) =>
      _s('Insufficient balance (need $need ₭, have $have ₭)', 'ຍອດຝາກບໍ່ພໍ (ຕ້ອງ $need ₭, ມີ $have ₭)');
  String get confirmPayMethod    => _s('Payment Method', 'ວິທີຈ່າຍ');
  String get cash                => _s('Cash', 'ເງິນສົດ');
  String get bankTransfer        => _s('Bank Transfer', 'ໂອນທະນາຄານ');
  String get btnConfirmPay       => _s('Confirm Payment', 'ຢືນຢັນຈ່າຍ');
  String get recipientTitle      => _s('Transfer Recipient', 'ຂໍ້ມູນຜູ້ຮັບໂອນ');
  String get fieldReqName        => _s('Recipient Name *', 'ຊື່ຜູ້ຮັບ *');
  String get hintReqName         => _s('e.g. John Smith', 'ທ. ສົມສີ ສີໄຊ');
  String get fieldReqAcc         => _s('Recipient Account *', 'ເລກບັນຊີຜູ້ຮັບ *');
  String get validReqName        => _s('Please enter recipient name', 'ກະລຸນາປ້ອນຊື່ຜູ້ຮັບ');
  String get validReqAcc         => _s('Please enter recipient account', 'ກະລຸນາປ້ອນເລກບັນຊີຜູ້ຮັບ');
  String get savingsBalance      => _s('Savings balance', 'ເງິນຝາກ');
  String paySuccess(String amount, String pm, String bal) =>
      _s('Paid $amount ₭ [$pm] ✓  Balance $bal ₭', 'ຈ່າຍ $amount ₭ [$pm] ✓  ຍອດ $bal ₭');
  String get paySuccessOffline   => _s('• offline, pending sync', '• offline, ລໍຖ້າ sync');
  String payFailed(String msg)   => _s('Payment failed: $msg', 'ຈ່າຍເງິນລົ້ມເຫຼວ: $msg');
  String get processing          => _s('Processing…', 'ກຳລັງດຳເນີນການ…');

  // ── Withdrawals / Payment history ─────────────────────────────────────────
  String get payHistoryTitle     => _s('Payment History', 'ປະຫວັດການຈ່າຍ');
  String get noPayments          => _s('No payments yet', 'ຍັງບໍ່ມີການຈ່າຍ');
  String get savingsWithdrawal   => _s('Savings withdrawal', 'ຖອນເງິນຝາກ');

  // ── Account transactions ──────────────────────────────────────────────────
  String get txTitle             => _s('Transactions', 'ລາຍການ');
  String get noTx                => _s('No transactions found', 'ບໍ່ພົບລາຍການ');
  String get txOfflineEmpty      => _s('No cached data\nConnect to internet to load', 'ບໍ່ມີ cache\nເຊື່ອມ internet ເພື່ອໂຫລດ');

  // ── Sync toast ────────────────────────────────────────────────────────────
  String syncResult(String msg)  => msg; // already formatted by server
}
