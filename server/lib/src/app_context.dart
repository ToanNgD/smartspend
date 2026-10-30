import 'core/config.dart';
import 'core/db.dart';
import 'core/security.dart';
import 'services/ai_service.dart';
import 'services/alert_service.dart';
import 'services/push_service.dart';
import 'services/storage_service.dart';

/// Gom các thành phần dùng chung để truyền cho các nhóm route.
class AppContext {
  final Config config;
  final Db db;
  final JwtService jwt;
  final PushService push;
  final AlertService alerts;
  final AiService ai;
  final StorageService storage;

  AppContext({
    required this.config,
    required this.db,
    required this.jwt,
    required this.push,
    required this.alerts,
    required this.ai,
    required this.storage,
  });
}
