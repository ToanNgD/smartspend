import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../app_context.dart';
import '../core/db.dart';
import '../core/http.dart';
import '../core/validate.dart';
import '../services/audit.dart';
import '../services/storage_service.dart';

/// UC06 Thêm, UC07 Sửa/xóa, UC08 Xem/tìm/lọc giao dịch, UC06.1 Đính kèm ảnh.
class TransactionRoutes {
  final AppContext c;
  TransactionRoutes(this.c);

  static const _select = '''
    SELECT t.id, t.type, t.amount, t.occurred_at, t.note, t.source, t.deleted_at, t.created_at, t.updated_at,
      t.wallet_id, w.name AS wallet_name, t.category_id, c.name AS category_name,
      c.icon AS category_icon, c.color AS category_color,
      (SELECT count(*) FROM transaction_attachments a WHERE a.transaction_id = t.id)::int AS attachment_count
    FROM transactions t
    JOIN wallets w ON w.id = t.wallet_id
    JOIN categories c ON c.id = t.category_id''';

  Router get router => Router()
    ..get('/', _list)
    ..post('/', _create)
    ..post('/bulk-delete', _bulkDelete)
    ..get('/<id>', _get)
    ..patch('/<id>', _update)
    ..delete('/<id>', _delete)
    ..post('/<id>/restore', _restore)
    ..get('/<id>/attachments', _listAttachments)
    ..post('/<id>/attachments', _upload);

  Router get attachmentRouter => Router()
    ..get('/<id>', _download)
    ..delete('/<id>', _deleteAttachment);

  // ------------------------------------------------------------------ danh sách
  Future<Response> _list(Request req) async {
    final q = req.url.queryParameters;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 30).clamp(1, 50);
    final type = q['type'];
    if (type != null && type.isNotEmpty && type != 'income' && type != 'expense') {
      throw ApiError.badRequest('type không hợp lệ');
    }
    final keyword = sanitize(q['q'] ?? '');
    if (keyword.length > 100) throw ApiError.badRequest('Từ khóa quá dài');
    final p = <String, dynamic>{
      'u': req.userId,
      'from': qDate(q, 'from'),
      'to': qDate(q, 'to'),
      'type': (type == null || type.isEmpty) ? null : type,
      'cat': qUuid(q, 'category_id'),
      'wal': qUuid(q, 'wallet_id'),
      // Thoát ký tự đại diện của LIKE để từ khóa chỉ là dữ liệu.
      'kw': keyword.isEmpty ? null : keyword.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_'),
    };
    const where = '''
      WHERE t.user_id = @u AND t.deleted_at IS NULL
        AND (@from::timestamptz IS NULL OR t.occurred_at >= @from::timestamptz)
        AND (@to::timestamptz IS NULL OR t.occurred_at < @to::timestamptz)
        AND (@type::text IS NULL OR t.type = @type::text)
        AND (@cat::uuid IS NULL OR t.category_id = @cat::uuid)
        AND (@wal::uuid IS NULL OR t.wallet_id = @wal::uuid)
        AND (@kw::text IS NULL
             OR f_unaccent(coalesce(t.note, '')) LIKE '%' || f_unaccent(@kw::text) || '%'
             OR f_unaccent(c.name) LIKE '%' || f_unaccent(@kw::text) || '%')''';

