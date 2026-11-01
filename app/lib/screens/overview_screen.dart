import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/top_actions.dart';
import '../widgets/tx_tile.dart';
import 'ai_input_screen.dart';
import 'budget_screens.dart';
import 'camera_screen.dart';
import 'report_screen.dart';
import 'transaction_screens.dart';

/// 7.1 Màn hình tổng quan: thu/chi/chênh lệch tháng này, ngân sách chính, nhập nhanh AI, giao dịch gần nhất.
class OverviewScreen extends StatelessWidget {
  final ValueChanged<int> onOpenTab;
  const OverviewScreen({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    final o = d.overview;
    final name = (d.me?['full_name'] as String?)?.split(' ').last ?? '';
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name.isEmpty ? 'Xin chào' : 'Xin chào, $name', style: TextStyle(fontSize: 13, color: context.muted)),
          const Text('Tổng quan'),
        ]),
        actions: topActions(context),
      ),
      body: RefreshIndicator(
        onRefresh: () => d.loadAll().catchError((e) {
          if (context.mounted) showError(context, e);
        }),
        child: o == null
            ? ListView(children: [
                if (d.loading)
                  const Padding(padding: EdgeInsets.all(80), child: Center(child: CircularProgressIndicator()))
                else
                  EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Chưa tải được dữ liệu',
                    subtitle: 'Kéo xuống để thử lại',
                    action: OutlinedButton(
                        onPressed: () => d.loadAll().catchError((e) {
                              if (context.mounted) showError(context, e);
                            }),
                        child: const Text('Thử lại')),
                  ),
              ])
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
                if (d.offline)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: context.warnColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                    child: const Row(children: [Icon(Icons.wifi_off_rounded, size: 18), SizedBox(width: 8), Expanded(child: Text('Đang ngoại tuyến, hiển thị dữ liệu đã lưu.'))]),
                  ),
                _SummaryCard(o: o, total: d.totalBalance),
                const SizedBox(height: 14),
                const _QuickInput(),
                SectionTitle('Ngân sách', trailing: TextButton(onPressed: () => onOpenTab(2), child: const Text('Tất cả'))),
                _MainBudget(o['main_budget'] == null ? null : Budget.fromJson(Map<String, dynamic>.from(o['main_budget']))),
                SectionTitle('Báo cáo tháng này',
                    trailing: TextButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportScreen())),
                        child: const Text('Chi tiết'))),
                const CategoryReportCard(compact: true),
                SectionTitle('Giao dịch gần đây', trailing: TextButton(onPressed: () => onOpenTab(1), child: const Text('Xem tất cả'))),
                _Recent(((o['recent_transactions'] as List?) ?? []).map((e) => Tx.fromJson(Map<String, dynamic>.from(e))).toList()),
              ]),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> o;
  final int total;
  const _SummaryCard({required this.o, required this.total});

  @override
  Widget build(BuildContext context) {
    final m = Map<String, dynamic>.from(o['month']);
    final change = Map<String, dynamic>.from(m['change_percent'] ?? {});
    final exp = (change['expense'] as num?)?.toDouble();
    final onP = context.cs.onPrimary;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [context.cs.primary, Color.lerp(context.cs.primary, Colors.black, 0.25)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Tổng số dư', style: TextStyle(color: onP.withValues(alpha: 0.8))),
        const SizedBox(height: 4),
        Money(total, style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: onP)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Thu tháng này', value: (m['income'] as num).toInt(), icon: Icons.south_west_rounded)),
          Expanded(child: _Stat(label: 'Chi tháng này', value: (m['expense'] as num).toInt(), icon: Icons.north_east_rounded)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Text('Chênh lệch: ', style: TextStyle(color: onP.withValues(alpha: 0.8))),
          Money((m['net'] as num).toInt(), sign: true, style: TextStyle(color: onP, fontWeight: FontWeight.w700)),
        ]),
        if (exp != null) ...[
          const SizedBox(height: 4),
          Text('Chi ${exp >= 0 ? 'tăng' : 'giảm'} ${exp.abs().toStringAsFixed(0)}% so với cùng kỳ tháng trước',
              style: TextStyle(color: onP.withValues(alpha: 0.85), fontSize: 12.5)),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  const _Stat({required this.label, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) {
    final onP = context.cs.onPrimary;
    return Row(children: [
      CircleAvatar(radius: 16, backgroundColor: onP.withValues(alpha: 0.15), child: Icon(icon, size: 16, color: onP)),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: onP.withValues(alpha: 0.8), fontSize: 12)),
          Money(value, style: TextStyle(color: onP, fontWeight: FontWeight.w700)),
        ]),
      ),
    ]);
  }
}

/// Ô nhập nhanh bằng câu tự nhiên + nút camera "chụp trước, nhập sau".
class _QuickInput extends StatelessWidget {
  const _QuickInput();
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            const SizedBox(width: 6),
            Icon(Icons.auto_awesome_rounded, color: context.cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiInputScreen())),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
                  child: Text('Gõ nhanh: "trưa nay ăn phở 50k"', style: TextStyle(color: context.muted)),
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Chụp ảnh rồi nhập',
              icon: const Icon(Icons.photo_camera_rounded),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraScreen(quickInput: true))),
            ),
          ]),
        ),
      );
}

class _MainBudget extends StatelessWidget {
  final Budget? b;
  const _MainBudget(this.b);
  @override
  Widget build(BuildContext context) {
    if (b == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.track_changes_rounded),
          title: const Text('Chưa có ngân sách'),
          subtitle: const Text('Đặt hạn mức để app nhắc bạn trước khi chi quá tay'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetFormScreen())),
        ),
      );
    }
    return BudgetCard(b: b!);
  }
}

class _Recent extends StatelessWidget {
  final List<Tx> items;
  const _Recent(this.items);
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Card(
          child: EmptyState(icon: Icons.receipt_long_rounded, title: 'Chưa có giao dịch', subtitle: 'Bấm nút + để ghi khoản đầu tiên'));
    }
    return Card(
      child: Column(children: [
        for (final t in items)
          TxTile(
            tx: t,
            showDate: true,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TxDetailScreen(id: t.id))),
          ),
      ]),
    );
  }
}
