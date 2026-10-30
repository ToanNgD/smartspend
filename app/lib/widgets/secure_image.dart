import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';

/// Ảnh giao dịch chỉ tải qua API có kiểm tra token (không có đường dẫn công khai).
/// Giữ trong bộ nhớ tạm của phiên, không ghi ra đĩa dạng thô.
class SecureImage extends StatefulWidget {
  final String attachmentId;
  final BoxFit fit;
  const SecureImage(this.attachmentId, {super.key, this.fit = BoxFit.cover});

  static final _mem = <String, Uint8List>{};
  static void clearMemory() => _mem.clear();

  @override
  State<SecureImage> createState() => _SecureImageState();
}

class _SecureImageState extends State<SecureImage> {
  Future<Uint8List>? _f;

  @override
  void initState() {
    super.initState();
    final cached = SecureImage._mem[widget.attachmentId];
    _f = cached != null
        ? Future.value(cached)
        : context.read<ApiClient>().getBytes('/attachments/${widget.attachmentId}').then((b) {
            if (SecureImage._mem.length > 60) SecureImage._mem.clear();
            return SecureImage._mem[widget.attachmentId] = b;
          });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
        future: _f,
        builder: (c, s) {
          if (s.hasData) return Image.memory(s.data!, fit: widget.fit, gaplessPlayback: true);
          if (s.hasError) return const Center(child: Icon(Icons.broken_image_outlined));
          return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
        },
      );
}
