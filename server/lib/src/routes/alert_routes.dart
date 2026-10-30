import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/http.dart';
import '../core/validate.dart';

/// Danh sách cảnh báo đã nhận; phản hồi "Bình thường" cho cảnh báo bất thường (6.3).
class AlertRoutes {
  final AppContext c;
  AlertRoutes(this.c);

  Router get router => Router()
    ..get('/', _list)
    ..post('/read-all', _readAll)
    ..post('/<id>/read', _read)
    ..post('/<id>/feedback', _feedback);

  Future<Response> _list(Request req) async {
    final q = req.url.queryParameters;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 30).clamp(1, 50);
    final before = qDate(q, 'before');
    final rows = await c.db.q(
        'SELECT id, type, title, body, budget_id, transaction_id, category_id, feedback, sent_at, read_at '
        'FROM alerts WHERE user_id = @u AND (@b::timestamptz IS NULL OR sent_at < @b::timestamptz) '
        'ORDER BY sent_at DESC LIMIT @l',
        {'u': req.userId, 'b': before, 'l': limit});
    final unread = await c.db.one(
        'SELECT count(*)::int AS n FROM alerts WHERE user_id = @u AND read_at IS NULL', {'u': req.userId});
    return jsonOk({'items': rows.map(clean).toList(), 'unread_count': unread!['n']});
  }

  Future<Response> _read(Request req, String id) async {
    requireUuid(id);
    final n = await c.db.exec(
        'UPDATE alerts SET read_at = coalesce(read_at, now()) WHERE id = @id AND user_id = @u', {'id': id, 'u': req.userId});
    if (n == 0) throw ApiError.notFound();
    return noContent();
  }

  Future<Response> _readAll(Request req) async {
    await c.db.exec('UPDATE alerts SET read_at = now() WHERE user_id = @u AND read_at IS NULL', {'u': req.userId});
    return noContent();
  }

  Future<Response> _feedback(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    f.oneOf('feedback', ['normal']);
    final n = await c.db.exec(
        "UPDATE alerts SET feedback = 'normal', read_at = coalesce(read_at, now()) "
        "WHERE id = @id AND user_id = @u AND type = 'anomaly'",
        {'id': id, 'u': req.userId});
    if (n == 0) throw ApiError.notFound();
    return noContent();
  }
}
