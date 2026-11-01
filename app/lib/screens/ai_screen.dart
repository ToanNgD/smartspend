import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/fetch.dart';
import '../widgets/top_actions.dart';
import 'ai_input_screen.dart';
import 'budget_screens.dart';

/// 6.2 Phân tích thói quen và gợi ý; 6.3 Dự báo.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key});
  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  List<Insight>? _items;
  int? _remaining;
  String? _engine;
  bool _analyzing = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Đọc kết quả đã lưu (cache) - không gọi lại AI mỗi lần mở màn hình.
  Future<void> _load() async {
    try {
      final r = await context.read<ApiClient>().get('/ai/insights');
      if (!mounted) return;
      setState(() {
        _items = (r['items'] as List).map((e) => Insight.fromJson(Map<String, dynamic>.from(e))).toList();
        _remaining = (r['manual_remaining_today'] as num?)?.toInt();
        _engine = r['engine'];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _analyze() async {
    setState(() => _analyzing = true);
    try {
      await context.read<ApiClient>().post('/ai/insights/analyze');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _act(Insight i) async {
    final a = i.action!;
    final cat = context.read<AppData>().categories.where((c) => c.type == 'expense' && c.name.toLowerCase() == '${a['category']}'.toLowerCase()).firstOrNull;
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => BudgetFormScreen(
          presetName: 'Ngân sách ${a['category']}',
          presetAmount: (a['amount'] as num?)?.toInt(),
          presetCategoryId: cat?.id,
        ),
      ),
    );
    if (ok == true && mounted) {
      try {
        await context.read<ApiClient>().patch('/ai/insights/${i.id}', {'status': 'acted'});
        _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Future<void> _dismiss(Insight i) async {
    try {
      await context.read<ApiClient>().patch('/ai/insights/${i.id}', {'status': 'dismissed'});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items?.where((i) => i.status != 'dismissed').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Trợ lý AI'), actions: topActions(context)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
          Card(
            child: ListTile(
              leading: Icon(Icons.edit_note_rounded, color: context.cs.primary),
              title: const Text('Nhập nhanh bằng câu nói'),
              subtitle: const Text('"trưa nay ăn phở 50k, cà phê 25k"'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiInputScreen())),
            ),
          ),
          SectionTitle('Gợi ý tối ưu chi tiêu',
              trailing: FilledButton.tonalIcon(
                onPressed: _analyzing || (_remaining ?? 1) <= 0 ? null : _analyze,
                icon: _analyzing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome, size: 18),
                label: Text(_remaining == null ? 'Phân tích ngay' : 'Phân tích ngay ($_remaining)'),
              )),
          if (_error != null)
            EmptyState(icon: Icons.cloud_off, title: _error.toString(), action: OutlinedButton(onPressed: _load, child: const Text('Thử lại')))
          else if (items == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            const Card(
              child: EmptyState(
                icon: Icons.lightbulb_outline,
                title: 'Chưa có gợi ý',
                subtitle: 'Bấm "Phân tích ngay" hoặc chờ bản phân tích tự động vào đầu tuần.',
              ),
            )
          else
            for (final i in items) Padding(padding: const EdgeInsets.only(bottom: 12), child: _InsightCard(i: i, onAct: _act, onDismiss: _dismiss)),
          if (_engine == 'basic')
            Text('Gợi ý đang được tạo bằng bộ phân tích thống kê cơ bản (chưa kết nối dịch vụ AI).',
                style: TextStyle(color: context.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Text('Nội dung chỉ mang tính tham khảo, không phải tư vấn tài chính hay đầu tư.', style: TextStyle(color: context.muted, fontSize: 12)),
          const SectionTitle('Dự báo cuối kỳ'),
          const _Forecasts(),
        ]),
      ),
    );
  }
}

class _InsightCard extends StatelessWidget {
  final Insight i;
  final void Function(Insight) onAct, onDismiss;
  const _InsightCard({required this.i, required this.onAct, required this.onDismiss});
  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (i.kind) {
      'trend' => (Icons.trending_up_rounded, context.cs.primary, 'Xu hướng'),
      'habit' => (Icons.calendar_today_rounded, context.warnColor, 'Thói quen'),
      'saving' => (Icons.savings_outlined, context.incomeColor, 'Tiết kiệm'),
      _ => (Icons.lightbulb_outline, context.cs.primary, 'Gợi ý'),
    };
    final a = i.action;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 16, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, size: 18, color: color)),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            if (i.status == 'acted') Icon(Icons.check_circle, size: 18, color: context.incomeColor),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Ẩn gợi ý', onPressed: () => onDismiss(i), icon: const Icon(Icons.close, size: 18)),
          ]),
          const SizedBox(height: 8),
          // Văn bản thuần, không render HTML.
          Text(i.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
          const SizedBox(height: 6),
          Text(i.content, style: TextStyle(color: context.cs.onSurface.withValues(alpha: 0.85), height: 1.4)),
          if (a != null && a['type'] == 'set_budget' && i.status != 'acted') ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => onAct(i),
              icon: const Icon(Icons.track_changes_rounded, size: 18),
              label: Text('Đặt ngân sách ${a['category']} ${vnd((a['amount'] as num?) ?? 0)}'),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Forecasts extends StatelessWidget {
  const _Forecasts();
  @override
  Widget build(BuildContext context) => Fetch(
        path: '/ai/forecast',
        builder: (c, data) {
          if (data['enough_data'] != true) {
            return Card(child: EmptyState(icon: Icons.hourglass_bottom_rounded, title: 'Chưa đủ dữ liệu', subtitle: data['message'] as String?));
          }
          final items = (data['items'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
          if (items.isEmpty) {
            return const Card(child: EmptyState(icon: Icons.track_changes, title: 'Tạo ngân sách để xem dự báo'));
          }
          return Card(
            child: Column(children: [
              for (final f in items)
                ListTile(
                  leading: Icon(f['will_exceed'] == true ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                      color: f['will_exceed'] == true ? context.warnColor : context.incomeColor),
                  title: Text(f['name']),
                  subtitle: Row(children: [
                    const Text('Dự kiến '),
                    Money((f['projected_total'] as num?) ?? 0, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Text(' / '),
                    Money((f['amount_limit'] as num?) ?? 0),
                  ]),
                  trailing: f['projected_hit_at'] == null
                      ? null
                      : Text('chạm ngày\n${fmtDate(DateTime.parse(f['projected_hit_at'])).substring(0, 5)}',
                          textAlign: TextAlign.right, style: TextStyle(color: context.warnColor, fontSize: 12)),
                ),
            ]),
          );
        },
      );
}
