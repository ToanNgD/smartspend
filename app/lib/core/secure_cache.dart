import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'vault.dart';

/// Bộ nhớ đệm cục bộ được mã hóa (2.1, 4.1, 7.1): dữ liệu báo cáo, danh sách, ảnh chờ tải lên.
/// Mọi nội dung được mã hóa bằng khóa dữ liệu của Vault trước khi ghi xuống đĩa.
class SecureCache {
  final Vault vault;
  SecureCache(this.vault);

  final _mem = <String, Uint8List>{}; // dùng khi chạy trên web
  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    _dir = Directory('${base.path}/secure_cache');
    await _dir!.create(recursive: true);
    return _dir!;
  }

  String _name(String key) => c.sha256.convert(utf8.encode(key)).toString();

  Future<void> putBytes(String key, List<int> data) async {
    if (!vault.isUnlocked) return;
    final enc = Uint8List.fromList(await vault.encrypt(data));
    if (kIsWeb) {
      _mem[key] = enc;
      return;
    }
    final f = File('${(await _root()).path}/${_name(key)}');
    await f.writeAsBytes(enc, flush: true);
  }

  Future<Uint8List?> getBytes(String key) async {
    if (!vault.isUnlocked) return null;
    try {
      Uint8List? enc;
      if (kIsWeb) {
        enc = _mem[key];
      } else {
        final f = File('${(await _root()).path}/${_name(key)}');
        if (await f.exists()) enc = await f.readAsBytes();
      }
      if (enc == null) return null;
      return Uint8List.fromList(await vault.decrypt(enc));
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String key) async {
    if (kIsWeb) {
      _mem.remove(key);
      return;
    }
    final f = File('${(await _root()).path}/${_name(key)}');
    if (await f.exists()) await f.delete();
  }

  Future<void> putJson(String key, Object? value) => putBytes(key, utf8.encode(jsonEncode(value)));

  Future<dynamic> getJson(String key) async {
    final b = await getBytes(key);
    if (b == null) return null;
    try {
      return jsonDecode(utf8.decode(b));
    } catch (_) {
      return null;
    }
  }

  /// Đăng xuất: xóa sạch bộ nhớ đệm.
  Future<void> wipe() async {
    _mem.clear();
    if (kIsWeb) return;
    final d = await _root();
    if (await d.exists()) await d.delete(recursive: true);
    _dir = null;
  }
}
