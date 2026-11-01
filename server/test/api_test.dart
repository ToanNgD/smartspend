// Kiểm thử tích hợp: chạy server (dart run bin/server.dart) với CSDL thật rồi chạy `dart test`.
// Biến môi trường API_URL (mặc định http://localhost:8080/api/v1).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

final base = Platform.environment['API_URL'] ?? 'http://localhost:8080/api/v1';
final rnd = Random();
String uid() => const Uuid().v4();

class Api {
  String? access;
  String? refresh;
  Map<String, dynamic>? user;

  Map<String, String> get _h => {
        'content-type': 'application/json',
        if (access != null) 'authorization': 'Bearer $access',
      };

  Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$base$path');
    final req = http.Request(method, uri)..headers.addAll(_h);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send());
    final text = utf8.decode(res.bodyBytes);
    return (res.statusCode, text.isEmpty ? null : (res.headers['content-type']?.contains('json') == true ? jsonDecode(text) : text));
  }

  Future<(int, dynamic)> get(String p) => call('GET', p);
  Future<(int, dynamic)> post(String p, [Object? b]) => call('POST', p, b ?? {});
  Future<(int, dynamic)> patch(String p, Object b) => call('PATCH', p, b);
  Future<(int, dynamic)> delete(String p, [Object? b]) => call('DELETE', p, b);

  Future<http.Response> upload(String txId, List<int> bytes) => http.post(Uri.parse('$base/transactions/$txId/attachments'),
      headers: {'authorization': 'Bearer $access', 'content-type': 'application/octet-stream'}, body: bytes);

  static Future<Api> register([String? email]) async {
    final a = Api();
    final (s, b) = await a.post('/auth/register', {
      'full_name': 'Người Thử ${rnd.nextInt(9999)}',
      'email': email ?? 'test${DateTime.now().microsecondsSinceEpoch}${rnd.nextInt(999)}@example.com',
      'password': 'matkhau123',
    });
    expect(s, 201, reason: '$b');
    a.access = b['access_token'];
    a.refresh = b['refresh_token'];
    a.user = b['user'];
    return a;
  }
}

Future<Map<String, dynamic>> catByName(Api a, String name) async {
  final (_, b) = await a.get('/categories?include_hidden=true');
  return (b['items'] as List).cast<Map<String, dynamic>>().firstWhere((c) => c['name'] == name);
}

Future<Map<String, dynamic>> cashWallet(Api a) async {
  final (_, b) = await a.get('/wallets');
  return (b['items'] as List).cast<Map<String, dynamic>>().firstWhere((w) => w['name'] == 'Tiền mặt');
}

Future<Map<String, dynamic>> addTx(Api a, {required String wallet, required String cat, int amount = 50000,
    String type = 'expense', String? note, String? key, DateTime? at}) async {
  final (s, b) = await a.post('/transactions', {
    'idempotency_key': key ?? uid(),
    'type': type,
    'amount': amount,
    'wallet_id': wallet,
    'category_id': cat,
    if (note != null) 'note': note,
    if (at != null) 'occurred_at': at.toUtc().toIso8601String(),
  });
  expect(s, anyOf(200, 201), reason: '$b');
  return b;
}

