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
    apiKey: 'AIzaSyCmTUtUa5ip24VuhLvibfmiaugzLbeEW1A',
    appId: '1:919727394355:android:7a1512eaaf724722a4dd46',
    messagingSenderId: '919727394355',
    projectId: 'smartspend-6eede',
    storageBucket: 'smartspend-6eede.firebasestorage.app',
  );
}
