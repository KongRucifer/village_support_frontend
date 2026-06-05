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

/// Offline-first login — ໃຊ້ security pattern ທີ່ຖືກຕ້ອງ:
///   Online  → server validates → JWT saved to Keychain/Keystore,
///             password hash saved to SQLite (ບໍ່ແມ່ນ plaintext).
///   Offline → SHA-256 hash ຂອງ password compare ກັບ DB hash,
///             JWT ດຶງຈາກ Keychain/Keystore.
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

  Future<AuthResult> login(String userName, String password) async {
    final online = await connectivity.isOnline();

    if (online) {
      try {
        final user = await api.loginTest(userName, password);

        // ສ້າງ random salt ແລະ hash password — ຫ້າມເກັບ plaintext.
        final salt = PasswordHashService.generateSalt();
        final hash = PasswordHashService.hash(password, salt);

        // Hash → SQLite (ອ່ານໄດ້ໂດຍ offline verify).
        await db.saveCachedUser(
          userName: userName,
          passwordHash: hash,
          passwordSalt: salt,
          id: user.id,
          roles: user.roles,
        );

        // JWT → Keychain/Keystore (ບໍ່ຢູ່ໃນ SQLite).
        await secureStorage.saveToken(userName, user.token);

        return AuthResult(user, false);
      } on ApiException catch (e) {
        if (e.statusCode == 401) rethrow; // ລະຫັດຜ່ານຜິດ — ຢ່າ fallback
        final cached = await _tryOfflineLogin(userName, password);
        if (cached != null) return AuthResult(cached, true);
        rethrow;
      } catch (_) {
        final cached = await _tryOfflineLogin(userName, password);
        if (cached != null) return AuthResult(cached, true);
        rethrow;
      }
    }

    // Offline path
    final cached = await _tryOfflineLogin(userName, password);
    if (cached != null) return AuthResult(cached, true);
    throw ApiException(
      'ບໍ່ມີອິນເຕີເນັດ ແລະ ບໍ່ມີ credentials ທີ່ cache ໄວ້ — '
      'ກະລຸນາ login online ຢ່າງໜ້ອຍ 1 ຄັ້ງກ່ອນ.',
    );
  }

  /// Offline credential check:
  ///   1. ດຶງ row ຈາກ SQLite.
  ///   2. Verify SHA-256(password:salt) == stored hash.
  ///   3. ດຶງ JWT ຈາກ Keychain/Keystore.
  Future<SystemUser?> _tryOfflineLogin(String userName, String password) async {
    final row = await db.getCachedUserRow(userName);
    if (row == null) return null;

    final storedHash = row['password_hash'] as String? ?? '';
    final storedSalt = row['password_salt'] as String? ?? '';

    // Hash comparison — password plaintext ຖືກໃຊ້ຊົ່ວຄາວ ຈາກນັ້ນ discard.
    if (!PasswordHashService.verify(password, storedSalt, storedHash)) {
      return null; // ລະຫັດຜ່ານຜິດ
    }

    // Retrieve JWT from secure storage.
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
}
