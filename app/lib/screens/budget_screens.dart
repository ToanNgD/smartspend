import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/fetch.dart';
import '../widgets/top_actions.dart';
import '../widgets/tx_editor.dart';
import '../widgets/tx_tile.dart';
import 'transaction_screens.dart';

/// Thẻ ngân sách: đã chi, còn lại, % đã dùng, số ngày còn lại, mức chi tối đa mỗi ngày (5.1).
class BudgetCard extends StatelessWidget {
  final Budget b;
  const BudgetCard({super.key, required this.b});
  @override
  Widget build(BuildContext context) {
    final over = b.remaining < 0;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetDetailScreen(budgetId: b.id))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: context.cs.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text(b.periodLabel, style: TextStyle(fontSize: 12, color: context.cs.primary)),
              ),
            ]),
            if (b.scope == 'categories')
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(b.categories.map((c) => c['name']).join(', '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.muted, fontSize: 12.5)),
              ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Money(b.spent, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              Text('  / ', style: TextStyle(color: context.muted)),
              Money(b.limit, style: TextStyle(color: context.muted)),
              const Spacer(),
              Text('${b.percent.toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            BudgetBar(percent: b.percent),
            const SizedBox(height: 8),
            Row(children: [
              Text(over ? 'Vượt ' : 'Còn lại ', style: TextStyle(color: context.muted, fontSize: 12.5)),
              Money(b.remaining.abs(),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: over ? context.expenseColor : null)),
              const Spacer(),
              Text('${b.daysLeft} ngày · tối đa ', style: TextStyle(color: context.muted, fontSize: 12.5)),
              Money(b.dailyAllowance, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              Text('/ngày', style: TextStyle(color: context.muted, fontSize: 12.5)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class BudgetsScreen extends StatelessWidget {
  const BudgetsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    return Scaffold(
      appBar: AppBar(title: const Text('Ngân sách'), actions: topActions(context)),
      body: RefreshIndicator(
        onRefresh: () => d.reloadBudgets().catchError((e) {
          if (context.mounted) showError(context, e);
        }),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
          if (d.budgets.isEmpty)
            EmptyState(
              icon: Icons.track_changes_rounded,
              title: 'Chưa có ngân sách',
              subtitle: 'Đặt hạn mức theo tuần hoặc tháng, cho toàn bộ hoặc một số danh mục.',
              action: FilledButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetFormScreen())),
                icon: const Icon(Icons.add),
                label: const Text('Tạo ngân sách'),
              ),
            )
          else ...[
            for (final b in d.budgets) Padding(padding: const EdgeInsets.only(bottom: 12), child: BudgetCard(b: b)),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetFormScreen())),
              icon: const Icon(Icons.add),
              label: const Text('Thêm ngân sách'),
            ),
          ],
        ]),
      ),
    );
  }
}

class BudgetDetailScreen extends StatelessWidget {
  final String budgetId;
  const BudgetDetailScreen({super.key, required this.budgetId});
  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    final b = d.budgets.where((x) => x.id == budgetId).firstOrNull;
    if (b == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off, title: 'Ngân sách không còn tồn tại'));
    }
    return Scaffold(
      appBar: AppBar(title: Text(b.name), actions: [
        IconButton(
          tooltip: 'Sửa',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetFormScreen(edit: b))),
        ),
        IconButton(
          tooltip: 'Xóa',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            if (!await confirm(context, 'Xóa ngân sách?', 'Các giao dịch vẫn được giữ nguyên.', ok: 'Xóa', danger: true)) return;
            if (!context.mounted) return;
            try {
              await context.read<ApiClient>().delete('/budgets/${b.id}');
              if (!context.mounted) return;
              final data = context.read<AppData>();
              await data.reloadBudgets();
              await data.afterTxChange();
              if (context.mounted) Navigator.pop(context);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        BudgetCard(b: b),
        _ForecastLine(budgetId: b.id),
        const SectionTitle('Khoản chi trong kỳ'),
        Fetch(
          path: '/transactions',
          query: {
            'type': 'expense',
            'from': (b.raw['period_start'] as String?),
            'to': (b.raw['period_end'] as String?),
            if (b.scope == 'categories' && b.categoryIds.length == 1) 'category_id': b.categoryIds.first,
            'limit': '50',
          },
          builder: (c, data) {
            var items = (data['items'] as List).map((e) => Tx.fromJson(Map<String, dynamic>.from(e))).toList();
            if (b.scope == 'categories') items = items.where((t) => b.categoryIds.contains(t.categoryId)).toList();
            items = items.where((t) => t.source != 'system').toList();
            if (items.isEmpty) return const Card(child: EmptyState(icon: Icons.receipt_long, title: 'Chưa có khoản chi nào trong kỳ'));
            return Card(
              child: Column(children: [
                for (final t in items)
                  TxTile(tx: t, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TxDetailScreen(id: t.id)))),
              ]),
            );
          },
        ),
      ]),
    );
  }
}

