import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/secure_image.dart';
import '../widgets/top_actions.dart';
import '../widgets/tx_tile.dart';
import 'camera_screen.dart';
import 'tx_form_screen.dart';

/// 4.3 Danh sách giao dịch: nhóm theo ngày (tổng thu/chi mỗi ngày), tìm kiếm không dấu,
/// lọc theo ngày/loại/danh mục/ví, tải thêm khi cuộn; giữ để chọn nhiều và xóa.
class TransactionsScreen extends StatefulWidget {
  final String? initialCategoryId;
  final String? initialWalletId;
  /// Lọc sẵn loại (income/expense) và khoảng ngày - dùng khi mở từ báo cáo để chỉ hiện giao dịch cấu thành.
  final String? initialType;
  final DateTimeRange? initialRange;
  final String? title;
  final bool standalone;
  /// Màn hình giao dịch của một ví / một danh mục (tiêu đề là tên ví, tên danh mục): bộ lọc không cho đổi
  /// hay bỏ điều kiện đó, để danh sách luôn khớp tiêu đề.
  final bool fixedWallet;
  final bool fixedCategory;
  const TransactionsScreen(
      {super.key,
      this.initialCategoryId,
      this.initialWalletId,
      this.initialType,
      this.initialRange,
      this.title,
      this.standalone = false,
      this.fixedWallet = false,
      this.fixedCategory = false});
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

/// Giao dịch hệ thống (số dư ban đầu, điều chỉnh số dư) không sửa, không xóa được (4.2).
const systemTxHint = 'Giao dịch hệ thống không sửa hay xóa được. Muốn đổi số dư, hãy dùng "Điều chỉnh số dư" '
    'trong Cài đặt → Ví.';

class _Filter {
  String? type, categoryId, walletId;
  DateTimeRange? range;
  bool fixedWallet = false, fixedCategory = false;
  /// Có điều kiện lọc do người dùng chọn (không tính điều kiện cố định của màn hình).
  bool get active =>
      (!fixedCategory && (type != null || categoryId != null)) || (!fixedWallet && walletId != null) || range != null;

  /// "Bỏ lọc": giữ lại điều kiện cố định của màn hình.
  void clear() {
    if (!fixedCategory) type = categoryId = null;
    if (!fixedWallet) walletId = null;
    range = null;
  }
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _filter = _Filter();
  final List<Tx> _items = [];
  final Set<String> _selected = {};
  Map<String, dynamic>? _totals;
  String? _cursor;
  bool _loading = false, _done = false;
  Object? _error;
  Timer? _debounce;
  int _version = -1;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _filter.categoryId = widget.initialCategoryId;
    _filter.walletId = widget.initialWalletId;
    _filter.type = widget.initialType;
    _filter.range = widget.initialRange;
    _filter.fixedWallet = widget.fixedWallet && widget.initialWalletId != null;
    _filter.fixedCategory = widget.fixedCategory && widget.initialCategoryId != null;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _more();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _query => {
        'q': _search.text.trim(),
        'type': _filter.type,
        'category_id': _filter.categoryId,
        'wallet_id': _filter.walletId,
        if (_filter.range != null) 'from': _filter.range!.start.toUtc().toIso8601String(),
        if (_filter.range != null) 'to': _filter.range!.end.add(const Duration(days: 1)).toUtc().toIso8601String(),
        'limit': '30',
      };

  /// Tải lại trang đầu. Giữ danh sách cũ trên màn hình cho đến khi có dữ liệu mới để không bị nháy trắng.
  Future<void> _reload() async {
    _selected.clear();
    await _more(reset: true);
  }

  Future<void> _more({bool reset = false}) async {
    if (_loading && !reset) return;
    if (_done && !reset) return;
    final id = ++_reqId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context
          .read<ApiClient>()
          .get('/transactions', query: {..._query, 'cursor': reset ? null : _cursor});
      if (id != _reqId || !mounted) return;
      setState(() {
        if (reset) {
          _items.clear();
          _totals = null;
        }
        _items.addAll((r['items'] as List).map((e) => Tx.fromJson(Map<String, dynamic>.from(e))));
        _cursor = r['next_cursor'];
        _done = _cursor == null;
        if (r['totals'] != null) _totals = Map<String, dynamic>.from(r['totals']);
      });
    } catch (e) {
      if (id == _reqId && mounted) setState(() => _error = e);
    } finally {
      if (id == _reqId && mounted) setState(() => _loading = false);
    }
  }

