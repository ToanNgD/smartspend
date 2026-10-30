import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

/// Kho ảnh riêng tư trên đĩa server. Tên tệp ngẫu nhiên, không có đường dẫn công khai.
/// Ảnh được giải mã và mã hóa lại thành JPEG: xóa sạch EXIF/GPS và mọi dữ liệu lạ chèn trong tệp.
class StorageService {
  final Directory root;
  StorageService(String dir) : root = Directory(dir) {
    root.createSync(recursive: true);
  }

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
    final file = _file(key);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(jpg, flush: true);
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

  File _file(String key) {
    if (!RegExp(r'^[0-9a-f]{32}\.jpg$').hasMatch(key)) {
      throw ArgumentError('storage key không hợp lệ');
    }
    return File('${root.path}/${key.substring(0, 2)}/$key');
  }

  Future<Uint8List?> read(String key) async {
    final f = _file(key);
    return await f.exists() ? f.readAsBytes() : null;
  }

  Future<void> delete(String key) async {
    final f = _file(key);
    if (await f.exists()) await f.delete();
  }
}
