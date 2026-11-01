import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/budget_service.dart';

/// UC14 Màn hình tổng quan và báo cáo. Tổng hợp ở server theo người dùng lấy từ token.
/// Giao dịch hệ thống (số dư ban đầu, điều chỉnh) không tính vào thu/chi.
class ReportRoutes {
  final AppContext c;
  ReportRoutes(this.c);

  Router get router => Router()
    ..get('/overview', _overview)
    ..get('/summary', _summary)
    ..get('/categories', _categories)
    ..get('/trend', _trend);

  static const _base = "t.user_id = @u AND t.deleted_at IS NULL AND t.source <> 'system' "
      'AND (@wal::uuid IS NULL OR t.wallet_id = @wal::uuid)';

  /// Xác định kỳ xem và kỳ so sánh. Kỳ chưa hết thì so với cùng số ngày của kỳ trước.
  Future<Map<String, dynamic>> _range(Request req) async {
    final q = req.url.queryParameters;
    final period = q['period'] ?? 'month';
    if (!['week', 'month', 'year', 'custom'].contains(period)) throw ApiError.badRequest('period không hợp lệ');
    final offset = (int.tryParse(q['offset'] ?? '0') ?? 0).clamp(-120, 0);
    final from = q['from'], to = q['to'];
    final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (period == 'custom' && (from == null || to == null || !dateRe.hasMatch(from) || !dateRe.hasMatch(to))) {
      throw ApiError.badRequest('Khoảng ngày không hợp lệ');
    }
    final r = await c.db.one('''
      WITH st AS (SELECT timezone AS tz, now() AT TIME ZONE timezone AS ln FROM user_settings WHERE user_id = @u),
      p AS (
        SELECT tz, ln,
          CASE WHEN @p = 'custom' THEN @from::date::timestamp
               ELSE date_trunc(@p, ln) + make_interval(weeks => CASE WHEN @p = 'week' THEN @o ELSE 0 END,
                      months => CASE WHEN @p = 'month' THEN @o ELSE 0 END, years => CASE WHEN @p = 'year' THEN @o ELSE 0 END)
          END AS s
        FROM st),
      q AS (
        SELECT tz, ln, s,
          CASE WHEN @p = 'custom' THEN @to::date::timestamp + interval '1 day'
               ELSE s + CASE @p WHEN 'week' THEN interval '1 week' WHEN 'month' THEN interval '1 month' ELSE interval '1 year' END
          END AS e,
          CASE WHEN @p = 'custom' THEN s - ((@to::date::timestamp + interval '1 day') - s)
               ELSE s - CASE @p WHEN 'week' THEN interval '1 week' WHEN 'month' THEN interval '1 month' ELSE interval '1 year' END
          END AS ps
        FROM p)
      SELECT tz, s, LEAST(e, ln) AS e_eff, e, ps,
        CASE WHEN ln < e AND ln >= s THEN LEAST(ps + (ln - s), s) ELSE s END AS pe,
        (ln < e AND ln >= s) AS ongoing
      FROM q''', {'u': req.userId, 'p': period == 'custom' ? 'custom' : period, 'o': offset, 'from': from, 'to': to});
    if (r == null) throw ApiError.unauthorized();
    if ((r['e'] as DateTime).isBefore(r['s'] as DateTime) || (r['e'] as DateTime).difference(r['s'] as DateTime).inDays > 3660) {
      throw ApiError.badRequest('Khoảng ngày không hợp lệ');
    }
    return {
      'u': req.userId,
      'tz': r['tz'],
      'wal': qUuid(q, 'wallet_id'),
      's': r['s'],
      'e': r['e_eff'],
      'ps': r['ps'],
      'pe': r['pe'],
      'ongoing': r['ongoing'],
      'period': period,
    };
  }