void main() {
  group('1.1 Đăng ký', () {
    test('mật khẩu yếu bị từ chối, email trùng bị từ chối', () async {
      final a = Api();
      var (s, b) = await a.post('/auth/register', {'full_name': 'A', 'email': 'x@y.vn', 'password': 'abcdefgh'});
      expect(s, 400);
      expect(b['error']['code'], 'weak_password');
      (s, b) = await a.post('/auth/register', {'full_name': 'A', 'email': 'sai-dinh-dang', 'password': 'abc12345'});
      expect(s, 400);
      final email = 'dup${DateTime.now().microsecondsSinceEpoch}@example.com';
      await Api.register(email);
      (s, b) = await a.post('/auth/register', {'full_name': 'B', 'email': email.toUpperCase(), 'password': 'abc12345'});
      expect(s, 409);
    });

    test('tạo sẵn 12 danh mục mặc định và ví Tiền mặt', () async {
      final a = await Api.register();
      final (_, c) = await a.get('/categories');
      expect((c['items'] as List).length, 12);
      final (_, w) = await a.get('/wallets');
      expect((w['items'] as List).single['name'], 'Tiền mặt');
    });
  });

  group('1.2 Đăng nhập và phiên', () {
    test('sai 5 lần thì khóa 15 phút, thông báo lỗi chung', () async {
      final email = 'lock${DateTime.now().microsecondsSinceEpoch}@example.com';
      await Api.register(email);
      final a = Api();
      for (var i = 0; i < 5; i++) {
        final (s, b) = await a.post('/auth/login', {'email': email, 'password': 'sai123456'});
        expect(s, 401);
        expect(b['error']['message'], 'Email hoặc mật khẩu không đúng');
      }
      final (s, b) = await a.post('/auth/login', {'email': email, 'password': 'matkhau123'});
      expect(s, 429);
      expect(b['error']['code'], 'login_locked');
    });

    test('email không tồn tại trả cùng thông báo', () async {
      final (s, b) = await Api().post('/auth/login', {'email': 'khongco${uid()}@example.com', 'password': 'x1234567'});
      expect(s, 401);
      expect(b['error']['message'], 'Email hoặc mật khẩu không đúng');
    });

    test('refresh token xoay vòng; dùng lại token cũ thì hủy toàn bộ phiên', () async {
      final a = await Api.register();
      final old = a.refresh!;
      var (s, b) = await a.post('/auth/refresh', {'refresh_token': old});
      expect(s, 200);
      final newer = b['refresh_token'] as String;
      expect(newer, isNot(old));
      (s, b) = await a.post('/auth/refresh', {'refresh_token': old});
      expect(s, 401);
      expect(b['error']['code'], 'session_revoked');
      (s, b) = await a.post('/auth/refresh', {'refresh_token': newer});
      expect(s, 401, reason: 'token mới cũng bị hủy');
    });

    test('đăng xuất hủy refresh token; thiếu/sai token bị chặn', () async {
      final a = await Api.register();
      var (s, _) = await a.post('/auth/logout', {'refresh_token': a.refresh});
      expect(s, 204);
      (s, _) = await a.post('/auth/refresh', {'refresh_token': a.refresh});
      expect(s, 401);
      final anon = Api();
      (s, _) = await anon.get('/wallets');
      expect(s, 401);
      anon.access = '${a.access!.substring(0, a.access!.length - 3)}abc';
      (s, _) = await anon.get('/wallets');
      expect(s, 401);
    });
  });

  group('3.1 Ví', () {
    test('tạo ví có số dư ban đầu, không trùng tên, lưu trữ, xóa, điều chỉnh', () async {
      final a = await Api.register();
      var (s, b) = await a.post('/wallets', {'name': 'MoMo', 'type': 'ewallet', 'initial_balance': 500000});
      expect(s, 201);
      expect(b['balance'], 500000);
      final momo = b['id'];
      (s, b) = await a.post('/wallets', {'name': 'momo', 'type': 'bank'});
      expect(s, 409);
      (s, b) = await a.patch('/wallets/$momo', {'balance': 1});
      expect(s, 400, reason: 'không sửa trực tiếp số dư');
      (s, b) = await a.post('/wallets/$momo/adjust', {'balance': 450000});
      expect(b['balance'], 450000);
      (s, b) = await a.get('/transactions');
      expect(b['totals']['income'], 0, reason: 'số dư ban đầu không tính vào tổng thu');
      expect(b['totals']['expense'], 0, reason: 'điều chỉnh số dư không tính vào tổng chi');
      (s, b) = await a.delete('/wallets/$momo');
      expect(s, 409, reason: 'ví đã có giao dịch');
      final cash = await cashWallet(a);
      (s, b) = await a.post('/wallets/$momo/archive');
      expect(s, 200);
      (s, b) = await a.post('/wallets/${cash['id']}/archive');
      expect(s, 409, reason: 'phải giữ một ví đang dùng');
      (s, b) = await a.post('/wallets/$momo/unarchive');
      (s, b) = await a.post('/wallets', {'name': 'Ví trống', 'type': 'cash'});
      (s, _) = await a.delete('/wallets/${b['id']}');
      expect(s, 204);
      // Giao dịch hệ thống không tính vào báo cáo thu chi.
      (s, b) = await a.get('/reports/summary?period=month');
      expect(b['income'], 0);
    });
  });

  group('3.2 Danh mục', () {
    test('mặc định chỉ ẩn; xóa danh mục có giao dịch phải chuyển sang danh mục khác', () async {
      final a = await Api.register();
      final food = await catByName(a, 'Ăn uống');
      var (s, b) = await a.patch('/categories/${food['id']}', {'name': 'Đồ ăn'});
      expect(s, 400);
      (s, b) = await a.delete('/categories/${food['id']}');
      expect(s, 400);
      (s, b) = await a.patch('/categories/${food['id']}', {'is_hidden': true});
      expect(b['is_hidden'], true);
      (s, b) = await a.post('/categories', {'name': 'Cà phê', 'type': 'expense', 'icon': 'coffee', 'color': '#6F4E37'});
      expect(s, 201);
      final cafe = b['id'];
      (s, b) = await a.post('/categories', {'name': 'cà phê', 'type': 'expense'});
      expect(s, 409);
      (s, b) = await a.post('/categories', {'name': '<script>', 'type': 'expense'});
      expect(s, 400);
      final w = await cashWallet(a);
      await addTx(a, wallet: w['id'], cat: cafe, amount: 30000);
      (s, b) = await a.delete('/categories/$cafe');
      expect(s, 409);
      expect(b['error']['code'], 'category_in_use');
      final income = await catByName(a, 'Lương');
      (s, b) = await a.delete('/categories/$cafe?move_to=${income['id']}');
      expect(s, 400, reason: 'phải cùng loại');
      final other = await catByName(a, 'Chi khác');
      (s, b) = await a.delete('/categories/$cafe?move_to=${other['id']}');
      expect(s, 200);
      expect(b['moved_transactions'], 1);

      // Danh mục chỉ còn giao dịch đã xóa: app thấy 0 giao dịch, xóa thẳng được;
      // giao dịch đã xóa được chuyển sang "Chi khác" để không mất dữ liệu.
      (s, b) = await a.post('/categories', {'name': 'Tạm', 'type': 'expense'});
      final tmp = b['id'];
      final t = await addTx(a, wallet: w['id'], cat: tmp, amount: 10000);
      await a.delete('/transactions/${t['id']}');
      (s, b) = await a.get('/categories');
      expect((b['items'] as List).firstWhere((c) => c['id'] == tmp)['tx_count'], 0);
      (s, b) = await a.delete('/categories/$tmp');
      expect(s, 200, reason: '$b');
      (s, b) = await a.post('/transactions/${t['id']}/restore');
      expect(b['category_id'], other['id']);
    });
  });

  group('4.x Giao dịch', () {
    test('thêm, chống gửi trùng, kiểm tra dữ liệu, sửa, xóa mềm, hoàn tác', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final salary = await catByName(a, 'Lương');
      final key = uid();
      final t1 = await addTx(a, wallet: w['id'], cat: food['id'], amount: 50000, note: 'Ăn phở', key: key);
      expect(t1['warnings'], contains('over_balance'));
      final again = await addTx(a, wallet: w['id'], cat: food['id'], amount: 50000, note: 'Ăn phở', key: key);
      expect(again['duplicate'], true);
      expect(again['id'], t1['id']);
      expect((await cashWallet(a))['balance'], -50000);

      var (s, b) = await a.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 1000, 'wallet_id': w['id'], 'category_id': salary['id']});
      expect(s, 400, reason: 'loại không khớp danh mục');
      (s, b) = await a.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 0, 'wallet_id': w['id'], 'category_id': food['id']});
      expect(s, 400);
      (s, b) = await a.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 1000, 'wallet_id': w['id'], 'category_id': food['id'],
        'note': 'x' * 201});
      expect(s, 400);
      (s, b) = await a.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 1000, 'wallet_id': w['id'], 'category_id': food['id'],
        'occurred_at': DateTime.now().add(const Duration(days: 5)).toUtc().toIso8601String()});
      expect(s, 400);

      (s, b) = await a.patch('/transactions/${t1['id']}', {'amount': 70000});
      expect(b['amount'], 70000);
      expect((await cashWallet(a))['balance'], -70000);
      (s, b) = await a.patch('/transactions/${t1['id']}', {'type': 'income', 'category_id': salary['id']});
      expect((await cashWallet(a))['balance'], 70000);
      (s, b) = await a.delete('/transactions/${t1['id']}');
      expect(s, 200);
      expect((await cashWallet(a))['balance'], 0);
      (s, b) = await a.post('/transactions/${t1['id']}/restore');
      expect(s, 200);
      expect((await cashWallet(a))['balance'], 70000);
    });

    test('tìm không dấu, lọc, phân trang, tổng thu chi', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final car = await catByName(a, 'Đi lại');
      for (var i = 0; i < 7; i++) {
        await addTx(a, wallet: w['id'], cat: food['id'], amount: 10000 + i, note: 'Phở bò $i');
      }
      await addTx(a, wallet: w['id'], cat: car['id'], amount: 20000, note: 'Đổ xăng');
      var (s, b) = await a.get('/transactions?q=PHO&limit=5');
      expect((b['items'] as List).length, 5);
      expect(b['totals']['count'], 7);
      expect(b['next_cursor'], isNotNull);
      (s, b) = await a.get('/transactions?q=PHO&limit=5&cursor=${b['next_cursor']}');
      expect((b['items'] as List).length, 2);
      expect(b['next_cursor'], isNull);
      (s, b) = await a.get('/transactions?category_id=${car['id']}');
      expect(b['totals']['expense'], 20000);
      (s, b) = await a.get('/transactions?q=%25');
      expect(b['totals']['count'], 0, reason: 'ký tự % chỉ là dữ liệu');
      (s, b) = await a.get('/transactions?limit=1000');
      expect((b['items'] as List).length, lessThanOrEqualTo(50));
    });

    test('xóa nhiều giao dịch', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final ids = [for (var i = 0; i < 3; i++) (await addTx(a, wallet: w['id'], cat: food['id']))['id']];
      final (s, b) = await a.post('/transactions/bulk-delete', {'ids': ids});
      expect(s, 200);
      expect((await cashWallet(a))['balance'], 0);
    });
  });

  group('Bảo mật: không truy cập được dữ liệu người khác', () {
    test('IDOR trên ví, danh mục, giao dịch, ảnh, ngân sách', () async {
      final a = await Api.register();
      final b = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final t = await addTx(a, wallet: w['id'], cat: food['id']);
      final up = await a.upload(t['id'], img.encodePng(img.Image(width: 20, height: 20)));
      final att = jsonDecode(up.body);
      expect((await b.get('/transactions/${t['id']}')).$1, 404);
      expect((await b.patch('/transactions/${t['id']}', {'amount': 1})).$1, 404);
      expect((await b.delete('/transactions/${t['id']}')).$1, 404);
      expect((await b.get('/attachments/${att['id']}')).$1, 404);
      expect((await b.delete('/attachments/${att['id']}')).$1, 404);
      expect((await b.patch('/wallets/${w['id']}', {'name': 'hack'})).$1, 404);
      expect((await b.patch('/categories/${food['id']}', {'is_hidden': true})).$1, 404);
      // Dùng ví/danh mục của A để ghi giao dịch cho B.
      final bw = await cashWallet(b);
      var (s, _) = await b.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 1000, 'wallet_id': w['id'], 'category_id': food['id']});
      expect(s, 400);
      (s, _) = await b.post('/transactions', {
        'idempotency_key': uid(), 'type': 'expense', 'amount': 1000, 'wallet_id': bw['id'], 'category_id': food['id']});
      expect(s, 400);
      (s, _) = await b.post('/budgets', {'name': 'x', 'amount_limit': 100000, 'period': 'month', 'scope': 'categories',
        'category_ids': [food['id']]});
      expect(s, 400);
      // Cố gửi user_id trong body cũng không có tác dụng.
      final (_, wb) = await b.post('/wallets', {'name': 'Ví B', 'type': 'cash', 'user_id': a.user!['id']});
      final (_, wa) = await a.get('/wallets');
      expect((wa['items'] as List).any((x) => x['id'] == wb['id']), false);
    });
  });

  group('UC06.1 Ảnh giao dịch', () {
    test('nhận ảnh thật, đổi sang JPEG, xóa EXIF, tối đa 3 ảnh, từ chối tệp giả', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final t = await addTx(a, wallet: w['id'], cat: food['id'], note: 'Bánh mì');
      final big = img.Image(width: 3000, height: 2000);
      img.fill(big, color: img.ColorRgb8(200, 120, 40));
      big.exif.imageIfd['Make'] = 'CameraThu';
      big.exif.gpsIfd['GPSLatitude'] = 21.0;
      final jpg = img.encodeJpg(big, quality: 70);
      var res = await a.upload(t['id'], jpg);
      expect(res.statusCode, 201, reason: res.body);
      final att = jsonDecode(res.body);
      expect(att['mime_type'], 'image/jpeg');
      expect(att['width'], 1600);
      final dl = await http.get(Uri.parse('$base/attachments/${att['id']}'), headers: {'authorization': 'Bearer ${a.access}'});
      expect(dl.statusCode, 200);
      expect(dl.headers['content-type'], 'image/jpeg');
      final decoded = img.decodeJpg(Uint8List.fromList(dl.bodyBytes))!;
      expect(decoded.exif.imageIfd['Make'], isNull, reason: 'EXIF phải bị xóa');
      expect(decoded.exif.gpsIfd.isEmpty, true);

      res = await a.upload(t['id'], utf8.encode('<?php echo 1; ?>'));
      expect(res.statusCode, 415);
      res = await a.upload(t['id'], [0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]);
      expect(res.statusCode, 415, reason: 'chữ ký JPEG nhưng nội dung hỏng');
      res = await a.upload(t['id'], img.encodePng(img.Image(width: 10, height: 10)));
      res = await a.upload(t['id'], img.encodePng(img.Image(width: 10, height: 10)));
      expect(res.statusCode, 201);
      res = await a.upload(t['id'], img.encodePng(img.Image(width: 10, height: 10)));
      expect(res.statusCode, 409);
      res = await a.upload(t['id'], List.filled(5 * 1024 * 1024 + 10, 0));
      expect(res.statusCode, anyOf(409, 413));
      // Xóa mềm giao dịch vẫn giữ ảnh để hoàn tác.
      await a.delete('/transactions/${t['id']}');
      await a.post('/transactions/${t['id']}/restore');
      final (_, d) = await a.get('/transactions/${t['id']}');
      expect((d['attachments'] as List).length, 3);
      final (s, _) = await a.delete('/attachments/${att['id']}');
      expect(s, 204);
    });
  });

  group('5.x Ngân sách và cảnh báo', () {
    test('tính mức đã dùng; cảnh báo 80% và 100% chỉ một lần; không tạo trùng', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final salary = await catByName(a, 'Lương');
      await addTx(a, wallet: w['id'], cat: salary['id'], type: 'income', amount: 5000000);
      var (s, b) = await a.post('/budgets', {'name': 'Tháng này', 'amount_limit': 1000000, 'period': 'month'});
      expect(s, 201);
      final budgetId = b['id'];
      (s, b) = await a.post('/budgets', {'name': 'Trùng', 'amount_limit': 2000000, 'period': 'month'});
      expect(s, 409);
      (s, b) = await a.post('/budgets', {'name': 'Ăn uống', 'amount_limit': 500000, 'period': 'week', 'scope': 'categories',
        'category_ids': [food['id']]});
      expect(s, 201);
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 850000);
      (s, b) = await a.get('/budgets/$budgetId');
      expect(b['spent'], 850000, reason: 'chỉ tính khoản chi');
      expect(b['status'], 'yellow');
      var (_, al) = await a.get('/alerts');
      final types = (al['items'] as List).map((x) => x['type']).toList();
      // Tháng 1.000.000đ: 85% -> chỉ cảnh báo 80%. Tuần Ăn uống 500.000đ: 170% -> 80% và 100% (chỉ đẩy 1 thông báo).
      expect(types.where((t) => t == 'budget_80').length, 2);
      expect(types.where((t) => t == 'budget_100').length, 1);
      for (final x in al['items'] as List) {
        expect(RegExp(r'\d{4,}|\d\.\d{3}|\dđ').hasMatch(x['body'] as String), false, reason: 'không chứa số tiền');
      }
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 10000);
      (_, al) = await a.get('/alerts');
      expect((al['items'] as List).where((x) => x['type'] == 'budget_80').length, 2,
          reason: 'mỗi ngưỡng chỉ cảnh báo một lần trong kỳ');
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 200000);
      (_, al) = await a.get('/alerts');
      expect((al['items'] as List).where((x) => x['type'] == 'budget_100').length, 2);
      (s, _) = await a.delete('/budgets/$budgetId');
      expect(s, 204);
      final (_, list) = await a.get('/transactions');
      expect(list['totals']['count'], 4, reason: 'xóa ngân sách không xóa giao dịch');
    });

    test('tắt cảnh báo trong cài đặt', () async {
      final a = await Api.register();
      await a.patch('/settings', {'budget_alerts_enabled': false});
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      await a.post('/budgets', {'name': 'T', 'amount_limit': 100000, 'period': 'month'});
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 200000);
      // Tạo thêm / sửa ngân sách khi đã vượt ngưỡng cũng không được cảnh báo.
      final (_, nb) = await a.post('/budgets', {'name': 'T2', 'amount_limit': 50000, 'period': 'week'});
      await a.patch('/budgets/${nb['id']}', {'amount_limit': 60000});
      final (_, al) = await a.get('/alerts');
      expect((al['items'] as List), isEmpty);
    });
  });

  group('6.3 Cảnh báo bất thường và dự báo', () {
    test('khoản chi lớn bất thường được gắn cờ; bấm "Bình thường" thì lần sau không báo', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      for (final v in [30000, 35000, 40000, 32000, 38000, 36000]) {
        await addTx(a, wallet: w['id'], cat: food['id'], amount: v,
            at: DateTime.now().subtract(Duration(days: rnd.nextInt(20) + 1)));
      }
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 900000);
      var (_, al) = await a.get('/alerts');
      final anomaly = (al['items'] as List).firstWhere((x) => x['type'] == 'anomaly');
      final (s, _) = await a.post('/alerts/${anomaly['id']}/feedback', {'feedback': 'normal'});
      expect(s, 204);
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 950000);
      (_, al) = await a.get('/alerts');
      expect((al['items'] as List).where((x) => x['type'] == 'anomaly').length, 1);
      final (_, f) = await a.get('/ai/forecast');
      expect(f['enough_data'], true);
    });

    test('chưa đủ 2 tuần dữ liệu thì không dự báo', () async {
      final a = await Api.register();
      final (_, f) = await a.get('/ai/forecast');
      expect(f['enough_data'], false);
      expect(f['message'], contains('Chưa đủ dữ liệu'));
    });
  });

  group('6.1 / 6.2 AI', () {
    test('nhập câu tự nhiên trả bản xem trước, không tự lưu', () async {
      final a = await Api.register();
      final food = await catByName(a, 'Ăn uống');
      final (s, b) = await a.post('/ai/parse', {'text': 'trưa nay ăn phở 50k, cà phê 25k'});
      expect(s, 200, reason: '$b');
      final items = (b['items'] as List).cast<Map<String, dynamic>>();
      expect(items.length, 2);
      expect(items.map((e) => e['amount']), containsAll([50000, 25000]));
      expect(items.first['category_id'], food['id']);
      final (_, list) = await a.get('/transactions');
      expect(list['totals']['count'], 0);
      final (s2, b2) = await a.post('/ai/parse', {'text': 'x' * 301});
      expect(s2, 400);
      final (_, b3) = await a.post('/ai/parse', {'text': 'hôm qua nhận lương 15tr'});
      expect(b3['items'][0]['type'], 'income');
      expect(b3['items'][0]['amount'], 15000000);
    });

    test('phân tích tạo thẻ gợi ý, lưu cache, giới hạn lượt mỗi ngày', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      for (var i = 0; i < 6; i++) {
        await addTx(a, wallet: w['id'], cat: food['id'], amount: 40000 + i * 1000,
            at: DateTime.now().subtract(Duration(minutes: i)));
      }
      var (s, b) = await a.post('/ai/insights/analyze');
      expect(s, 200, reason: '$b');
      final items = (b['items'] as List).cast<Map<String, dynamic>>();
      expect(items, isNotEmpty);
      final saving = items.firstWhere((x) => x['kind'] == 'saving');
      expect(saving['action']['type'], 'set_budget');
      (s, b) = await a.get('/ai/insights');
      expect((b['items'] as List).length, items.length);
      // Thứ tự thẻ cố định: Xu hướng, Thói quen, Tiết kiệm.
      const order = {'trend': 0, 'habit': 1, 'saving': 2};
      final kinds = (b['items'] as List).map((x) => order[x['kind']]!).toList();
      expect(kinds, [...kinds]..sort());
      (s, _) = await a.patch('/ai/insights/${saving['id']}', {'status': 'acted'});
      expect(s, 204);
      await a.post('/ai/insights/analyze');
      await a.post('/ai/insights/analyze');
      (s, b) = await a.post('/ai/insights/analyze');
      expect(s, 429);
    });
  });

  group('6.2 Phân tích khi chưa có khoản chi', () {
    test('chưa có khoản chi trong tháng: báo chưa đủ dữ liệu, không trừ lượt', () async {
      final a = await Api.register();
      var (s, b) = await a.get('/ai/insights');
      final before = b['manual_remaining_today'];
      (s, b) = await a.post('/ai/insights/analyze');
      expect(s, 400);
      expect(b['error']['code'], 'not_enough_data');
      (s, b) = await a.get('/ai/insights');
      expect(b['manual_remaining_today'], before);
      expect(b['items'], isEmpty);
    });
  });

  group('7.1 Báo cáo', () {
    test('tổng quan, theo danh mục (gộp <3%), xu hướng', () async {
      final a = await Api.register();
      final w = await cashWallet(a);
      final food = await catByName(a, 'Ăn uống');
      final car = await catByName(a, 'Đi lại');
      final book = await catByName(a, 'Học tập');
      await addTx(a, wallet: w['id'], cat: food['id'], amount: 1000000);
      await addTx(a, wallet: w['id'], cat: car['id'], amount: 500000);
      await addTx(a, wallet: w['id'], cat: book['id'], amount: 10000);
      var (s, b) = await a.get('/reports/overview');
      expect(s, 200, reason: '$b');
      expect(b['month']['expense'], 1510000);
      expect((b['recent_transactions'] as List).length, 3);
      (s, b) = await a.get('/reports/categories?period=month&type=expense');
      expect(b['total'], 1510000);
      expect((b['items'] as List).length, 2);
      expect(b['other']['amount'], 10000);
      // Khoảng ngày của báo cáo danh mục khớp với báo cáo tổng hợp (ngày cuối tính cả ngày đó).
      final (_, sum) = await a.get('/reports/summary?period=month');
      expect([b['from'], b['to']], [sum['from'], sum['to']]);
      (s, b) = await a.get('/reports/categories?period=month&offset=-1&type=expense');
      final (_, prevSum) = await a.get('/reports/summary?period=month&offset=-1');
      expect([b['from'], b['to']], [prevSum['from'], prevSum['to']]);
      (s, b) = await a.get('/reports/trend?period=month&group=day');
      expect(s, 200);
      expect((b['items'] as List).fold<int>(0, (x, e) => x + (e['expense'] as int)), 1510000);
      (s, b) = await a.get('/reports/summary?period=month&offset=-1');
      expect(b['expense'], 0);
      (s, b) = await a.get('/reports/summary?period=custom&from=2026-01-01&to=2026-12-31');
      expect(s, 200);
      (s, b) = await a.get('/reports/summary?period=custom&from=abc&to=2026-12-31');
      expect(s, 400);
    });
  });
}