  /// Chọn (hoặc bỏ chọn) giao dịch để xóa nhiều. Giao dịch hệ thống không xóa được nên không cho chọn.
  void _select(Tx t, {bool add = false}) {
    if (t.source == 'system') return showInfo(context, systemTxHint);
    setState(() => !add && _selected.contains(t.id) ? _selected.remove(t.id) : _selected.add(t.id));
  }

  Future<void> _bulkDelete() async {
    final n = _selected.length;
    if (!await confirm(context, 'Xóa $n giao dịch?', 'Số dư ví và ngân sách sẽ được tính lại.', ok: 'Xóa', danger: true)) return;
    if (!mounted) return;
    final data = context.read<AppData>();
    final api = context.read<ApiClient>();
    final messenger = ScaffoldMessenger.of(context);
    final ids = _selected.toList();
    try {
      await api.post('/transactions/bulk-delete', {'ids': ids});
      await data.afterTxChange();
      if (!mounted) return;
      showInfo(context, 'Đã xóa $n giao dịch',
          action: SnackBarAction(
              label: 'Hoàn tác',
              onPressed: () async {
                var failed = 0;
                Object? error;
                for (final id in ids) {
                  try {
                    await api.post('/transactions/$id/restore');
                  } catch (e) {
                    failed++;
                    error = e;
                  }
                }
                await data.afterTxChange();
                if (failed > 0) {
                  messenger.showSnackBar(SnackBar(content: Text('Chưa hoàn tác được $failed giao dịch: $error')));
                }
              }));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _openFilter() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => _FilterSheet(filter: _filter),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.select<AppData, int>((d) => d.txVersion);
    if (v != _version) {
      _version = v;
      WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
    }
    final selecting = _selected.isNotEmpty;
    final groups = <String, List<Tx>>{};
    for (final t in _items) {
      final l = t.occurredAt;
      groups.putIfAbsent('${l.year}-${l.month}-${l.day}', () => []).add(t);
    }
    return Scaffold(
      appBar: selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
              title: Text('Đã chọn ${_selected.length}'),
              actions: [IconButton(tooltip: 'Xóa', icon: const Icon(Icons.delete_outline), onPressed: _bulkDelete)],
            )
          : AppBar(
              title: Text(widget.title ?? 'Giao dịch'),
              actions: widget.standalone ? null : topActions(context),
            ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: 'Tìm theo ghi chú, danh mục (không cần dấu)',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _search.clear();
                            _reload();
                          }),
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 350), _reload);
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Bộ lọc',
              onPressed: _openFilter,
              icon: Badge(isLabelVisible: _filter.active, child: const Icon(Icons.tune_rounded)),
            ),
          ]),
        ),
        if (_totals != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            // Màn hình hẹp hoặc tổng tiền lớn thì phần Thu/Chi xuống dòng thay vì bị cắt.
            child: SizedBox(
              width: double.infinity,
              child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, runSpacing: 2, children: [
                Text('${_totals!['count']} giao dịch', style: TextStyle(color: context.muted, fontSize: 13)),
                Wrap(spacing: 12, children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Thu ', style: TextStyle(color: context.muted, fontSize: 13)),
                    Money((_totals!['income'] as num).toInt(),
                        style: TextStyle(color: context.incomeColor, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Chi ', style: TextStyle(color: context.muted, fontSize: 13)),
                    Money((_totals!['expense'] as num).toInt(),
                        style: TextStyle(color: context.expenseColor, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ]),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: _items.isEmpty && !_loading
                ? ListView(children: [
                    _error != null
                        ? EmptyState(icon: Icons.cloud_off, title: _error.toString(), action: OutlinedButton(onPressed: _reload, child: const Text('Thử lại')))
                        : const EmptyState(icon: Icons.search_off_rounded, title: 'Không có giao dịch phù hợp'),
                  ])
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: groups.length + 1,
                    itemBuilder: (c, i) {
                      if (i == groups.length) {
                        return Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: _loading
                                ? const CircularProgressIndicator()
                                : (_done ? Text('Đã hiển thị tất cả', style: TextStyle(color: context.muted)) : const SizedBox()),
                          ),
                        );
                      }
                      final list = groups.values.elementAt(i);
                      // Tổng theo ngày không tính giao dịch hệ thống (số dư ban đầu, điều chỉnh) - khớp báo cáo.
                      final real = list.where((t) => t.source != 'system');
                      final inc = real.where((t) => t.isIncome).fold<int>(0, (s, t) => s + t.amount);
                      final exp = real.where((t) => !t.isIncome).fold<int>(0, (s, t) => s + t.amount);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          child: Column(children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              // Chữ lớn hoặc màn hình hẹp: tổng thu/chi của ngày xuống dòng thay vì bị cắt.
                              child: SizedBox(
                                width: double.infinity,
                                child: Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 10,
                                  runSpacing: 2,
                                  children: [
                                    Text(dayHeader(list.first.occurredAt), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    Wrap(spacing: 10, children: [
                                      if (inc > 0) Money(inc, sign: true, style: TextStyle(color: context.incomeColor, fontSize: 12.5)),
                                      if (exp > 0) Money(-exp, style: TextStyle(color: context.expenseColor, fontSize: 12.5)),
                                    ]),
                                  ],
                                ),
                              ),
                            ),
                            for (final t in list)
                              TxTile(
                                tx: t,
                                selected: _selected.contains(t.id),
                                onLongPress: () => _select(t, add: true),
                                onTap: () {
                                  if (selecting) {
                                    _select(t);
                                  } else {
                                    Navigator.push(context, MaterialPageRoute(builder: (_) => TxDetailScreen(id: t.id)));
                                  }
                                },
                              ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  final _Filter filter;
  const _FilterSheet({required this.filter});
  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  @override
  Widget build(BuildContext context) {
    final f = widget.filter;
    final d = context.watch<AppData>();
    final cats = d.categories.where((c) => f.type == null || c.type == f.type).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Bộ lọc', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        if (!f.fixedCategory) ...[
          SegmentedButton<String?>(
            segments: const [
              ButtonSegment(value: null, label: Text('Tất cả')),
              ButtonSegment(value: 'expense', label: Text('Chi')),
              ButtonSegment(value: 'income', label: Text('Thu')),
            ],
            selected: {f.type},
            onSelectionChanged: (s) => setState(() {
              f.type = s.first;
              if (f.categoryId != null && d.categoryById(f.categoryId)?.type != f.type && f.type != null) f.categoryId = null;
            }),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(f.range == null ? 'Chọn khoảng ngày' : '${fmtDate(f.range!.start)} – ${fmtDate(f.range!.end)}'),
          onPressed: () async {
            final now = DateTime.now();
            final first = DateTime(now.year - 5);
            final init = f.range;
            final r = await showDateRangePicker(
                context: context,
                firstDate: first,
                lastDate: now,
                initialDateRange: init != null && !init.start.isBefore(first) && !init.end.isAfter(now) ? init : null);
            if (r != null) setState(() => f.range = r);
          },
        ),
        // isExpanded + cắt "…": tên danh mục/ví dài không làm tràn ô chọn.
        if (!f.fixedCategory) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: f.categoryId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Danh mục'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Tất cả danh mục')),
              for (final c in cats)
                DropdownMenuItem(value: c.id, child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => f.categoryId = v),
          ),
        ],
        if (!f.fixedWallet) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: f.walletId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Ví'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Tất cả ví')),
              for (final w in d.wallets)
                DropdownMenuItem(value: w.id, child: Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => f.walletId = v),
          ),
        ],
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                f.clear();
                Navigator.pop(context);
              },
              child: const Text('Bỏ lọc'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Áp dụng'))),
        ]),
      ]),
    );
  }
}

