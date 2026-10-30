import 'http.dart';

final _uuidRe = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _ctrlRe = RegExp('[\\u0000-\\u001F\\u007F-\\u009F\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]');
final _spaceRe = RegExp(r'\s+');
final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Giới hạn số tiền một giao dịch: 10 tỷ đồng (khớp CHECK trong CSDL).
const maxAmount = 10000000000;

bool isUuid(Object? v) => v is String && _uuidRe.hasMatch(v);

/// Làm sạch chuỗi: bỏ ký tự điều khiển và ký tự định hướng ẩn, gộp khoảng trắng.
String sanitize(String s) => s.replaceAll(_ctrlRe, ' ').replaceAll(_spaceRe, ' ').trim();

/// Bộ đọc trường từ body JSON, ném ApiError 400 khi sai.
class Fields {
  final Map<String, dynamic> body;
  Fields(this.body);

  bool has(String k) => body.containsKey(k);

  String str(String k, {int min = 1, required int max, String? label, bool noAngle = false}) {
    final v = body[k];
    if (v is! String) throw ApiError.badRequest('${label ?? k} không hợp lệ');
    final s = sanitize(v);
    if (s.length < min || s.length > max) {
      throw ApiError.badRequest('${label ?? k} phải từ $min đến $max ký tự');
    }
    if (noAngle && (s.contains('<') || s.contains('>'))) {
      throw ApiError.badRequest('${label ?? k} chứa ký tự không cho phép');
    }
    return s;
  }

  String? optStr(String k, {required int max, String? label}) {
    final v = body[k];
    if (v == null) return null;
    if (v is! String) throw ApiError.badRequest('${label ?? k} không hợp lệ');
    final s = sanitize(v);
    if (s.length > max) throw ApiError.badRequest('${label ?? k} tối đa $max ký tự');
    return s.isEmpty ? null : s;
  }

  String uuid(String k, {String? label}) {
    final v = body[k];
    if (!isUuid(v)) throw ApiError.badRequest('${label ?? k} không hợp lệ');
    return (v as String).toLowerCase();
  }

  String? optUuid(String k) => body[k] == null ? null : uuid(k);

  int integer(String k, {int min = 0, int max = maxAmount, String? label}) {
    final v = body[k];
    final n = v is int ? v : (v is double && v == v.roundToDouble() ? v.toInt() : null);
    if (n == null || n < min || n > max) {
      throw ApiError.badRequest('${label ?? k} không hợp lệ');
    }
    return n;
  }

  bool boolean(String k) {
    final v = body[k];
    if (v is! bool) throw ApiError.badRequest('$k không hợp lệ');
    return v;
  }

  String oneOf(String k, List<String> allowed, {String? label}) {
    final v = body[k];
    if (v is! String || !allowed.contains(v)) {
      throw ApiError.badRequest('${label ?? k} không hợp lệ');
    }
    return v;
  }

  DateTime dateTime(String k, {String? label}) {
    final v = body[k];
    final d = v is String ? DateTime.tryParse(v) : null;
    if (d == null) throw ApiError.badRequest('${label ?? k} không hợp lệ');
    return d.toUtc();
  }

  List<String> uuidList(String k, {int max = 50}) {
    final v = body[k];
    if (v is! List || v.length > max || !v.every(isUuid)) {
      throw ApiError.badRequest('$k không hợp lệ');
    }
    return v.map((e) => (e as String).toLowerCase()).toSet().toList();
  }
}

String? qUuid(Map<String, String> q, String k) {
  final v = q[k];
  if (v == null || v.isEmpty) return null;
  if (!isUuid(v)) throw ApiError.badRequest('$k không hợp lệ');
  return v.toLowerCase();
}

DateTime? qDate(Map<String, String> q, String k) {
  final v = q[k];
  if (v == null || v.isEmpty) return null;
  final d = DateTime.tryParse(v);
  if (d == null) throw ApiError.badRequest('$k không hợp lệ');
  return d.toUtc();
}

void requireUuid(String v) {
  if (!isUuid(v)) throw ApiError.notFound();
}
