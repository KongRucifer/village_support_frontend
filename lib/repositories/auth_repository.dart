import 'dart:convert';
import '../models/system_user.dart';
import '../services/api_client.dart';
import '../services/connectivity_service.dart';
import '../services/local_db.dart';
import '../services/password_hash_service.dart';
import '../services/secure_storage_service.dart';

class AuthResult {
  final SystemUser user;
  final bool offline;
  AuthResult(this.user, this.offline);
}

/// Offline-first login + proactive token refresh.
///
/// Security model:
///   • Password → SHA-256 hash in SQLite + plaintext in Keychain (for refresh only).
///   • JWT      → Keychain/Keystore (ບໍ່ຢູ່ໃນ SQLite).
///   • Token lifetime: 30 minutes. `refreshIfExpired()` ເຮັດ silent refresh
///     ໂດຍ user ບໍ່ຮູ້ຕົວ ເມື່ອ token ຈະໝົດອາຍຸ.
class AuthRepository {
  final ApiClient api;
  final LocalDb db;
  final ConnectivityService connectivity;
  final SecureStorageService secureStorage;

  AuthRepository({
    required this.api,
    required this.db,
    required this.connectivity,
    required this.secureStorage,
  });

  // ── Login ────────────────────────────────────────────────────────────────────

  Future<AuthResult> login(String userName, String password) async {
    final online = await connectivity.isOnline();

    if (online) {
      try {
        final user = await api.loginTest(userName, password);
        await _cacheCredentials(userName, password, user);
        return AuthResult(user, false);
      } on ApiException catch (e) {
        if (e.statusCode == 401) rethrow;
        final cached = await _tryOfflineLogin(userName, password);
        if (cached != null) return AuthResult(cached, true);
        rethrow;
      } catch (_) {
        final cached = await _tryOfflineLogin(userName, password);
        if (cached != null) return AuthResult(cached, true);
        rethrow;
      }
    }

    final cached = await _tryOfflineLogin(userName, password);
    if (cached != null) return AuthResult(cached, true);
    throw ApiException(
      'ບໍ່ມີ internet ແລະ ບໍ່ມີ credentials cache — ກະລຸນາ login online ກ່ອນ.',
    );
  }

  // ── Proactive token refresh ──────────────────────────────────────────────────

  /// ໂທຫາ method ນີ້ກ່ອນ API calls ສຳຄັນ.
  /// ຖ້າ token ຈະໝົດ/ໝົດແລ້ວ ແລະ online → silent re-authenticate.
  /// ຖ້າ offline → ໃຊ້ token ເກົ່າ (server ຈະ reject ດ້ວຍ 401 ເອງ).
  Future<void> refreshIfExpired(SystemUser user) async {
    if (!_isTokenExpiredOrClose(user.token)) return; // ຍັງໃຊ້ໄດ້
    if (!await connectivity.isOnline()) return;       // offline → skip

    final password = await secureStorage.getPassword(user.userName);
    if (password == null) return; // ບໍ່ມີ credentials → skip

    try {
      final fresh = await api.loginTest(user.userName, password);
      // ອັບເດດ token ໃນ object ດຽວກັນ (non-final field).
      user.token = fresh.token;
      await secureStorage.saveToken(user.userName, fresh.token);
    } catch (_) {
      // Refresh ລົ້ມເຫຼວ → ປ່ອຍ token ເກົ່າ; server ຈະ reject ດ້ວຍ 401
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// ເກັບ credentials: hash → SQLite, plaintext+token → Keychain.
  Future<void> _cacheCredentials(
    String userName,
    String password,
    SystemUser user,
  ) async {
    final salt = PasswordHashService.generateSalt();
    final hash = PasswordHashService.hash(password, salt);

    await db.saveCachedUser(
      userName: userName,
      passwordHash: hash,
      passwordSalt: salt,
      id: user.id,
      roles: user.roles,
    );
    await secureStorage.saveToken(userName, user.token);
    // Password ໃນ Keychain ສຳລັບ silent refresh ເທົ່ານັ້ນ.
    await secureStorage.savePassword(userName, password);
  }

  /// Offline credential verification: hash comparison.
  Future<SystemUser?> _tryOfflineLogin(String userName, String password) async {
    final row = await db.getCachedUserRow(userName);
    if (row == null) return null;

    final storedHash = row['password_hash'] as String? ?? '';
    final storedSalt = row['password_salt'] as String? ?? '';

    if (!PasswordHashService.verify(password, storedSalt, storedHash)) {
      return null;
    }

    final token = await secureStorage.getToken(userName) ?? '';
    return SystemUser(
      id: (row['id'] ?? 0) as int,
      userName: userName,
      roles: ((row['roles'] ?? '') as String)
          .split(',')
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      token: token,
    );
  }

  /// Parse JWT payload ແລະ ກວດສອບ expiry.
  /// ສົ່ງ true ຖ້າ token ໝົດ ຫຼື ຈະໝົດໃນ 5 ນາທີ (buffer).
  bool _isTokenExpiredOrClose(String token) {
    if (token.isEmpty) return true;
    try {
      final parts = token.split('.');
      if (parts.length != 3) return true;

      // Base64url → JSON (pad ຖ້າຈຳເປັນ)
      var payload = parts[1];
      switch (payload.length % 4) {
        case 2: payload += '=='; break;
        case 3: payload += '=';  break;
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      final exp = (map['exp'] as num?)?.toInt();
      if (exp == null) return true;

      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= exp - 300; // refresh ຖ້າ ≤ 5 ນາທີ ຍັງເຫຼືອ
    } catch (_) {
      return true; // parse ຜິດ → assume expired
    }
  }
}
