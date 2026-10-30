import 'dart:io';
import 'dart:math';

import '../core/db.dart';
import 'budget_service.dart';
import 'push_service.dart';

/// 5.2 Cảnh báo vượt ngân sách, 6.3 Dự báo và cảnh báo bất thường.
/// Mỗi sự kiện chỉ cảnh báo một lần nhờ khóa dedupe_key UNIQUE trong bảng alerts.
/// Nội dung thông báo không chứa số tiền cụ thể.
class AlertService {
  final Db db;
  final PushService push;
  AlertService(this.db, this.push);

  /// Gọi sau khi một khoản chi được tạo/sửa/khôi phục. Lỗi ở đây không làm hỏng giao dịch.
  Future<void> afterExpenseChange(String userId,
      {required String categoryId, String? newTransactionId}) async {
    try {
      final st = await db.one(
          'SELECT budget_alerts_enabled, smart_alerts_enabled FROM user_settings WHERE user_id = @u',
          {'u': userId});
      if (st == null) return;
      if (st['budget_alerts_enabled'] == true) {
        await checkBudgets(userId, categoryId: categoryId);
      }
      if (st['smart_alerts_enabled'] == true) {
        await checkForecasts(userId, categoryId: categoryId);
        if (newTransactionId != null) await checkAnomaly(userId, newTransactionId);
      }
    } catch (e) {
      stderr.writeln('[alerts] lỗi kiểm tra cảnh báo: ${e.runtimeType}');
    }
  }

  Future<void> checkBudgets(String userId, {String? categoryId}) async {
    final budgets = await budgetsWithUsage(db.pool, userId, categoryId: categoryId);
    for (final b in budgets) {
      final pct = b['percent'] as double;
      final periodKey = (b['period_start'] as String).substring(0, 10);
      String? toPush;
      for (final th in [80, 100]) {
        if (pct < th) continue;
        final title = th == 100 ? 'Đã vượt ngân sách' : 'Sắp chạm ngân sách';
        final body = th == 100
            ? 'Ngân sách ${b['name']} đã dùng hết 100%'
            : 'Ngân sách ${b['name']} đã dùng $th%';
        final inserted = await _insert(userId,
            type: 'budget_$th',
            dedupe: 'budget:${b['id']}:$periodKey:$th',
            title: title,
            body: body,
            budgetId: b['id'] as String);
        if (inserted != null) toPush = inserted;
      }
      // Chạm cả 80% và 100% cùng lúc thì chỉ đẩy một thông báo (mức cao nhất).
      if (toPush != null) await _push(userId, toPush);
    }
  }

  /// Dự báo cuối kỳ dựa trên tốc độ chi trung bình mỗi ngày (thống kê đơn giản).
  Future<List<Map<String, dynamic>>> forecasts(String userId) async {
    final enough = await hasEnoughData(userId);
    final budgets = await budgetsWithUsage(db.pool, userId);
    final now = DateTime.now().toUtc();
    return budgets.map((b) {
      final start = DateTime.parse(b['period_start'] as String);
      final end = DateTime.parse(b['period_end'] as String);
      final spent = b['spent'] as int;
      final limit = b['amount_limit'] as int;
      final elapsedDays = max(1.0, now.difference(start).inMinutes / 1440);
      final totalDays = end.difference(start).inMinutes / 1440;
      final rate = spent / elapsedDays;
      final projected = (rate * totalDays).round();
      String? hitDate;
      if (spent < limit && projected > limit && rate > 0) {
        final d = start.add(Duration(minutes: (limit / rate * 1440).ceil()));
        if (d.isBefore(end)) hitDate = d.toIso8601String();
      }
      return {
        'budget_id': b['id'],
        'name': b['name'],
        'period': b['period'],
        'enough_data': enough,
        'spent': spent,
        'amount_limit': limit,
        'daily_rate': rate.round(),
        'projected_total': enough ? projected : null,
        'projected_hit_at': enough ? hitDate : null,
        'will_exceed': enough && projected > limit,
      };
    }).toList();
  }

  /// Cần tối thiểu 2 tuần dữ liệu mới dự báo (6.3).
  Future<bool> hasEnoughData(String userId) async {
    final r = await db.one(
        "SELECT min(occurred_at) <= now() - interval '14 days' AS ok FROM transactions "
        "WHERE user_id = @u AND deleted_at IS NULL AND source <> 'system'",
        {'u': userId});
    return r?['ok'] == true;
  }

  Future<void> checkForecasts(String userId, {String? categoryId}) async {
    final list = await forecasts(userId);
    final tz = await _tz(userId);
    for (final f in list) {
      if (f['will_exceed'] != true || f['projected_hit_at'] == null) continue;
      final b = (await budgetsWithUsage(db.pool, userId, budgetId: f['budget_id'] as String)).first;
      if (categoryId != null && b['scope'] != 'all' &&
          !(b['category_ids'] as List).contains(categoryId)) {
        continue;
      }
      final start = DateTime.parse(b['period_start'] as String);
      // Không dự báo khi kỳ mới bắt đầu dưới 3 ngày để tránh báo nhầm.
      if (DateTime.now().toUtc().difference(start).inHours < 72) continue;
      final day = await db.one(
          "SELECT to_char(@d::timestamptz AT TIME ZONE @tz, 'DD/MM') AS d",
          {'d': f['projected_hit_at'], 'tz': tz});
      final id = await _insert(userId,
          type: 'forecast',
          dedupe: 'forecast:${b['id']}:${(b['period_start'] as String).substring(0, 10)}',
          title: 'Dự báo vượt ngân sách',
          body: 'Với tốc độ hiện tại, ngân sách ${b['name']} có thể vượt vào ngày ${day!['d']}',
          budgetId: b['id'] as String);
      if (id != null) await _push(userId, id);
    }
  }

