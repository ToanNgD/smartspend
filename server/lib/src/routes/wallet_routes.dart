import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../app_context.dart';
import '../core/db.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/audit.dart';

/// UC04 Quản lý ví. Số dư là kết quả tính từ giao dịch, không sửa trực tiếp.
class WalletRoutes {
  final AppContext c;
  WalletRoutes(this.c);

  static const types = ['cash', 'bank', 'ewallet'];
  static const _cols = 'id, name, type, balance, is_archived, created_at, updated_at';

  Router get router => Router()
    ..get('/', _list)
    ..post('/', _create)
    ..patch('/<id>', _update)
    ..post('/<id>/archive', (Request r, String id) => _setArchived(r, id, true))
    ..post('/<id>/unarchive', (Request r, String id) => _setArchived(r, id, false))
    ..post('/<id>/adjust', _adjust)
    ..delete('/<id>', _delete);

  Future<Response> _list(Request req) async {
    final rows = await c.db.q(
        'SELECT $_cols, (SELECT count(*) FROM transactions t WHERE t.wallet_id = w.id)::int AS tx_count '
        'FROM wallets w WHERE user_id = @u ORDER BY is_archived, created_at',
        {'u': req.userId});
    final total = rows.where((w) => w['is_archived'] != true).fold<int>(0, (s, w) => s + (w['balance'] as int));
    return jsonOk({'items': rows.map(clean).toList(), 'total_balance': total});
  }

  Future<Response> _create(Request req) async {
    final f = Fields(await readJson(req));
    final name = f.str('name', max: 30, label: 'Tên ví', noAngle: true);
    final type = f.oneOf('type', types, label: 'Loại ví');
    final initial = f.has('initial_balance') ? f.integer('initial_balance', label: 'Số dư ban đầu') : 0;
    final w = await c.db.tx((s) async {
      await _ensureNameFree(s, req.userId, name);
      final w = await s.row(
          'INSERT INTO wallets (user_id, name, type) VALUES (@u, @n, @t) RETURNING $_cols',
          {'u': req.userId, 'n': name, 't': type});
      await audit(s, req.userId, 'wallet', w!['id'] as String, 'create');
      if (initial > 0) {
        // Ghi giao dịch "Số dư ban đầu" để số dư luôn là kết quả tính từ giao dịch (3.1).
        await systemTx(s, req.userId, w['id'] as String, 'income', initial, 'Số dư ban đầu');
      }
      return s.row('SELECT $_cols FROM wallets WHERE id = @id', {'id': w['id']});
    });
    return jsonOk(clean(w!), status: 201);
  }

  Future<Response> _update(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    final w = await c.db.tx((s) async {
      final cur = await _own(s, req.userId, id);
      final fields = <String>[];
      var name = cur['name'] as String;
      var type = cur['type'] as String;
      if (f.has('name')) {
        name = f.str('name', max: 30, label: 'Tên ví', noAngle: true);
        if (name.toLowerCase() != (cur['name'] as String).toLowerCase()) {
          await _ensureNameFree(s, req.userId, name, exceptId: id);
        }
        if (name != cur['name']) fields.add('name');
      }
      if (f.has('type')) {
        type = f.oneOf('type', types, label: 'Loại ví');
        if (type != cur['type']) fields.add('type');
      }
      if (f.has('balance')) throw ApiError.badRequest('Không sửa trực tiếp số dư, hãy dùng điều chỉnh số dư');
      final w = await s.row(
          'UPDATE wallets SET name = @n, type = @t WHERE id = @id AND user_id = @u RETURNING $_cols',
          {'n': name, 't': type, 'id': id, 'u': req.userId});
      if (fields.isNotEmpty) await audit(s, req.userId, 'wallet', id, 'update', fields);
      return w;
    });
    return jsonOk(clean(w!));
  }

  Future<Response> _setArchived(Request req, String id, bool archived) async {
    requireUuid(id);
    final w = await c.db.tx((s) async {
      await s.run('SELECT 1 FROM wallets WHERE user_id = @u FOR UPDATE', {'u': req.userId});
      final cur = await _own(s, req.userId, id);
      if (archived && cur['is_archived'] != true) {
        final active = await s.row(
            'SELECT count(*)::int AS n FROM wallets WHERE user_id = @u AND NOT is_archived', {'u': req.userId});
        if ((active!['n'] as int) <= 1) {
          throw ApiError.conflict('Phải giữ lại ít nhất một ví đang dùng', 'last_wallet');
        }
      }
      final w = await s.row(
          'UPDATE wallets SET is_archived = @a WHERE id = @id AND user_id = @u RETURNING $_cols',
          {'a': archived, 'id': id, 'u': req.userId});
      await audit(s, req.userId, 'wallet', id, 'update', ['is_archived']);
      return w;
    });
    return jsonOk(clean(w!));
  }

