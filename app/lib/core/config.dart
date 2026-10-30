/// Địa chỉ API của server SmartSpend.
/// - Mặc định: server trên cloud (Render) - app build ra dùng được ở mọi mạng.
/// - Muốn chạy với server trên máy tính (khi phát triển):
///   flutter run --dart-define=API_URL=http://10.0.2.2:8080/api/v1        (máy ảo Android)
///   flutter run --dart-define=API_URL=http://192.168.x.x:8080/api/v1     (điện thoại thật, cùng Wi-Fi)
class AppConfig {
  static const cloudApiUrl = 'https://smartspend-api-9oce.onrender.com/api/v1';
  static const _fromEnv = String.fromEnvironment('API_URL');

  static String get apiUrl => _fromEnv.isNotEmpty ? _fromEnv : cloudApiUrl;

  /// Quay lại app sau hơn 60 giây ở nền thì yêu cầu xác thực lại (2.1).
  static const lockAfter = Duration(seconds: 60);
  static const maxPinAttempts = 5;
}
