import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/db.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/audit.dart';

/// UC05 Quản lý danh mục. Danh mục mặc định chỉ được ẩn, không sửa/xóa.
class CategoryRoutes {
  final AppContext c;
  CategoryRoutes(this.c);

  static const icons = [
    'food', 'car', 'bag', 'bolt', 'home', 'play', 'health', 'book', 'dots', 'wallet', 'star', 'gift',
    'coffee', 'pet', 'baby', 'phone', 'plane', 'shirt', 'gym', 'heart', 'tool', 'chart',
  ];
  static const _cols = 'id, name, type, icon, color, is_default, is_hidden, created_at, updated_at';
  static final _colorRe = RegExp(r'^#[0-9A-Fa-f]{6}$');

  Router get router => Router()
    ..get('/', _list)
    ..post('/', _create)
    ..patch('/<id>', _update)
    ..delete('/<id>', _delete);

  Future<Response> _list(Request req) async {
    final includeHidden = req.url.queryParameters['include_hidden'] == 'true';
    final rows = await c.db.q(
        'SELECT $_cols, (SELECT count(*) FROM transactions t WHERE t.category_id = c.id AND t.deleted_at IS NULL)::int AS tx_count '
        'FROM categories c WHERE user_id = @u AND (@h OR NOT is_hidden) '
        "ORDER BY type DESC, is_default DESC, (name IN ('Chi khác', 'Thu khác')), name",
        {'u': req.userId, 'h': includeHidden});
    return jsonOk({'items': rows.map(clean).toList()});
  }

  Future<Response> _create(Request req) async {
    final f = Fields(await readJson(req));
    final name = f.str('name', max: 30, label: 'Tên danh mục', noAngle: true);
    final type = f.oneOf('type', ['income', 'expense'], label: 'Loại danh mục');
    final icon = f.has('icon') ? f.oneOf('icon', icons, label: 'Biểu tượng') : 'dots';
    final color = f.has('color') ? _color(f) : '#8B9590';
    final row = await c.db.tx((s) async {
      await _ensureNameFree(s, req.userId, type, name);
      final r = await s.row(
          'INSERT INTO categories (user_id, name, type, icon, color) VALUES (@u, @n, @t, @i, @c) RETURNING $_cols',
          {'u': req.userId, 'n': name, 't': type, 'i': icon, 'c': color});
      await audit(s, req.userId, 'category', r!['id'] as String, 'create');
      return r;
    });
    return jsonOk(clean(row), status: 201);
  }

  Future<Response> _update(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    final row = await c.db.tx((s) async {
      final cur = await _own(s, req.userId, id);
      final isDefault = cur['is_default'] == true;
      final changed = <String>[];
      var name = cur['name'] as String, icon = cur['icon'] as String, color = cur['color'] as String;
      var hidden = cur['is_hidden'] as bool;
      if (isDefault && (f.has('name') || f.has('icon') || f.has('color'))) {
        throw ApiError.badRequest('Danh mục mặc định chỉ được ẩn hoặc hiện', 'default_category');
      }
      if (f.has('type')) throw ApiError.badRequest('Không đổi được loại của danh mục');
      if (f.has('name')) {
        name = f.str('name', max: 30, label: 'Tên danh mục', noAngle: true);
        if (name.toLowerCase() != (cur['name'] as String).toLowerCase()) {
          await _ensureNameFree(s, req.userId, cur['type'] as String, name, exceptId: id);
        }
        if (name != cur['name']) changed.add('name');
      }
      if (f.has('icon')) {
        icon = f.oneOf('icon', icons, label: 'Biểu tượng');
        if (icon != cur['icon']) changed.add('icon');
      }
      if (f.has('color')) {
        color = _color(f);
        if (color != cur['color']) changed.add('color');
      }
      if (f.has('is_hidden')) {
        hidden = f.boolean('is_hidden');
        if (hidden != cur['is_hidden']) changed.add('is_hidden');
      }
      final r = await s.row(
          'UPDATE categories SET name = @n, icon = @i, color = @c, is_hidden = @h WHERE id = @id AND user_id = @u RETURNING $_cols',
          {'n': name, 'i': icon, 'c': color, 'h': hidden, 'id': id, 'u': req.userId});
      if (changed.isNotEmpty) await audit(s, req.userId, 'category', id, 'update', changed);
      return r;
    });
    return jsonOk(clean(row!));
  }

