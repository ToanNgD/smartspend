import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token lưu trong Keychain (iOS) / Keystore (Android), không lưu ở SharedPreferences hay file thường.
/// Access token chỉ giữ trong bộ nhớ.
class TokenStore {
  static const storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _refreshKey = 'refresh_token';

  String? accessToken;

  Future<String?> readRefresh() => storage.read(key: _refreshKey);

  Future<void> save(String access, String refresh) async {
    accessToken = access;
    await storage.write(key: _refreshKey, value: refresh);
  }

  Future<void> clear() async {
    accessToken = null;
    await storage.delete(key: _refreshKey);
  }
}
