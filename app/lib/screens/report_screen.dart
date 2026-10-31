import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/fetch.dart';
import 'transaction_screens.dart';

/// Tham số kỳ báo cáo dùng chung.
class ReportQuery {
  final String period; // week | month | year
  final int offset; // 0 = kỳ hiện tại, -1 = kỳ trước...
  final String? walletId;
  const ReportQuery({this.period = 'month', this.offset = 0, this.walletId});
  Map<String, dynamic> toQuery() => {'period': period, 'offset': '$offset', 'wallet_id': walletId};
  ReportQuery copy({String? period, int? offset, String? walletId, bool clearWallet = false}) => ReportQuery(
      period: period ?? this.period, offset: offset ?? this.offset, walletId: clearWallet ? null : (walletId ?? this.walletId));
}

/// Báo cáo theo danh mục: biểu đồ tròn + danh sách; danh mục < 3% gộp vào "Khác" (server tính).
class CategoryReportCard extends StatefulWidget {
  final bool compact;
  final ReportQuery query;
  final String type;
  const CategoryReportCard({super.key, this.compact = false, this.query = const ReportQuery(), this.type = 'expense'});
  @override
  State<CategoryReportCard> createState() => _CategoryReportCardState();
}

class _CategoryReportCardState extends State<CategoryReportCard> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Fetch(
          path: '/reports/categories',
          query: {...widget.query.toQuery(), 'type': widget.type},
          loadingHeight: 140,
          builder: (c, data) {
            final r = Map<String, dynamic>.from(data);
            final total = (r['total'] as num).toInt();
            if (total == 0) {
              return EmptyState(
                  icon: Icons.pie_chart_outline_rounded,
                  title: widget.type == 'expense' ? 'Chưa có khoản chi trong kỳ' : 'Chưa có khoản thu trong kỳ');
            }
            final items = (r['items'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
            final other = r['other'] == null ? null : Map<String, dynamic>.from(r['other']);
            final slices = [
              ...items.map((e) => (e['name'] as String, (e['amount'] as num).toInt(), (e['percent'] as num).toDouble(),
                  hexColor(e['color']), e['icon'] as String, e['category_id'] as String?)),
              if (other != null)
                ('Khác', (other['amount'] as num).toInt(), (other['percent'] as num).toDouble(), Colors.grey, 'dots', null),
            ];
            final shown = widget.compact ? slices.take(4).toList() : slices;
            return Column(children: [
              Row(children: [
                SizedBox(
                  width: widget.compact ? 120 : 150,
                  height: widget.compact ? 120 : 150,
                  child: Stack(alignment: Alignment.center, children: [
                    PieChart(PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: widget.compact ? 36 : 46,
                      sections: [
                        for (final x in slices)
                          PieChartSectionData(value: x.$2.toDouble(), color: x.$4, radius: widget.compact ? 20 : 26, showTitle: false),
                      ],
                    )),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.type == 'expense' ? 'Tổng chi' : 'Tổng thu', style: TextStyle(fontSize: 11, color: context.muted)),
                      Money(total, short: true, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                  ]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(children: [
                    for (final x in shown)
                      InkWell(
                        onTap: x.$6 == null || widget.compact
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => TransactionsScreen(initialCategoryId: x.$6, title: x.$1, standalone: true))),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: x.$4, shape: BoxShape.circle)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(x.$1, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Text('${x.$3.toStringAsFixed(0)}%', style: TextStyle(color: context.muted)),
                          ]),
                        ),
                      ),
                  ]),
                ),
              ]),
              if (!widget.compact) ...[
                const SizedBox(height: 12),
                const Divider(),
                for (final x in slices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CategoryIcon(icon: x.$5, color: '#${x.$4.toARGB32().toRadixString(16).substring(2)}', size: 36),
                    title: Text(x.$1),
                    subtitle: BudgetBarThin(percent: x.$3, color: x.$4),
                    trailing: Money(x.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: x.$6 == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => TransactionsScreen(initialCategoryId: x.$6, title: x.$1, standalone: true))),
                  ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class BudgetBarThin extends StatelessWidget {
  final double percent;
  final Color color;
  const BudgetBarThin({super.key, required this.percent, required this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              value: (percent / 100).clamp(0, 1), minHeight: 6, color: color, backgroundColor: color.withValues(alpha: 0.12)),
        ),
      );
}

/// 7.1 Báo cáo: theo danh mục, xu hướng thu/chi, so sánh với kỳ trước.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  ReportQuery q = const ReportQuery();
  String type = 'expense';

  String get _label {
    final p = q.period, o = q.offset;
    if (o == 0) return {'week': 'Tuần này', 'month': 'Tháng này', 'year': 'Năm nay'}[p]!;
    if (o == -1) return {'week': 'Tuần trước', 'month': 'Tháng trước', 'year': 'Năm trước'}[p]!;
    return '${-o} ${{'week': 'tuần', 'month': 'tháng', 'year': 'năm'}[p]} trước';
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    return Scaffold(
      appBar: AppBar(title: const Text('Báo cáo')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 40), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'week', label: Text('Tuần')),
            ButtonSegment(value: 'month', label: Text('Tháng')),
            ButtonSegment(value: 'year', label: Text('Năm')),
          ],
          selected: {q.period},
          onSelectionChanged: (s) => setState(() => q = q.copy(period: s.first, offset: 0)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          IconButton(
              tooltip: 'Kỳ trước',
              onPressed: q.offset > -60 ? () => setState(() => q = q.copy(offset: q.offset - 1)) : null,
              icon: const Icon(Icons.chevron_left)),
          Expanded(child: Text(_label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(
              tooltip: 'Kỳ sau',
              onPressed: q.offset < 0 ? () => setState(() => q = q.copy(offset: q.offset + 1)) : null,
              icon: const Icon(Icons.chevron_right)),
        ]),
        DropdownButtonFormField<String?>(
          initialValue: q.walletId,
          decoration: const InputDecoration(labelText: 'Ví', isDense: true),
          items: [
            const DropdownMenuItem(value: null, child: Text('Tất cả ví')),
            for (final w in d.wallets) DropdownMenuItem(value: w.id, child: Text(w.name)),
          ],
          onChanged: (v) => setState(() => q = v == null ? q.copy(clearWallet: true) : q.copy(walletId: v)),
        ),
        const SizedBox(height: 12),
        _SummaryCompare(q: q),
        SectionTitle('Theo danh mục',
            trailing: SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [ButtonSegment(value: 'expense', label: Text('Chi')), ButtonSegment(value: 'income', label: Text('Thu'))],
              selected: {type},
              onSelectionChanged: (s) => setState(() => type = s.first),
            )),
        CategoryReportCard(query: q, type: type),
        const SectionTitle('Xu hướng thu chi'),
        _TrendChart(q: q),
      ]),
    );
  }
}

