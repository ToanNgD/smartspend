import 'dart:io';

import 'package:dotenv/dotenv.dart';

/// Cấu hình đọc từ biến môi trường hoặc file .env.
/// Chạy trên máy: dùng file .env. Chạy trên cloud (Render): khai báo biến môi trường trên trang quản trị.
class Config {
  final int port;
  final String dbHost;
  final int dbPort;
  final String dbName;
  final String dbUser;
  final String dbPassword;
  final bool dbSsl;
  final String jwtSecret;
  final Duration accessTtl;
  final Duration refreshTtl;
  final String storageDriver; // local | supabase
  final String uploadDir;
  final String supabaseUrl;
  final String supabaseKey;
  final String supabaseBucket;
  final String geminiApiKey;
  final String geminiModel;
  final int aiParsePerDay;
  final int aiAnalyzePerDay;
  final int aiPhrasePerDay;
  final String fcmServiceAccount;
  final bool enableScheduler;
  final int registerPerHour;
  final int requestsPerMinute;
  final bool trustProxy;

  Config({
    required this.port,
    required this.dbHost,
    required this.dbPort,
    required this.dbName,
    required this.dbUser,
    required this.dbPassword,
    required this.dbSsl,
    required this.jwtSecret,
    required this.accessTtl,
    required this.refreshTtl,
    required this.storageDriver,
    required this.uploadDir,
    required this.supabaseUrl,
    required this.supabaseKey,
    required this.supabaseBucket,
    required this.geminiApiKey,
    required this.geminiModel,
    required this.aiParsePerDay,
    required this.aiAnalyzePerDay,
    required this.aiPhrasePerDay,
    required this.fcmServiceAccount,
    required this.enableScheduler,
    required this.registerPerHour,
    required this.requestsPerMinute,
    required this.trustProxy,
  });

  bool get aiEnabled => geminiApiKey.isNotEmpty;
  bool get pushEnabled => fcmServiceAccount.isNotEmpty;


  factory Config.load({Map<String, String>? overrides}) {
    final env = DotEnv(includePlatformEnvironment: true, quiet: true);
    if (File('.env').existsSync()) env.load(['.env']);
    String get(String k, [String def = '']) {
      final v = overrides?[k] ?? env[k];
      return (v == null || v.isEmpty) ? def : v;
    }

    int getInt(String k, int def) => int.tryParse(get(k)) ?? def;
    bool getBool(String k, bool def) {
      final v = get(k).toLowerCase();
      return v.isEmpty ? def : (v == 'true' || v == '1' || v == 'yes');
    }

    final secret = get('JWT_SECRET');
    if (secret.length < 32) {
      throw StateError('JWT_SECRET phải có ít nhất 32 ký tự (xem .env.example).');
    }

    // DATABASE_URL (dạng postgresql://user:pass@host:port/db) được ưu tiên nếu có - Supabase cung cấp sẵn chuỗi này.
    var host = get('DB_HOST', '127.0.0.1');
    var port = getInt('DB_PORT', 5432);
    var name = get('DB_NAME', 'smartspend');
    var user = get('DB_USER', 'postgres');
    var pass = get('DB_PASSWORD');
    var ssl = getBool('DB_SSL', false);
    final url = get('DATABASE_URL');
    if (url.isNotEmpty) {
      final u = Uri.parse(url);
      host = u.host;
      port = u.hasPort ? u.port : 5432;
      name = u.pathSegments.isNotEmpty && u.pathSegments.first.isNotEmpty ? u.pathSegments.first : 'postgres';
      final info = u.userInfo.split(':');
      user = Uri.decodeComponent(info.first);
      if (info.length > 1) pass = Uri.decodeComponent(info.sublist(1).join(':'));
      final mode = u.queryParameters['sslmode'];
      ssl = mode == null ? getBool('DB_SSL', true) : mode != 'disable';
    }

    final access = getInt('ACCESS_TOKEN_MINUTES', 20).clamp(15, 30);
    final driver = get('STORAGE_DRIVER', 'local');
    if (driver != 'local' && driver != 'supabase') {
      throw StateError('STORAGE_DRIVER chỉ nhận local hoặc supabase.');
    }
    if (driver == 'supabase' && (get('SUPABASE_URL').isEmpty || get('SUPABASE_SERVICE_KEY').isEmpty)) {
      throw StateError('STORAGE_DRIVER=supabase cần SUPABASE_URL và SUPABASE_SERVICE_KEY.');
    }
    return Config(
      port: getInt('PORT', 8080),
      dbHost: host,
      dbPort: port,
      dbName: name,
      dbUser: user,
      dbPassword: pass,
      dbSsl: ssl,
      jwtSecret: secret,
      accessTtl: Duration(minutes: access),
      refreshTtl: Duration(days: getInt('REFRESH_TOKEN_DAYS', 30)),
      storageDriver: driver,
      uploadDir: get('UPLOAD_DIR', './storage/attachments'),
      supabaseUrl: _origin(get('SUPABASE_URL')),
      supabaseKey: get('SUPABASE_SERVICE_KEY'),
      supabaseBucket: get('SUPABASE_BUCKET', 'attachments'),
      geminiApiKey: get('GEMINI_API_KEY'),
      geminiModel: get('GEMINI_MODEL', 'gemini-3.6-flash'),
      aiParsePerDay: getInt('AI_PARSE_PER_DAY', 50),
      aiAnalyzePerDay: getInt('AI_ANALYZE_PER_DAY', 3),
      aiPhrasePerDay: getInt('AI_PHRASE_PER_DAY', 10),
      // FCM_SERVICE_ACCOUNT_JSON: dán nguyên nội dung file JSON (tiện trên Render); FCM_SERVICE_ACCOUNT: đường dẫn file.
      fcmServiceAccount: get('FCM_SERVICE_ACCOUNT_JSON').trim().startsWith('{')
          ? get('FCM_SERVICE_ACCOUNT_JSON').trim()
          : get('FCM_SERVICE_ACCOUNT'),
      enableScheduler: getBool('ENABLE_SCHEDULER', true),
      registerPerHour: getInt('REGISTER_PER_IP_PER_HOUR', 5),
      requestsPerMinute: getInt('REQUESTS_PER_MINUTE', 120),
      trustProxy: getBool('TRUST_PROXY', false),
    );
  }
}

/// Chỉ giữ phần gốc của địa chỉ (https://xxxx.supabase.co), phòng khi dán thừa /rest/v1 hoặc dấu / ở cuối.
String _origin(String url) {
  if (url.isEmpty) return url;
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme || u.host.isEmpty) return url.trim();
  return u.hasPort ? '${u.scheme}://${u.host}:${u.port}' : '${u.scheme}://${u.host}';
}
