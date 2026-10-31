import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'api_client.dart';

/// Thông báo đẩy qua Firebase Cloud Messaging (chỉ để nhận cảnh báo từ server).
/// Thông báo chỉ mang mã định danh (alert_id, budget_id); nội dung chi tiết lấy qua API sau khi mở khóa.
class PushService {
  final ApiClient api;
  PushService(this.api);

  bool _ready = false;
  String? token;
  StreamSubscription? _refreshSub, _openSub, _fgSub;

  /// Gọi khi người dùng bấm vào thông báo (app đang ở nền hoặc đã tắt).
  void Function(Map<String, dynamic> data)? onOpen;
  /// Gọi khi có thông báo lúc app đang mở.
  void Function(String title, String body, Map<String, dynamic> data)? onForeground;

  Future<bool> _init() async {
    if (_ready) return true;
    if (kIsWeb) return false;
    try {
      final opts = DefaultFirebaseOptions.currentPlatform;
      // Chưa cấu hình Firebase cho nền tảng này (chưa chạy tool/firebase_setup.dart, hoặc iPhone) -> bỏ qua.
      if (opts == null) return false;
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: opts);
      _ready = true;
    } catch (_) {
      _ready = false; // chưa cấu hình Firebase -> bỏ qua thông báo đẩy
    }
    return _ready;
  }

  /// Đăng ký thiết bị với server sau khi đăng nhập và mở khóa.
  Future<void> register() async {
    if (!await _init()) return;
    try {
      final m = FirebaseMessaging.instance;
      final perm = await m.requestPermission();
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      // getToken/onTokenRefresh vẫn chạy trên mọi phiên bản firebase_messaging nhóm có thể cài.
      // ignore: deprecated_member_use
      token = await m.getToken();
      if (token != null) await _send(token!);
      // ignore: deprecated_member_use
      _refreshSub ??= m.onTokenRefresh.listen((t) {
        token = t;
        _send(t);
      });
      _openSub ??= FirebaseMessaging.onMessageOpenedApp.listen((msg) => onOpen?.call(msg.data));
      _fgSub ??= FirebaseMessaging.onMessage.listen((msg) {
        final n = msg.notification;
        if (n != null) onForeground?.call(n.title ?? '', n.body ?? '', msg.data);
      });
      final initial = await m.getInitialMessage();
      if (initial != null) onOpen?.call(initial.data);
    } catch (_) {}
  }

  Future<void> _send(String t) async {
    try {
      await api.post('/devices', {
        'push_token': t,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    } catch (_) {}
  }

  /// Đăng xuất: hủy mã thiết bị để không nhận thông báo của tài khoản cũ.
  Future<void> unregister() async {
    if (!_ready) return;
    try {
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    token = null;
  }
}