class _SummaryCompare extends StatelessWidget {
  final ReportQuery q;
  const _SummaryCompare({required this.q});
  @override
  Widget build(BuildContext context) {
    return Fetch(
      path: '/reports/summary',
      query: q.toQuery(),
      builder: (c, data) {
        final r = Map<String, dynamic>.from(data);
        final ch = Map<String, dynamic>.from(r['change_percent']);
        final prev = Map<String, dynamic>.from(r['previous']);
        Widget cell(String label, int v, double? pct, Color color, {bool lowerIsBetter = false}) => Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(color: context.muted, fontSize: 12)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Money(v, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                if (pct != null)
                  Text('${pct >= 0 ? '▲' : '▼'} ${pct.abs().toStringAsFixed(1)}%',
                      style: TextStyle(
                          fontSize: 12,
                          color: (pct > 0) == lowerIsBetter ? context.expenseColor : context.incomeColor)),
              ]),
            );
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                cell('Thu', (r['income'] as num).toInt(), (ch['income'] as num?)?.toDouble(), context.incomeColor),
                cell('Chi', (r['expense'] as num).toInt(), (ch['expense'] as num?)?.toDouble(), context.expenseColor, lowerIsBetter: true),
                cell('Chênh lệch', (r['net'] as num).toInt(), null, context.cs.onSurface),
              ]),
              const SizedBox(height: 10),
              Text(
                r['ongoing'] == true
                    ? 'So với cùng số ngày của kỳ trước (${_d(prev['from'])} – ${_d(prev['to'])})'
                    : 'So với kỳ trước (${_d(prev['from'])} – ${_d(prev['to'])})',
                style: TextStyle(color: context.muted, fontSize: 12),
              ),
            ]),
          ),
        );
      },
    );
  }

  static String _d(String s) {
    final d = DateTime.parse(s);
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }
}

