import 'dart:convert';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:smartspend/core/api_client.dart';
import 'package:smartspend/core/format.dart';
import 'package:smartspend/core/images.dart';
import 'package:smartspend/core/secure_cache.dart';
import 'package:smartspend/core/token_store.dart';
import 'package:smartspend/core/vault.dart';
import 'package:smartspend/models/models.dart';
import 'package:smartspend/screens/ai_screen.dart';
import 'package:smartspend/screens/alerts_screen.dart';
import 'package:smartspend/screens/auth_screens.dart';
import 'package:smartspend/screens/lock_screens.dart';
import 'package:smartspend/screens/report_screen.dart';
import 'package:smartspend/state/app_data.dart';
import 'package:smartspend/widgets/common.dart';
import 'package:smartspend/widgets/tx_editor.dart';

/// API giả cho màn Cảnh báo: 60 cảnh báo, trả theo trang giống server (limit, before).
class _FakeAlertsApi extends ApiClient {
  _FakeAlertsApi() : super(TokenStore());
  final calls = <String?>[];
  final all = List.generate(60, (i) => <String, dynamic>{
        'id': 'a$i', 'type': 'budget_80', 'title': 'Cảnh báo số $i', 'body': 'Nội dung $i',
        'sent_at': DateTime.utc(2026, 11, 2, 12).subtract(Duration(minutes: i)).toIso8601String(),
        'read_at': '2026-11-02T13:00:00Z',
      });

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final before = query?['before'] as String?;
    calls.add(before);
    final b = before == null ? null : DateTime.parse(before);
    final items = all
        .where((a) => b == null || DateTime.parse(a['sent_at'] as String).isBefore(b))
        .take(int.parse(query!['limit'] as String))
        .toList();
    return {'items': items, 'unread_count': 0};
  }

  @override
  Future<dynamic> post(String path, [Object? body]) async => null;
}

/// API giả trả dữ liệu tối thiểu cho AppData và thẻ báo cáo theo danh mục; đếm số lần gọi từng đường dẫn.
class _FakeDataApi extends ApiClient {
  _FakeDataApi() : super(TokenStore());
  final calls = <String>[];

  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    calls.add(path);
    return switch (path) {
      '/me' => {'id': 'u', 'full_name': 'Nguyễn An', 'email': 'an@vidu.vn', 'features': <String, dynamic>{}},
      '/wallets' => {'items': [], 'total_balance': 0},
      '/categories' => {'items': []},
      '/reports/overview' => {
          'month': {'income': 0, 'expense': 0, 'net': 0, 'change_percent': <String, dynamic>{}},
          'recent_transactions': [],
          'unread_alerts': 0,
        },
      '/budgets' => {'items': []},
      '/settings' => {'budget_alerts_enabled': true, 'smart_alerts_enabled': true},
      '/reports/categories' => {'from': '2026-11-01', 'to': '2026-11-03', 'type': 'expense', 'total': 0, 'items': [], 'other': null},
      _ => <String, dynamic>{},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('vi'));

