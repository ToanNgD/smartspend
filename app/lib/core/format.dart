import 'package:intl/intl.dart';

final _money = NumberFormat.decimalPattern('vi');

/// Số tiền lớn nhất của một giao dịch, hạn mức ngân sách hay số dư nhập vào: 10 tỷ đồng (khớp giới hạn của server).
const maxMoney = 10000000000;

/// 1250000 -> "1.250.000đ"
String vnd(num v, {bool sign = false}) {
  final s = _money.format(v.abs());
  final prefix = v < 0 ? '-' : (sign && v > 0 ? '+' : '');
  return '$prefix$sđ';
}

/// Rút gọn cho biểu đồ: 1.250.000 -> "1,3tr", 50.000 -> "50k", 2.040.000 -> "2tr".
/// Chọn đơn vị theo giá trị SAU khi làm tròn, để 999.999 thành "1tr" (không phải "1000k")
/// và 999.990.000 thành "1 tỷ" (không phải "1000,0tr").
String vndShort(num v) {
  final a = v.abs();
  // Một chữ số thập phân, bỏ ",0" thừa: 2.0 -> "2", 1.25 -> "1,3".
  String one(double x) {
    final t = x.toStringAsFixed(1);
    return (t.endsWith('.0') ? t.substring(0, t.length - 2) : t).replaceAll('.', ',');
  }

  final String s;
  if (a < 999.5) {
    s = a.toStringAsFixed(0);
  } else if (a < 999500) {
    s = '${(a / 1000).round()}k';
  } else if (a < 999950000) {
    s = '${one(a / 1000000)}tr';
  } else {
    s = '${one(a / 1000000000)} tỷ';
  }
  return (v < 0 ? '-' : '') + s;
}

/// Phần trăm theo cách viết tiếng Việt: 12.5 -> "12,5%" (dấu phẩy thập phân, giống "1,3tr").
String fmtPercent(num v, {int digits = 1}) => '${v.toStringAsFixed(digits).replaceAll('.', ',')}%';

const hiddenMoney = '••••••';

final _dayFmt = DateFormat('dd/MM/yyyy');
final _timeFmt = DateFormat('HH:mm');
const _weekdays = ['Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy', 'Chủ Nhật'];

String fmtDate(DateTime d) => _dayFmt.format(d.toLocal());
String fmtTime(DateTime d) => _timeFmt.format(d.toLocal());
String fmtDateTime(DateTime d) => '${fmtTime(d)} · ${fmtDate(d)}';
String fmtDayMonth(DateTime d) => _dayMonthFmt.format(d.toLocal());
final _dayMonthFmt = DateFormat('dd/MM');

/// "Hôm nay", "Hôm qua", "Thứ Tư, 28/10/2026"
String dayHeader(DateTime d) {
  final l = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(l.year, l.month, l.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hôm nay';
  if (diff == 1) return 'Hôm qua';
  return '${_weekdays[l.weekday - 1]}, ${_dayFmt.format(l)}';
}

String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// Phân tích số tiền người dùng gõ: "50.000" hoặc "50000" -> 50000
int? parseMoney(String s) {
  final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}