/// Chi tiết giao dịch: ảnh đính kèm (UC06.1), sửa, xóa có hoàn tác (UC07).
class TxDetailScreen extends StatefulWidget {
  final String id;
  const TxDetailScreen({super.key, required this.id});
  @override
  State<TxDetailScreen> createState() => _TxDetailScreenState();
}

class _TxDetailScreenState extends State<TxDetailScreen> {
  Tx? _tx;
  Object? _error;
  List<String> _pending = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<ApiClient>();
      final data = context.read<AppData>();
      final r = await api.get('/transactions/${widget.id}');
      final p = await data.pendingKeys(widget.id);
      if (mounted) {
        setState(() {
          _tx = Tx.fromJson(Map<String, dynamic>.from(r));
          _pending = p;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'Xóa giao dịch?', 'Số dư ví sẽ được hoàn lại.', ok: 'Xóa', danger: true)) return;
    if (!mounted) return;
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.delete('/transactions/${widget.id}');
      await data.afterTxChange();
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: const Text('Đã xóa giao dịch'),
        duration: const Duration(seconds: 5),
        // Tự tắt sau 5 giây (Flutter 3.38 trở đi mặc định giữ mãi thông báo có nút).
        persist: false,
        action: SnackBarAction(
          label: 'Hoàn tác',
          onPressed: () async {
            try {
              await api.post('/transactions/${widget.id}/restore');
              await data.afterTxChange();
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('Chưa hoàn tác được: $e')));
            }
          },
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      // Chưa có dữ liệu (lần tải đầu) thì báo lỗi tại chỗ kèm nút Thử lại; đang có dữ liệu thì chỉ báo nhanh.
      if (_tx == null) {
        setState(() => _error = e);
      } else {
        showError(context, e);
      }
    }
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  Future<void> _addPhoto() async {
    final imgs = await Navigator.push<List<Uint8List>>(
        context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => CameraScreen(maxCount: 3 - _tx!.attachments.length - _pending.length)));
    if (imgs == null || imgs.isEmpty || !mounted) return;
    final data = context.read<AppData>();
    try {
      final failed = await data.uploadImages(widget.id, imgs);
      if (failed > 0 && mounted) showInfo(context, '$failed ảnh chưa tải lên được, bạn có thể thử lại sau');
      await data.afterTxChange();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deletePhoto(Attachment a) async {
    if (!await confirm(context, 'Xóa ảnh này?', 'Ảnh sẽ bị xóa vĩnh viễn.', ok: 'Xóa', danger: true)) return;
    if (!mounted) return;
    try {
      await context.read<ApiClient>().delete('/attachments/${a.id}');
      if (!mounted) return;
      await context.read<AppData>().afterTxChange();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _viewPhoto(Attachment a) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
            body: InteractiveViewer(child: Center(child: SecureImage(a.id, fit: BoxFit.contain))),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = _tx;
    // Giao dịch đã bị xóa (vd mở từ một cảnh báo cũ): chỉ xem, không sửa, xóa hay thêm ảnh.
    final deleted = t?.deletedAt != null;
    final canEdit = t != null && t.source != 'system' && !deleted;
    return Scaffold(
      appBar: AppBar(title: const Text('Chi tiết giao dịch'), actions: [
        if (canEdit)
          IconButton(
            tooltip: 'Sửa',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => TxFormScreen(edit: t)));
              if (changed == true) _load();
            },
          ),
        // Giao dịch hệ thống (số dư ban đầu, điều chỉnh số dư) không sửa, không xóa được.
        if (canEdit) IconButton(tooltip: 'Xóa', icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ]),
      body: t == null
          ? Center(
              child: _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off,
                      title: _error.toString(),
                      action: OutlinedButton(onPressed: _retry, child: const Text('Thử lại')))
                  : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (deleted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    color: context.warnColor.withValues(alpha: 0.12),
                    child: const ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Giao dịch này đã bị xóa'),
                      subtitle: Text('Không còn được tính vào số dư, ngân sách và báo cáo.'),
                    ),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    CategoryIcon(icon: t.categoryIcon, color: t.categoryColor, size: 56),
                    const SizedBox(height: 12),
                    Text(t.title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Money(t.signed, colored: true, sign: true, style: Theme.of(context).textTheme.headlineMedium),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  _row(Icons.category_outlined, 'Danh mục', t.categoryName),
                  _row(walletIcon(context.read<AppData>().walletById(t.walletId)?.type ?? 'cash'), 'Ví', t.walletName),
                  _row(Icons.schedule, 'Thời gian', fmtDateTime(t.occurredAt)),
                  _row(Icons.swap_vert, 'Loại', t.isIncome ? 'Khoản thu' : 'Khoản chi'),
                  if (t.source == 'ai') _row(Icons.auto_awesome, 'Nguồn', 'Nhập bằng AI'),
                  if (t.source == 'system') _row(Icons.settings_suggest_outlined, 'Nguồn', 'Giao dịch hệ thống (số dư)'),
                  if (t.note != null) _row(Icons.notes, 'Ghi chú', t.note!),
                ]),
              ),
              if (t.source == 'system' && !deleted)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Text(systemTxHint, style: TextStyle(color: context.muted, fontSize: 12.5)),
                ),
              if (canEdit) ...[
                SectionTitle('Ảnh (${t.attachments.length + _pending.length}/3)',
                    trailing: t.attachments.length + _pending.length < 3
                        ? TextButton.icon(onPressed: _addPhoto, icon: const Icon(Icons.add_a_photo_outlined), label: const Text('Thêm ảnh'))
                        : null),
                if (t.attachments.isEmpty && _pending.isEmpty)
                  Text('Chưa có ảnh. Chụp món đồ hoặc hóa đơn để dễ nhớ hơn.', style: TextStyle(color: context.muted)),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final a in t.attachments)
                    GestureDetector(
                      onTap: () => _viewPhoto(a),
                      onLongPress: () => _deletePhoto(a),
                      child: Stack(children: [
                        ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: SizedBox(width: 104, height: 104, child: SecureImage(a.id))),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            iconSize: 16,
                            tooltip: 'Xóa ảnh',
                            onPressed: () => _deletePhoto(a),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ]),
                    ),
                  for (final k in _pending) _PendingThumb(keyName: k, txId: t.id, onDone: _load),
                ]),
              ],
            ]),
    );
  }

  Widget _row(IconData i, String label, String value) => ListTile(
        leading: Icon(i, size: 22),
        title: Text(label, style: TextStyle(color: context.muted, fontSize: 13)),
        subtitle: Text(value, style: Theme.of(context).textTheme.bodyLarge),
      );
}

