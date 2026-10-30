import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../app_context.dart';
import '../core/db.dart';
import '../core/http.dart';
import '../core/rate_limit.dart';
import '../core/security.dart';
import '../core/validate.dart';

/// UC01 Đăng ký, UC02 Đăng nhập / duy trì / kết thúc phiên.
class AuthRoutes {
  final AppContext c;
  AuthRoutes(this.c) : _registerByIp = RateLimiter(c.config.registerPerHour, const Duration(hours: 1));

  final RateLimiter _registerByIp;
  final _loginByIp = RateLimiter(30, const Duration(minutes: 15));
  // Đếm sai cho email không tồn tại, để phản hồi giống hệt email có thật.
  final _unknownEmailFails = RateLimiter(5, const Duration(minutes: 15));

  static const _genericLoginError = 'Email hoặc mật khẩu không đúng';
  static const _lockedMessage = 'Bạn đã nhập sai quá nhiều lần. Vui lòng thử lại sau 15 phút.';

  Router get router => Router()
    ..post('/register', _register)
    ..post('/login', _login)
    ..post('/refresh', _refresh)
    ..post('/logout', _logout);

  Future<Response> _register(Request req) async {
    if (!_registerByIp.hit(req.clientIp)) {
      throw ApiError(429, 'rate_limited', 'Bạn đã đăng ký quá nhiều lần, vui lòng thử lại sau');
    }
    final f = Fields(await readJson(req));
    final name = f.str('full_name', max: 100, label: 'Họ tên', noAngle: true);
    final email = f.str('email', max: 255, label: 'Email').toLowerCase();
    if (!emailRe.hasMatch(email)) throw ApiError.badRequest('Email không đúng định dạng');
    final pw = f.body['password'] is String ? f.body['password'] as String : '';
    final problem = passwordProblem(pw);
    if (problem != null) throw ApiError.badRequest(problem, 'weak_password');
    final device = f.optStr('device_name', max: 100);

    final exists = await c.db.one('SELECT 1 FROM users WHERE lower(email) = @e', {'e': email});
    if (exists != null) throw ApiError.conflict('Email đã được sử dụng', 'email_taken');

    final hash = await hashPassword(pw);
    final result = await c.db.tx((s) async {
      final u = await s.row(
          'INSERT INTO users (full_name, email, password_hash) VALUES (@n, @e, @h) '
          'RETURNING id, full_name, email, created_at',
          {'n': name, 'e': email, 'h': hash});
      await s.run('SELECT init_user_data(@id)', {'id': u!['id']});
      final tokens = await _issueTokens(s, u['id'] as String, device, null)
        ..remove('_rid');
      return {'user': clean(u), ...tokens};
    });
    return jsonOk(result, status: 201);
  }

  Future<Response> _login(Request req) async {
    if (!_loginByIp.hit(req.clientIp)) {
      throw ApiError(429, 'rate_limited', 'Bạn thao tác quá nhanh, vui lòng thử lại sau');
    }
    final f = Fields(await readJson(req));
    final email = (f.body['email'] is String ? f.body['email'] as String : '').trim().toLowerCase();
    final pw = f.body['password'] is String ? f.body['password'] as String : '';
    final device = f.optStr('device_name', max: 100);
    if (email.isEmpty || pw.isEmpty || email.length > 255 || pw.length > 200) {
      throw ApiError(401, 'invalid_credentials', _genericLoginError);
    }

    final u = await c.db.one(
        'SELECT id, full_name, email, password_hash, failed_login_count, '
        '(locked_until IS NOT NULL AND locked_until > now()) AS locked '
        'FROM users WHERE lower(email) = @e',
        {'e': email});

    if (u == null) {
      await verifyPassword(pw, await dummyHash);
      if (_unknownEmailFails.count(email) >= 5) {
        throw ApiError(429, 'login_locked', _lockedMessage);
      }
      _unknownEmailFails.hit(email);
      throw ApiError(401, 'invalid_credentials', _genericLoginError);
    }
    if (u['locked'] == true) throw ApiError(429, 'login_locked', _lockedMessage);

    final ok = await verifyPassword(pw, u['password_hash'] as String);
    if (!ok) {
      await c.db.exec(
          'UPDATE users SET '
          'failed_login_count = CASE WHEN failed_login_count + 1 >= 5 THEN 0 ELSE failed_login_count + 1 END, '
          "locked_until = CASE WHEN failed_login_count + 1 >= 5 THEN now() + interval '15 minutes' ELSE locked_until END "
          'WHERE id = @id',
          {'id': u['id']});
      throw ApiError(401, 'invalid_credentials', _genericLoginError);
    }

    final result = await c.db.tx((s) async {
      await s.run('UPDATE users SET failed_login_count = 0, locked_until = NULL WHERE id = @id',
          {'id': u['id']});
      final tokens = await _issueTokens(s, u['id'] as String, device, null)
        ..remove('_rid');
      return {
        'user': {'id': u['id'], 'full_name': u['full_name'], 'email': u['email']},
        ...tokens,
      };
    });
    return jsonOk(result);
  }

