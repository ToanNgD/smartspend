// Tạo tài khoản demo với dữ liệu mẫu ~6 tuần để trình diễn (báo cáo, ngân sách, dự báo, gợi ý).
// Chạy khi server đang bật:  dart run tool/seed_demo.dart [email] [mat_khau]
// Mặc định: demo@smartspend.vn / demo1234
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

final base = Platform.environment['API_URL'] ?? 'http://localhost:8080/api/v1';
late String token;

Future<dynamic> call(String method, String path, [Object? body]) async {
  final req = http.Request(method, Uri.parse('$base$path'))
    ..headers['content-type'] = 'application/json'
    ..headers['authorization'] = 'Bearer $token';
  if (body != null) req.body = jsonEncode(body);
  final res = await http.Response.fromStream(await req.send());
  if (res.statusCode == 429 && !path.startsWith('/ai/')) {
    // Server giới hạn tần suất -> chờ rồi gửi lại (cùng idempotency_key nên không tạo trùng).
    await Future.delayed(const Duration(seconds: 10));
    return call(method, path, body);
  }
  final text = utf8.decode(res.bodyBytes);
  if (res.statusCode >= 400) throw Exception('$method $path -> ${res.statusCode} $text');
  return text.isEmpty ? null : jsonDecode(text);
}

Future<void> main(List<String> args) async {
  final email = args.isNotEmpty ? args[0] : 'demo@smartspend.vn';
  final pw = args.length > 1 ? args[1] : 'demo1234';
  var res = await http.post(Uri.parse('$base/auth/register'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'full_name': 'Nguyễn Minh Anh', 'email': email, 'password': pw}));
  if (res.statusCode == 409) {
    stdout.writeln('Tài khoản $email đã tồn tại, bỏ qua.');
    return;
  }
  if (res.statusCode != 201) throw Exception(res.body);
  token = jsonDecode(res.body)['access_token'];

  final cats = {for (final c in (await call('GET', '/categories'))['items']) c['name']: c['id']};
  final wallets = (await call('GET', '/wallets'))['items'] as List;
  final cash = wallets.first['id'];
  final bank = (await call('POST', '/wallets', {'name': 'Vietcombank', 'type': 'bank', 'initial_balance': 8000000}))['id'];
  final momo = (await call('POST', '/wallets', {'name': 'MoMo', 'type': 'ewallet', 'initial_balance': 1200000}))['id'];
  await call('POST', '/wallets/$cash/adjust', {'balance': 1500000});

  final rnd = Random(7);
  // Giờ trong dữ liệu mẫu tính theo giờ Việt Nam (UTC+7), không phụ thuộc múi giờ của máy chạy script.
  final now = DateTime.now().toUtc().add(const Duration(hours: 7));
  Future<void> tx(String cat, int amount, DateTime at, {String type = 'expense', String? note, String? wallet}) =>
      call('POST', '/transactions', {
        'idempotency_key': const Uuid().v4(),
        'type': type,
        'amount': amount,
        'category_id': cats[cat],
        'wallet_id': wallet ?? [cash, momo, bank][rnd.nextInt(3)],
        'occurred_at': at.toUtc().toIso8601String(),
        if (note != null) 'note': note,
      });

  final meals = ['Phở bò', 'Cơm tấm', 'Bún chả', 'Bánh mì', 'Cơm văn phòng', 'Bún bò Huế', 'Mì quảng'];
  final drinks = ['Cà phê sữa', 'Trà sữa', 'Bạc xỉu', 'Nước cam'];
  var count = 0;
  for (var d = 42; d >= 0; d--) {
    final day = DateTime.utc(now.year, now.month, now.day).subtract(Duration(days: d));
    DateTime at(int h, int m) {
      var t = day.add(Duration(hours: h, minutes: m));
      if (t.isAfter(now)) t = now.subtract(const Duration(minutes: 5));
      return t.subtract(const Duration(hours: 7)); // đổi giờ Việt Nam -> UTC
    }

    await tx('Ăn uống', 25000 + rnd.nextInt(6) * 5000, at(7, 30), note: 'Bánh mì', wallet: cash);
    await tx('Ăn uống', 35000 + rnd.nextInt(5) * 5000, at(12, 10), note: meals[rnd.nextInt(meals.length)]);
    count += 2;
    if (rnd.nextDouble() < 0.6) {
      await tx('Ăn uống', 25000 + rnd.nextInt(4) * 5000, at(15, 0), note: drinks[rnd.nextInt(drinks.length)], wallet: momo);
      count++;
    }
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      await tx('Giải trí', 80000 + rnd.nextInt(6) * 20000, at(19, 30), note: day.weekday == 6 ? 'Xem phim' : 'Karaoke');
      await tx('Ăn uống', 150000 + rnd.nextInt(5) * 30000, at(18, 45), note: 'Ăn tối cùng bạn');
      count += 2;
    }
    if (rnd.nextDouble() < 0.35) {
      await tx('Đi lại', 20000 + rnd.nextInt(6) * 5000, at(8, 15), note: 'Grab', wallet: momo);
      count++;
    }
    if (day.day % 9 == 0) {
      await tx('Đi lại', 70000 + rnd.nextInt(3) * 10000, at(17, 40), note: 'Đổ xăng', wallet: cash);
      count++;
    }
    if (day.day == 5) {
      await tx('Lương', 15000000, at(9, 0), type: 'income', note: 'Lương tháng', wallet: bank);
      await tx('Nhà ở', 3500000, at(10, 0), note: 'Tiền phòng trọ', wallet: bank);
      await tx('Hóa đơn', 420000, at(20, 0), note: 'Tiền điện nước', wallet: bank);
      count += 3;
    }
    if (day.day == 12 || day.day == 26) {
      await tx('Mua sắm', 250000 + rnd.nextInt(8) * 50000, at(21, 0), note: 'Shopee', wallet: momo);
      count++;
    }
    if (d == 20) {
      await tx('Học tập', 650000, at(14, 0), note: 'Sách và tài liệu', wallet: bank);
      count++;
    }
  }
  await call('POST', '/budgets', {'name': 'Chi tiêu tháng', 'amount_limit': 9000000, 'period': 'month'});
  await call('POST', '/budgets', {
    'name': 'Ăn uống tuần', 'amount_limit': 900000, 'period': 'week', 'scope': 'categories', 'category_ids': [cats['Ăn uống']]});
  await call('POST', '/ai/insights/analyze');
  stdout.writeln('Đã tạo tài khoản demo: $email / $pw ($count giao dịch).');
}