/// Ảnh "Chưa tải lên" (mất mạng khi tải) - bấm để thử lại.
class _PendingThumb extends StatelessWidget {
  final String keyName, txId;
  final VoidCallback onDone;
  const _PendingThumb({required this.keyName, required this.txId, required this.onDone});
  @override
  Widget build(BuildContext context) {
    final data = context.read<AppData>();
    return GestureDetector(
      onTap: () async {
        final left = await data.retryPending(txId);
        if (context.mounted) {
          showInfo(context, left == 0 ? 'Đã tải ảnh lên' : 'Vẫn chưa tải lên được: ${data.lastUploadError ?? 'kiểm tra mạng'}');
        }
        onDone();
      },
      child: Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 104,
            height: 104,
            child: FutureBuilder<Uint8List?>(
              future: data.pendingImage(keyName),
              builder: (c, s) => s.data == null ? const ColoredBox(color: Colors.black12) : Image.memory(s.data!, fit: BoxFit.cover),
            ),
          ),
        ),
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(16)),
            child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.cloud_upload_outlined, color: Colors.white),
              Text('Chưa tải lên', style: TextStyle(color: Colors.white, fontSize: 11)),
              Text('Chạm để thử lại', style: TextStyle(color: Colors.white70, fontSize: 10)),
            ]),
          ),
        ),
      ]),
    );
  }
}
