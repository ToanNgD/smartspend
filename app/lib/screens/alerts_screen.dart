import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import 'budget_screens.dart';
import 'transaction_screens.dart';

/// Danh sách cảnh báo (5.2, 6.3). Cảnh báo bất thường có nút "Bình thường".
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});
  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<AlertItem>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<ApiClient>().get('/alerts', query: {'limit': '50'});
      if (!mounted) return;
      setState(() => _items = (r['items'] as List).map((e) => AlertItem.fromJson(Map<String, dynamic>.from(e))).toList());
      context.read<AppData>().setUnread((r['unread_count'] as num).toInt());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(AlertItem a) async {
    final api = context.read<ApiClient>();
    if (a.readAt == null) {
      try {
        await api.post('/alerts/${a.id}/read');
      } catch (_) {}
    }
    if (!mounted) return;
    if (a.budgetId != null) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetDetailScreen(budgetId: a.budgetId!)));
    } else if (a.transactionId != null) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => TxDetailScreen(id: a.transactionId!)));
    }
    _load();
  }

  Future<void> _normal(AlertItem a) async {
    try {
      await context.read<ApiClient>().post('/alerts/${a.id}/feedback', {'feedback': 'normal'});
      if (mounted) showInfo(context, 'Đã ghi nhận. Lần sau sẽ không cảnh báo khoản tương tự của danh mục này.');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Cảnh báo'), actions: [
          TextButton(
            onPressed: () async {
              try {
                await context.read<ApiClient>().post('/alerts/read-all');
                _load();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
            child: const Text('Đọc hết'),
          ),
        ]),
        body: RefreshIndicator(
          onRefresh: _load,
          child: _items == null
              ? ListView(children: [
                  Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(child: _error != null ? Text(_error.toString()) : const CircularProgressIndicator())),
                ])
              : _items!.isEmpty
                  ? ListView(children: const [
                      EmptyState(icon: Icons.notifications_none, title: 'Chưa có cảnh báo', subtitle: 'Bạn sẽ được báo khi ngân sách chạm 80%, 100% hoặc có khoản chi bất thường.'),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _items!.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (c, i) {
                        final a = _items![i];
                        final (icon, color) = switch (a.type) {
                          'budget_100' => (Icons.error_outline, context.expenseColor),
                          'budget_80' => (Icons.warning_amber_rounded, context.warnColor),
                          'forecast' => (Icons.trending_up, context.warnColor),
                          _ => (Icons.bolt_rounded, context.cs.primary),
                        };
                        return Card(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _open(a),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Expanded(
                                          child: Text(a.title,
                                              style: TextStyle(fontWeight: a.readAt == null ? FontWeight.w800 : FontWeight.w600))),
                                      if (a.readAt == null)
                                        Container(width: 8, height: 8, decoration: BoxDecoration(color: context.cs.primary, shape: BoxShape.circle)),
                                    ]),
                                    const SizedBox(height: 4),
                                    Text(a.body),
                                    const SizedBox(height: 4),
                                    Text(fmtDateTime(a.sentAt), style: TextStyle(color: context.muted, fontSize: 12)),
                                    if (a.type == 'anomaly' && a.feedback == null)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(onPressed: () => _normal(a), child: const Text('Bình thường')),
                                      ),
                                    if (a.feedback == 'normal')
                                      Text('Đã đánh dấu bình thường', style: TextStyle(color: context.muted, fontSize: 12)),
                                  ]),
                                ),
                              ]),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      );
}
