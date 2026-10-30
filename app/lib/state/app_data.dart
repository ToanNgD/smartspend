
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/api_client.dart';
import '../core/secure_cache.dart';
import '../models/models.dart';

/// Dữ liệu dùng chung giữa các màn hình: ví, danh mục, tổng quan, ngân sách, cài đặt.
/// Bản sao gần nhất được lưu vào bộ nhớ đệm đã mã hóa để mở app khi mất mạng vẫn xem được.
class AppData extends ChangeNotifier {
  final ApiClient api;
  final SecureCache cache;
  AppData(this.api, this.cache);

  Map<String, dynamic>? me;
  List<Wallet> wallets = [];
  int totalBalance = 0;
  List<TxCategory> categories = [];
  Map<String, dynamic>? overview;
  List<Budget> budgets = [];
  Map<String, dynamic> settings = {};
  int unreadAlerts = 0;
  bool offline = false;
  bool loading = false;
  bool hideAmounts = false;
  /// Tăng mỗi khi giao dịch thay đổi để các màn hình danh sách tự tải lại.
  int txVersion = 0;

  void toggleHide() {
    hideAmounts = !hideAmounts;
    notifyListeners();
  }

  List<Wallet> get activeWallets => wallets.where((w) => !w.isArchived).toList();
  Wallet? walletById(String? id) => wallets.where((w) => w.id == id).firstOrNull;
  TxCategory? categoryById(String? id) => categories.where((c) => c.id == id).firstOrNull;
  List<TxCategory> visibleCategories(String type) =>
      categories.where((c) => c.type == type && !c.isHidden).toList();