  /// Điều chỉnh số dư: tạo giao dịch hệ thống bằng phần chênh lệch.
  Future<Response> _adjust(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    final target = f.integer('balance', min: -maxAmount, label: 'Số dư thực tế');
    final w = await c.db.tx((s) async {
      final cur = await _own(s, req.userId, id, lock: true);
      final diff = target - (cur['balance'] as int);
      if (diff != 0) {
        await systemTx(s, req.userId, id, diff > 0 ? 'income' : 'expense', diff.abs(), 'Điều chỉnh số dư');
      }
      return s.row('SELECT $_cols FROM wallets WHERE id = @id', {'id': id});
    });
    return jsonOk(clean(w!));
  }

  /// Chỉ xóa được ví chưa từng có giao dịch và không phải ví đang dùng cuối cùng.
  Future<Response> _delete(Request req, String id) async {
    requireUuid(id);
    await c.db.tx((s) async {
      await s.run('SELECT 1 FROM wallets WHERE user_id = @u FOR UPDATE', {'u': req.userId});
      final cur = await _own(s, req.userId, id);
      final used = await s.row('SELECT 1 FROM transactions WHERE wallet_id = @id LIMIT 1', {'id': id});
      if (used != null) {
        throw ApiError.conflict('Ví đã có giao dịch, hãy lưu trữ thay vì xóa', 'wallet_has_transactions');
      }
      if (cur['is_archived'] != true) {
        final active = await s.row(
            'SELECT count(*)::int AS n FROM wallets WHERE user_id = @u AND NOT is_archived', {'u': req.userId});
        if ((active!['n'] as int) <= 1) {
          throw ApiError.conflict('Không thể xóa ví cuối cùng', 'last_wallet');
        }
      }
      await s.run('DELETE FROM wallets WHERE id = @id AND user_id = @u', {'id': id, 'u': req.userId});
      await audit(s, req.userId, 'wallet', id, 'delete');
    });
    return noContent();
  }

  Future<Map<String, dynamic>> _own(Session s, String userId, String id, {bool lock = false}) async {
    final w = await s.row(
        'SELECT $_cols FROM wallets WHERE id = @id AND user_id = @u${lock ? ' FOR UPDATE' : ''}',
        {'id': id, 'u': userId});
    if (w == null) throw ApiError.notFound('Không tìm thấy ví');
    return w;
  }

  Future<void> _ensureNameFree(Session s, String userId, String name, {String? exceptId}) async {
    final r = await s.row(
        'SELECT 1 FROM wallets WHERE user_id = @u AND lower(name) = lower(@n) AND (@ex::uuid IS NULL OR id <> @ex::uuid)',
        {'u': userId, 'n': name, 'ex': exceptId});
    if (r != null) throw ApiError.conflict('Tên ví đã tồn tại', 'duplicate_name');
  }

  static Future<void> systemTx(Session s, String userId, String walletId, String type, int amount, String note) async {
    final cat = await s.row(
        'SELECT id FROM categories WHERE user_id = @u AND type = @t AND is_default '
        "AND name = CASE WHEN @t = 'income' THEN 'Thu khác' ELSE 'Chi khác' END",
        {'u': userId, 't': type});
    final catId = cat?['id'] ??
        (await s.row(
            'SELECT id FROM categories WHERE user_id = @u AND type = @t ORDER BY is_default DESC, created_at LIMIT 1',
            {'u': userId, 't': type}))!['id'];
    final tx = await s.row(
        "INSERT INTO transactions (user_id, wallet_id, category_id, type, amount, note, source, idempotency_key) "
        "VALUES (@u, @w, @c, @t, @a, @n, 'system', @k) RETURNING id",
        {'u': userId, 'w': walletId, 'c': catId, 't': type, 'a': amount, 'n': note, 'k': const Uuid().v4()});
    await s.run(
        'UPDATE wallets SET balance = balance + @d WHERE id = @w',
        {'d': type == 'income' ? amount : -amount, 'w': walletId});
    await audit(s, userId, 'transaction', tx!['id'] as String, 'create');
  }
}
