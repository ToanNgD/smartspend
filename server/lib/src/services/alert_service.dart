import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../core/db.dart';
import 'ai_service.dart';
import 'budget_service.dart';
import 'push_service.dart';

/// 5.2 Cảnh báo vượt ngân sách, 6.3 Dự báo và cảnh báo bất thường.
/// Mỗi sự kiện chỉ cảnh báo một lần nhờ khóa dedupe_key UNIQUE trong bảng alerts.
/// Cảnh báo không còn đúng thì được gỡ: mức đã dùng giảm xuống dưới ngưỡng (xóa/sửa khoản chi, tăng hạn mức...),
/// khoản chi bị cảnh báo bất thường đã bị xóa hoặc được sửa hết bất thường. Nhờ vậy lần chạm ngưỡng sau vẫn được báo.
/// (Xóa ngân sách thì budget_routes gỡ luôn các cảnh báo của ngân sách đó.)
/// Nội dung thông báo không chứa số tiền cụ thể.
/// Cảnh báo dự báo và bất thường (UC13): server tự tính bằng thống kê, sau đó nhờ dịch vụ AI
/// diễn đạt câu chữ từ các con số đã tính; AI lỗi/hết lượt thì dùng câu mẫu (UC13 - 3a).
class AlertService {
  final Db db;
  final PushService push;
  final AiService? ai;
  AlertService(this.db, this.push, [this.ai]);

  /// Gọi sau khi một khoản chi được tạo/sửa/khôi phục. Lỗi ở đây không làm hỏng giao dịch.
  /// [categoryId] là danh mục của khoản chi sau khi lưu; null khi giao dịch không còn là khoản chi
  /// (sửa khoản chi thành khoản thu): khi đó chỉ gỡ các cảnh báo ngưỡng không còn đúng.
  /// [newTransactionId]: khoản chi cần xét chi bất thường (vừa thêm hoặc vừa hoàn tác xóa).
  /// [editedTransactionId]: giao dịch vừa được sửa số tiền, danh mục hoặc loại - xét lại cảnh báo bất thường của nó.
  Future<void> afterExpenseChange(String userId,
      {String? categoryId, String? newTransactionId, String? editedTransactionId}) async {
    try {
      // Sửa giao dịch có thể làm mức đã dùng giảm (bớt tiền, đổi danh mục hoặc ngày).
      await _rearmBudgets(userId);
      final st = await db.one(
          'SELECT budget_alerts_enabled, smart_alerts_enabled FROM user_settings WHERE user_id = @u',
          {'u': userId});
      if (editedTransactionId != null) {
        await _recheckAnomaly(userId, editedTransactionId, notify: st?['smart_alerts_enabled'] == true);
      }
      if (categoryId == null || st == null) return;
      if (st['budget_alerts_enabled'] == true) {
        await checkBudgets(userId, categoryId: categoryId);
      }
      if (st['smart_alerts_enabled'] == true) {
        // background: nhờ AI diễn đạt và gửi thông báo chạy nền, không làm chậm việc lưu giao dịch.
        await checkForecasts(userId, categoryId: categoryId, background: true);
        if (newTransactionId != null) await checkAnomaly(userId, newTransactionId, background: true);
      }
    } catch (e) {
      stderr.writeln('[alerts] lỗi kiểm tra cảnh báo: ${e.runtimeType}');
    }
  }

  /// Gọi sau khi tạo/sửa ngân sách hoặc xóa danh mục (giao dịch và phạm vi ngân sách có thể chuyển sang danh mục khác).
  /// Luôn gỡ cảnh báo ngưỡng không còn đúng (vd tăng hạn mức); chỉ kiểm tra ngưỡng mới khi người dùng
  /// đang bật cảnh báo ngân sách.
  Future<void> afterBudgetChange(String userId) async {
    try {
      await _rearmBudgets(userId);
      final st = await db.one('SELECT budget_alerts_enabled FROM user_settings WHERE user_id = @u', {'u': userId});
      if (st?['budget_alerts_enabled'] == true) await checkBudgets(userId);
    } catch (e) {
      stderr.writeln('[alerts] lỗi kiểm tra cảnh báo: ${e.runtimeType}');
    }
  }

