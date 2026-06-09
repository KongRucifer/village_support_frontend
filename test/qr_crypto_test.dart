import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_test/flutter_test.dart';
import 'package:village_support_app/services/qr_crypto.dart';

void main() {
  test('AES-256-CBC round-trip matches C# EncryptAES params', () {
    // Replicate the C# EncryptAES to produce a Base64 payload, then decrypt.
    const secret = 'LTS@superSecretKey';
    const plain = '160206180000191';
    final keyBytes = crypto.sha256.convert(utf8.encode(secret)).bytes;
    final encrypter = enc.Encrypter(
        enc.AES(enc.Key(Uint8List.fromList(keyBytes)), mode: enc.AESMode.cbc, padding: 'PKCS7'));
    final iv = enc.IV(Uint8List(16));
    final b64 = encrypter.encrypt(plain, iv: iv).base64;
    print('encrypted base64 = $b64');

    final decrypted = QrCrypto.tryDecrypt(b64);
    expect(decrypted, plain);
  });
}
