import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'config.dart';

final _rnd = Random.secure();

/// Chuỗi ngẫu nhiên an toàn dạng hex.
String randomHex(int bytes) =>
    List.generate(bytes, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// Băm mật khẩu bằng bcrypt (có salt). Chạy trong isolate riêng để không chặn server.
Future<String> hashPassword(String pw) =>
    Isolate.run(() => BCrypt.hashpw(pw, BCrypt.gensalt(logRounds: 10)));

Future<bool> verifyPassword(String pw, String hash) => Isolate.run(() {
      try {
        return BCrypt.checkpw(pw, hash);
      } catch (_) {
        return false;
      }
    });

/// Bản băm giả để so sánh khi email không tồn tại, giúp thời gian phản hồi giống nhau.
final Future<String> dummyHash = hashPassword('khong-phai-mat-khau-that-123');

/// Mật khẩu tối thiểu 8 ký tự, có cả chữ và số; tối đa 72 byte (giới hạn bcrypt).
String? passwordProblem(String pw) {
  if (pw.length < 8) return 'Mật khẩu tối thiểu 8 ký tự';
  if (utf8.encode(pw).length > 72) return 'Mật khẩu quá dài';
  if (!RegExp(r'[A-Za-zÀ-ỹ]').hasMatch(pw) || !RegExp(r'\d').hasMatch(pw)) {
    return 'Mật khẩu phải gồm cả chữ và số';
  }
  return null;
}

class JwtService {
  final Config config;
  JwtService(this.config);

  String issueAccess(String userId) {
    final jwt = JWT({'typ': 'access'}, subject: userId, issuer: 'smartspend');
    return jwt.sign(SecretKey(config.jwtSecret),
        algorithm: JWTAlgorithm.HS256, expiresIn: config.accessTtl);
  }

  /// Trả về userId nếu token hợp lệ, ngược lại null.
  String? verifyAccess(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(config.jwtSecret), issuer: 'smartspend');
      final p = jwt.payload;
      if (p is! Map || p['typ'] != 'access') return null;
      return jwt.subject;
    } catch (_) {
      return null;
    }
  }
}