class _ForecastLine extends StatelessWidget {
  final String budgetId;
  const _ForecastLine({required this.budgetId});
  @override
  Widget build(BuildContext context) => Fetch(
        path: '/ai/forecast',
        loadingHeight: 0,
        builder: (c, data) {
          if (data['enough_data'] != true) {
            return Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Dự báo: chưa đủ dữ liệu (cần ít nhất 2 tuần giao dịch).', style: TextStyle(color: context.muted, fontSize: 12.5)),
            );
          }
          final f = (data['items'] as List).map((e) => Map<String, dynamic>.from(e)).where((e) => e['budget_id'] == budgetId).firstOrNull;
          if (f == null) return const SizedBox();
          final hit = f['projected_hit_at'] == null ? null : DateTime.parse(f['projected_hit_at']).toLocal();
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              color: (f['will_exceed'] == true ? context.warnColor : context.incomeColor).withValues(alpha: 0.10),
              child: ListTile(
                leading: Icon(f['will_exceed'] == true ? Icons.trending_up : Icons.check_circle_outline),
                title: Row(children: [
                  const Text('Dự kiến cuối kỳ: '),
                  Money((f['projected_total'] as num).toInt(), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                subtitle: Text(hit != null
                    ? 'Với tốc độ hiện tại, bạn có thể chạm hạn mức vào ngày ${DateFormat('dd/MM').format(hit)}'
                    : f['will_exceed'] == true
                        ? 'Dự kiến vượt hạn mức trong kỳ này'
                        : 'Đang trong tầm kiểm soát'),
              ),
            ),
          );
        },
      );
}

/// Tạo / sửa ngân sách. Có thể mở sẵn giá trị từ thẻ gợi ý AI (vẫn phải xác nhận).
class BudgetFormScreen extends StatefulWidget {
  final Budget? edit;
  final String? presetName;
  final int? presetAmount;
  final String? presetCategoryId;
  const BudgetFormScreen({super.key, this.edit, this.presetName, this.presetAmount, this.presetCategoryId});
  @override
  State<BudgetFormScreen> createState() => _BudgetFormScreenState();
}

class _BudgetFormScreenState extends State<BudgetFormScreen> {
  late final _name = TextEditingController(text: widget.edit?.name ?? widget.presetName ?? '');
  late final _limit = TextEditingController(
      text: (widget.edit?.limit ?? widget.presetAmount) == null
          ? ''
          : NumberFormat.decimalPattern('vi').format(widget.edit?.limit ?? widget.presetAmount));
  late String _period = widget.edit?.period ?? 'month';
  late String _scope = widget.edit?.scope ?? (widget.presetCategoryId != null ? 'categories' : 'all');
  late final Set<String> _cats = {...?widget.edit?.categoryIds, if (widget.presetCategoryId != null) widget.presetCategoryId!};

  Future<void> _save() async {
    final limit = int.tryParse(_limit.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (_name.text.trim().isEmpty) return showInfo(context, 'Nhập tên ngân sách');
    if (limit == null || limit < 1000) return showInfo(context, 'Hạn mức tối thiểu 1.000đ');
    if (_scope == 'categories' && _cats.isEmpty) return showInfo(context, 'Chọn ít nhất một danh mục');
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    try {
      if (widget.edit == null) {
        await api.post('/budgets', {
          'name': _name.text.trim(),
          'amount_limit': limit,
          'period': _period,
          'scope': _scope,
          if (_scope == 'categories') 'category_ids': _cats.toList(),
        });
      } else {
        await api.patch('/budgets/${widget.edit!.id}', {
          'name': _name.text.trim(),
          'amount_limit': limit,
          if (_scope == 'categories') 'category_ids': _cats.toList(),
        });
      }
      await data.reloadBudgets();
      await data.afterTxChange();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.edit != null;
    final cats = context.watch<AppData>().visibleCategories('expense');
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Sửa ngân sách' : 'Tạo ngân sách')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, maxLength: 40, decoration: const InputDecoration(labelText: 'Tên ngân sách', hintText: 'vd: Chi tiêu tháng')),
        const SizedBox(height: 4),
        TextField(
          controller: _limit,
          keyboardType: TextInputType.number,
          inputFormatters: [MoneyInputFormatter()],
          decoration: const InputDecoration(labelText: 'Hạn mức', suffixText: 'đ'),
        ),
        const SizedBox(height: 16),
        Text('Chu kỳ', style: TextStyle(color: context.muted)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'week', label: Text('Hằng tuần')), ButtonSegment(value: 'month', label: Text('Hằng tháng'))],
          selected: {_period},
          onSelectionChanged: editing ? null : (s) => setState(() => _period = s.first),
        ),
        const SizedBox(height: 16),
        Text('Phạm vi', style: TextStyle(color: context.muted)),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'all', label: Text('Toàn bộ khoản chi')), ButtonSegment(value: 'categories', label: Text('Một số danh mục'))],
          selected: {_scope},
          onSelectionChanged: editing ? null : (s) => setState(() => _scope = s.first),
        ),
        if (_scope == 'categories') ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              FilterChip(
                avatar: Icon(iconMap[c.icon], size: 18, color: hexColor(c.color)),
                label: Text(c.name),
                selected: _cats.contains(c.id),
                onSelected: (v) => setState(() => v ? _cats.add(c.id) : _cats.remove(c.id)),
              ),
          ]),
        ],
        const SizedBox(height: 16),
        Text('Chỉ tính các khoản chi. Bạn sẽ nhận cảnh báo khi dùng đến 80% và 100% hạn mức.',
            style: TextStyle(color: context.muted, fontSize: 12.5)),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: BusyButton(label: 'Lưu ngân sách', onPressed: _save)),
      ),
    );
  }
}