  static const _inCur = 't.occurred_at >= (@s::timestamp AT TIME ZONE @tz) AND t.occurred_at < (@e::timestamp AT TIME ZONE @tz)';
  static const _inPrev = 't.occurred_at >= (@ps::timestamp AT TIME ZONE @tz) AND t.occurred_at < (@pe::timestamp AT TIME ZONE @tz)';

  Map<String, dynamic> _params(Map<String, dynamic> r) =>
      {'u': r['u'], 'tz': r['tz'], 'wal': r['wal'], 's': r['s'], 'e': r['e'], 'ps': r['ps'], 'pe': r['pe']};

  Future<Map<String, dynamic>> _summaryData(Map<String, dynamic> r) async {
    final t = await c.db.one('''
      SELECT
        COALESCE(sum(amount) FILTER (WHERE type = 'income' AND $_inCur), 0)::bigint AS income,
        COALESCE(sum(amount) FILTER (WHERE type = 'expense' AND $_inCur), 0)::bigint AS expense,
        COALESCE(sum(amount) FILTER (WHERE type = 'income' AND $_inPrev), 0)::bigint AS p_income,
        COALESCE(sum(amount) FILTER (WHERE type = 'expense' AND $_inPrev), 0)::bigint AS p_expense
      FROM transactions t WHERE $_base''', _params(r));
    double? pct(int cur, int prev) => prev == 0 ? null : double.parse(((cur - prev) * 100 / prev).toStringAsFixed(1));
    final income = t!['income'] as int, expense = t['expense'] as int;
    final pi = t['p_income'] as int, pe = t['p_expense'] as int;
    String d(Object v) => (v as DateTime).toIso8601String().substring(0, 10);
    // Ngày cuối (bao gồm) để hiển thị: mốc kết thúc là mốc mở nên lùi 1 giây.
    String last(Object v) => d((v as DateTime).subtract(const Duration(seconds: 1)));
    return {
      'from': d(r['s']),
      'to': last(r['e']),
      'ongoing': r['ongoing'],
      'income': income,
      'expense': expense,
      'net': income - expense,
      'previous': {'from': d(r['ps']), 'to': last(r['pe']), 'income': pi, 'expense': pe, 'net': pi - pe},
      'change_percent': {'income': pct(income, pi), 'expense': pct(expense, pe)},
    };
  }

  Future<Response> _summary(Request req) async => jsonOk(await _summaryData(await _range(req)));

  /// Báo cáo theo danh mục; danh mục dưới 3% gộp vào "Khác".
  Future<Response> _categories(Request req) async {
    final r = await _range(req);
    final type = req.url.queryParameters['type'] ?? 'expense';
    if (type != 'income' && type != 'expense') throw ApiError.badRequest('type không hợp lệ');
    final rows = await c.db.q('''
      SELECT c.id AS category_id, c.name, c.icon, c.color, sum(t.amount)::bigint AS amount, count(*)::int AS count
      FROM transactions t JOIN categories c ON c.id = t.category_id
      WHERE $_base AND t.type = @type AND $_inCur
      GROUP BY c.id ORDER BY amount DESC''', {..._params(r), 'type': type});
    final total = rows.fold<int>(0, (s, x) => s + (x['amount'] as int));
    final items = <Map<String, dynamic>>[];
    final other = <Map<String, dynamic>>[];
    for (final x in rows) {
      final pct = total == 0 ? 0.0 : (x['amount'] as int) * 100 / total;
      final item = {...x, 'percent': double.parse(pct.toStringAsFixed(1))};
      (pct < 3 ? other : items).add(item);
    }
    final otherAmount = other.fold<int>(0, (s, x) => s + (x['amount'] as int));
    // from/to là ngày đầu và ngày cuối (bao gồm) của kỳ, cách tính giống /reports/summary,
    // để app mở đúng các giao dịch cấu thành khi bấm vào một danh mục.
    final from = (r['s'] as DateTime).toIso8601String().substring(0, 10);
    final last = (r['e'] as DateTime).subtract(const Duration(seconds: 1)).toIso8601String().substring(0, 10);
    return jsonOk({
      'from': from,
      'to': last.compareTo(from) < 0 ? from : last,
      'type': type,
      'total': total,
      'items': items,
      'other': other.isEmpty
          ? null
          : {
              'name': 'Khác',
              'amount': otherAmount,
              'percent': double.parse((otherAmount * 100 / total).toStringAsFixed(1)),
              'count': other.fold<int>(0, (s, x) => s + (x['count'] as int)),
              'categories': other,
            },
    });
  }

