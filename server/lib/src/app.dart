import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'app_context.dart';
import 'core/config.dart';
import 'core/db.dart';
import 'core/http.dart';
import 'core/middleware.dart';
import 'core/security.dart';
import 'routes/account_routes.dart';
import 'routes/ai_routes.dart';
import 'routes/alert_routes.dart';
import 'routes/auth_routes.dart';
import 'routes/budget_routes.dart';
import 'routes/category_routes.dart';
import 'routes/report_routes.dart';
import 'routes/transaction_routes.dart';
import 'routes/wallet_routes.dart';
import 'services/ai_service.dart';
import 'services/alert_service.dart';
import 'services/push_service.dart';
import 'services/storage_service.dart';

AppContext buildContext(Config config) {
  final db = Db.connect(config);
  final push = PushService(db, config.fcmServiceAccount);
  return AppContext(
    config: config,
    db: db,
    jwt: JwtService(config),
    push: push,
    alerts: AlertService(db, push),
    ai: AiService(config, db),
    storage: StorageService(config.uploadDir),
  );
}

/// Ghép toàn bộ API dưới tiền tố /api/v1.
Handler buildHandler(AppContext c) {
  final tx = TransactionRoutes(c);
  final collections = <String, Handler>{
    'auth': AuthRoutes(c).router.call,
    'wallets': WalletRoutes(c).router.call,
    'categories': CategoryRoutes(c).router.call,
    'transactions': tx.router.call,
    'attachments': tx.attachmentRouter.call,
    'budgets': BudgetRoutes(c).router.call,
    'alerts': AlertRoutes(c).router.call,
    'reports': ReportRoutes(c).router.call,
    'ai': AiRoutes(c).router.call,
  };
  final api = Router()..get('/health', (Request _) => jsonOk({'status': 'ok'}));
  collections.forEach((name, h) {
    // "/wallets" và "/wallets/..." đều đi vào cùng router con.
    api.all('/$name', (Request r) => h(r.change(path: name)));
    api.mount('/$name/', h);
  });
  api.mount('/', AccountRoutes(c).router.call);

  final root = Router()
    ..mount('/api/v1/', api.call)
    ..all('/<_|.*>', (Request _) => jsonError(ApiError.notFound('Không tìm thấy API')));

  const publicPaths = {
    '/api/v1/health',
    '/api/v1/auth/register',
    '/api/v1/auth/login',
    '/api/v1/auth/refresh',
    '/api/v1/auth/logout',
  };

  return const Pipeline()
      .addMiddleware(accessLog())
      .addMiddleware(securityHeaders())
      .addMiddleware(errorHandler())
      .addMiddleware(clientIp())
      .addMiddleware(auth(c.jwt, publicPaths: publicPaths))
      .addMiddleware(globalRateLimit(c.config.requestsPerMinute))
      .addHandler(root.call);
}

/// Tác vụ định kỳ: mỗi giờ kiểm tra dự báo vượt ngân sách và phân tích hàng tuần.
Timer startScheduler(AppContext c) {
  Future<void> tick() async {
    try {
      await c.alerts.runScheduledForecasts();
      await c.ai.runWeeklyInsights();
    } catch (e) {
      stderr.writeln('[scheduler] lỗi: ${e.runtimeType}');
    }
  }

  Timer(const Duration(seconds: 30), tick);
  return Timer.periodic(const Duration(hours: 1), (_) => tick());
}
