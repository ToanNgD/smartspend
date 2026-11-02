package vn.smartspend.smartspend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity: bắt buộc cho local_auth (BiometricPrompt).
class MainActivity : FlutterFragmentActivity() {
    private var notifyChannel: MethodChannel? = null

    // Dữ liệu của thông báo đã bấm để mở app (khi app đã tắt hẳn); Dart lấy một lần sau khi mở khóa.
    private var launchPayload: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Che nội dung app trong màn hình đa nhiệm và chặn chụp màn hình (dữ liệu tài chính nhạy cảm).
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        // Kênh thông báo cho cảnh báo ngân sách / bất thường (Android 8+), trùng id server gửi kèm.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                ALERT_CHANNEL, "Cảnh báo chi tiêu", NotificationManager.IMPORTANCE_HIGH
            ).apply { description = "Cảnh báo vượt ngân sách, dự báo và khoản chi bất thường" }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        // Chỉ lấy khi app được mở mới từ thông báo. Khi hệ thống tắt app ở nền rồi dựng lại activity
        // (savedInstanceState khác null), intent cũ vẫn còn: không được mở lại màn hình của thông báo cũ.
        if (savedInstanceState == null) launchPayload = intent?.getStringExtra(EXTRA_PAYLOAD)
    }

    // Khi app đang mở, Firebase không tự hiện thông báo đẩy trên Android: Dart gọi "show" để hiện
    // thông báo hệ thống giống lúc app ở nền. Bấm vào thông báo thì gửi dữ liệu lại cho Dart ("opened").
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        notifyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFY_CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "show" -> {
                        showAlert(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("payload") ?: ""
                        )
                        result.success(true)
                    }
                    "takeLaunchPayload" -> {
                        result.success(launchPayload)
                        launchPayload = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        // Dart chưa đăng ký nhận (app vừa được dựng lại, chưa mở khóa) thì Flutter giữ tin nhắn này
        // và chuyển cho Dart ngay khi Dart đăng ký, nên không bị mất.
        notifyChannel?.invokeMethod("opened", payload)
    }

    private fun showAlert(title: String, body: String, payload: String) {
        val id = (System.currentTimeMillis() % Int.MAX_VALUE).toInt()
        val open = Intent(this, MainActivity::class.java).apply {
            putExtra(EXTRA_PAYLOAD, payload)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            this, id, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = newBuilder()
            .setSmallIcon(R.mipmap.ic_launcher_monochrome)
            .setColor(getColor(R.color.splash_bg))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        getSystemService(NotificationManager::class.java).notify(id, notification)
    }

    @Suppress("DEPRECATION")
    private fun newBuilder(): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, ALERT_CHANNEL)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }

    companion object {
        private const val ALERT_CHANNEL = "smartspend_alerts"
        private const val NOTIFY_CHANNEL = "vn.smartspend/notify"
        private const val EXTRA_PAYLOAD = "vn.smartspend.notify.payload"
    }
}
