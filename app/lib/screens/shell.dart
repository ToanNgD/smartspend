import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/app_data.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'ai_screen.dart';
import 'alerts_screen.dart';
import 'budget_screens.dart';
import 'overview_screen.dart';
import 'transaction_screens.dart';
import 'tx_form_screen.dart';

/// Khung chính: Tổng quan · Giao dịch · (+) · Ngân sách · AI (giống bản demo).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    context.read<Session>().addListener(_checkLink);
  }

  @override
  void dispose() {
    context.read<Session>().removeListener(_checkLink);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await context.read<AppData>().loadAll();
      if (!mounted) return;
      final s = context.read<Session>();
      if (s.rootedWarning) {
        s.rootedWarning = false;
        showDialog(
          context: context,
          builder: (c) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded),
            title: const Text('Thiết bị có thể đã bị root/jailbreak'),
            content: const Text('Trên thiết bị này, dữ liệu tài chính của bạn có nguy cơ bị ứng dụng khác đọc trộm. '
                'Hãy cân nhắc trước khi sử dụng.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Tôi hiểu'))],
          ),
        );
      }
      _checkLink();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Mở màn hình đích từ thông báo đẩy - chỉ khi app đã mở khóa.
  void _checkLink() {
    final s = context.read<Session>();
    final link = s.pendingLink;
    if (link == null || s.status != SessionStatus.ready || !mounted) return;
    s.pendingLink = null;
    final budgetId = link['budget_id'];
    if (budgetId is String) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => BudgetDetailScreen(budgetId: budgetId)));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const AlertsScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      OverviewScreen(onOpenTab: (i) => setState(() => _tab = i)),
      const TransactionsScreen(),
      const BudgetsScreen(),
      const AiScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Thêm giao dịch',
        shape: const CircleBorder(),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TxFormScreen())),
        child: const Icon(Icons.add_rounded, size: 30),
      ),
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        height: 68,
        padding: EdgeInsets.zero,
        child: Row(children: [
          _NavItem(icon: Icons.grid_view_rounded, label: 'Tổng quan', on: _tab == 0, onTap: () => setState(() => _tab = 0)),
          _NavItem(icon: Icons.receipt_long_rounded, label: 'Giao dịch', on: _tab == 1, onTap: () => setState(() => _tab = 1)),
          const SizedBox(width: 72),
          _NavItem(icon: Icons.track_changes_rounded, label: 'Ngân sách', on: _tab == 2, onTap: () => setState(() => _tab = 2)),
          _NavItem(icon: Icons.auto_awesome_rounded, label: 'AI', on: _tab == 3, onTap: () => setState(() => _tab = 3)),
        ]),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.on, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final color = on ? context.cs.primary : context.muted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: color),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }
}