  /// Xóa danh mục riêng; nếu đang có giao dịch thì bắt buộc chọn danh mục khác cùng loại để chuyển sang.
  Future<Response> _delete(Request req, String id) async {
    requireUuid(id);
    final moveTo = qUuid(req.url.queryParameters, 'move_to');
    final moved = await c.db.tx((s) async {
      final cur = await _own(s, req.userId, id);
      if (cur['is_default'] == true) {
        throw ApiError.badRequest('Danh mục mặc định chỉ được ẩn, không xóa', 'default_category');
      }
      // Chỉ tính giao dịch đang hiển thị (khớp tx_count app thấy); giao dịch đã xóa mềm vẫn phải chuyển đi vì còn khóa ngoại.
      final used = await s.row(
          'SELECT count(*) FILTER (WHERE deleted_at IS NULL)::int AS n, count(*)::int AS total '
          'FROM transactions WHERE category_id = @id AND user_id = @u',
          {'id': id, 'u': req.userId});
      final n = used!['n'] as int;
      final total = used['total'] as int;
      if (n > 0 && moveTo == null) {
        throw ApiError(409, 'category_in_use', 'Danh mục đang có giao dịch, hãy chọn danh mục để chuyển sang',
            {'transaction_count': n});
      }
      String? target;
      if (moveTo != null) {
        if (moveTo == id) throw ApiError.badRequest('Danh mục chuyển sang phải khác danh mục bị xóa');
        final t = await _own(s, req.userId, moveTo);
        if (t['type'] != cur['type']) throw ApiError.badRequest('Danh mục chuyển sang phải cùng loại thu/chi');
        target = moveTo;
      } else if (total > 0) {
        // Chỉ còn giao dịch đã xóa: chuyển sang danh mục mặc định "Chi khác"/"Thu khác" cùng loại.
        final def = await s.row(
            'SELECT id FROM categories WHERE user_id = @u AND type = @t AND is_default '
            "AND name = CASE WHEN @t = 'income' THEN 'Thu khác' ELSE 'Chi khác' END",
            {'u': req.userId, 't': cur['type']});
        target = (def ??
            await s.row(
                'SELECT id FROM categories WHERE user_id = @u AND type = @t AND id <> @id '
                'ORDER BY is_default DESC, created_at LIMIT 1',
                {'u': req.userId, 't': cur['type'], 'id': id}))?['id'] as String?;
        if (target == null) throw ApiError.badRequest('Không còn danh mục cùng loại để chuyển giao dịch cũ sang');
      }
      if (target != null && total > 0) {
        await s.run('UPDATE transactions SET category_id = @to WHERE category_id = @id AND user_id = @u',
            {'to': target, 'id': id, 'u': req.userId});
      }
      // Ngân sách theo danh mục: chuyển phạm vi sang danh mục mới (bỏ trùng).
      if (moveTo != null) {
        await s.run(
            'INSERT INTO budget_categories (budget_id, category_id, user_id) '
            'SELECT budget_id, @to, user_id FROM budget_categories WHERE category_id = @id AND user_id = @u '
            'ON CONFLICT DO NOTHING',
            {'to': moveTo, 'id': id, 'u': req.userId});
      }
      await s.run('DELETE FROM budget_categories WHERE category_id = @id AND user_id = @u', {'id': id, 'u': req.userId});
      await s.run('DELETE FROM categories WHERE id = @id AND user_id = @u', {'id': id, 'u': req.userId});
      await audit(s, req.userId, 'category', id, 'delete');
      return n;
    });
    return jsonOk({'moved_transactions': moved});
  }

  String _color(Fields f) {
    final v = f.body['color'];
    if (v is! String || !_colorRe.hasMatch(v)) throw ApiError.badRequest('Màu không hợp lệ');
    return v.toUpperCase();
  }

  Future<Map<String, dynamic>> _own(Session s, String userId, String id) async {
    final r = await s.row('SELECT $_cols FROM categories WHERE id = @id AND user_id = @u FOR UPDATE',
        {'id': id, 'u': userId});
    if (r == null) throw ApiError.notFound('Không tìm thấy danh mục');
    return r;
  }

  Future<void> _ensureNameFree(Session s, String userId, String type, String name, {String? exceptId}) async {
    final r = await s.row(
        'SELECT 1 FROM categories WHERE user_id = @u AND type = @t AND lower(name) = lower(@n) '
        'AND (@ex::uuid IS NULL OR id <> @ex::uuid)',
        {'u': userId, 't': type, 'n': name, 'ex': exceptId});
    if (r != null) throw ApiError.conflict('Tên danh mục đã tồn tại trong loại này', 'duplicate_name');
  }
}
