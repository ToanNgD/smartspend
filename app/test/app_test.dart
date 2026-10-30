import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:intl/date_symbol_data_local.dart';
import 'package:smartspend/core/format.dart';
import 'package:smartspend/core/images.dart';
import 'package:smartspend/core/vault.dart';
import 'package:smartspend/models/models.dart';
import 'package:smartspend/screens/auth_screens.dart';
import 'package:smartspend/screens/lock_screens.dart';
import 'package:smartspend/widgets/tx_editor.dart';

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
  });

  test('quy tắc mật khẩu giống server', () {
    expect(passwordRule('abc'), isNotNull);
    expect(passwordRule('abcdefgh'), isNotNull);
    expect(passwordRule('12345678'), isNotNull);
    expect(passwordRule('matkhau123'), isNull);
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
