package vn.smartspend.smartspend

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity: bắt buộc cho local_auth (BiometricPrompt).
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Che nội dung app trong màn hình đa nhiệm và chặn chụp màn hình (dữ liệu tài chính nhạy cảm).
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        // Kênh thông báo cho cảnh báo ngân sách / bất thường (Android 8+), trùng id server gửi kèm.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "smartspend_alerts", "Cảnh báo chi tiêu", NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "Cảnh báo vượt ngân sách, dự báo và khoản chi bất thường" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