  /// Xu hướng thu/chi theo ngày, tuần hoặc tháng (có đủ các mốc, kể cả mốc bằng 0).
  Future<Response> _trend(Request req) async {
    final r = await _range(req);
    final group = req.url.queryParameters['group'] ?? 'day';
    if (!['day', 'week', 'month'].contains(group)) throw ApiError.badRequest('group không hợp lệ');
    final rows = await c.db.q('''
      WITH b AS (
        SELECT g AS bucket FROM generate_series(date_trunc(@g, @s::timestamp), @e::timestamp - interval '1 second',
          ('1 ' || @g)::interval) g)
      SELECT b.bucket,
        COALESCE(sum(t.amount) FILTER (WHERE t.type = 'income'), 0)::bigint AS income,
        COALESCE(sum(t.amount) FILTER (WHERE t.type = 'expense'), 0)::bigint AS expense
      FROM b LEFT JOIN transactions t ON $_base AND $_inCur
        AND date_trunc(@g, t.occurred_at AT TIME ZONE @tz) = b.bucket
      GROUP BY b.bucket ORDER BY b.bucket''', {..._params(r), 'g': group});
    return jsonOk({
      'group': group,
      'items': rows
          .map((x) => {
                'date': (x['bucket'] as DateTime).toIso8601String().substring(0, 10),
                'income': x['income'],
                'expense': x['expense'],
              })
          .toList(),
    });
  }

  /// Màn hình chính: tổng tháng này, ngân sách chính, giao dịch gần nhất, tổng số dư.
  Future<Response> _overview(Request req) async {
    final r = await _range(Request('GET', Uri.parse('http://x/?period=month'), context: req.context));
    final summary = await _summaryData(r);
    final budgets = await budgetsWithUsage(c.db.pool, req.userId);
    Map<String, dynamic>? main;
    for (final b in budgets) {
      if (b['scope'] == 'all' && b['period'] == 'month') main = b;
    }
    main ??= budgets.isEmpty ? null : budgets.first;
    final recent = await c.db.q('''
      SELECT t.id, t.type, t.amount, t.occurred_at, t.note, t.source, t.wallet_id, w.name AS wallet_name,
        t.category_id, c.name AS category_name, c.icon AS category_icon, c.color AS category_color,
        (SELECT count(*) FROM transaction_attachments a WHERE a.transaction_id = t.id)::int AS attachment_count
      FROM transactions t JOIN wallets w ON w.id = t.wallet_id JOIN categories c ON c.id = t.category_id
      WHERE t.user_id = @u AND t.deleted_at IS NULL ORDER BY t.occurred_at DESC, t.id DESC LIMIT 5''', {'u': req.userId});
    final bal = await c.db.one(
        'SELECT COALESCE(sum(balance), 0)::bigint AS total FROM wallets WHERE user_id = @u AND NOT is_archived',
        {'u': req.userId});
    final unread = await c.db.one(
        'SELECT count(*)::int AS n FROM alerts WHERE user_id = @u AND read_at IS NULL', {'u': req.userId});
    return jsonOk({
      'month': summary,
      'main_budget': main,
      'budget_count': budgets.length,
      'recent_transactions': recent.map(clean).toList(),
      'total_balance': bal!['total'],
      'unread_alerts': unread!['n'],
    });
  }
}