  /// So khoản chi mới với trung bình 90 ngày của cùng danh mục (trung bình, độ lệch chuẩn).
  Future<void> checkAnomaly(String userId, String txId) async {
    final t = await db.one(
        "SELECT t.amount, t.category_id, c.name AS category FROM transactions t "
        "JOIN categories c ON c.id = t.category_id "
        "WHERE t.id = @id AND t.user_id = @u AND t.type = 'expense' AND t.source <> 'system' "
        "AND t.deleted_at IS NULL",
        {'id': txId, 'u': userId});
    if (t == null) return;
    // Người dùng đã bấm "Bình thường" cho danh mục này -> không cảnh báo loại tương tự nữa.
    final muted = await db.one(
        "SELECT 1 FROM alerts WHERE user_id = @u AND type = 'anomaly' AND category_id = @c "
        "AND feedback = 'normal' LIMIT 1",
        {'u': userId, 'c': t['category_id']});
    if (muted != null) return;
    // Chống làm phiền: mỗi danh mục tối đa một cảnh báo bất thường trong 24 giờ.
    final recent = await db.one(
        "SELECT 1 FROM alerts WHERE user_id = @u AND type = 'anomaly' AND category_id = @c "
        "AND sent_at > now() - interval '24 hours' LIMIT 1",
        {'u': userId, 'c': t['category_id']});
    if (recent != null) return;
    final s = await db.one(
        "SELECT count(*)::int AS n, avg(amount)::float8 AS avg, coalesce(stddev_samp(amount), 0)::float8 AS sd "
        "FROM transactions WHERE user_id = @u AND category_id = @c AND type = 'expense' "
        "AND deleted_at IS NULL AND source <> 'system' AND id <> @id "
        "AND occurred_at >= now() - interval '90 days'",
        {'u': userId, 'c': t['category_id'], 'id': txId});
    final n = s!['n'] as int;
    if (n < 5) return;
    final avg = s['avg'] as double;
    final sd = s['sd'] as double;
    final amount = (t['amount'] as int).toDouble();
    if (amount >= 3 * avg && amount > avg + 2 * sd) {
      final id = await _insert(userId,
          type: 'anomaly',
          dedupe: 'anomaly:$txId',
          title: 'Khoản chi bất thường',
          body: 'Khoản chi ${t['category']} vừa rồi cao hơn nhiều so với thường lệ',
          transactionId: txId,
          categoryId: t['category_id'] as String);
      if (id != null) await _push(userId, id);
    }
  }

  /// Tác vụ định kỳ: dự báo cho mọi người dùng có ngân sách.
  Future<void> runScheduledForecasts() async {
    final users = await db.q(
        'SELECT DISTINCT b.user_id FROM budgets b JOIN user_settings s ON s.user_id = b.user_id '
        'WHERE s.smart_alerts_enabled');
    for (final u in users) {
      try {
        await checkForecasts(u['user_id'] as String);
      } catch (e) {
        stderr.writeln('[alerts] forecast job lỗi: ${e.runtimeType}');
      }
    }
  }

  Future<String> _tz(String userId) async =>
      (await db.one('SELECT timezone FROM user_settings WHERE user_id = @u', {'u': userId}))?['timezone']
          as String? ??
      'Asia/Ho_Chi_Minh';

  Future<String?> _insert(String userId,
      {required String type,
      required String dedupe,
      required String title,
      required String body,
      String? budgetId,
      String? transactionId,
      String? categoryId}) async {
    final r = await db.one(
        'INSERT INTO alerts (user_id, type, budget_id, transaction_id, category_id, dedupe_key, title, body) '
        'VALUES (@u, @t, @b, @tx, @c, @k, @title, @body) '
        'ON CONFLICT (user_id, dedupe_key) DO NOTHING RETURNING id',
        {
          'u': userId,
          't': type,
          'b': budgetId,
          'tx': transactionId,
          'c': categoryId,
          'k': dedupe,
          'title': title,
          'body': body,
        });
    return r?['id'] as String?;
  }

  Future<void> _push(String userId, String alertId) async {
    final a = await db.one(
        'SELECT id, type, title, body, budget_id, transaction_id FROM alerts WHERE id = @id', {'id': alertId});
    if (a == null) return;
    // Liên kết mở từ thông báo chỉ mang mã định danh (5.2).
    await push.sendToUser(userId, title: a['title'] as String, body: a['body'] as String, data: {
      'alert_id': a['id'] as String,
      'type': a['type'] as String,
      if (a['budget_id'] != null) 'budget_id': a['budget_id'] as String,
      if (a['transaction_id'] != null) 'transaction_id': a['transaction_id'] as String,
    });
  }
}
