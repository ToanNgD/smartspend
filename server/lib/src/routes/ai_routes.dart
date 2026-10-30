import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/ai_service.dart';

/// UC11 Nhập bằng ngôn ngữ tự nhiên, UC12 Phân tích & gợi ý, UC13 Dự báo.
class AiRoutes {
  final AppContext c;
  AiRoutes(this.c);

  Router get router => Router()
    ..post('/parse', _parse)
    ..get('/insights', _insights)
    ..post('/insights/analyze', _analyze)
    ..patch('/insights/<id>', _setStatus)
    ..get('/forecast', _forecast);

  /// AI chỉ trả bản xem trước; người dùng xác nhận rồi app mới gọi POST /transactions.
  Future<Response> _parse(Request req) async {
    final f = Fields(await readJson(req));
    final text = f.str('text', max: 300, label: 'Câu nhập');
    return jsonOk(await c.ai.parse(req.userId, text));
  }

  /// Trả kết quả đã lưu (cache), không gọi lại AI mỗi lần mở màn hình.
  Future<Response> _insights(Request req) async {
    final rows = await c.db.q(
        'SELECT id, period_start, period_end, kind, title, content, action, status, trigger_type, created_at '
        'FROM ai_insights WHERE user_id = @u AND created_at = (SELECT max(created_at) FROM ai_insights WHERE user_id = @u) '
        'ORDER BY id',
        {'u': req.userId});
    final usage = await c.db.one(
        "SELECT coalesce(sum(call_count), 0)::int AS n FROM ai_usage WHERE user_id = @u AND feature = 'analyze' "
        'AND usage_date = (now() AT TIME ZONE (SELECT timezone FROM user_settings WHERE user_id = @u))::date',
        {'u': req.userId});
    return jsonOk({
      'items': rows.map(AiService.insightJson).toList(),
      'manual_remaining_today': c.config.aiAnalyzePerDay - (usage!['n'] as int),
      'engine': c.config.aiEnabled ? 'gemini' : 'basic',
    });
  }

  Future<Response> _analyze(Request req) async {
    final items = await c.ai.analyze(req.userId, manual: true);
    return jsonOk({'items': items});
  }

  Future<Response> _setStatus(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    final status = f.oneOf('status', ['acted', 'dismissed']);
    final n = await c.db.exec('UPDATE ai_insights SET status = @s WHERE id = @id AND user_id = @u',
        {'s': status, 'id': id, 'u': req.userId});
    if (n == 0) throw ApiError.notFound();
    return noContent();
  }

  Future<Response> _forecast(Request req) async {
    final enough = await c.alerts.hasEnoughData(req.userId);
    return jsonOk({
      'enough_data': enough,
      'message': enough ? null : 'Chưa đủ dữ liệu (cần ít nhất 2 tuần giao dịch)',
      'items': await c.alerts.forecasts(req.userId),
    });
  }
}