  /// Gọi sau khi xóa (một hoặc nhiều) giao dịch.
  /// - Mức đã dùng của ngân sách có thể giảm: gỡ cảnh báo ngưỡng không còn đúng.
  /// - Khoản chi bị cảnh báo bất thường đã bị xóa: gỡ luôn cảnh báo đó (hoàn tác thì xét lại).
  ///   Giữ cảnh báo người dùng đã bấm "Bình thường" vì nó ghi nhớ lựa chọn cho danh mục.
  Future<void> afterTransactionsDeleted(String userId, List<String> transactionIds) async {
    try {
      await db.exec(
          "DELETE FROM alerts WHERE user_id = @u AND type = 'anomaly' AND feedback IS NULL "
          'AND transaction_id = ANY(@ids::uuid[])',
          {'u': userId, 'ids': transactionIds});
      await _rearmBudgets(userId);
    } catch (e) {
      stderr.writeln('[alerts] lỗi gỡ cảnh báo: ${e.runtimeType}');
    }
  }

  /// Khóa của cảnh báo ngưỡng [th] trong kỳ hiện tại của ngân sách [b]: mỗi ngưỡng một lần mỗi kỳ.
  String _budgetKey(Map<String, dynamic> b, int th) =>
      'budget:${b['id']}:${(b['period_start'] as String).substring(0, 10)}:$th';

  /// Ngưỡng nào mà mức đã dùng trong kỳ hiện tại giờ thấp hơn thì gỡ cảnh báo của ngưỡng đó:
  /// cảnh báo sai biến mất khỏi danh sách và lần chạm ngưỡng sau được báo lại.
  /// Chạy cả khi người dùng tắt cảnh báo (chỉ gỡ, không gửi gì).
  Future<void> _rearmBudgets(String userId) async {
    final keys = [
      for (final b in await budgetsWithUsage(db.pool, userId))
        for (final th in [80, 100])
          if ((b['percent'] as double) < th) _budgetKey(b, th),
    ];
    if (keys.isEmpty) return;
    await db.exec(
        "DELETE FROM alerts WHERE user_id = @u AND type IN ('budget_80', 'budget_100') AND dedupe_key = ANY(@k::text[])",
        {'u': userId, 'k': keys});
  }

