import 'package:uuid/uuid.dart';

/// Các mô hình dữ liệu khớp với JSON trả về từ server.
String _uuid() => const Uuid().v4();
DateTime _dt(Object? v) => DateTime.parse(v as String).toLocal();
DateTime? _dtn(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
int _int(Object? v) => (v as num?)?.toInt() ?? 0;

class Wallet {
  final String id, name, type;
  final int balance;
  final bool isArchived;
  final int txCount;
  Wallet.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        type = j['type'],
        balance = _int(j['balance']),
        isArchived = j['is_archived'] == true,
        txCount = _int(j['tx_count']);

  String get typeLabel => const {'cash': 'Tiền mặt', 'bank': 'Ngân hàng', 'ewallet': 'Ví điện tử'}[type] ?? type;
}

class TxCategory {
  final String id, name, type, icon, color;
  final bool isDefault, isHidden;
  final int txCount;
  TxCategory.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        type = j['type'],
        icon = j['icon'] ?? 'dots',
        color = j['color'] ?? '#8B9590',
        isDefault = j['is_default'] == true,
        isHidden = j['is_hidden'] == true,
        txCount = _int(j['tx_count']);
}

class Attachment {
  final String id;
  final int? width, height;
  Attachment.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        width = (j['width'] as num?)?.toInt(),
        height = (j['height'] as num?)?.toInt();
}

class Tx {
  final String id, type, source, walletId, walletName, categoryId, categoryName, categoryIcon, categoryColor;
  final int amount, attachmentCount;
  final DateTime occurredAt;
  final String? note;
  final List<Attachment> attachments;
  Tx.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        type = j['type'],
        source = j['source'] ?? 'manual',
        amount = _int(j['amount']),
        occurredAt = _dt(j['occurred_at']),
        note = j['note'],
        walletId = j['wallet_id'],
        walletName = j['wallet_name'] ?? '',
        categoryId = j['category_id'],
        categoryName = j['category_name'] ?? '',
        categoryIcon = j['category_icon'] ?? 'dots',
        categoryColor = j['category_color'] ?? '#8B9590',
        attachmentCount = _int(j['attachment_count']),
        attachments = ((j['attachments'] as List?) ?? []).map((e) => Attachment.fromJson(e)).toList();

  bool get isIncome => type == 'income';
  int get signed => isIncome ? amount : -amount;
  String get title => (note?.isNotEmpty ?? false) ? note! : categoryName;
}

class Budget {
  final String id, name, period, scope, status;
  final int limit, spent, remaining, daysLeft, dailyAllowance;
  final double percent;
  final List<String> categoryIds;
  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic> raw;
  Budget.fromJson(Map<String, dynamic> j)
      : raw = j,
        id = j['id'],
        name = j['name'],
        period = j['period'],
        scope = j['scope'],
        status = j['status'] ?? 'green',
        limit = _int(j['amount_limit']),
        spent = _int(j['spent']),
        remaining = _int(j['remaining']),
        daysLeft = _int(j['days_left']),
        dailyAllowance = _int(j['daily_allowance']),
        percent = (j['percent'] as num?)?.toDouble() ?? 0,
        categoryIds = ((j['category_ids'] as List?) ?? []).cast<String>(),
        categories = ((j['categories'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e)).toList();

  String get periodLabel => period == 'week' ? 'Tuần này' : 'Tháng này';
}

class AlertItem {
  final String id, type, title, body;
  final String? budgetId, transactionId, feedback;
  final DateTime sentAt;
  final DateTime? readAt;
  AlertItem.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        type = j['type'],
        title = j['title'],
        body = j['body'],
        budgetId = j['budget_id'],
        transactionId = j['transaction_id'],
        feedback = j['feedback'],
        sentAt = _dt(j['sent_at']),
        readAt = _dtn(j['read_at']);
}

class Insight {
  final String id, kind, title, content, status;
  final Map<String, dynamic>? action;
  final DateTime createdAt;
  Insight.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        kind = j['kind'],
        title = j['title'],
        content = j['content'],
        status = j['status'] ?? 'new',
        action = j['action'] == null ? null : Map<String, dynamic>.from(j['action']),
        createdAt = _dt(j['created_at']);
}

/// Bản xem trước do AI (hoặc bộ phân tích dự phòng) trả về - chưa lưu.
class TxDraft {
  /// Mã chống gửi trùng: tạo một lần cho mỗi bản nháp, bấm lưu nhiều lần vẫn cùng mã.
  final String key = _uuid();
  String type;
  int? amount;
  String? categoryId, walletId, note;
  DateTime occurredAt;
  TxDraft({this.type = 'expense', this.amount, this.categoryId, this.walletId, this.note, DateTime? occurredAt})
      : occurredAt = occurredAt ?? DateTime.now();
  factory TxDraft.fromJson(Map<String, dynamic> j) => TxDraft(
        type: j['type'] ?? 'expense',
        amount: (j['amount'] as num?)?.toInt(),
        categoryId: j['category_id'],
        walletId: j['wallet_id'],
        note: j['note'],
        occurredAt: j['occurred_at'] == null ? null : _dt(j['occurred_at']),
      );
}
