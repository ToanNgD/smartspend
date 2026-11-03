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
  ServiceAccountCredentials? _creds;
  String? _projectId;
  AutoRefreshingAuthClient? _client;
  Future<AutoRefreshingAuthClient?>? _connecting;
  /// Khóa tài khoản dịch vụ không đọc được (sai nội dung, sai đường dẫn): tắt hẳn thông báo đẩy.
  bool _invalid = false;
  /// Lần kết nối FCM gần nhất bị lỗi mạng: chờ tới mốc này mới thử lại (không tắt hẳn).
  DateTime? _retryAt;

  static const retryDelay = Duration(minutes: 5);

  PushService(this.db, this.serviceAccountPath) {
    if (serviceAccountPath.isEmpty) return;
    try {
      // Nhận nội dung JSON trực tiếp hoặc đường dẫn tới file JSON.
      final raw = serviceAccountPath.trim().startsWith('{')
          ? serviceAccountPath
          : File(serviceAccountPath).readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _projectId = json['project_id'] as String;
      _creds = ServiceAccountCredentials.fromJson(json);
    } catch (e) {
      _invalid = true;
      stderr.writeln('[push] Khóa FCM không đọc được (${e.runtimeType}). Thông báo đẩy bị tắt.');
    }
  }

  /// Có cấu hình FCM và khóa đọc được. Lỗi mạng tạm thời không làm giá trị này thành false.
  bool get enabled => serviceAccountPath.isNotEmpty && !_invalid;

  Future<AutoRefreshingAuthClient?> _getClient() async {
    if (_client != null) return _client;
    if (!enabled) return null;
    final retryAt = _retryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return null;
    // Nhiều cảnh báo cùng lúc chỉ dẫn tới một lần kết nối.
    return _connecting ??= () async {
      try {
        _client = await clientViaServiceAccount(_creds!, ['https://www.googleapis.com/auth/firebase.messaging']);
        _retryAt = null;
        return _client;
      } catch (e) {
        // Mất mạng hoặc dịch vụ của Google tạm lỗi: lần gửi sau (sau 5 phút) thử kết nối lại.
        _retryAt = DateTime.now().add(retryDelay);
        stderr.writeln('[push] Chưa kết nối được FCM (${e.runtimeType}), sẽ thử lại sau ${retryDelay.inMinutes} phút.');
        return null;
      } finally {
        _connecting = null;
      }
    }();
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
