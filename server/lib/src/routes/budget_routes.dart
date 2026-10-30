import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/db.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/audit.dart';
import '../services/budget_service.dart';

/// UC09 Tạo và theo dõi ngân sách. Mức đã dùng luôn do server tính.
class BudgetRoutes {
  final AppContext c;
  BudgetRoutes(this.c);

  Router get router => Router()
    ..get('/', _list)
    ..get('/<id>', _get)
    ..post('/', _create)
    ..patch('/<id>', _update)
    ..delete('/<id>', _delete);

  Future<Response> _list(Request req) async {
    final items = await budgetsWithUsage(c.db.pool, req.userId);
    return jsonOk({'items': await _withNames(req.userId, items)});
  }

  Future<Response> _get(Request req, String id) async {
    requireUuid(id);
    final items = await budgetsWithUsage(c.db.pool, req.userId, budgetId: id);
    if (items.isEmpty) throw ApiError.notFound('Không tìm thấy ngân sách');
    return jsonOk((await _withNames(req.userId, items)).first);
  }

  Future<Response> _create(Request req) async {
    final f = Fields(await readJson(req));
    final name = f.str('name', max: 40, label: 'Tên ngân sách', noAngle: true);
    final limit = f.integer('amount_limit', min: 1000, label: 'Hạn mức');
    final period = f.oneOf('period', ['week', 'month'], label: 'Chu kỳ');
    final scope = f.has('scope') ? f.oneOf('scope', ['all', 'categories'], label: 'Phạm vi') : 'all';
    final cats = scope == 'categories' ? f.uuidList('category_ids', max: 20) : <String>[];
    if (scope == 'categories' && cats.isEmpty) throw ApiError.badRequest('Hãy chọn ít nhất một danh mục chi');

    final id = await c.db.tx((s) async {
      await s.run('SELECT 1 FROM users WHERE id = @u FOR UPDATE', {'u': req.userId});
      await _checkCategories(s, req.userId, cats);
      await _checkDuplicate(s, req.userId, period, scope, cats);
      final b = await s.row(
          'INSERT INTO budgets (user_id, name, amount_limit, period, scope) VALUES (@u, @n, @l, @p, @s) RETURNING id',
          {'u': req.userId, 'n': name, 'l': limit, 'p': period, 's': scope});
      final id = b!['id'] as String;
      await _setCategories(s, req.userId, id, cats);
      await audit(s, req.userId, 'budget', id, 'create');
      return id;
    });
    // Tạo ngân sách khi đã chi quá ngưỡng thì cảnh báo ngay.
    await c.alerts.checkBudgets(req.userId);
    final items = await budgetsWithUsage(c.db.pool, req.userId, budgetId: id);
    return jsonOk((await _withNames(req.userId, items)).first, status: 201);
  }

  Future<Response> _update(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    await c.db.tx((s) async {
      await s.run('SELECT 1 FROM users WHERE id = @u FOR UPDATE', {'u': req.userId});
      final cur = await s.row('SELECT * FROM budgets WHERE id = @id AND user_id = @u FOR UPDATE',
          {'id': id, 'u': req.userId});
      if (cur == null) throw ApiError.notFound('Không tìm thấy ngân sách');
      final changed = <String>[];
      final name = f.has('name') ? f.str('name', max: 40, label: 'Tên ngân sách', noAngle: true) : cur['name'] as String;
      final limit = f.has('amount_limit') ? f.integer('amount_limit', min: 1000, label: 'Hạn mức') : cur['amount_limit'] as int;
      if (f.has('period') || f.has('scope')) {
        throw ApiError.badRequest('Không đổi được chu kỳ/phạm vi, hãy tạo ngân sách mới');
      }
      if (name != cur['name']) changed.add('name');
      if (limit != cur['amount_limit']) changed.add('amount_limit');
      if (f.has('category_ids')) {
        if (cur['scope'] != 'categories') throw ApiError.badRequest('Ngân sách toàn bộ không có danh mục');
        final cats = f.uuidList('category_ids', max: 20);
        if (cats.isEmpty) throw ApiError.badRequest('Hãy chọn ít nhất một danh mục chi');
        await _checkCategories(s, req.userId, cats);
        await _checkDuplicate(s, req.userId, cur['period'] as String, 'categories', cats, exceptId: id);
        await _setCategories(s, req.userId, id, cats);
        changed.add('category_ids');
      }
      await s.run('UPDATE budgets SET name = @n, amount_limit = @l WHERE id = @id AND user_id = @u',
          {'n': name, 'l': limit, 'id': id, 'u': req.userId});
      if (changed.isNotEmpty) await audit(s, req.userId, 'budget', id, 'update', changed);
    });
    await c.alerts.checkBudgets(req.userId);
    return _get(req, id);
  }