  Future<void> checkBudgets(String userId, {String? categoryId}) async {
    final budgets = await budgetsWithUsage(db.pool, userId, categoryId: categoryId);
    for (final b in budgets) {
      // percent được làm tròn xuống (budget_service) nên "pct >= 80" đúng khi số tiền đã chi thật sự đạt 80% hạn mức.
      final pct = b['percent'] as double;
      String? toPush;
      for (final th in [80, 100]) {
        if (pct < th) continue;
        final title = th == 100 ? 'Đã vượt ngân sách' : 'Sắp chạm ngân sách';
        final body = th == 100
            ? 'Ngân sách ${b['name']} đã dùng hết 100%'
            : 'Ngân sách ${b['name']} đã dùng $th%';
        final inserted = await _insert(userId,
            type: 'budget_$th',
            dedupe: _budgetKey(b, th),
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
      // Kỳ mới bắt đầu dưới 3 ngày: số liệu quá ít, nhân lên cả kỳ dễ báo nhầm -> chưa dự báo (6.3).
      final tooEarly = now.difference(start).inHours < 72;
      final ok = enough && !tooEarly;
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
        'too_early': tooEarly,
        'spent': spent,
        'amount_limit': limit,
        'daily_rate': rate.round(),
        'projected_total': ok ? projected : null,
        'projected_hit_at': ok ? hitDate : null,
        'will_exceed': ok && projected > limit,
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

  Future<void> checkForecasts(String userId, {String? categoryId, bool background = false}) async {
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
      if (id != null) {
        await _deliver(userId, id,
            background: background,
            kind: 'du_bao_vuot_ngan_sach',
            name: b['name'] as String,
            mustContain: day['d'] as String,
            facts: {
              'ten_ngan_sach': b['name'] as String,
              'chu_ky': b['period'] == 'week' ? 'tuần' : 'tháng',
              'da_dung_phan_tram': (b['percent'] as double).round(),
              'du_kien_cuoi_ky_phan_tram': ((f['projected_total'] as int) * 100 / (f['amount_limit'] as int)).round(),
              'ngay_du_kien_vuot': day['d'] as String,
              'so_ngay_con_lai': b['days_left'] as int,
            });
      }
    }
  }

  /// Khoản chi (chưa xóa, không phải giao dịch hệ thống) kèm tên danh mục; null nếu không phải khoản chi như vậy.
  Future<Map<String, dynamic>?> _expenseTx(String userId, String txId) => db.one(
      "SELECT t.amount, t.category_id, c.name AS category FROM transactions t "
      "JOIN categories c ON c.id = t.category_id "
      "WHERE t.id = @id AND t.user_id = @u AND t.type = 'expense' AND t.source <> 'system' "
      "AND t.deleted_at IS NULL",
      {'id': txId, 'u': userId});

  /// Khoản chi [t] bị coi là bất thường khi cao gấp từ 3 lần trung bình 90 ngày của cùng danh mục và vượt
  /// trung bình cộng 2 lần độ lệch chuẩn (cần ít nhất 5 khoản khác). Trả về số lần so với trung bình, null nếu bình thường.
  Future<double?> _anomalyRatio(String userId, String txId, Map<String, dynamic> t) async {
    final s = await db.one(
        "SELECT count(*)::int AS n, avg(amount)::float8 AS avg, coalesce(stddev_samp(amount), 0)::float8 AS sd "
        "FROM transactions WHERE user_id = @u AND category_id = @c AND type = 'expense' "
        "AND deleted_at IS NULL AND source <> 'system' AND id <> @id "
        "AND occurred_at >= now() - interval '90 days'",
        {'u': userId, 'c': t['category_id'], 'id': txId});
    if ((s!['n'] as int) < 5) return null;
    final avg = s['avg'] as double;
    final sd = s['sd'] as double;
    final amount = (t['amount'] as int).toDouble();
    return amount >= 3 * avg && amount > avg + 2 * sd ? amount / avg : null;
  }

  /// Sau khi sửa số tiền, danh mục hoặc loại của giao dịch: xét lại cảnh báo chi bất thường của chính giao dịch đó.
  /// - Hết bất thường (bớt tiền, đổi danh mục, đổi thành khoản thu) thì gỡ cảnh báo.
  /// - Vẫn bất thường trong cùng danh mục thì giữ cảnh báo cũ (không gửi lại).
  /// - Trở thành bất thường thì báo như khoản chi mới (khi [notify], tức đang bật cảnh báo thông minh).
  /// Cảnh báo người dùng đã bấm "Bình thường" được giữ nguyên.
  Future<void> _recheckAnomaly(String userId, String txId, {required bool notify}) async {
    final old = await db.one(
        "SELECT id, category_id, feedback FROM alerts WHERE user_id = @u AND type = 'anomaly' AND transaction_id = @t LIMIT 1",
        {'u': userId, 't': txId});
    if (old != null && old['feedback'] == 'normal') return;
    final t = await _expenseTx(userId, txId);
    if (old != null) {
      final keep = t != null && t['category_id'] == old['category_id'] && await _anomalyRatio(userId, txId, t) != null;
      if (keep) return;
      await db.exec('DELETE FROM alerts WHERE id = @id AND user_id = @u', {'id': old['id'], 'u': userId});
    }
    if (t != null && notify) await checkAnomaly(userId, txId, background: true);
  }

  /// So khoản chi mới với trung bình 90 ngày của cùng danh mục (trung bình, độ lệch chuẩn).
  Future<void> checkAnomaly(String userId, String txId, {bool background = false}) async {
    final t = await _expenseTx(userId, txId);
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
    final ratio = await _anomalyRatio(userId, txId, t);
    if (ratio != null) {
      final id = await _insert(userId,
          type: 'anomaly',
          dedupe: 'anomaly:$txId',
          title: 'Khoản chi bất thường',
          body: 'Khoản chi ${t['category']} vừa rồi cao hơn nhiều so với thường lệ',
          transactionId: txId,
          categoryId: t['category_id'] as String);
      if (id != null) {
        await _deliver(userId, id,
            background: background,
            kind: 'chi_bat_thuong',
            name: t['category'] as String,
            facts: {
              'danh_muc': t['category'] as String,
              'gap_bao_nhieu_lan_trung_binh': double.parse(ratio.toStringAsFixed(1)),
            });
      }
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

  /// Nhờ AI diễn đạt lại câu cảnh báo (nếu được) rồi gửi thông báo đẩy.
  /// Cảnh báo đã được lưu sẵn với câu mẫu, nên AI lỗi hay chậm thì người dùng vẫn nhận được cảnh báo.
  Future<void> _deliver(String userId, String alertId,
      {required bool background,
      required String kind,
      required String name,
      required Map<String, Object> facts,
      String? mustContain}) async {
    Future<void> run() async {
      try {
        final p = await ai?.phraseAlert(userId, kind: kind, name: name, facts: facts, mustContain: mustContain);
        if (p != null) {
          await db.exec('UPDATE alerts SET title = @t, body = @b WHERE id = @id',
              {'t': p.title, 'b': p.body, 'id': alertId});
        }
      } catch (e) {
        stderr.writeln('[alerts] lỗi diễn đạt cảnh báo bằng AI: ${e.runtimeType}');
      }
      try {
        await _push(userId, alertId);
      } catch (e) {
        stderr.writeln('[alerts] lỗi gửi thông báo: ${e.runtimeType}');
      }
    }

    if (background) {
      unawaited(run());
    } else {
      await run();
    }
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