class _TrendChart extends StatefulWidget {
  final ReportQuery q;
  const _TrendChart({required this.q});
  @override
  State<_TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<_TrendChart> {
  /// Nhóm người dùng chọn; null = dùng mặc định theo kỳ.
  String? _picked;

  /// Các cách nhóm hợp lý cho từng kỳ (UC14: theo ngày, tuần hoặc tháng).
  static List<String> _options(String period) => switch (period) {
        'week' => const ['day'],
        'month' => const ['day', 'week'],
        'year' => const ['week', 'month'],
        _ => const ['day', 'week', 'month'],
      };

  static const _names = {'day': 'Ngày', 'week': 'Tuần', 'month': 'Tháng'};

  @override
  Widget build(BuildContext context) {
    final q = widget.q;
    final options = _options(q.period);
    final group = options.contains(_picked) ? _picked! : (q.period == 'year' ? 'month' : 'day');
    final chart = _buildChart(context, q, group);
    if (options.length < 2) return chart;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(
        alignment: Alignment.centerRight,
        child: SegmentedButton<String>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          showSelectedIcon: false,
          segments: [for (final o in options) ButtonSegment(value: o, label: Text('Theo ${_names[o]!.toLowerCase()}'))],
          selected: {group},
          onSelectionChanged: (s) => setState(() => _picked = s.first),
        ),
      ),
      const SizedBox(height: 8),
      chart,
    ]);
  }

  Widget _buildChart(BuildContext context, ReportQuery q, String group) {
    return Fetch(
      path: '/reports/trend',
      query: {...q.toQuery(), 'group': group},
      loadingHeight: 220,
      builder: (c, data) {
        final items = ((data['items'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
        final maxY = items.fold<int>(0, (m, e) => [m, (e['income'] as num).toInt(), (e['expense'] as num).toInt()].reduce((a, b) => a > b ? a : b));
        final hide = context.watch<AppData>().hideAmounts;
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 20, 16, 8),
            child: Column(children: [
              SizedBox(
                height: 200,
                child: BarChart(BarChartData(
                  maxY: maxY == 0 ? 1 : maxY * 1.15,
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(enabled: !hide),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: !hide,
                        reservedSize: 44,
                        getTitlesWidget: (v, m) => Text(vndShort(v), style: TextStyle(fontSize: 10, color: context.muted)),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        getTitlesWidget: (v, m) {
                          final i = v.toInt();
                          if (i < 0 || i >= items.length) return const SizedBox();
                          final step = items.length > 12 ? (items.length / 6).ceil() : 1;
                          if (i % step != 0) return const SizedBox();
                          final d = DateTime.parse(items[i]['date']);
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(group == 'month' ? 'T${d.month}' : '${d.day}/${d.month}',
                                style: TextStyle(fontSize: 10, color: context.muted)),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < items.length; i++)
                      BarChartGroupData(x: i, barsSpace: 2, barRods: [
                        BarChartRodData(
                            toY: (items[i]['income'] as num).toDouble(),
                            color: context.incomeColor,
                            width: items.length > 20 ? 3 : 7,
                            borderRadius: BorderRadius.circular(2)),
                        BarChartRodData(
                            toY: (items[i]['expense'] as num).toDouble(),
                            color: context.expenseColor,
                            width: items.length > 20 ? 3 : 7,
                            borderRadius: BorderRadius.circular(2)),
                      ]),
                  ],
                )),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _Legend(color: context.incomeColor, label: 'Thu'),
                const SizedBox(width: 16),
                _Legend(color: context.expenseColor, label: 'Chi'),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]);
}
