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

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;
  // Chỉ dựng một tab khi người dùng mở nó lần đầu -> mở app nhanh hơn, ít gọi server hơn.
  final Set<int> _visited = {0};
  bool _opening = false;
  late final Session _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _session = context.read<Session>()..addListener(_checkLink);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.removeListener(_checkLink);
    super.dispose();
  }

  /// Quay lại app từ nền: làm mới số dư, cảnh báo... (nhiều nhất 30 giây một lần).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && context.read<Session>().status == SessionStatus.ready) {
      context.read<AppData>().refreshSummary(ifOlderThan: const Duration(seconds: 30));
    }
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

  void _go(int i) => setState(() {
        _tab = i;
        _visited.add(i);
      });

  /// Chống bấm nút + hai lần mở hai form.
  Future<void> _openAdd() async {
    if (_opening) return;
    _opening = true;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TxFormScreen()));
    _opening = false;
  }

  Widget _page(int i) {
    if (!_visited.contains(i)) return const SizedBox.shrink();
    return switch (i) {
      0 => OverviewScreen(onOpenTab: _go),
      1 => const TransactionsScreen(),
      2 => const BudgetsScreen(),
      _ => const AiScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Nút Back của Android: đang ở tab khác thì về Tổng quan trước, không thoát app ngay.
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _tab != 0) _go(0);
      },
      child: Scaffold(
        body: IndexedStack(index: _tab, children: [for (var i = 0; i < 4; i++) _page(i)]),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        floatingActionButton: FloatingActionButton(
          tooltip: 'Thêm giao dịch',
          shape: const CircleBorder(),
          onPressed: _openAdd,
          child: const Icon(Icons.add_rounded, size: 30),
        ),
        bottomNavigationBar: BottomAppBar(
          shape: const CircularNotchedRectangle(),
          notchMargin: 8,
          height: 68,
          padding: EdgeInsets.zero,
          child: Row(children: [
            _NavItem(icon: Icons.grid_view_rounded, label: 'Tổng quan', on: _tab == 0, onTap: () => _go(0)),
            _NavItem(icon: Icons.receipt_long_rounded, label: 'Giao dịch', on: _tab == 1, onTap: () => _go(1)),
            const SizedBox(width: 72),
            _NavItem(icon: Icons.track_changes_rounded, label: 'Ngân sách', on: _tab == 2, onTap: () => _go(2)),
            _NavItem(icon: Icons.auto_awesome_rounded, label: 'AI', on: _tab == 3, onTap: () => _go(3)),
          ]),
        ),
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