  Future<Response> _refresh(Request req) async {
    final body = await readJson(req);
    final token = body['refresh_token'];
    if (token is! String || token.length != 64) throw ApiError.unauthorized();
    final hash = sha256Hex(token);

    final result = await c.db.tx<Object>((s) async {
      final row = await s.row(
          'SELECT id, user_id, family_id, device_name, revoked_at, (expires_at < now()) AS expired '
          'FROM refresh_tokens WHERE token_hash = @h FOR UPDATE',
          {'h': hash});
      if (row == null) return ApiError.unauthorized();
      if (row['revoked_at'] != null) {
        // Token cũ bị dùng lại -> có thể đã bị đánh cắp: hủy toàn bộ phiên của tài khoản.
        await s.run(
            'UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = @u AND revoked_at IS NULL',
            {'u': row['user_id']});
        await s.run('DELETE FROM device_tokens WHERE user_id = @u', {'u': row['user_id']});
        return ApiError(401, 'session_revoked', 'Phiên đăng nhập đã bị thu hồi, vui lòng đăng nhập lại');
      }
      if (row['expired'] == true) return ApiError.unauthorized();
      final tokens = await _issueTokens(
          s, row['user_id'] as String, row['device_name'] as String?, row['family_id'] as String);
      await s.run('UPDATE refresh_tokens SET revoked_at = now(), replaced_by = @n WHERE id = @id',
          {'n': tokens['_rid'], 'id': row['id']});
      return tokens;
    });
    if (result is ApiError) throw result;
    final map = Map<String, dynamic>.from(result as Map)..remove('_rid');
    return jsonOk(map);
  }

  Future<Response> _logout(Request req) async {
    final body = await readJson(req);
    final token = body['refresh_token'];
    final push = body['push_token'];
    if (token is String && token.length == 64) {
      final row = await c.db.one(
          'SELECT user_id, family_id FROM refresh_tokens WHERE token_hash = @h',
          {'h': sha256Hex(token)});
      if (row != null) {
        await c.db.exec(
            'UPDATE refresh_tokens SET revoked_at = now() WHERE family_id = @f AND revoked_at IS NULL',
            {'f': row['family_id']});
        if (push is String && push.isNotEmpty) {
          await c.db.exec('DELETE FROM device_tokens WHERE user_id = @u AND push_token = @p',
              {'u': row['user_id'], 'p': push});
        }
      }
    }
    return noContent();
  }

  Future<Map<String, dynamic>> _issueTokens(
      Session s, String userId, String? device, String? family) async {
    final refresh = randomHex(32);
    final id = const Uuid().v4();
    await s.run(
        'INSERT INTO refresh_tokens (id, user_id, family_id, token_hash, device_name, expires_at) '
        'VALUES (@id, @u, @f, @h, @d, now() + make_interval(days => @days))',
        {
          'id': id,
          'u': userId,
          'f': family ?? const Uuid().v4(),
          'h': sha256Hex(refresh),
          'd': device,
          'days': c.config.refreshTtl.inDays,
        });
    return {
      'access_token': c.jwt.issueAccess(userId),
      'refresh_token': refresh,
      'expires_in': c.config.accessTtl.inSeconds,
      '_rid': id,
    };
  }
}
