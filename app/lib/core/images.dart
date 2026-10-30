import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Chuẩn bị ảnh trước khi tải lên (UC06.1): xoay đúng chiều, cắt theo khung (nếu có),
/// cạnh dài tối đa 1600 px, mã hóa lại JPEG -> mọi thông tin EXIF (gồm vị trí GPS) bị loại bỏ.
/// Chạy trong isolate riêng để không giật giao diện. Server vẫn kiểm tra và mã hóa lại.
Future<Uint8List?> prepareImage(Uint8List raw, {double? aspect}) =>
    compute(_process, _Job(raw, aspect));

class _Job {
  final Uint8List bytes;
  final double? aspect; // rộng / cao, vd 1.0 (vuông) hoặc 0.75 (dọc 3:4)
  _Job(this.bytes, this.aspect);
}

Uint8List? _process(_Job job) {
  try {
    var image = img.decodeImage(job.bytes);
    if (image == null) return null;
    image = img.bakeOrientation(image);
    final a = job.aspect;
    if (a != null) {
      final cur = image.width / image.height;
      if (cur > a) {
        final w = (image.height * a).round();
        image = img.copyCrop(image, x: (image.width - w) ~/ 2, y: 0, width: w, height: image.height);
      } else if (cur < a) {
        final h = (image.width / a).round();
        image = img.copyCrop(image, x: 0, y: (image.height - h) ~/ 2, width: image.width, height: h);
      }
    }
    const edge = 1600;
    if (image.width > edge || image.height > edge) {
      image = image.width >= image.height ? img.copyResize(image, width: edge) : img.copyResize(image, height: edge);
    }
    image.exif = img.ExifData();
    return img.encodeJpg(image, quality: 85);
  } catch (_) {
    return null;
  }
}

const maxImagesPerTx = 3;
const maxImageBytes = 5 * 1024 * 1024;
