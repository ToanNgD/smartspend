import 'package:smartspend_server/src/services/ai_service.dart';
import 'package:test/test.dart';

/// UC13: kiểm tra câu cảnh báo do AI viết trước khi dùng (không cần server, không gọi AI thật).
void main() {
  ({String title, String body})? check(String title, String body, {String name = 'Ăn uống', String? day}) =>
      AiService.checkPhrase({'title': title, 'body': body}, name: name, mustContain: day);

  test('Câu hợp lệ được dùng', () {
    final r = check('Sắp vượt ngân sách', 'Ngân sách Ăn uống có thể vượt vào ngày 22/10, bạn thử chậm lại chút nhé', day: '22/10');
    expect(r, isNotNull);
    expect(check('Chi tiêu khác thường', 'Khoản ăn uống vừa rồi cao gấp 4,5 lần thường lệ, có phải bạn đãi bạn bè?'), isNotNull);
  });

  test('Có số tiền thì bỏ (thông báo hiện trên màn hình khóa)', () {
    for (final b in [
      'Ngân sách Ăn uống đã chi 1.500.000, sắp vượt',
      'Ăn uống vừa chi 300k, cao bất thường',
      'Ăn uống: 2 triệu rồi đó',
      'Ăn uống tốn 50.000đ',
      'Ăn uống đã chi 120 nghìn',
    ]) {
      expect(check('Cảnh báo', b), isNull, reason: b);
    }
  });

  test('Không nhầm ngày, phần trăm, số lần là số tiền', () {
    expect(check('Dự báo', 'Ăn uống đã dùng 85%, có thể vượt vào ngày 22/10 đó', day: '22/10'), isNotNull);
    expect(check('Lưu ý', 'Có 3 khoản Ăn uống cao gấp 3 lần thường lệ'), isNotNull);
  });

  test('Sai tên, sai ngày, quá dài hoặc có HTML thì bỏ', () {
    expect(check('Dự báo', 'Ngân sách Mua sắm có thể vượt vào ngày 22/10', day: '22/10'), isNull);
    expect(check('Dự báo', 'Ngân sách Ăn uống có thể vượt vào ngày 25/10', day: '22/10'), isNull);
    expect(check('Dự báo', 'Ăn uống ${'rất ' * 50}nhiều'), isNull);
    expect(check('<b>Dự báo</b>', 'Ăn uống sắp vượt'), isNull);
    expect(check('', 'Ăn uống sắp vượt'), isNull);
  });

  test('So tên không phân biệt dấu/hoa thường', () {
    expect(check('Lưu ý', 'Khoản ĂN UỐNG hôm nay cao hơn thường lệ'), isNotNull);
  });
}
