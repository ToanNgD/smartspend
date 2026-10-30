// Chạy ngay các tác vụ định kỳ (dự báo vượt ngân sách, phân tích hàng tuần) - tiện khi demo.
// dart run tool/run_jobs.dart
import 'package:smartspend_server/src/app.dart';
import 'package:smartspend_server/src/core/config.dart';

Future<void> main() async {
  final c = buildContext(Config.load());
  await c.alerts.runScheduledForecasts();
  await c.ai.runWeeklyInsights();
  await c.db.close();
  print('Đã chạy xong tác vụ định kỳ.');
}
