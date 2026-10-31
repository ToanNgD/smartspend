import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../core/db.dart';

/// Gửi thông báo đẩy qua Firebase Cloud Messaging (HTTP v1).
/// Nội dung thông báo không bao giờ chứa số tiền hay số dư.
class PushService {
  final Db db;
  final String serviceAccountPath;
  AutoRefreshingAuthClient? _client;
  String? _projectId;
  bool _initFailed = false;

  PushService(this.db, this.serviceAccountPath);

  bool get enabled => serviceAccountPath.isNotEmpty && !_initFailed;

  Future<AutoRefreshingAuthClient?> _getClient() async {
    if (_client != null) return _client;
    if (!enabled) return null;
    try {
      // Nhận nội dung JSON trực tiếp hoặc đường dẫn tới file JSON.
      final raw = serviceAccountPath.trim().startsWith('{')
          ? serviceAccountPath
          : await File(serviceAccountPath).readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _projectId = json['project_id'] as String;
      _client = await clientViaServiceAccount(ServiceAccountCredentials.fromJson(json),
          ['https://www.googleapis.com/auth/firebase.messaging']);
      return _client;
    } catch (e) {
      _initFailed = true;
      stderr.writeln('[push] Không khởi tạo được FCM: ${e.runtimeType}. Thông báo đẩy bị tắt.');
      return null;
    }
  }

  /// Gửi tới mọi thiết bị của người dùng. Trả về số thiết bị gửi thành công.
  Future<int> sendToUser(String userId,
      {required String title, required String body, Map<String, String> data = const {}}) async {
    final client = await _getClient();
    if (client == null) return 0;
    final devices = await db.q('SELECT push_token FROM device_tokens WHERE user_id = @u', {'u': userId});
    var sent = 0;
    for (final d in devices) {
      final token = d['push_token'] as String;
      try {
        final res = await client.post(
          Uri.parse('https://fcm.googleapis.com/v1/projects/$_projectId/messages:send'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'message': {
              'token': token,
              'notification': {'title': title, 'body': body},
              'data': data,
              'android': {
                'priority': 'high',
                'notification': {'channel_id': 'smartspend_alerts', 'color': '#1C6B52'},
              },
            }
          }),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          sent++;
        } else if (res.statusCode == 404 || res.body.contains('UNREGISTERED')) {
          await db.exec('DELETE FROM device_tokens WHERE push_token = @t', {'t': token});
        } else {
          stderr.writeln('[push] FCM trả về ${res.statusCode}');
        }
      } on http.ClientException catch (e) {
        stderr.writeln('[push] lỗi mạng: ${e.message}');
      } catch (e) {
        stderr.writeln('[push] lỗi: ${e.runtimeType}');
      }
    }
    return sent;
  }
}
