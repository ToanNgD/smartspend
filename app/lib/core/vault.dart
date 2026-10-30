import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'token_store.dart';

/// Kho khóa trên thiết bị (2.1).
/// - Dữ liệu cục bộ được mã hóa AES-GCM bằng một "khóa dữ liệu" ngẫu nhiên.
/// - Khóa dữ liệu được bọc (mã hóa) bằng khóa dẫn xuất từ PIN (PBKDF2 có salt), nên chỉ lấy ra được
///   khi nhập đúng PIN; bản dùng cho sinh trắc học nằm trong Keychain/Keystore và chỉ được đọc
///   sau khi hệ điều hành xác thực vân tay/khuôn mặt thành công.
/// - PIN không lưu dạng thô, chỉ lưu bản băm có salt.
class Vault {
  static const _s = TokenStore.storage;
  static const _kPinSalt = 'pin_salt';
  static const _kPinHash = 'pin_hash';
  static const _kWrapSalt = 'wrap_salt';
  static const _kWrapped = 'wrapped_key';
  static const _kBio = 'bio_key';
  static const _kPlain = 'plain_key';
  static const _kFails = 'pin_fails';

  final _aes = AesGcm.with256bits();
  final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: kIsWeb ? 20000 : 60000, bits: 256);
  final _auth = LocalAuthentication();

  SecretKey? _dataKey;
  bool get isUnlocked => _dataKey != null;

  static List<int> _random(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  Future<bool> hasPin() async => await _s.read(key: _kWrapped) != null;
  Future<bool> hasLockDisabled() async => await _s.read(key: _kPlain) != null;
  Future<bool> biometricEnabled() async => await _s.read(key: _kBio) != null;

  Future<bool> biometricAvailable() async {
    if (kIsWeb) return false;
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<SecretKey> _derive(String pin, List<int> salt) => _kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);

  /// Thiết lập (hoặc đổi) PIN. Khóa dữ liệu hiện tại giữ nguyên để không mất dữ liệu đệm.
  Future<void> setPin(String pin) async {
    _dataKey ??= SecretKey(_random(32));
    final raw = await _dataKey!.extractBytes();
    final pinSalt = _random(16), wrapSalt = _random(16);
    final hash = await (await _derive(pin, pinSalt)).extractBytes();
    final wrapKey = await _derive(pin, wrapSalt);
    final box = await _aes.encrypt(raw, secretKey: wrapKey);
    await _s.write(key: _kPinSalt, value: base64.encode(pinSalt));
    await _s.write(key: _kPinHash, value: base64.encode(hash));
    await _s.write(key: _kWrapSalt, value: base64.encode(wrapSalt));
    await _s.write(key: _kWrapped, value: base64.encode(box.concatenation()));
    await _s.delete(key: _kPlain);
    await _s.delete(key: _kFails);
  }

  /// Trả về true nếu đúng PIN. Số lần sai được lưu bền để không thể "khởi động lại app để thử tiếp".
  Future<bool> unlockWithPin(String pin) async {
    final salt = await _s.read(key: _kPinSalt);
    final hash = await _s.read(key: _kPinHash);
    final wrapSalt = await _s.read(key: _kWrapSalt);
    final wrapped = await _s.read(key: _kWrapped);
    if (salt == null || hash == null || wrapSalt == null || wrapped == null) return false;
    final h = await (await _derive(pin, base64.decode(salt))).extractBytes();
    if (!_constEq(h, base64.decode(hash))) {
      await _s.write(key: _kFails, value: '${await failedAttempts() + 1}');
      return false;
    }
    try {
      final box = SecretBox.fromConcatenation(base64.decode(wrapped), nonceLength: 12, macLength: 16);
      final raw = await _aes.decrypt(box, secretKey: await _derive(pin, base64.decode(wrapSalt)));
      _dataKey = SecretKey(raw);
      await _s.delete(key: _kFails);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<int> failedAttempts() async => int.tryParse(await _s.read(key: _kFails) ?? '') ?? 0;

  /// Mở khóa bằng sinh trắc học qua API của hệ điều hành (local_auth / BiometricPrompt).
  Future<bool> unlockWithBiometric() async {
    if (!await biometricEnabled()) return false;
    try {
      final ok = await _auth.authenticate(localizedReason: 'Xác thực để mở SmartSpend');
      if (!ok) return false;
      final raw = await _s.read(key: _kBio);
      if (raw == null) return false;
      _dataKey = SecretKey(base64.decode(raw));
      await _s.delete(key: _kFails);
      return true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Bật/tắt sinh trắc học (chỉ khi đang mở khóa). Bật cần xác thực sinh trắc một lần.
  Future<bool> setBiometric(bool on) async {
    if (!isUnlocked) return false;
    if (!on) {
      await _s.delete(key: _kBio);
      return true;
    }
    try {
      final ok = await _auth.authenticate(localizedReason: 'Xác thực để bật mở khóa bằng sinh trắc học');
      if (!ok) return false;
    } catch (_) {
      return false;
    }
    await _s.write(key: _kBio, value: base64.encode(await _dataKey!.extractBytes()));
    return true;
  }

  /// Tắt khóa ứng dụng (chỉ gọi sau khi đã xác thực lại).
  Future<void> disableLock() async {
    if (!isUnlocked) return;
    await _s.write(key: _kPlain, value: base64.encode(await _dataKey!.extractBytes()));
    for (final k in [_kPinSalt, _kPinHash, _kWrapSalt, _kWrapped, _kBio, _kFails]) {
      await _s.delete(key: k);
    }
  }

  /// Khi khóa ứng dụng bị tắt: lấy khóa dữ liệu trực tiếp.
  Future<bool> unlockWithoutLock() async {
    final raw = await _s.read(key: _kPlain);
    if (raw == null) return false;
    _dataKey = SecretKey(base64.decode(raw));
    return true;
  }

  void lock() => _dataKey = null;

  /// Xóa toàn bộ khóa (đăng xuất).
  Future<void> wipe() async {
    _dataKey = null;
    for (final k in [_kPinSalt, _kPinHash, _kWrapSalt, _kWrapped, _kBio, _kPlain, _kFails]) {
      await _s.delete(key: k);
    }
  }

  Future<List<int>> encrypt(List<int> data) async {
    final key = _dataKey;
    if (key == null) throw StateError('Ứng dụng đang khóa');
    return (await _aes.encrypt(data, secretKey: key)).concatenation();
  }

  Future<List<int>> decrypt(List<int> data) async {
    final key = _dataKey;
    if (key == null) throw StateError('Ứng dụng đang khóa');
    return _aes.decrypt(SecretBox.fromConcatenation(data, nonceLength: 12, macLength: 16), secretKey: key);
  }

  static bool _constEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a[i] ^ b[i];
    }
    return r == 0;
  }
}
