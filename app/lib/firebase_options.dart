// File tạm. Chạy `flutterfire configure` trong thư mục app/ để sinh lại file này
// với cấu hình Firebase thật của nhóm (bật thông báo đẩy). Khi chưa có, app vẫn chạy bình thường,
// chỉ không nhận thông báo đẩy (cảnh báo vẫn xem được trong màn hình Cảnh báo).
import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions? get currentPlatform => null;
}
