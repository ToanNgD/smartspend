import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'config.dart';
import 'token_store.dart';

/// Lỗi trả về từ server, mang thông báo tiếng Việt để hiển thị.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  ApiException(this.status, this.code, this.message, [this.details]);
  @override
  String toString() => message;
}

/// Gọi API qua HTTPS (bản phát hành). Tự đính kèm access token và tự xin token mới khi hết hạn.
class ApiClient {
  final TokenStore tokens;
  final Dio dio;
  void Function()? onSessionExpired;
  Future<bool>? _refreshing;

  ApiClient(this.tokens)
      : dio = Dio(BaseOptions(
          baseUrl: AppConfig.apiUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          contentType: 'application/json',
        )) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, h) {
        final t = tokens.accessToken;
        if (t != null && o.extra['noAuth'] != true) o.headers['authorization'] = 'Bearer $t';
        h.next(o);
      },
      onError: (e, h) async {
        final res = e.response;
        final isAuthPath = e.requestOptions.path.startsWith('/auth/');
        if (res?.statusCode == 401 && !isAuthPath && e.requestOptions.extra['retried'] != true) {
          if (await refresh()) {
            final o = e.requestOptions..extra['retried'] = true;
            o.headers['authorization'] = 'Bearer ${tokens.accessToken}';
            try {
              return h.resolve(await dio.fetch(o));
            } on DioException catch (e2) {
              return h.next(e2);
            }
          }
          onSessionExpired?.call();
        }
        h.next(e);
      },
    ));
  }

  /// Xin cặp token mới bằng refresh token. Gộp các lần gọi đồng thời thành một
  /// (refresh token xoay vòng: gửi trùng sẽ bị server coi là token bị đánh cắp).
  Future<bool> refresh() {
    return _refreshing ??= () async {
      try {
        final rt = await tokens.readRefresh();
        if (rt == null) return false;
        final r = await dio.post('/auth/refresh',
            data: {'refresh_token': rt}, options: Options(extra: {'noAuth': true}));
        await tokens.save(r.data['access_token'] as String, r.data['refresh_token'] as String);
        return true;
      } catch (_) {
        return false;
      } finally {
        Future.microtask(() => _refreshing = null);
      }
    }();
  }

  Future<dynamic> _wrap(Future<Response> Function() fn) async {
    try {
      final r = await fn();
      return r.data;
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['error'] is Map) {
        final err = data['error'] as Map;
        throw ApiException(e.response!.statusCode ?? 0, '${err['code']}', '${err['message']}',
            err['details'] is Map ? Map<String, dynamic>.from(err['details'] as Map) : null);
      }
      if (e.type == DioExceptionType.connectionError || e.type == DioExceptionType.connectionTimeout) {
        throw ApiException(0, 'offline', 'Không kết nối được máy chủ. Kiểm tra mạng và thử lại.');
      }
      throw ApiException(e.response?.statusCode ?? 0, 'error', 'Có lỗi xảy ra, vui lòng thử lại.');
    }
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => dio.get(path, queryParameters: query?..removeWhere((k, v) => v == null || v == '')));
  Future<dynamic> post(String path, [Object? body]) => _wrap(() => dio.post(path, data: body ?? {}));
  Future<dynamic> patch(String path, Object body) => _wrap(() => dio.patch(path, data: body));
  Future<dynamic> delete(String path, {Object? body, Map<String, dynamic>? query}) =>
      _wrap(() => dio.delete(path, data: body, queryParameters: query));

  Future<dynamic> uploadBytes(String path, Uint8List bytes) => _wrap(() => dio.post(path,
      data: Stream.fromIterable([bytes]),
      options: Options(contentType: 'application/octet-stream', headers: {'content-length': bytes.length})));

  Future<Uint8List> getBytes(String path) async {
    final r = await _wrap(() => dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes)));
    return Uint8List.fromList(r as List<int>);
  }
}
