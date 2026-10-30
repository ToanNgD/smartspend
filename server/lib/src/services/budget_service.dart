import 'package:postgres/postgres.dart';

import '../core/db.dart';

/// Tính mức đã dùng của ngân sách trong kỳ hiện tại (theo múi giờ người dùng).
/// Việc tính toán nằm ở server để app không thể giả mạo số liệu (5.1).
/// Chỉ tính khoản chi, bỏ qua giao dịch hệ thống (số dư ban đầu, điều chỉnh số dư).
const budgetUsageSql = '''
WITH st AS (SELECT timezone AS tz FROM user_settings WHERE user_id = @u),
b AS (
  SELECT b.*,
    (date_trunc(CASE WHEN b.period = 'week' THEN 'week' ELSE 'month' END, now() AT TIME ZONE st.tz)
       AT TIME ZONE st.tz) AS period_start,
    ((date_trunc(CASE WHEN b.period = 'week' THEN 'week' ELSE 'month' END, now() AT TIME ZONE st.tz)
       + CASE WHEN b.period = 'week' THEN interval '1 week' ELSE interval '1 month' END)
       AT TIME ZONE st.tz) AS period_end
  FROM budgets b CROSS JOIN st
  WHERE b.user_id = @u
    AND (@bid::uuid IS NULL OR b.id = @bid::uuid)
    AND (@cid::uuid IS NULL OR b.scope = 'all'
         OR EXISTS (SELECT 1 FROM budget_categories x WHERE x.budget_id = b.id AND x.category_id = @cid::uuid))
)
SELECT b.id, b.name, b.amount_limit, b.period, b.scope, b.period_start, b.period_end,
  b.created_at, b.updated_at,
  COALESCE((
    SELECT sum(t.amount) FROM transactions t
    WHERE t.user_id = @u AND t.type = 'expense' AND t.deleted_at IS NULL AND t.source <> 'system'
      AND t.occurred_at >= b.period_start AND t.occurred_at < b.period_end
      AND (b.scope = 'all' OR t.category_id IN
           (SELECT bc.category_id FROM budget_categories bc WHERE bc.budget_id = b.id))
  ), 0)::bigint AS spent,
  COALESCE((SELECT array_agg(bc.category_id::text ORDER BY bc.category_id)
            FROM budget_categories bc WHERE bc.budget_id = b.id), '{}'::text[]) AS category_ids
FROM b
ORDER BY (b.scope = 'all') DESC, b.period DESC, b.created_at
''';

Future<List<Map<String, dynamic>>> budgetsWithUsage(Session s, String userId,
    {String? budgetId, String? categoryId}) async {
  final rows = await s.rows(budgetUsageSql, {'u': userId, 'bid': budgetId, 'cid': categoryId});
  return rows.map(_decorate).toList();
}

Map<String, dynamic> _decorate(Map<String, dynamic> r) {
  final limit = r['amount_limit'] as int;
  final spent = r['spent'] as int;
  final start = r['period_start'] as DateTime;
  final end = r['period_end'] as DateTime;
  final now = DateTime.now().toUtc();
  final remaining = limit - spent;
  final daysLeft = (end.difference(now).inHours / 24).ceil().clamp(1, 31);
  final pct = limit == 0 ? 0.0 : spent * 100 / limit;
  return {
    'id': r['id'],
    'name': r['name'],
    'amount_limit': limit,
    'period': r['period'],
    'scope': r['scope'],
    'category_ids': r['category_ids'],
    'period_start': start.toIso8601String(),
    'period_end': end.toIso8601String(),
    'spent': spent,
    'remaining': remaining,
    'percent': double.parse(pct.toStringAsFixed(1)),
    'days_left': daysLeft,
    'daily_allowance': remaining > 0 ? remaining ~/ daysLeft : 0,
    // xanh < 80%, vàng 80-99%, đỏ >= 100% (khớp ngưỡng cảnh báo 5.2)
    'status': pct >= 100 ? 'red' : (pct >= 80 ? 'yellow' : 'green'),
    'created_at': (r['created_at'] as DateTime).toIso8601String(),
  };
}
