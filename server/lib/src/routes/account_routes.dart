import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/http.dart';
import '../core/validate.dart';

/// Thông tin tài khoản, cài đặt đồng bộ (UC10, UC13) và mã thiết bị nhận thông báo.
class AccountRoutes {
  final AppContext c;
  AccountRoutes(this.c);

  Router get router => Router()
    ..get('/me', _me)
    ..get('/settings', _getSettings)
    ..patch('/settings', _patchSettings)
    ..post('/devices', _registerDevice)
    ..delete('/devices', _removeDevice);

  Future<Response> _me(Request req) async {
    final u = await c.db.one(
        'SELECT id, full_name, email, created_at FROM users WHERE id = @u', {'u': req.userId});
    if (u == null) throw ApiError.unauthorized();
    return jsonOk({
      ...clean(u),
      'features': {'ai': c.config.aiEnabled, 'push': c.config.pushEnabled},
    });
  }

  Future<Response> _getSettings(Request req) async {
    final s = await c.db.one(
        'SELECT budget_alerts_enabled, smart_alerts_enabled, timezone FROM user_settings WHERE user_id = @u',
        {'u': req.userId});
    return jsonOk(s);
  }

  Future<Response> _patchSettings(Request req) async {
    final f = Fields(await readJson(req));
    final sets = <String>[];
    final p = <String, dynamic>{'u': req.userId};
    if (f.has('budget_alerts_enabled')) {
      sets.add('budget_alerts_enabled = @b');
      p['b'] = f.boolean('budget_alerts_enabled');
    }
    if (f.has('smart_alerts_enabled')) {
      sets.add('smart_alerts_enabled = @s');
      p['s'] = f.boolean('smart_alerts_enabled');
    }
    if (f.has('timezone')) {
      final tz = f.str('timezone', max: 50);
      final ok = await c.db.one('SELECT 1 FROM pg_timezone_names WHERE name = @t', {'t': tz});
      if (ok == null) throw ApiError.badRequest('Múi giờ không hợp lệ');
      sets.add('timezone = @tz');
      p['tz'] = tz;
    }
    if (sets.isNotEmpty) {
      await c.db.exec('UPDATE user_settings SET ${sets.join(', ')} WHERE user_id = @u', p);
    }
    return _getSettings(req);
  }

  Future<Response> _registerDevice(Request req) async {
    final f = Fields(await readJson(req));
    final token = f.str('push_token', min: 10, max: 4096);
    final platform = f.oneOf('platform', ['android', 'ios']);
    // Mã thiết bị gắn với tài khoản đang đăng nhập; nếu máy đổi tài khoản thì chuyển chủ.
    await c.db.exec(
        'INSERT INTO device_tokens (user_id, push_token, platform) VALUES (@u, @t, @p) '
        'ON CONFLICT (push_token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform, '
        'last_seen_at = now()',
        {'u': req.userId, 't': token, 'p': platform});
    return noContent();
  }

  Future<Response> _removeDevice(Request req) async {
    final f = Fields(await readJson(req));
    final token = f.str('push_token', min: 10, max: 4096);
    await c.db.exec('DELETE FROM device_tokens WHERE user_id = @u AND push_token = @t',
        {'u': req.userId, 't': token});
    return noContent();
  }
}
