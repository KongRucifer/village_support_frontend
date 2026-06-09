import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

/// Decrypts the QR payload produced by the backoffice (C#) `EncryptAES`.
///
/// The C# side does:
///   key     = SHA256(UTF8(secretKey))          → 32 bytes (AES-256)
///   iv      = new byte[16]                      → 16 zero bytes
///   cipher  = AES default (CBC) + PKCS7 padding
///   output  = Convert.ToBase64String(...)       (plaintext is UTF-8)
///
/// So to recover the account number we Base64-decode, then AES-256-CBC decrypt
/// with the same zero IV and SHA-256-derived key.
class QrCrypto {
  QrCrypto._();

  static final enc.Encrypter _encrypter = () {
    final keyBytes = crypto.sha256.convert(utf8.encode(AppConfig.secretKey)).bytes;
    final key = enc.Key(Uint8List.fromList(keyBytes));
    return enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
  }();

  /// 16 zero bytes — matches `byte[] iv = new byte[16];` in the C# code.
  static final enc.IV _iv = enc.IV(Uint8List(16));

  /// Decrypt a Base64 AES payload into its plaintext (the account number).
  /// Returns null if [base64Text] is not a valid encrypted payload (e.g. an
  /// older plain-text QR, or a corrupt scan).
  static String? tryDecrypt(String base64Text) {
    try {
      final out = _encrypter.decrypt(enc.Encrypted.fromBase64(base64Text), iv: _iv);
      return out.isEmpty ? null : out;
    } catch (e) {
      if (kDebugMode) debugPrint('[QR] decrypt failed: $e');
      return null;
    }
  }
}
