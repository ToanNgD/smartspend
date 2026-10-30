import 'package:postgres/postgres.dart';

import 'config.dart';

/// Kết nối PostgreSQL dùng pool. Mọi truy vấn đều tham số hóa (Sql.named).
class Db {
  final Pool pool;
  Db(this.pool);

  factory Db.connect(Config c) {
    final pool = Pool.withEndpoints(
      [
        Endpoint(
          host: c.dbHost,
          port: c.dbPort,
          database: c.dbName,
          username: c.dbUser,
          password: c.dbPassword,
        ),
      ],
      settings: PoolSettings(
        maxConnectionCount: 10,
        sslMode: c.dbSsl ? SslMode.require : SslMode.disable,
      ),
    );
    return Db(pool);
  }

  /// Trả về danh sách bản ghi dạng Map.
  Future<List<Map<String, dynamic>>> query(Session s, String sql,
      [Map<String, dynamic> params = const {}]) async {
    final r = await s.execute(Sql.named(sql), parameters: usedParams(sql, params));
    return r.map((row) => row.toColumnMap()).toList();
  }

  Future<List<Map<String, dynamic>>> q(String sql,
          [Map<String, dynamic> params = const {}]) =>
      query(pool, sql, params);

  Future<Map<String, dynamic>?> one(String sql,
      [Map<String, dynamic> params = const {}]) async {
    final rows = await q(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> exec(String sql, [Map<String, dynamic> params = const {}]) async {
    final r = await pool.execute(Sql.named(sql), parameters: usedParams(sql, params));
    return r.affectedRows;
  }

  /// Chạy nhiều câu lệnh trong cùng một transaction CSDL.
  Future<T> tx<T>(Future<T> Function(TxSession s) fn) => pool.runTx(fn);

  Future<void> close() => pool.close();
}

/// Tiện ích dùng trong transaction.
extension SessionX on Session {
  Future<List<Map<String, dynamic>>> rows(String sql,
      [Map<String, dynamic> params = const {}]) async {
    final r = await execute(Sql.named(sql), parameters: usedParams(sql, params));
    return r.map((row) => row.toColumnMap()).toList();
  }

  Future<Map<String, dynamic>?> row(String sql,
      [Map<String, dynamic> params = const {}]) async {
    final r = await rows(sql, params);
    return r.isEmpty ? null : r.first;
  }

  Future<int> run(String sql, [Map<String, dynamic> params = const {}]) async {
    final r = await execute(Sql.named(sql), parameters: usedParams(sql, params));
    return r.affectedRows;
  }
}

/// Chỉ giữ các tham số thực sự xuất hiện trong câu SQL (thư viện postgres không nhận tham số thừa).
Map<String, dynamic> usedParams(String sql, Map<String, dynamic> params) {
  if (params.isEmpty) return params;
  return {
    for (final e in params.entries)
      if (RegExp('@${RegExp.escape(e.key)}(?![A-Za-z0-9_])').hasMatch(sql)) e.key: e.value
  };
}
