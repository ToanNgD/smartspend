import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Cấu hình đọc từ biến môi trường hoặc file .env.
class Config {
  final int port;
  final String dbHost;
  final int dbPort;
  final String dbName;
  final String dbUser;
  final String dbPassword;
  final String jwtSecret;
  final Duration accessTtl;
  final Duration refreshTtl;
  final String uploadDir;
  final String geminiApiKey;
  final String geminiModel;
  final int aiParsePerDay;
  final int aiAnalyzePerDay;
  final String fcmServiceAccount;
  final bool enableScheduler;
  final int registerPerHour;
  final int requestsPerMinute;

  Config({
    required this.port,
    required this.dbHost,
    required this.dbPort,
    required this.dbName,
    required this.dbUser,
    required this.dbPassword,
    required this.jwtSecret,
    required this.accessTtl,
    required this.refreshTtl,
    required this.uploadDir,
    required this.geminiApiKey,
    required this.geminiModel,
    required this.aiParsePerDay,
    required this.aiAnalyzePerDay,
    required this.fcmServiceAccount,
    required this.enableScheduler,
    required this.registerPerHour,
    required this.requestsPerMinute,
  });

  bool get aiEnabled => geminiApiKey.isNotEmpty;
  bool get pushEnabled => fcmServiceAccount.isNotEmpty;

  factory Config.load({Map<String, String>? overrides}) {
    final env = DotEnv(includePlatformEnvironment: true, quiet: true);
    if (File('.env').existsSync()) env.load(['.env']);
    String get(String k, [String def = '']) => overrides?[k] ?? env[k] ?? def;
    int getInt(String k, int def) => int.tryParse(get(k)) ?? def;

    final secret = get('JWT_SECRET');
    if (secret.length < 32) {
      throw StateError('JWT_SECRET phải có ít nhất 32 ký tự (xem .env.example).');
    }
    final access = getInt('ACCESS_TOKEN_MINUTES', 20).clamp(15, 30);
    return Config(
      port: getInt('PORT', 8080),
      dbHost: get('DB_HOST', '127.0.0.1'),
      dbPort: getInt('DB_PORT', 5432),
      dbName: get('DB_NAME', 'smartspend'),
      dbUser: get('DB_USER', 'postgres'),
      dbPassword: get('DB_PASSWORD'),
      jwtSecret: secret,
      accessTtl: Duration(minutes: access),
      refreshTtl: Duration(days: getInt('REFRESH_TOKEN_DAYS', 30)),
      uploadDir: get('UPLOAD_DIR', './storage/attachments'),
      geminiApiKey: get('GEMINI_API_KEY'),
      geminiModel: get('GEMINI_MODEL', 'gemini-3.6-flash'),
      aiParsePerDay: getInt('AI_PARSE_PER_DAY', 50),
      aiAnalyzePerDay: getInt('AI_ANALYZE_PER_DAY', 3),
      fcmServiceAccount: get('FCM_SERVICE_ACCOUNT'),
      enableScheduler: get('ENABLE_SCHEDULER', 'true') == 'true',
      registerPerHour: getInt('REGISTER_PER_IP_PER_HOUR', 5),
      requestsPerMinute: getInt('REQUESTS_PER_MINUTE', 120),
    );
  }
}
