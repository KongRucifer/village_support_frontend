import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// ຈັດການ hash + ຢືນຢັນ password ສຳລັບ offline login.
///
/// ເຫດຜົນດ້ານຄວາມປອດໄພ:
///   • ລະຫັດຜ່ານຈະບໍ່ຖືກເກັບໄວ້ໂດຍກົງ (Zero-Trust for Passwords).
///   • ໃຊ້ SHA-256 + random salt (32 bytes) ເພື່ອປ້ອງກັນ rainbow-table attack.
///   • salt ຈະຖືກສ້າງໃໝ່ທຸກຄັ້ງທີ່ cache credentials, ສ້ອງ replay attack.
///
/// ⚠ ໝາຍເຫດ: SHA-256 ດ່ຽວໆ ດ້ອຍກວ່າ bcrypt/argon2 ໃນເລື່ອງ slow-hashing.
///   ສຳລັບ production ຂະໜາດໃຫຍ່, ໃຫ້ upgrade ໄປໃຊ້ argon2 ຜ່ານ package
///   `argon2_flutter` ຫຼື ຮ້ອງຂໍ hash ຈາກ backend ແທນ.
class PasswordHashService {
  const PasswordHashService._();

  /// ສ້າງ random salt (base64url, 32 bytes entropy).
  static String generateSalt() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Hash password ດ້ວຍ SHA-256(password + salt).
  /// ສົ່ງ hex string ທີ່ເກັບໄວ້ໃນ DB ແທນ plaintext.
  static String hash(String password, String salt) {
    final input = utf8.encode('$password:$salt');
    return sha256.convert(input).toString();
  }

  /// ຢືນຢັນ password ໂດຍ compare hash — ບໍ່ compare plaintext.
  static bool verify(String password, String salt, String storedHash) {
    return hash(password, salt) == storedHash;
  }
}
