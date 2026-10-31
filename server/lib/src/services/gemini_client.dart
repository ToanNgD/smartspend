import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Gọi Gemini qua REST từ server. API key chỉ nằm ở server (biến môi trường).
/// Không bao giờ ghi nội dung gửi/nhận vào log.
class GeminiClient {
  final String apiKey;
  final String model;
  final http.Client _http;
  GeminiClient(this.apiKey, this.model, [http.Client? client]) : _http = client ?? http.Client();

  bool get enabled => apiKey.isNotEmpty;

  /// Trả về JSON đã giải mã, hoặc null nếu lỗi (server sẽ dùng bộ dự phòng).
  Future<Map<String, dynamic>?> generateJson({
    required String systemInstruction,
    required Object input,
    required Map<String, dynamic> schema,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!enabled) return null;
    final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
    Map<String, dynamic> body(bool withSchema) => {
          'systemInstruction': {
            'parts': [
              {'text': systemInstruction}
            ]
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': jsonEncode(input)}
              ]
            }
          ],
          'generationConfig': {
            'responseMimeType': 'application/json',
            if (withSchema) 'responseSchema': schema,
          },
        };
    for (final withSchema in [true, false]) {
      try {
        final res = await _http
            .post(uri,
                headers: {'content-type': 'application/json', 'x-goog-api-key': apiKey},
                body: jsonEncode(body(withSchema)))
            .timeout(timeout);
        if (res.statusCode == 400 && withSchema) continue; // thử lại không kèm schema
        if (res.statusCode != 200) {
          stderr.writeln('[ai] Gemini trả về mã ${res.statusCode}');
          return null;
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final parts = (((data['candidates'] as List?)?.first as Map?)?['content'] as Map?)?['parts'] as List?;
        final text = parts?.map((p) => (p as Map)['text'] ?? '').join() ?? '';
        final cleaned = text.trim().replaceAll(RegExp(r'^```(json)?|```$'), '').trim();
        final v = jsonDecode(cleaned);
        return v is Map<String, dynamic> ? v : null;
      } catch (e) {
        stderr.writeln('[ai] lỗi gọi Gemini: ${e.runtimeType}');
        return null;
      }
    }
    return null;
  }
}
