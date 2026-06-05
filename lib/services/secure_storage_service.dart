import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// ເກັບຮັກສາ JWT token ໃນ OS-level secure storage:
///   • Android → EncryptedSharedPreferences (AES-256 ໂດຍ Android Keystore)
///   • iOS     → Keychain Services
///
/// ຫ້າມໃຊ້ SharedPreferences ຫຼື SQLite ທຳມະດາໃນການເກັບ Token.
/// ຂໍ້ມູນໃນ secure storage ຈະຖືກລຶບໂດຍອັດຕະໂນມັດເມື່ອ uninstall app.
class SecureStorageService {
  static const _opts = AndroidOptions(
    encryptedSharedPreferences: true, // AES-256 via Android Keystore
  );

  final FlutterSecureStorage _store = const FlutterSecureStorage(
    aOptions: _opts,
  );

  // ── Key naming ───────────────────────────────────────────────────────────────
  static String _tokenKey(String userName) => 'jwt_token_$userName';
  static String _pwKey(String userName)    => 'pw_for_refresh_$userName';
  static const String _lastUserKey = 'last_logged_in_user';

  // ── Token operations ─────────────────────────────────────────────────────────

  /// ບັນທຶກ JWT access-token ຂອງ user (ແທນ SQLite).
  Future<void> saveToken(String userName, String token) async {
    await _store.write(key: _tokenKey(userName), value: token);
    await _store.write(key: _lastUserKey, value: userName);
  }

  /// ດຶງ JWT token ຄືນ. ສົ່ງ null ຖ້າບໍ່ມີ ຫຼື ໝົດອາຍຸ.
  Future<String?> getToken(String userName) async {
    return _store.read(key: _tokenKey(userName));
  }

  /// ດຶງ userName ຂອງຜູ້ທີ່ login ຄັ້ງລ່າສຸດ.
  Future<String?> getLastUser() async {
    return _store.read(key: _lastUserKey);
  }

  /// ລຶບ token ຂອງ user ນີ້ (logout).
  Future<void> clearToken(String userName) async {
    await _store.delete(key: _tokenKey(userName));
  }

  // ── Password for silent token refresh ────────────────────────────────────────
  // ເຫດຜົນ: Token ມີອາຍຸ 30 ນາທີ. ເພື່ອ refresh ໂດຍ user ບໍ່ຮູ້ຕົວ, ຕ້ອງ
  // re-authenticate ກັບ server. Password ຈຶ່ງຖືກເກັບໃນ Keychain/Keystore
  // (ບໍ່ແມ່ນ SQLite), ຊຶ່ງ OS ຄຸ້ມຄອງ encryption ໃຫ້ດ້ວຍ hardware-backed key.
  // Password ຈະຖືກລຶບທັນທີຫຼັງ logout / uninstall.

  Future<void> savePassword(String userName, String password) async {
    await _store.write(key: _pwKey(userName), value: password);
  }

  Future<String?> getPassword(String userName) async {
    return _store.read(key: _pwKey(userName));
  }

  Future<void> clearPassword(String userName) async {
    await _store.delete(key: _pwKey(userName));
  }

  /// ລຶບທຸກຂໍ້ມູນໃນ secure storage (full logout / uninstall cleanup).
  Future<void> clearAll() async {
    await _store.deleteAll();
  }
}
