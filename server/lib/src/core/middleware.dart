import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import 'http.dart';
import 'rate_limit.dart';
import 'security.dart';

/// Bắt mọi lỗi, đổi thành JSON; không ghi dữ liệu nhạy cảm vào log.
Middleware errorHandler() => (inner) => (req) async {
      try {
        return await inner(req);
      } on ApiError catch (e) {
        return jsonError(e);
      } on ServerException catch (e) {
        // Lỗi ràng buộc CSDL (CHECK, UNIQUE, trigger) -> 400/409 với thông báo chung.
        final code = e.code ?? '';
        if (code == '23505') {
          return jsonError(ApiError.conflict('Dữ liệu bị trùng'));
        }
        if (code.startsWith('23') || code == 'P0001' || code == '22P02' || code == '22003') {
          stderr.writeln('[db] ${req.method} ${req.url.path} -> $code');
          return jsonError(ApiError.badRequest(
              code == 'P0001' ? (e.message) : 'Dữ liệu không hợp lệ'));
        }
        stderr.writeln('[db-error] ${req.method} ${req.url.path} -> $code ${e.message}');
        return jsonError(ApiError(500, 'server_error', 'Lỗi máy chủ, vui lòng thử lại'));
      } catch (e, st) {
        stderr.writeln('[error] ${req.method} ${req.url.path} -> ${e.runtimeType}: $e');
        stderr.writeln(st.toString().split('\n').take(6).join('\n'));
        return jsonError(ApiError(500, 'server_error', 'Lỗi máy chủ, vui lòng thử lại'));
      }
    };

/// Log gọn: phương thức, đường dẫn (không query vì có thể chứa từ khóa tìm kiếm), mã, thời gian.
Middleware accessLog() => (inner) => (req) async {
      final sw = Stopwatch()..start();
      final res = await inner(req);
      stdout.writeln('${DateTime.now().toIso8601String()} ${req.method} /${req.url.path} '
          '${res.statusCode} ${sw.elapsedMilliseconds}ms');
      return res;
    };

/// Gắn IP client vào context (dùng cho giới hạn đăng ký/đăng nhập).
/// Khi chạy sau proxy của nhà cung cấp cloud (TRUST_PROXY=true), IP thật nằm trong X-Forwarded-For.
/// Lấy phần tử CUỐI: đó là IP do proxy tự ghi thêm. Các phần tử phía trước do client tự gửi
/// nên có thể bị giả để lách giới hạn tần suất.
Middleware clientIp({bool trustProxy = false}) => (inner) => (req) {
      final info = req.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      var ip = info?.remoteAddress.address ?? 'unknown';
      final fwd = req.headers['x-forwarded-for'];
      if (trustProxy && fwd != null && fwd.isNotEmpty) {
        final last = fwd.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).lastOrNull;
        if (last != null) ip = last;
      }
      return inner(req.change(context: {'clientIp': ip}));
    };

Middleware securityHeaders() => (inner) => (req) async {
      final res = await inner(req);
      return res.change(headers: {
        'x-content-type-options': 'nosniff',
        'x-frame-options': 'DENY',
        'referrer-policy': 'no-referrer',
        if (!res.headers.containsKey('cache-control')) 'cache-control': 'no-store',
      });
    };

/// Kiểm tra access token cho mọi đường dẫn trừ danh sách công khai.
Middleware auth(JwtService jwt, {required Set<String> publicPaths}) => (inner) => (req) {
      final path = '/${req.url.path}';
      if (publicPaths.contains(path) || req.method == 'OPTIONS') return inner(req);
      final h = req.headers['authorization'] ?? '';
      if (!h.startsWith('Bearer ')) return jsonError(ApiError.unauthorized());
      final uid = jwt.verifyAccess(h.substring(7).trim());
      if (uid == null) {
        return jsonError(ApiError(401, 'token_expired', 'Phiên đăng nhập đã hết hạn'));
      }
      return inner(req.change(context: {'userId': uid}));
    };

/// Giới hạn chung: mặc định 120 yêu cầu/phút cho mỗi người dùng (hoặc IP nếu chưa đăng nhập).
Middleware globalRateLimit(int perMinute) {
  final rl = RateLimiter(perMinute, const Duration(minutes: 1));
  return (inner) => (req) {
        final key = (req.context['userId'] as String?) ?? 'ip:${req.context['clientIp']}';
        if (!rl.hit(key)) {
          return jsonError(ApiError(429, 'rate_limited', 'Bạn thao tác quá nhanh, vui lòng thử lại sau'));
        }
        return inner(req);
      };
}
