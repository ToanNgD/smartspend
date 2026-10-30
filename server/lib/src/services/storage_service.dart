import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../core/http.dart';
import '../core/security.dart';

class StoredImage {
  final String key;
  final int size;
  final int width;
  final int height;
  StoredImage(this.key, this.size, this.width, this.height);
}

/// Kho ảnh riêng tư. Tên tệp ngẫu nhiên, không có đường dẫn công khai; ảnh chỉ tải được qua API có kiểm tra token.
/// Ảnh được giải mã và mã hóa lại thành JPEG: xóa sạch EXIF/GPS và mọi dữ liệu lạ chèn trong tệp.
/// Hai cách lưu: thư mục trên server (LocalStorage) hoặc Supabase Storage bucket riêng tư (SupabaseStorage, dùng khi chạy trên cloud).
abstract class StorageService {
  static const maxBytes = 5 * 1024 * 1024;
  static const maxEdge = 1600;

  /// Xác định loại tệp bằng chữ ký đầu tệp (magic bytes), không tin đuôi tệp hay header.
  static String? sniffMime(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return 'image/png';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  Future<StoredImage> save(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw ApiError(413, 'too_large', 'Ảnh vượt quá 5 MB');
    }
    if (sniffMime(bytes) == null) {
      throw ApiError(415, 'unsupported_type', 'Chỉ nhận ảnh JPEG, PNG hoặc WebP');
    }
    final out = await Isolate.run(() => _process(bytes));
    if (out == null) {
      throw ApiError(415, 'unsupported_type', 'Tệp ảnh bị hỏng hoặc không đọc được');
    }
    final (jpg, w, h) = out;
    if (jpg.length > maxBytes) throw ApiError(413, 'too_large', 'Ảnh vượt quá 5 MB');
    final key = '${randomHex(16)}.jpg';
    await put(key, jpg);
    return StoredImage(key, jpg.length, w, h);
  }

  static (Uint8List, int, int)? _process(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null) return null;
      final info = decoder.startDecode(bytes);
      // Chống "bom giải nén": từ chối ảnh có kích thước điểm ảnh quá lớn.
      if (info == null || info.width <= 0 || info.height <= 0 ||
          info.width * info.height > 40000000) {
        return null;
      }
      var image = decoder.decode(bytes, frame: 0);
      if (image == null) return null;
      image = img.bakeOrientation(image);
      final longEdge = image.width > image.height ? image.width : image.height;
      if (longEdge > maxEdge) {
        image = image.width >= image.height
            ? img.copyResize(image, width: maxEdge, interpolation: img.Interpolation.average)
            : img.copyResize(image, height: maxEdge, interpolation: img.Interpolation.average);
      }
      image.exif = img.ExifData();
      final jpg = img.encodeJpg(image, quality: 85);
      return (jpg, image.width, image.height);
    } catch (_) {
      return null;
    }
  }

  static void checkKey(String key) {
    if (!RegExp(r'^[0-9a-f]{32}\.jpg$').hasMatch(key)) {
      throw ArgumentError('storage key không hợp lệ');
    }
  }

  /// Đường dẫn trong kho: chia thư mục con theo 2 ký tự đầu để không dồn quá nhiều tệp một chỗ.
  static String pathOf(String key) {
    checkKey(key);
    return '${key.substring(0, 2)}/$key';
  }

  Future<void> put(String key, Uint8List bytes);
  Future<Uint8List?> read(String key);
  Future<void> delete(String key);
}

/// Lưu trong thư mục trên máy chạy server (khi chạy trên máy cá nhân).
class LocalStorage extends StorageService {
  final Directory root;
  LocalStorage(String dir) : root = Directory(dir) {
    root.createSync(recursive: true);
  }

  File _file(String key) => File('${root.path}/${StorageService.pathOf(key)}');

  @override
  Future<void> put(String key, Uint8List bytes) async {
    final f = _file(key);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> read(String key) async {
    final f = _file(key);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}

/// Lưu trong Supabase Storage (bucket để chế độ Private). Khóa dịch vụ chỉ nằm trên server.
class SupabaseStorage extends StorageService {
  final String baseUrl;
  final String key;
  final String bucket;
  final http.Client _http;
  SupabaseStorage(this.baseUrl, this.key, this.bucket, [http.Client? client]) : _http = client ?? http.Client();

  Map<String, String> get _auth => {
        'apikey': key,
        // Khóa kiểu cũ (JWT service_role) gửi kèm Authorization; khóa mới (sb_secret_...) chỉ cần apikey.
        if (key.startsWith('eyJ')) 'authorization': 'Bearer $key',
      };

  Uri _obj(String k) => Uri.parse('$baseUrl/storage/v1/object/$bucket/${StorageService.pathOf(k)}');

  @override
  Future<void> put(String k, Uint8List bytes) async {
    final res = await _http
        .post(_obj(k), headers: {..._auth, 'content-type': 'image/jpeg', 'x-upsert': 'false'}, body: bytes)
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200 && res.statusCode != 201) {
      stderr.writeln('[storage] Supabase upload lỗi ${res.statusCode}');
      throw ApiError(502, 'storage_error', 'Không lưu được ảnh, vui lòng thử lại');
    }
  }

  @override
  Future<Uint8List?> read(String k) async {
    final res = await _http.get(_obj(k), headers: _auth).timeout(const Duration(seconds: 30));
    if (res.statusCode == 200) return res.bodyBytes;
    if (res.statusCode != 400 && res.statusCode != 404) {
      stderr.writeln('[storage] Supabase download lỗi ${res.statusCode}');
    }
    return null;
  }

  @override
  Future<void> delete(String k) async {
    final res = await _http
        .delete(Uri.parse('$baseUrl/storage/v1/object/$bucket'),
            headers: {..._auth, 'content-type': 'application/json'},
            body: jsonEncode({'prefixes': [StorageService.pathOf(k)]}))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) stderr.writeln('[storage] Supabase delete lỗi ${res.statusCode}');
  }
}