  group('Định dạng tiền', () {
    test('vnd, vndShort, parseMoney', () {
      expect(vnd(1250000), '1.250.000đ');
      expect(vnd(-50000), '-50.000đ');
      expect(vnd(20000, sign: true), '+20.000đ');
      expect(vndShort(1250000), '1,3tr');
      expect(vndShort(50000), '50k');
      expect(parseMoney('1.250.000'), 1250000);
      expect(parseMoney('abc'), isNull);
    });

    test('ô nhập số tiền tự thêm dấu chấm', () {
      final f = MoneyInputFormatter();
      final v = f.formatEditUpdate(TextEditingValue.empty, const TextEditingValue(text: '1500000'));
      expect(v.text, '1.500.000');
    });

    test('số tiền rút gọn chọn đơn vị sau khi làm tròn; phần trăm dùng dấu phẩy', () {
      expect(vndShort(999400), '999k');
      expect(vndShort(999999), '1tr', reason: 'không hiện "1000k"');
      expect(vndShort(2000000), '2tr');
      expect(vndShort(2040000), '2tr', reason: 'không hiện "2,0tr"');
      expect(vndShort(999990000), '1 tỷ', reason: 'không hiện "1000,0tr"');
      expect(vndShort(1500000000), '1,5 tỷ');
      expect(vndShort(-50000), '-50k');
      expect(vndShort(0), '0');
      expect(fmtPercent(12.5), '12,5%');
      expect(fmtPercent(2.44), '2,4%');
    });

    test('chạm cột biểu đồ xu hướng: hiện mốc thời gian và số tiền đã định dạng', () {
      final item = {'date': '2026-11-03', 'income': 150000, 'expense': 320000};
      expect(trendTooltipText(item, 'day'), '03/11/2026\nThu: 150.000đ\nChi: 320.000đ');
      expect(trendTooltipText({...item, 'date': '2026-11-01'}, 'week'), startsWith('Tuần từ 01/11\n'));
      expect(trendTooltipText(item, 'month'), startsWith('Tháng 11/2026\n'));
    });
  });

