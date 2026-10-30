import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Lỗi nghiệp vụ trả về cho app với mã HTTP và mã lỗi máy đọc được.
class ApiError implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  ApiError(this.status, this.code, this.message, [this.details]);

  factory ApiError.badRequest(String message, [String code = 'invalid_input']) =>
      ApiError(400, code, message);
  factory ApiError.notFound([String message = 'Không tìm thấy dữ liệu']) =>
      ApiError(404, 'not_found', message);
  factory ApiError.unauthorized([String message = 'Phiên đăng nhập không hợp lệ']) =>
      ApiError(401, 'unauthorized', message);
  factory ApiError.conflict(String message, [String code = 'conflict']) =>
      ApiError(409, code, message);

  Map<String, dynamic> toJson() => {
        'error': {'code': code, 'message': message, if (details != null) 'details': details}
      };
}

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

Response jsonOk(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body, toEncodable: _encode), headers: _jsonHeaders);

Response jsonError(ApiError e) =>
    Response(e.status, body: jsonEncode(e.toJson()), headers: _jsonHeaders);

Response noContent() => Response(204);

Object? _encode(Object? v) {
  if (v is DateTime) return v.toUtc().toIso8601String();
  return v.toString();
}

/// Chuẩn hóa bản ghi CSDL thành JSON (DateTime -> ISO 8601).
Map<String, dynamic> clean(Map<String, dynamic> m) =>
    m.map((k, v) => MapEntry(k, v is DateTime ? v.toUtc().toIso8601String() : v));

const maxJsonBytes = 64 * 1024;

Future<Map<String, dynamic>> readJson(Request req) async {
  final len = req.contentLength;
  if (len != null && len > maxJsonBytes) {
    throw ApiError(413, 'too_large', 'Dữ liệu gửi lên quá lớn');
  }
  final bytes = <int>[];
  await for (final chunk in req.read()) {
    bytes.addAll(chunk);
    if (bytes.length > maxJsonBytes) {
      throw ApiError(413, 'too_large', 'Dữ liệu gửi lên quá lớn');
    }
  }
  if (bytes.isEmpty) return {};
  try {
    final v = jsonDecode(utf8.decode(bytes));
    if (v is Map<String, dynamic>) return v;
  } catch (_) {}
  throw ApiError.badRequest('Dữ liệu JSON không hợp lệ');
}

extension ReqX on Request {
  /// Mã người dùng luôn lấy từ token (do middleware gắn vào), không lấy từ body.
  String get userId => context['userId'] as String;
  String get clientIp => (context['clientIp'] as String?) ?? 'unknown';
}
