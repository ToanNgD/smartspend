import 'package:postgres/postgres.dart';

import '../core/db.dart';

/// Ghi nhật ký thay đổi: chỉ lưu tên trường đã đổi, không lưu giá trị (4.2).
Future<void> audit(Session s, String userId, String entity, String entityId, String action,
    [List<String>? fields]) async {
  await s.run(
      'INSERT INTO audit_logs (user_id, entity, entity_id, action, changed_fields) '
      'VALUES (@u, @e, @id, @a, @f::text[])',
      {'u': userId, 'e': entity, 'id': entityId, 'a': action, 'f': fields});
}