  testWidgets('cảnh báo chi vượt số dư: thêm mới so với số dư ví, sửa thì không tính chính khoản đang sửa', (tester) async {
    final data = AppData(ApiClient(TokenStore()), SecureCache(Vault()));
    // Khoản chi 600.000đ đã lưu: ví từ 1.000.000đ còn 400.000đ.
    data.wallets = [
      Wallet.fromJson({'id': 'w1', 'name': 'Tiền mặt', 'type': 'cash', 'balance': 400000, 'is_archived': false, 'tx_count': 2}),
    ];
    data.categories = [
      TxCategory.fromJson(
          {'id': 'c1', 'name': 'Ăn uống', 'type': 'expense', 'icon': 'food', 'color': '#D9822B', 'is_default': true, 'is_hidden': false}),
    ];
    final orig = Tx.fromJson({
      'id': 't1', 'type': 'expense', 'amount': 600000, 'occurred_at': '2026-11-03T02:00:00Z',
      'wallet_id': 'w1', 'wallet_name': 'Tiền mặt', 'category_id': 'c1', 'category_name': 'Ăn uống',
    });
    TxDraft draft(int amount) =>
        TxDraft(type: 'expense', amount: amount, categoryId: 'c1', walletId: 'w1', occurredAt: DateTime(2026, 11, 3, 9));
    Future<void> show(TxEditor e) => tester.pumpWidget(ChangeNotifierProvider.value(
        value: data, child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: e)))));
    final warn = find.textContaining('lớn hơn số dư ví');

    await show(TxEditor(key: UniqueKey(), draft: draft(600000), original: orig));
    expect(warn, findsNothing, reason: 'mở sửa, chưa đổi gì: không báo vượt số dư');
    await show(TxEditor(key: UniqueKey(), draft: draft(1200000), original: orig));
    expect(warn, findsOneWidget, reason: 'sửa thành 1.200.000đ, nhiều hơn 1.000.000đ thì báo');
    await show(TxEditor(key: UniqueKey(), draft: draft(600000)));
    expect(warn, findsOneWidget, reason: 'thêm mới 600.000đ khi ví còn 400.000đ thì báo');
  });

  testWidgets('kéo để làm mới, quay lại app thì thẻ báo cáo tải lại; đổi giao dịch chỉ tải lại một lần', (tester) async {
    final api = _FakeDataApi();
    final data = AppData(api, SecureCache(Vault()));
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider.value(value: data)],
      child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: CategoryReportCard(compact: true)))),
    ));
    await tester.pumpAndSettle();
    int n() => api.calls.where((p) => p == '/reports/categories').length;
    expect(n(), 1);
    await data.loadAll(); // kéo để làm mới ở Tổng quan
    await tester.pumpAndSettle();
    expect(n(), 2, reason: 'kéo để làm mới');
    await data.refreshSummary(); // quay lại app từ nền
    await tester.pumpAndSettle();
    expect(n(), 3, reason: 'quay lại app');
    await data.afterTxChange();
    await tester.pumpAndSettle();
    expect(n(), 4, reason: 'đổi giao dịch: tải lại đúng một lần');
  });

  test('giới hạn độ dài ô nhập đếm giống server (emoji tính 2, không cắt đôi emoji)', () {
    const f = MaxLengthFormatter(5);
    TextEditingValue v(String t) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    expect(f.formatEditUpdate(v('abcd'), v('abcde')).text, 'abcde');
    expect(f.formatEditUpdate(v('abcde'), v('abcdef')).text, 'abcde', reason: 'đã đầy thì không nhận thêm');
    expect(f.formatEditUpdate(v(''), v('ab😀cd')).text, 'ab😀c');
    expect(f.formatEditUpdate(v(''), v('abcd😀')).text, 'abcd');
  });

  testWidgets('thông báo có nút "Hoàn tác" tự tắt sau vài giây', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showInfo(c, 'Đã xóa 2 giao dịch', action: SnackBarAction(label: 'Hoàn tác', onPressed: () {})),
            child: const Text('xóa'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('xóa'));
    await tester.pumpAndSettle();
    expect(find.text('Hoàn tác'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Đã xóa 2 giao dịch'), findsNothing);
  });

  testWidgets('màn Cảnh báo: tải thêm cảnh báo cũ hơn; mở một cảnh báo xong vẫn giữ danh sách và chỗ đang xem',
      (tester) async {
    final api = _FakeAlertsApi();
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider(create: (_) => AppData(api, SecureCache(Vault()))),
      ],
      child: const MaterialApp(home: AlertsScreen()),
    ));
    await tester.pumpAndSettle();
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Xem cảnh báo cũ hơn'), 500, scrollable: list);
    await tester.tap(find.text('Xem cảnh báo cũ hơn'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Cảnh báo số 55'), 300, scrollable: list);
    expect(find.text('Xem cảnh báo cũ hơn'), findsNothing, reason: 'đã hết cảnh báo');
    await tester.tap(find.text('Cảnh báo số 55'));
    await tester.pumpAndSettle();
    expect(find.text('Cảnh báo số 55'), findsOneWidget, reason: 'tải lại vẫn giữ đủ 60 cảnh báo và chỗ đang xem');
    expect(api.calls.length, 4, reason: 'trang đầu, tải thêm, rồi tải lại đủ 2 trang');
  });

  test('quy tắc mật khẩu giống server', () {
    expect(passwordRule('abc'), isNotNull);
    expect(passwordRule('abcdefgh'), isNotNull);
    expect(passwordRule('12345678'), isNotNull);
    expect(passwordRule('matkhau123'), isNull);
  });

  test('chế độ ẩn số tiền che số tiền trong thẻ gợi ý, giữ phần trăm và ngày', () {
    expect(maskMoneyText('Kỳ này bạn đã chi 1.250.000đ, tháng trước 980.000đ.'), 'Kỳ này bạn đã chi ••••••, tháng trước ••••••.');
    expect(maskMoneyText('Đặt hạn mức 900.000đ/tháng, tiết kiệm khoảng 1,2 triệu hoặc 50k'),
        'Đặt hạn mức ••••••/tháng, tiết kiệm khoảng •••••• hoặc ••••••');
    const keep = 'Chi Ăn uống tăng 25% so với cùng kỳ; Thứ Hai chiếm 35%, 5 khoản, ngày 22/11, 3 đêm';
    expect(maskMoneyText(keep), keep);
  });

  test('đọc JSON giao dịch và bản nháp AI', () {
    final t = Tx.fromJson({
      'id': 'a', 'type': 'expense', 'amount': 50000, 'occurred_at': '2026-10-30T05:00:00Z', 'note': 'Phở',
      'wallet_id': 'w', 'wallet_name': 'Tiền mặt', 'category_id': 'c', 'category_name': 'Ăn uống',
      'attachment_count': 2, 'source': 'ai',
    });
    expect(t.signed, -50000);
    expect(t.title, 'Phở');
    final d1 = TxDraft(), d2 = TxDraft();
    expect(d1.key, isNot(d2.key), reason: 'mỗi bản nháp có mã chống gửi trùng riêng');
    final d = TxDraft.fromJson({'type': 'income', 'amount': 15000000, 'category_id': null, 'occurred_at': '2026-10-29T05:00:00Z'});
    expect(d.categoryId, isNull);
    expect(d.amount, 15000000);
  });

  test('PBKDF2 tự viết cho kết quả giống chuẩn (tương thích PIN đã lưu)', () async {
    final salt = List<int>.generate(16, (i) => i * 7);
    final mine = pbkdf2Sha256([utf8.encode('135792'), salt, 1000]);
    final ref = await (await cg.Pbkdf2(macAlgorithm: cg.Hmac.sha256(), iterations: 1000, bits: 256)
            .deriveKey(secretKey: cg.SecretKey(utf8.encode('135792')), nonce: salt))
        .extractBytes();
    expect(mine, ref);
  });

  group('Vault (khóa ứng dụng)', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('PIN bọc khóa dữ liệu; sai PIN bị đếm; đúng PIN giải mã được dữ liệu cũ', () async {
      final v = Vault();
      await v.setPin('135792');
      final enc = await v.encrypt(utf8.encode('dữ liệu bí mật'));
      v.lock();
      expect(v.isUnlocked, false);
      expect(() => v.encrypt([1]), throwsStateError);
      expect(await v.unlockWithPin('000000'), false);
      expect(await v.failedAttempts(), 1);
      expect(await v.unlockWithPin('135792'), true);
      expect(await v.failedAttempts(), 0);
      expect(utf8.decode(await v.decrypt(enc)), 'dữ liệu bí mật');
      // Không lưu PIN dạng thô.
      final all = await const FlutterSecureStorage().readAll();
      expect(all.values.any((x) => x.contains('135792')), false);
    });

    test('đổi PIN giữ nguyên khóa dữ liệu; đăng xuất xóa sạch', () async {
      final v = Vault();
      await v.setPin('135792');
      final enc = await v.encrypt([1, 2, 3]);
      await v.setPin('246801');
      v.lock();
      expect(await v.unlockWithPin('135792'), false);
      expect(await v.unlockWithPin('246801'), true);
      expect(await v.decrypt(enc), [1, 2, 3]);
      await v.wipe();
      expect(await v.hasPin(), false);
      expect(v.isUnlocked, false);
    });
  });

  test('chuẩn bị ảnh: thu nhỏ 1600px, cắt khung vuông, xóa EXIF', () async {
    final src = img.Image(width: 3200, height: 2400);
    img.fill(src, color: img.ColorRgb8(120, 200, 80));
    src.exif.imageIfd['Make'] = 'MayAnh';
    src.exif.gpsIfd['GPSLatitude'] = 21.03;
    final out = await prepareImage(img.encodeJpg(src), aspect: 1);
    final d = img.decodeJpg(out!)!;
    expect(d.width, 1600);
    expect(d.height, 1600);
    expect(d.exif.imageIfd['Make'], isNull);
    expect(d.exif.gpsIfd.isEmpty, true);
    expect(await prepareImage(Uint8List.fromList([1, 2, 3])), isNull, reason: 'tệp không phải ảnh bị từ chối');
  });

  testWidgets('bàn phím PIN nhập đủ 6 số', (tester) async {
    var value = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (c, set) => PinPad(value: value, onChanged: (v) => set(() => value = v)),
        ),
      ),
    ));
    for (final d in ['1', '3', '5', '7', '9', '2', '4']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    expect(value, '135792', reason: 'không nhận quá 6 số');
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
    expect(value, '13579');
  });
}
