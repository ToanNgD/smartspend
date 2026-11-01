import 'package:intl/intl.dart';

final _money = NumberFormat.decimalPattern('vi');

/// 1250000 -> "1.250.000đ"
String vnd(num v, {bool sign = false}) {
  final s = _money.format(v.abs());
  final prefix = v < 0 ? '-' : (sign && v > 0 ? '+' : '');
  return '$prefix$sđ';
}

/// Rút gọn cho biểu đồ: 1.250.000 -> "1,3tr", 50.000 -> "50k"
String vndShort(num v) {
  final a = v.abs();
  String s;
  if (a >= 1000000000) {
    s = '${(a / 1000000000).toStringAsFixed(a % 1000000000 == 0 ? 0 : 1)} tỷ';
  } else if (a >= 1000000) {
    s = '${(a / 1000000).toStringAsFixed(a % 1000000 == 0 ? 0 : 1)}tr';
  } else if (a >= 1000) {
    s = '${(a / 1000).round()}k';
  } else {
    s = a.toStringAsFixed(0);
  }
  return (v < 0 ? '-' : '') + s.replaceAll('.', ',');
}

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