  Future<void> loadAll() async {
    loading = true;
    notifyListeners();
    try {
      final r = await Future.wait([
        api.get('/me'),
        api.get('/wallets'),
        api.get('/categories', query: {'include_hidden': 'true'}),
        api.get('/reports/overview'),
        api.get('/budgets'),
        api.get('/settings'),
      ]);
      _apply(r[0], r[1], r[2], r[3], r[4], r[5]);
      offline = false;
      await cache.putJson('app_data', r);
    } on ApiException catch (e) {
      if (e.code == 'offline') {
        final c = await cache.getJson('app_data');
        if (c is List && c.length == 6) _apply(c[0], c[1], c[2], c[3], c[4], c[5]);
        offline = true;
      } else {
        rethrow;
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _apply(dynamic meJ, dynamic w, dynamic c, dynamic o, dynamic b, dynamic s) {
    me = Map<String, dynamic>.from(meJ);
    wallets = (w['items'] as List).map((e) => Wallet.fromJson(e)).toList();
    totalBalance = (w['total_balance'] as num).toInt();
    categories = (c['items'] as List).map((e) => TxCategory.fromJson(e)).toList();
    overview = Map<String, dynamic>.from(o);
    unreadAlerts = (o['unread_alerts'] as num?)?.toInt() ?? 0;
    budgets = (b['items'] as List).map((e) => Budget.fromJson(e)).toList();
    settings = Map<String, dynamic>.from(s);
  }

  /// Gọi sau mỗi thay đổi giao dịch: số dư, tổng quan và ngân sách do server tính lại.
  Future<void> afterTxChange() async {
    txVersion++;
    try {
      final r = await Future.wait([api.get('/wallets'), api.get('/reports/overview'), api.get('/budgets')]);
      wallets = (r[0]['items'] as List).map((e) => Wallet.fromJson(e)).toList();
      totalBalance = (r[0]['total_balance'] as num).toInt();
      overview = Map<String, dynamic>.from(r[1]);
      unreadAlerts = (r[1]['unread_alerts'] as num?)?.toInt() ?? 0;
      budgets = (r[2]['items'] as List).map((e) => Budget.fromJson(e)).toList();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> reloadWallets() async {
    final w = await api.get('/wallets');
    wallets = (w['items'] as List).map((e) => Wallet.fromJson(e)).toList();
    totalBalance = (w['total_balance'] as num).toInt();
    notifyListeners();
  }

  Future<void> reloadCategories() async {
    final c = await api.get('/categories', query: {'include_hidden': 'true'});
    categories = (c['items'] as List).map((e) => TxCategory.fromJson(e)).toList();
    notifyListeners();
  }

  Future<void> reloadBudgets() async {
    final b = await api.get('/budgets');
    budgets = (b['items'] as List).map((e) => Budget.fromJson(e)).toList();
    notifyListeners();
  }

  Future<void> updateSettings(Map<String, dynamic> patch) async {
    settings = Map<String, dynamic>.from(await api.patch('/settings', patch));
    notifyListeners();
  }

  void setUnread(int n) {
    unreadAlerts = n;
    notifyListeners();
  }

  void clear() {
    me = null;
    wallets = [];
    categories = [];
    overview = null;
    budgets = [];
    settings = {};
    unreadAlerts = 0;
    hideAmounts = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------- giao dịch
  /// Lưu giao dịch (4.1) rồi tải ảnh lên sau khi lưu thành công.
  /// Trả về (giao dịch, danh sách cảnh báo, số ảnh chưa tải lên được).
  Future<(Tx, List<String>, int)> createTx(TxDraft d, {String source = 'manual', List<Uint8List> images = const []}) async {
    final r = await api.post('/transactions', {
      'idempotency_key': d.idempotencyKey,
      'type': d.type,
      'amount': d.amount,
      'category_id': d.categoryId,
      'wallet_id': d.walletId,
      'occurred_at': d.occurredAt.toUtc().toIso8601String(),
      if (d.note != null && d.note!.trim().isNotEmpty) 'note': d.note!.trim(),
      'source': source,
    });
    final tx = Tx.fromJson(r);
    final failed = await uploadImages(tx.id, images);
    await afterTxChange();
    return (tx, ((r['warnings'] as List?) ?? []).cast<String>(), failed);
  }

  /// Tải từng ảnh lên; ảnh lỗi mạng được giữ (đã mã hóa) để thử lại - trạng thái "Chưa tải lên".
  Future<int> uploadImages(String txId, List<Uint8List> images) async {
    var failed = 0;
    for (final img in images) {
      try {
        await api.uploadBytes('/transactions/$txId/attachments', img);
      } on ApiException catch (e) {
        if (e.code == 'offline' || e.status >= 500) {
          await _savePending(txId, img);
          failed++;
        } else {
          rethrow;
        }
      }
    }
    return failed;
  }

  Future<void> _savePending(String txId, Uint8List img) async {
    final key = 'pending:$txId:${const Uuid().v4()}';
    await cache.putBytes(key, img);
    final idx = ((await cache.getJson('pending_index')) as List?)?.cast<String>() ?? [];
    idx.add(key);
    await cache.putJson('pending_index', idx);
  }

  Future<List<String>> pendingKeys(String txId) async {
    final idx = ((await cache.getJson('pending_index')) as List?)?.cast<String>() ?? [];
    return idx.where((k) => k.startsWith('pending:$txId:')).toList();
  }

  Future<Uint8List?> pendingImage(String key) => cache.getBytes(key);

  /// Thử tải lại các ảnh chưa tải lên của một giao dịch. Trả về số ảnh còn lỗi.
  Future<int> retryPending(String txId) async {
    final idx = ((await cache.getJson('pending_index')) as List?)?.cast<String>() ?? [];
    var left = 0;
    for (final key in idx.where((k) => k.startsWith('pending:$txId:')).toList()) {
      final img = await cache.getBytes(key);
      if (img == null) {
        idx.remove(key);
        continue;
      }
      try {
        await api.uploadBytes('/transactions/$txId/attachments', img);
        idx.remove(key);
        await cache.remove(key);
      } on ApiException catch (e) {
        if (e.code == 'offline' || e.status >= 500) {
          left++;
        } else {
          idx.remove(key);
          await cache.remove(key);
        }
      }
    }
    await cache.putJson('pending_index', idx);
    return left;
  }

  Future<void> discardPending(String key) async {
    final idx = ((await cache.getJson('pending_index')) as List?)?.cast<String>() ?? [];
    idx.remove(key);
    await cache.remove(key);
    await cache.putJson('pending_index', idx);
  }
}

extension on TxDraft {
  String get idempotencyKey => key;
}
