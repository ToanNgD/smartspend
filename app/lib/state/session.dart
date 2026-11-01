import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/push.dart';
import '../core/secure_cache.dart';
import '../core/token_store.dart';
import '../core/vault.dart';

enum SessionStatus { loading, loggedOut, setupLock, locked, ready }

/// Trạng thái đăng nhập và khóa ứng dụng (UC01, UC02, UC03).
class Session extends ChangeNotifier with WidgetsBindingObserver {
  final TokenStore tokens;
  final ApiClient api;
  final Vault vault;
  final SecureCache cache;
  final PushService push;

  Session({required this.tokens, required this.api, required this.vault, required this.cache, required this.push}) {
    api.onSessionExpired = () => logout(message: 'Phiên đăng nhập đã hết hạn, vui lòng đăng nhập lại.');
    WidgetsBinding.instance.addObserver(this);
  }

  SessionStatus status = SessionStatus.loading;
  String? message; // thông báo hiển thị ở màn hình đăng nhập
  bool obscured = false; // che nội dung trong màn hình đa nhiệm
  bool rootedWarning = false;
  Map<String, dynamic>? pendingLink; // liên kết từ thông báo, mở sau khi xác thực
  DateTime? _backgroundAt;
  bool _loggingOut = false;

  /// Bấm vào thông báo: ghi nhớ màn hình đích; app mở màn hình đó ngay nếu đang mở khóa, hoặc sau khi xác thực.
  void openLink(Map<String, dynamic> data) {
    pendingLink = data;
    notifyListeners();
  }

  void _set(SessionStatus s) {
    status = s;
    notifyListeners();
  }

  Future<void> init() async {
    rootedWarning = await _looksRooted();
    final rt = await tokens.readRefresh();
    if (rt == null) {
      await vault.wipe(); // dữ liệu sót lại của phiên cũ (vd cài lại app trên iOS)
      return _set(SessionStatus.loggedOut);
    }
    if (await vault.hasLockDisabled()) {
      await vault.unlockWithoutLock();
      return _enterReady();
    }
    _set(await vault.hasPin() ? SessionStatus.locked : SessionStatus.setupLock);
  }

  Future<void> login(String email, String password) async {
    final r = await api.post('/auth/login', {'email': email.trim(), 'password': password, 'device_name': _device()});
    await _afterAuth(r);
  }

  Future<void> register(String name, String email, String password) async {
    final r = await api.post('/auth/register',
        {'full_name': name.trim(), 'email': email.trim(), 'password': password, 'device_name': _device()});
    await _afterAuth(r);
  }

  Future<void> _afterAuth(dynamic r) async {
    await tokens.save(r['access_token'] as String, r['refresh_token'] as String);
    message = null;
    // Sau lần đăng nhập đầu tiên, bắt buộc thiết lập khóa (PIN + sinh trắc học).
    _set(SessionStatus.setupLock);
  }

  Future<void> completeLockSetup(String pin, {required bool biometric}) async {
    await vault.setPin(pin);
    if (biometric) await vault.setBiometric(true);
    await _enterReady();
  }

  /// Trả về null nếu đúng, ngược lại số lần thử còn lại. Hết lượt thì buộc đăng nhập lại.
  Future<int?> unlockWithPin(String pin) async {
    if (await vault.unlockWithPin(pin)) {
      await _enterReady();
      return null;
    }
    final left = AppConfig.maxPinAttempts - await vault.failedAttempts();
    if (left <= 0) {
      await logout(message: 'Bạn đã nhập sai PIN 5 lần. Vui lòng đăng nhập lại bằng mật khẩu.');
      return 0;
    }
    return left;
  }

  Future<bool> unlockWithBiometric() async {
    if (await vault.unlockWithBiometric()) {
      await _enterReady();
      return true;
    }
    return false;
  }

  Future<void> _enterReady() async {
    obscured = false;
    if (tokens.accessToken == null) {
      final ok = await api.refresh();
      if (!ok) {
        // Không có mạng: vẫn vào app với dữ liệu đệm; nếu token bị thu hồi thì đăng xuất.
        final rt = await tokens.readRefresh();
        if (rt == null) return logout(message: 'Phiên đăng nhập đã hết hạn, vui lòng đăng nhập lại.');
      }
    }
    _set(SessionStatus.ready);
    push.register();
  }

  void lockNow() {
    if (status != SessionStatus.ready) return;
    vault.hasPin().then((has) {
      if (!has) return;
      vault.lock();
      _set(SessionStatus.locked);
    });
  }

  void _setObscured(bool v) {
    if (obscured == v) return;
    obscured = v;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // "inactive" cũng xảy ra khi hộp thoại vân tay/Face ID, hộp xin quyền hay thanh thông báo hiện lên.
        // Không che trong các trường hợp đó (trước đây gây lỗi màn hình trắng sau khi quét vân tay).
        // Android đã có FLAG_SECURE che nội dung trong màn hình đa nhiệm nên chỉ cần che ở iOS.
        if (!Vault.authenticating && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) _setObscured(true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgroundAt ??= DateTime.now();
        if (!Vault.authenticating) _setObscured(true);
      case AppLifecycleState.resumed:
        final since = _backgroundAt;
        _backgroundAt = null;
        _setObscured(false);
        if (since != null && DateTime.now().difference(since) > AppConfig.lockAfter) lockNow();
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Đăng xuất: hủy refresh token ở server, xóa token, khóa và toàn bộ dữ liệu cục bộ.
  Future<void> logout({String? message}) async {
    if (_loggingOut) return;
    _loggingOut = true;
    try {
      final rt = await tokens.readRefresh();
      if (rt != null) {
        try {
          await api.post('/auth/logout', {'refresh_token': rt, if (push.token != null) 'push_token': push.token});
        } catch (_) {}
      }
      await push.unregister();
      await tokens.clear();
      await cache.wipe();
      await vault.wipe();
      this.message = message;
      pendingLink = null;
      _set(SessionStatus.loggedOut);
    } finally {
      _loggingOut = false;
    }
  }

  String _device() => kIsWeb ? 'Web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android');

  /// Phát hiện đơn giản máy đã root/jailbreak để cảnh báo người dùng (2.1).
  static Future<bool> _looksRooted() async {
    if (kIsWeb) return false;
    const paths = [
      '/system/app/Superuser.apk', '/sbin/su', '/system/bin/su', '/system/xbin/su', '/data/local/xbin/su',
      '/data/local/bin/su', '/system/sd/xbin/su', '/su/bin/su', '/data/adb/magisk',
      '/Applications/Cydia.app', '/Library/MobileSubstrate/MobileSubstrate.dylib', '/bin/bash', '/usr/sbin/sshd',
      '/etc/apt', '/private/var/lib/apt/',
    ];
    final checks = defaultTargetPlatform == TargetPlatform.iOS ? paths.sublist(9) : paths.sublist(0, 9);
    for (final p in checks) {
      try {
        if (await File(p).exists()) return true;
      } catch (_) {}
    }
    return false;
  }
}