  /// Xóa ngân sách không xóa giao dịch.
  Future<Response> _delete(Request req, String id) async {
    requireUuid(id);
    await c.db.tx((s) async {
      final n = await s.run('DELETE FROM budgets WHERE id = @id AND user_id = @u', {'id': id, 'u': req.userId});
      if (n == 0) throw ApiError.notFound('Không tìm thấy ngân sách');
      await audit(s, req.userId, 'budget', id, 'delete');
    });
    return noContent();
  }

  Future<void> _checkCategories(Session s, String userId, List<String> ids) async {
    if (ids.isEmpty) return;
    final r = await s.row(
        "SELECT count(*)::int AS n FROM categories WHERE user_id = @u AND type = 'expense' AND id = ANY(@ids::uuid[])",
        {'u': userId, 'ids': ids});
    if ((r!['n'] as int) != ids.length) throw ApiError.badRequest('Danh mục không hợp lệ', 'invalid_category');
  }

  /// Không tạo hai ngân sách trùng phạm vi và chu kỳ.
  Future<void> _checkDuplicate(Session s, String userId, String period, String scope, List<String> cats,
      {String? exceptId}) async {
    if (scope == 'all') {
      final r = await s.row(
          "SELECT 1 FROM budgets WHERE user_id = @u AND period = @p AND scope = 'all' AND (@ex::uuid IS NULL OR id <> @ex::uuid)",
          {'u': userId, 'p': period, 'ex': exceptId});
      if (r != null) throw ApiError.conflict('Đã có ngân sách toàn bộ cho chu kỳ này', 'duplicate_budget');
      return;
    }
    final sorted = [...cats]..sort();
    final r = await s.row('''
      SELECT 1 FROM budgets b WHERE b.user_id = @u AND b.period = @p AND b.scope = 'categories'
        AND (@ex::uuid IS NULL OR b.id <> @ex::uuid)
        AND (SELECT array_agg(category_id::text ORDER BY category_id::text) FROM budget_categories WHERE budget_id = b.id) = @c::text[]''',
        {'u': userId, 'p': period, 'ex': exceptId, 'c': sorted});
    if (r != null) throw ApiError.conflict('Đã có ngân sách cùng danh mục và chu kỳ này', 'duplicate_budget');
  }

  Future<void> _setCategories(Session s, String userId, String budgetId, List<String> cats) async {
    await s.run('DELETE FROM budget_categories WHERE budget_id = @b AND user_id = @u', {'b': budgetId, 'u': userId});
    for (final cid in cats) {
      await s.run('INSERT INTO budget_categories (budget_id, category_id, user_id) VALUES (@b, @c, @u)',
          {'b': budgetId, 'c': cid, 'u': userId});
    }
  }

  Future<List<Map<String, dynamic>>> _withNames(String userId, List<Map<String, dynamic>> items) async {
    final cats = await c.db.q('SELECT id, name, icon, color FROM categories WHERE user_id = @u', {'u': userId});
    final byId = {for (final x in cats) x['id'] as String: x};
    return items
        .map((b) => {
              ...b,
              'categories': (b['category_ids'] as List).map((id) => byId[id]).whereType<Map>().toList(),
            })
        .toList();
  }
}
