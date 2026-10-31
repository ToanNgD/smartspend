// Tạo lib/firebase_options.dart từ file android/app/google-services.json (tải ở Firebase Console).
// Chạy trong thư mục app:  dart run tool/firebase_setup.dart
// Không cần cài Firebase CLI hay sửa Gradle.
import 'dart:convert';
import 'dart:io';

void main() {
  final f = File('android/app/google-services.json');
  if (!f.existsSync()) {
    stderr.writeln('Không thấy android/app/google-services.json. Tải file này ở Firebase Console rồi đặt vào đúng chỗ.');
    exit(1);
  }
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final info = j['project_info'] as Map<String, dynamic>;
  final clients = (j['client'] as List).cast<Map<String, dynamic>>();
  final client = clients.firstWhere(
    (c) => c['client_info']['android_client_info']['package_name'] == 'vn.smartspend.smartspend',
    orElse: () {
      stderr.writeln('google-services.json không có app Android "vn.smartspend.smartspend". '
          'Kiểm tra lại package name khi thêm app trong Firebase.');
      exit(1);
    },
  );
  final appId = client['client_info']['mobilesdk_app_id'];
  final apiKey = (client['api_key'] as List).first['current_key'];
  final out = '''
// File sinh tự động bởi tool/firebase_setup.dart từ android/app/google-services.json.
// Các giá trị này là cấu hình công khai của app (không phải khóa bí mật của server).
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class DefaultFirebaseOptions {
  /// Chỉ Android nhận thông báo đẩy. iPhone cần tài khoản Apple Developer trả phí (APNs)
  /// nên trả về null: app vẫn chạy, cảnh báo xem trong màn hình Cảnh báo.
  static FirebaseOptions? get currentPlatform {
    if (kIsWeb) return null;
    if (defaultTargetPlatform == TargetPlatform.android) return android;
    return null;
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: '$apiKey',
    appId: '$appId',
    messagingSenderId: '${info['project_number']}',
    projectId: '${info['project_id']}',
    storageBucket: '${info['storage_bucket'] ?? ''}',
  );
}
''';
  File('lib/firebase_options.dart').writeAsStringSync(out);
  stdout.writeln('Đã tạo lib/firebase_options.dart cho project Firebase "${info['project_id']}".');
}
