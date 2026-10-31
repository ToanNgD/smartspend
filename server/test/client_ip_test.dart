import 'package:smartspend_server/src/core/middleware.dart';
import 'package:test/test.dart';

/// Kiểm thử cách lấy IP thật khi chạy sau Cloudflare + proxy của Render (không cần chạy server).
void main() {
  const remote = '10.0.0.5';

  test('Không tin proxy: bỏ qua mọi header', () {
    expect(resolveClientIp({'cf-connecting-ip': '1.2.3.4', 'x-forwarded-for': '5.6.7.8'}, remote, trustProxy: false), remote);
  });

  test('Ưu tiên CF-Connecting-IP / True-Client-IP do Cloudflare ghi', () {
    expect(resolveClientIp({'cf-connecting-ip': '1.2.3.4', 'x-forwarded-for': '9.9.9.9, 1.2.3.4, 104.22.17.40'}, remote, trustProxy: true), '1.2.3.4');
    expect(resolveClientIp({'true-client-ip': '2001:db8::1'}, remote, trustProxy: true), '2001:db8::1');
  });

  test('Không có header Cloudflare: lấy phần tử áp chót của X-Forwarded-For, không lấy IP Cloudflare ở cuối', () {
    expect(resolveClientIp({'x-forwarded-for': '99.61.165.29, 104.22.17.40'}, remote, trustProxy: true), '99.61.165.29');
  });

  test('Client tự chèn IP giả vào đầu X-Forwarded-For không lách được', () {
    expect(resolveClientIp({'x-forwarded-for': '6.6.6.6, 99.61.165.29, 104.22.17.40'}, remote, trustProxy: true), '99.61.165.29');
  });

  test('Header rác hoặc rỗng: dùng IP kết nối', () {
    expect(resolveClientIp({'cf-connecting-ip': 'abc', 'x-forwarded-for': ' , '}, remote, trustProxy: true), remote);
    expect(resolveClientIp({}, remote, trustProxy: true), remote);
    expect(resolveClientIp({'x-forwarded-for': '7.7.7.7'}, remote, trustProxy: true), '7.7.7.7');
  });
}
