// Tiện ích xử lý tiếng Việt cho bộ phân tích dự phòng (không cần AI).

const _src = 'àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ';
const _dst = 'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';

/// Bỏ dấu và chuyển chữ thường: "Cà Phê" -> "ca phe".
String fold(String s) {
  final lower = s.toLowerCase();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    final i = _src.indexOf(ch);
    b.write(i >= 0 ? _dst[i] : ch);
  }
  return b.toString();
}

/// Định dạng tiền: 1250000 -> "1.250.000đ".
String vnd(int n) {
  final neg = n < 0;
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${neg ? '-' : ''}$bđ';
}

class AmountMatch {
  final int start;
  final int end;
  final int amount;
  AmountMatch(this.start, this.end, this.amount);
}

class _Tagged extends AmountMatch {
  final bool explicit;
  _Tagged(super.start, super.end, super.amount, this.explicit);
}

// Số (có thể có dấu phân cách) + đơn vị tùy chọn + phần lẻ kiểu "2tr5" + "rưỡi".
final _amountRe = RegExp(
  r'(?<![\p{L}\d])(\d+(?:[.,]\d+)*)\s*'
  r'(k|K|nghìn|ngàn|nghin|ngan|tr|triệu|trieu|củ|cu|m|M|đồng|dong|đ|vnđ|vnd)?'
  r'(?![\p{L}])(?:\s*(\d{1,3})(?![\p{L}\d]))?(\s*(?:rưỡi|ruoi))?',
  unicode: true,
);

/// Tìm mọi số tiền trong câu, hiểu 50k, 2tr, 2tr5, 1 củ, 3 triệu rưỡi, 200.000đ.
List<AmountMatch> findAmounts(String text) {
  final out = <AmountMatch>[];
  for (final m in _amountRe.allMatches(text)) {
    final raw = m.group(1)!;
    final unit = fold(m.group(2) ?? '');
    final tail = m.group(3);
    final half = m.group(4) != null;
    double base;
    if (RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(raw) && (unit.isEmpty || unit.startsWith('d') || unit == 'vnd')) {
      base = double.parse(raw.replaceAll(RegExp(r'[.,]'), ''));
    } else {
      final v = double.tryParse(raw.replaceAll(',', '.'));
      if (v == null) continue;
      base = v;
    }
    int mult;
    switch (unit) {
      case 'k':
      case 'nghin':
      case 'ngan':
        mult = 1000;
      case 'tr':
      case 'trieu':
      case 'cu':
      case 'm':
        mult = 1000000;
      case 'dong':
      case 'd':
      case 'vnd':
        mult = 1;
      default:
        // Không có đơn vị: số nhỏ hơn 1000 hiểu là nghìn ("phở 50" = 50.000đ).
        mult = base < 1000 ? 1000 : 1;
    }
    // Số lẻ sau đơn vị chỉ có nghĩa với triệu/nghìn: 2tr5 = 2.500.000, 1tr250 = 1.250.000.
    if (tail != null && unit.isEmpty) {
      continue; // "12 3" không phải số tiền rõ ràng
    }
    var amount = base * mult;
    if (tail != null && mult >= 1000) {
      final t = int.parse(tail);
      final scale = mult ~/ (tail.length == 1 ? 10 : (tail.length == 2 ? 100 : 1000));
      amount += t * scale;
    }
    if (half && mult >= 1000) amount += mult / 2;
    final n = amount.round();
    if (n <= 0) continue;
    out.add(_Tagged(m.start, m.end, n, unit.isNotEmpty || base >= 1000));
  }
  // Có số tiền ghi rõ đơn vị thì bỏ các số nhỏ không đơn vị ("mua 2 cái áo 300k").
  final hasExplicit = out.any((a) => (a as _Tagged).explicit);
  return hasExplicit ? out.where((a) => (a as _Tagged).explicit).toList() : out;
}

/// Từ khóa -> tên danh mục mặc định (so khớp sau khi bỏ dấu).
const categoryKeywords = <String, List<String>>{
  'Ăn uống': [
    'an', 'com', 'pho', 'bun', 'banh mi', 'banh', 'ca phe', 'cafe', 'cf', 'tra sua', 'tra', 'nuoc',
    'an sang', 'an trua', 'an toi', 'lau', 'nuong', 'do an', 'hu tieu', 'mi', 'chao', 'xoi', 'kem',
    'bia', 'ruou', 'sinh to', 'an vat', 'nha hang', 'quan', 'cho', 'sieu thi', 'rau', 'thit', 'ca'
  ],
  'Đi lại': ['xang', 'grab', 'be', 'taxi', 'xe', 'gui xe', 've xe', 'bus', 'xe buyt', 'tau', 'may bay', 've may bay', 'sua xe', 'rua xe', 'gojek', 'xanh sm'],
  'Mua sắm': ['mua', 'quan ao', 'ao', 'giay', 'dep', 'tui', 'shopee', 'lazada', 'tiki', 'my pham', 'dien thoai', 'tai nghe', 'do dung'],
  'Hóa đơn': ['dien', 'tien dien', 'tien nuoc', 'internet', 'wifi', 'mang', 'cuoc', 'dien thoai tra sau', 'nap the', 'gas', 'hoa don'],
  'Nhà ở': ['nha', 'tien nha', 'thue nha', 'tro', 'tien tro', 'phong'],
  'Giải trí': ['phim', 'xem phim', 'game', 'karaoke', 'du lich', 'netflix', 'spotify', 'choi', 've concert', 'concert'],
  'Sức khỏe': ['thuoc', 'kham', 'benh vien', 'nha thuoc', 'gym', 'tap', 'bao hiem', 'nha khoa'],
  'Học tập': ['sach', 'hoc', 'hoc phi', 'khoa hoc', 'vo', 'but', 'tai lieu', 'photo', 'in'],
  'Lương': ['luong', 'nhan luong'],
  'Thưởng': ['thuong', 'tien thuong', 'bonus'],
};

final incomeWords = RegExp(
    r'(^|\s)(luong|thuong|duoc cho|duoc tang|nhan|thu nhap|ban duoc|ban|lai|hoan tien|tien ve|me cho|bo cho|li xi|lixi)(\s|$)');

/// Điểm khớp từ khóa: ưu tiên cụm dài hơn.
String? guessCategory(String foldedText, String type) {
  String? best;
  var bestLen = 0;
  categoryKeywords.forEach((cat, words) {
    final isIncome = cat == 'Lương' || cat == 'Thưởng';
    if ((type == 'income') != isIncome) return;
    for (final w in words) {
      if (RegExp('(^|\\s)${RegExp.escape(w)}(\\s|\$)').hasMatch(foldedText) && w.length > bestLen) {
        best = cat;
        bestLen = w.length;
      }
    }
  });
  return best;
}
