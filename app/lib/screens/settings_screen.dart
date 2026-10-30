import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../core/theme.dart';
import '../state/app_data.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'category_screens.dart';
import 'lock_screens.dart';
import 'report_screen.dart';
import 'wallet_screens.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _lockOn, _bioOn, _bioAvail;

  @override
  void initState() {
    super.initState();
    _refreshLock();
  }

  Future<void> _refreshLock() async {
    final v = context.read<Session>().vault;
    final hasPin = await v.hasPin();
    final bio = await v.biometricEnabled();
    final avail = await v.biometricAvailable();
    if (mounted) {
      setState(() {
        _lockOn = hasPin;
        _bioOn = bio;
        _bioAvail = avail;
      });
    }
  }

  /// Xác thực lại bằng PIN trước thao tác nhạy cảm (đổi/tắt khóa).
  Future<bool> _verifyPin() async {
    final s = context.read<Session>();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => const _PinVerifySheet(),
    );
    if (ok != true && await s.vault.failedAttempts() >= AppConfig.maxPinAttempts) {
      await s.logout(message: 'Bạn đã nhập sai PIN quá 5 lần. Vui lòng đăng nhập lại bằng mật khẩu.');
    }
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    final s = context.read<Session>();
    final st = d.settings;
    final features = Map<String, dynamic>.from(d.me?['features'] ?? {});
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        Card(
          child: ListTile(
            leading: CircleAvatar(child: Text(((d.me?['full_name'] as String?) ?? '?').trim().characters.first.toUpperCase())),
            title: Text(d.me?['full_name'] ?? ''),
            subtitle: Text(d.me?['email'] ?? ''),
          ),
        ),
        const SectionTitle('Bảo mật'),
        Card(
          child: Column(children: [
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline),
              title: const Text('Khóa ứng dụng bằng PIN'),
              subtitle: const Text('Yêu cầu xác thực khi mở app hoặc quay lại sau 60 giây'),
              value: _lockOn ?? true,
              onChanged: _lockOn == null
                  ? null
                  : (v) async {
                      if (!v) {
                        if (!await confirm(context, 'Tắt khóa ứng dụng?',
                            'Người khác cầm điện thoại của bạn có thể xem dữ liệu tài chính. Bạn vẫn muốn tắt?',
                            ok: 'Tắt', danger: true)) {
                          return;
                        }
                        if (!await _verifyPin()) return;
                        await s.vault.disableLock();
                      } else {
                        if (!context.mounted) return;
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => const SetupLockScreen(changeOnly: true)));
                      }
                      _refreshLock();
                    },
            ),
            if (_lockOn == true)
              ListTile(
                leading: const Icon(Icons.pin_outlined),
                title: const Text('Đổi mã PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  if (!await _verifyPin()) return;
                  if (!context.mounted) return;
                  final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const SetupLockScreen(changeOnly: true)));
                  if (ok == true && context.mounted) showInfo(context, 'Đã đổi mã PIN');
                },
              ),
            if (_lockOn == true && _bioAvail == true)
              SwitchListTile(
                secondary: const Icon(Icons.fingerprint),
                title: const Text('Mở khóa bằng vân tay / khuôn mặt'),
                value: _bioOn ?? false,
                onChanged: (v) async {
                  await s.vault.setBiometric(v);
                  _refreshLock();
                },
              ),
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off_outlined),
              title: const Text('Ẩn số tiền'),
              subtitle: const Text('Hiện "••••••", chạm để xem - dùng khi ở nơi đông người'),
              value: d.hideAmounts,
              onChanged: (_) => d.toggleHide(),
            ),
          ]),
        ),
        const SectionTitle('Thông báo'),
        Card(
          child: Column(children: [
            SwitchListTile(
              secondary: const Icon(Icons.track_changes_outlined),
              title: const Text('Cảnh báo ngân sách'),
              subtitle: const Text('Khi dùng đến 80% và 100% hạn mức'),
              value: st['budget_alerts_enabled'] == true,
              onChanged: (v) => d.updateSettings({'budget_alerts_enabled': v}).catchError((e) {
                if (context.mounted) showError(context, e);
              }),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Cảnh báo thông minh'),
              subtitle: const Text('Dự báo vượt ngân sách, khoản chi bất thường'),
              value: st['smart_alerts_enabled'] == true,
              onChanged: (v) => d.updateSettings({'smart_alerts_enabled': v}).catchError((e) {
                if (context.mounted) showError(context, e);
              }),
            ),
          ]),
        ),
        const SectionTitle('Quản lý'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Ví'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletsScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.category_outlined),
              title: const Text('Danh mục'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CategoriesScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart_rounded),
              title: const Text('Báo cáo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportScreen())),
            ),
          ]),
        ),
        const SectionTitle('Thông tin'),
        Card(
          child: Column(children: [
            ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('Máy chủ'), subtitle: Text(AppConfig.apiUrl)),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Phân tích AI'),
              subtitle: Text(features['ai'] == true ? 'Đã kết nối dịch vụ AI' : 'Bộ phân tích cơ bản (chưa kết nối AI)'),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('Thông báo đẩy'),
              subtitle: Text(features['push'] == true ? 'Máy chủ đã bật' : 'Máy chủ chưa cấu hình (vẫn xem được trong mục Cảnh báo)'),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: context.expenseColor),
          icon: const Icon(Icons.logout),
          label: const Text('Đăng xuất'),
          onPressed: () async {
            if (!await confirm(context, 'Đăng xuất?', 'Toàn bộ dữ liệu lưu trên máy này sẽ bị xóa.', ok: 'Đăng xuất', danger: true)) return;
            if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            await s.logout();
          },
        ),
      ]),
    );
  }
}

class _PinVerifySheet extends StatefulWidget {
  const _PinVerifySheet();
  @override
  State<_PinVerifySheet> createState() => _PinVerifySheetState();
}

class _PinVerifySheetState extends State<_PinVerifySheet> {
  String _pin = '';
  String? _msg;
  bool _err = false;

  Future<void> _changed(String v) async {
    setState(() {
      _pin = v;
      _err = false;
    });
    if (v.length < 6) return;
    final vault = context.read<Session>().vault;
    if (await vault.unlockWithPin(v)) {
      if (mounted) Navigator.pop(context, true);
      return;
    }
    final left = AppConfig.maxPinAttempts - await vault.failedAttempts();
    if (left <= 0) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    setState(() {
      _pin = '';
      _err = true;
      _msg = 'Sai mã PIN. Còn $left lần thử.';
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Nhập mã PIN hiện tại', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(_msg ?? 'Xác thực lại để tiếp tục', style: TextStyle(color: _err ? context.expenseColor : context.muted)),
            const SizedBox(height: 24),
            PinPad(value: _pin, onChanged: _changed, error: _err),
          ]),
        ),
      );
}