    // Phân trang theo con trỏ (occurred_at, id) để tải thêm khi cuộn.
    var cursorSql = '';
    final cursor = q['cursor'];
    if (cursor != null && cursor.isNotEmpty) {
      try {
        final parts = utf8.decode(base64Url.decode(cursor)).split('|');
        final t = DateTime.parse(parts[0]);
        if (!isUuid(parts[1])) throw const FormatException();
        p['ct'] = t.toUtc();
        p['cid'] = parts[1];
        cursorSql = ' AND (t.occurred_at, t.id) < (@ct::timestamptz, @cid::uuid)';
      } catch (_) {
        throw ApiError.badRequest('cursor không hợp lệ');
      }
    }
    p['lim'] = limit + 1;
    final rows = await c.db.q('$_select $where $cursorSql ORDER BY t.occurred_at DESC, t.id DESC LIMIT @lim', p);
    String? next;
    if (rows.length > limit) {
      rows.removeLast();
      final last = rows.last;
      next = base64Url.encode(utf8.encode(
          '${(last['occurred_at'] as DateTime).toUtc().toIso8601String()}|${last['id']}'));
    }
    Map<String, dynamic>? totals;
    if (cursorSql.isEmpty) {
      p.remove('lim');
      totals = await c.db.one('''
        -- Tổng thu/chi không tính giao dịch hệ thống (số dư ban đầu, điều chỉnh) - khớp với báo cáo.
        SELECT COALESCE(sum(t.amount) FILTER (WHERE t.type = 'income' AND t.source <> 'system'), 0)::bigint AS income,
               COALESCE(sum(t.amount) FILTER (WHERE t.type = 'expense' AND t.source <> 'system'), 0)::bigint AS expense,
               count(*)::int AS count
        FROM transactions t JOIN categories c ON c.id = t.category_id $where''', p);
    }
    return jsonOk({'items': rows.map(clean).toList(), 'next_cursor': next, 'totals': totals});
  }

  Future<Response> _get(Request req, String id) async {
    requireUuid(id);
    final t = await c.db.one('$_select WHERE t.id = @id AND t.user_id = @u', {'id': id, 'u': req.userId});
    if (t == null) throw ApiError.notFound('Không tìm thấy giao dịch');
    final atts = await _attachments(id, req.userId);
    return jsonOk({...clean(t), 'attachments': atts});
  }

  // ------------------------------------------------------------------ thêm
  Future<Response> _create(Request req) async {
    final f = Fields(await readJson(req));
    final key = f.uuid('idempotency_key', label: 'Mã chống gửi trùng');
    final type = f.oneOf('type', ['income', 'expense'], label: 'Loại giao dịch');
    final amount = f.integer('amount', min: 1, label: 'Số tiền');
    final walletId = f.uuid('wallet_id', label: 'Ví');
    final categoryId = f.uuid('category_id', label: 'Danh mục');
    final occurred = f.has('occurred_at') ? _checkDate(f.dateTime('occurred_at', label: 'Thời gian')) : DateTime.now().toUtc();
    final note = f.optStr('note', max: 200, label: 'Ghi chú');
    final source = f.has('source') ? f.oneOf('source', ['manual', 'ai'], label: 'Nguồn') : 'manual';

    final result = await c.db.tx((s) async {
      final wallet = await _wallet(s, req.userId, walletId, requireActive: true);
      await _category(s, req.userId, categoryId, type);
      final ins = await s.row(
          'INSERT INTO transactions (user_id, wallet_id, category_id, type, amount, occurred_at, note, source, idempotency_key) '
          'VALUES (@u, @w, @c, @t, @a, @o, @n, @s, @k) '
          'ON CONFLICT (user_id, idempotency_key) DO NOTHING RETURNING id',
          {'u': req.userId, 'w': walletId, 'c': categoryId, 't': type, 'a': amount, 'o': occurred, 'n': note, 's': source, 'k': key});
      if (ins == null) {
        // Bấm hai lần hoặc mạng chập chờn gửi lại: trả về giao dịch đã tạo, không tạo thêm.
        final old = await s.row('SELECT id FROM transactions WHERE user_id = @u AND idempotency_key = @k',
            {'u': req.userId, 'k': key});
        return {'id': old!['id'], 'duplicate': true, 'warnings': <String>[]};
      }
      final id = ins['id'] as String;
      await s.run('UPDATE wallets SET balance = balance + @d WHERE id = @w',
          {'d': _effect(type, amount), 'w': walletId});
      await audit(s, req.userId, 'transaction', id, 'create');
      final warnings = <String>[
        if (type == 'expense' && amount > (wallet['balance'] as int)) 'over_balance',
      ];
      return {'id': id, 'duplicate': false, 'warnings': warnings};
    });
    if (result['duplicate'] != true && type == 'expense') {
      await c.alerts.afterExpenseChange(req.userId, categoryId: categoryId, newTransactionId: result['id'] as String);
    }
    final t = await c.db.one('$_select WHERE t.id = @id', {'id': result['id']});
    return jsonOk({...clean(t!), 'warnings': result['warnings'], 'duplicate': result['duplicate']},
        status: result['duplicate'] == true ? 200 : 201);
  }

  // ------------------------------------------------------------------ sửa
  Future<Response> _update(Request req, String id) async {
    requireUuid(id);
    final f = Fields(await readJson(req));
    final res = await c.db.tx((s) async {
      final old = await s.row(
          'SELECT * FROM transactions WHERE id = @id AND user_id = @u AND deleted_at IS NULL FOR UPDATE',
          {'id': id, 'u': req.userId});
      if (old == null) throw ApiError.notFound('Không tìm thấy giao dịch');
      if (old['source'] == 'system') {
        throw ApiError.badRequest('Giao dịch hệ thống không sửa được, hãy dùng điều chỉnh số dư');
      }
      final type = f.has('type') ? f.oneOf('type', ['income', 'expense'], label: 'Loại giao dịch') : old['type'] as String;
      final amount = f.has('amount') ? f.integer('amount', min: 1, label: 'Số tiền') : old['amount'] as int;
      final walletId = f.has('wallet_id') ? f.uuid('wallet_id', label: 'Ví') : old['wallet_id'] as String;
      final categoryId = f.has('category_id') ? f.uuid('category_id', label: 'Danh mục') : old['category_id'] as String;
      final occurred = f.has('occurred_at')
          ? _checkDate(f.dateTime('occurred_at', label: 'Thời gian'))
          : old['occurred_at'] as DateTime;
      final note = f.has('note') ? f.optStr('note', max: 200, label: 'Ghi chú') : old['note'] as String?;

      final changed = <String>[
        if (type != old['type']) 'type',
        if (amount != old['amount']) 'amount',
        if (walletId != old['wallet_id']) 'wallet_id',
        if (categoryId != old['category_id']) 'category_id',
        if (!occurred.isAtSameMomentAs(old['occurred_at'] as DateTime)) 'occurred_at',
        if (note != old['note']) 'note',
      ];
      if (changed.isEmpty) return {'changed': false, 'type': type, 'category_id': categoryId};

      // Khóa ví theo thứ tự cố định để tránh deadlock.
      final ws = {old['wallet_id'] as String, walletId}.toList()..sort();
      for (final w in ws) {
        await _wallet(s, req.userId, w, requireActive: w == walletId && w != old['wallet_id']);
      }
      await _category(s, req.userId, categoryId, type);
      // Hoàn tác ảnh hưởng của giao dịch cũ rồi áp dụng giao dịch mới.
      await s.run('UPDATE wallets SET balance = balance - @d WHERE id = @w',
          {'d': _effect(old['type'] as String, old['amount'] as int), 'w': old['wallet_id']});
      await s.run('UPDATE wallets SET balance = balance + @d WHERE id = @w', {'d': _effect(type, amount), 'w': walletId});
      await s.run(
          'UPDATE transactions SET type = @t, amount = @a, wallet_id = @w, category_id = @c, occurred_at = @o, note = @n '
          'WHERE id = @id AND user_id = @u',
          {'t': type, 'a': amount, 'w': walletId, 'c': categoryId, 'o': occurred, 'n': note, 'id': id, 'u': req.userId});
      await audit(s, req.userId, 'transaction', id, 'update', changed);
      return {'changed': true, 'type': type, 'category_id': categoryId};
    });
    if (res['changed'] == true && res['type'] == 'expense') {
      await c.alerts.afterExpenseChange(req.userId, categoryId: res['category_id'] as String);
    }
    return _get(req, id);
  }

  // ------------------------------------------------------------------ xóa / hoàn tác
  Future<Response> _delete(Request req, String id) async {
    requireUuid(id);
    await c.db.tx((s) => _softDelete(s, req.userId, id));
    return jsonOk({'id': id, 'deleted': true});
  }

  Future<Response> _bulkDelete(Request req) async {
    final f = Fields(await readJson(req));
    final ids = f.uuidList('ids', max: 100);
    if (ids.isEmpty) throw ApiError.badRequest('Chưa chọn giao dịch');
    await c.db.tx((s) async {
      for (final id in ids) {
        await _softDelete(s, req.userId, id);
      }
    });
    return jsonOk({'deleted': ids.length});
  }

  Future<void> _softDelete(Session s, String userId, String id) async {
    final t = await s.row(
        'UPDATE transactions SET deleted_at = now() WHERE id = @id AND user_id = @u AND deleted_at IS NULL '
        'RETURNING type, amount, wallet_id',
        {'id': id, 'u': userId});
    if (t == null) throw ApiError.notFound('Không tìm thấy giao dịch');
    await s.run('UPDATE wallets SET balance = balance - @d WHERE id = @w',
        {'d': _effect(t['type'] as String, t['amount'] as int), 'w': t['wallet_id']});
    // Ảnh vẫn được giữ để hoàn tác.
    await audit(s, userId, 'transaction', id, 'delete');
  }

  Future<Response> _restore(Request req, String id) async {
    requireUuid(id);
    final t = await c.db.tx((s) async {
      final t = await s.row(
          'UPDATE transactions SET deleted_at = NULL WHERE id = @id AND user_id = @u AND deleted_at IS NOT NULL '
          'RETURNING type, amount, wallet_id, category_id',
          {'id': id, 'u': req.userId});
      if (t == null) throw ApiError.notFound('Không tìm thấy giao dịch đã xóa');
      await s.run('UPDATE wallets SET balance = balance + @d WHERE id = @w',
          {'d': _effect(t['type'] as String, t['amount'] as int), 'w': t['wallet_id']});
      await audit(s, req.userId, 'transaction', id, 'restore');
      return t;
    });
    if (t['type'] == 'expense') {
      await c.alerts.afterExpenseChange(req.userId, categoryId: t['category_id'] as String);
    }
    return _get(req, id);
  }

  // ------------------------------------------------------------------ ảnh
  Future<List<Map<String, dynamic>>> _attachments(String txId, String userId) async {
    final rows = await c.db.q(
        'SELECT id, mime_type, size_bytes, width, height, created_at FROM transaction_attachments '
        'WHERE transaction_id = @t AND user_id = @u ORDER BY created_at',
        {'t': txId, 'u': userId});
    return rows.map(clean).toList();
  }

  Future<Response> _listAttachments(Request req, String id) async {
    requireUuid(id);
    final t = await c.db.one('SELECT 1 FROM transactions WHERE id = @id AND user_id = @u', {'id': id, 'u': req.userId});
    if (t == null) throw ApiError.notFound('Không tìm thấy giao dịch');
    return jsonOk({'items': await _attachments(id, req.userId)});
  }

  Future<Response> _upload(Request req, String id) async {
    requireUuid(id);
    // Kiểm tra quyền sở hữu và số ảnh trước khi nhận tệp.
    final t = await c.db.one(
        'SELECT (SELECT count(*) FROM transaction_attachments a WHERE a.transaction_id = t.id)::int AS n '
        'FROM transactions t WHERE t.id = @id AND t.user_id = @u AND t.deleted_at IS NULL',
        {'id': id, 'u': req.userId});
    if (t == null) throw ApiError.notFound('Không tìm thấy giao dịch');
    if ((t['n'] as int) >= 3) throw ApiError.conflict('Mỗi giao dịch chỉ được đính kèm tối đa 3 ảnh', 'attachment_limit');

    final bytes = await _readLimited(req, StorageService.maxBytes);
    final stored = await c.storage.save(bytes);
    try {
      final row = await c.db.tx((s) async {
        final r = await s.row(
            'INSERT INTO transaction_attachments (user_id, transaction_id, storage_key, mime_type, size_bytes, width, height) '
            "VALUES (@u, @t, @k, 'image/jpeg', @sz, @w, @h) RETURNING id, mime_type, size_bytes, width, height, created_at",
            {'u': req.userId, 't': id, 'k': stored.key, 'sz': stored.size, 'w': stored.width, 'h': stored.height});
        await audit(s, req.userId, 'attachment', r!['id'] as String, 'create');
        return r;
      });
      return jsonOk(clean(row), status: 201);
    } catch (e) {
      await c.storage.delete(stored.key);
      if (e is ServerException && e.code == 'P0001') {
        throw ApiError.conflict('Mỗi giao dịch chỉ được đính kèm tối đa 3 ảnh', 'attachment_limit');
      }
      rethrow;
    }
  }

  Future<Response> _download(Request req, String id) async {
    requireUuid(id);
    final a = await c.db.one(
        'SELECT storage_key, mime_type FROM transaction_attachments WHERE id = @id AND user_id = @u',
        {'id': id, 'u': req.userId});
    if (a == null) throw ApiError.notFound('Không tìm thấy ảnh');
    final bytes = await c.storage.read(a['storage_key'] as String);
    if (bytes == null) throw ApiError.notFound('Không tìm thấy ảnh');
    return Response.ok(bytes, headers: {
      'content-type': a['mime_type'] as String,
      'content-length': '${bytes.length}',
      'cache-control': 'private, max-age=86400',
    });
  }

  Future<Response> _deleteAttachment(Request req, String id) async {
    requireUuid(id);
    final key = await c.db.tx((s) async {
      final a = await s.row(
          'DELETE FROM transaction_attachments a USING transactions t '
          'WHERE a.id = @id AND a.user_id = @u AND t.id = a.transaction_id AND t.deleted_at IS NULL '
          'RETURNING a.storage_key',
          {'id': id, 'u': req.userId});
      if (a == null) throw ApiError.notFound('Không tìm thấy ảnh');
      await audit(s, req.userId, 'attachment', id, 'delete');
      return a['storage_key'] as String;
    });
    await c.storage.delete(key);
    return noContent();
  }

  // ------------------------------------------------------------------ tiện ích
  static int _effect(String type, int amount) => type == 'income' ? amount : -amount;

  static DateTime _checkDate(DateTime d) {
    final now = DateTime.now().toUtc();
    if (d.isAfter(now.add(const Duration(days: 1)))) {
      throw ApiError.badRequest('Không chọn được ngày quá xa trong tương lai');
    }
    if (d.isBefore(now.subtract(const Duration(days: 3650)))) {
      throw ApiError.badRequest('Ngày giao dịch không hợp lệ');
    }
    return d;
  }

  Future<Map<String, dynamic>> _wallet(Session s, String userId, String id, {bool requireActive = false}) async {
    final w = await s.row('SELECT id, balance, is_archived FROM wallets WHERE id = @id AND user_id = @u FOR UPDATE',
        {'id': id, 'u': userId});
    if (w == null) throw ApiError.badRequest('Ví không hợp lệ', 'invalid_wallet');
    if (requireActive && w['is_archived'] == true) {
      throw ApiError.badRequest('Ví đã được lưu trữ, hãy chọn ví khác', 'wallet_archived');
    }
    return w;
  }

  Future<void> _category(Session s, String userId, String id, String type) async {
    final cat = await s.row('SELECT type FROM categories WHERE id = @id AND user_id = @u', {'id': id, 'u': userId});
    if (cat == null) throw ApiError.badRequest('Danh mục không hợp lệ', 'invalid_category');
    if (cat['type'] != type) throw ApiError.badRequest('Loại giao dịch không khớp loại danh mục', 'category_type_mismatch');
  }

  static Future<Uint8List> _readLimited(Request req, int max) async {
    final len = req.contentLength;
    if (len != null && len > max) throw ApiError(413, 'too_large', 'Ảnh vượt quá 5 MB');
    final b = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      b.add(chunk);
      if (b.length > max) throw ApiError(413, 'too_large', 'Ảnh vượt quá 5 MB');
    }
    return b.takeBytes();
  }
}
