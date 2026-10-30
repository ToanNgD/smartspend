import 'dart:io';

import 'package:shelf/shelf_io.dart' as io;
import 'package:smartspend_server/src/app.dart';
import 'package:smartspend_server/src/core/config.dart';

Future<void> main() async {
  final config = Config.load();
  final ctx = buildContext(config);
  // Kiểm tra kết nối CSDL ngay khi khởi động.
  await ctx.db.q('SELECT 1');
  final handler = buildHandler(ctx);
  final server = await io.serve(handler, InternetAddress.anyIPv4, config.port);
  server.autoCompress = true;
  if (config.enableScheduler) startScheduler(ctx);
  stdout.writeln('SmartSpend API chạy tại http://${server.address.host}:${server.port}/api/v1');
  stdout.writeln('AI: ${config.aiEnabled ? 'Gemini (${config.geminiModel})' : 'bộ phân tích dự phòng (chưa có GEMINI_API_KEY)'}');
  stdout.writeln('Thông báo đẩy: ${config.pushEnabled ? 'bật' : 'tắt (chưa có FCM_SERVICE_ACCOUNT)'}');

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    await ctx.db.close();
    exit(0);
  });
}
