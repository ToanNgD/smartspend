import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/alerts_screen.dart';
import '../screens/settings_screen.dart';
import '../state/app_data.dart';
import '../state/session.dart';

/// Nút trên thanh tiêu đề: ẩn số tiền, cảnh báo, khóa ngay, cài đặt.
List<Widget> topActions(BuildContext context) {
  final d = context.watch<AppData>();
  return [
    IconButton(
      tooltip: d.hideAmounts ? 'Hiện số tiền' : 'Ẩn số tiền',
      icon: Icon(d.hideAmounts ? Icons.visibility_off_outlined : Icons.visibility_outlined),
      onPressed: d.toggleHide,
    ),
    IconButton(
      tooltip: 'Cảnh báo',
      icon: Badge(
        isLabelVisible: d.unreadAlerts > 0,
        label: Text('${d.unreadAlerts > 9 ? '9+' : d.unreadAlerts}'),
        child: const Icon(Icons.notifications_none_rounded),
      ),
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AlertsScreen())),
    ),
    IconButton(
      tooltip: 'Khóa ứng dụng',
      icon: const Icon(Icons.lock_outline_rounded),
      onPressed: () => context.read<Session>().lockNow(),
    ),
    IconButton(
      tooltip: 'Cài đặt',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
    ),
    const SizedBox(width: 4),
  ];
}
