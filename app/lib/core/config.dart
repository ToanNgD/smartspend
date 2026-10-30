import 'package:flutter/foundation.dart';

/// Địa chỉ API. Đổi khi chạy: flutter run --dart-define=API_URL=http://192.168.1.10:8080/api/v1
/// - Máy ảo Android: 10.0.2.2 trỏ về máy tính đang chạy server.
/// - Điện thoại thật: dùng IP LAN của máy tính (cùng mạng Wi-Fi).
/// - Bản phát hành phải dùng https://
class AppConfig {
  static const _fromEnv = String.fromEnvironment('API_URL');

  static String get apiUrl {
    if (_fromEnv.isNotEmpty) return _fromEnv;
    if (kIsWeb) return 'http://localhost:8080/api/v1';
    return defaultTargetPlatform == TargetPlatform.android
        ? 'http://10.0.2.2:8080/api/v1'
        : 'http://localhost:8080/api/v1';
  }

  /// Quay lại app sau hơn 60 giây ở nền thì yêu cầu xác thực lại (2.1).
  static const lockAfter = Duration(seconds: 60);
  static const maxPinAttempts = 5;
}
