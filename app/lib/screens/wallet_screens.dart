import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/tx_editor.dart';
import 'transaction_screens.dart';

/// UC04 Quản lý ví: tạo (có số dư ban đầu), sửa, lưu trữ/dùng lại, xóa (chỉ khi chưa có giao dịch),
/// điều chỉnh số dư bằng giao dịch điều chỉnh.
class WalletsScreen extends StatelessWidget {
  const WalletsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    final active = d.wallets.where((w) => !w.isArchived).toList();
    final archived = d.wallets.where((w) => w.isArchived).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Ví')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Thêm ví'),
      ),
      body: RefreshIndicator(
        onRefresh: d.reloadWallets,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 100), children: [
          Card(
            child: ListTile(
              title: const Text('Tổng số dư các ví đang dùng'),
              subtitle: Money(d.totalBalance, style: Theme.of(context).textTheme.headlineSmall),
            ),
          ),
          const SectionTitle('Đang dùng'),
          Card(child: Column(children: [for (final w in active) _WalletTile(w: w)])),
          if (archived.isNotEmpty) ...[
            const SectionTitle('Đã lưu trữ'),
            Card(child: Column(children: [for (final w in archived) _WalletTile(w: w)])),
          ],
        ]),
      ),
    );
  }
}

Future<void> _openForm(BuildContext context, [Wallet? w]) =>
    showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _WalletForm(edit: w));

class _WalletTile extends StatelessWidget {
  final Wallet w;
  const _WalletTile({required this.w});

  Future<void> _action(BuildContext context, String a) async {
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    try {
      switch (a) {
        case 'edit':
          await _openForm(context, w);
        case 'archive':
          await api.post('/wallets/${w.id}/archive');
        case 'unarchive':
          await api.post('/wallets/${w.id}/unarchive');
        case 'adjust':
          final v = await showDialog<int>(context: context, builder: (_) => _AdjustDialog(w: w));
          if (v != null) {
            await api.post('/wallets/${w.id}/adjust', {'balance': v});
            await data.afterTxChange();
          }
        case 'delete':
          if (!await confirm(context, 'Xóa ví ${w.name}?', 'Chỉ xóa được ví chưa có giao dịch.', ok: 'Xóa', danger: true)) return;
          await api.delete('/wallets/${w.id}');
        case 'history':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => _WalletHistory(w: w)));
      }
      await data.reloadWallets();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
        leading: CircleAvatar(
          backgroundColor: context.cs.primary.withValues(alpha: 0.12),
          child: Icon(walletIcon(w.type), color: context.cs.primary),
        ),
        title: Text(w.name),
        subtitle: Text(w.typeLabel),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Money(w.balance, style: TextStyle(fontWeight: FontWeight.w700, color: w.balance < 0 ? context.expenseColor : null)),
          PopupMenuButton<String>(
            onSelected: (a) => _action(context, a),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'history', child: Text('Xem giao dịch')),
              const PopupMenuItem(value: 'edit', child: Text('Sửa tên, loại')),
              const PopupMenuItem(value: 'adjust', child: Text('Điều chỉnh số dư')),
              PopupMenuItem(value: w.isArchived ? 'unarchive' : 'archive', child: Text(w.isArchived ? 'Dùng lại' : 'Lưu trữ')),
              if (w.txCount == 0) const PopupMenuItem(value: 'delete', child: Text('Xóa ví')),
            ],
          ),
        ]),
        onTap: () => _action(context, 'history'),
      );
}

/// Hộp thoại điều chỉnh số dư; trả về số dư thực tế người dùng nhập (hoặc null nếu hủy).
class _AdjustDialog extends StatefulWidget {
  final Wallet w;
  const _AdjustDialog({required this.w});
  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Điều chỉnh số dư'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Số dư hiện tại: ${vnd(widget.w.balance)}. Nhập số dư thực tế, app sẽ tạo một giao dịch điều chỉnh.'),
          const SizedBox(height: 12),
          TextField(
              controller: _ctl,
              autofocus: true,
              keyboardType: moneyKeyboard,
              textInputAction: TextInputAction.done,
              inputFormatters: [MoneyInputFormatter()],
              decoration: const InputDecoration(labelText: 'Số dư thực tế', suffixText: 'đ')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(context, parseMoney(_ctl.text)), child: const Text('Điều chỉnh')),
        ],
      );
}

class _WalletHistory extends StatelessWidget {
  final Wallet w;
  const _WalletHistory({required this.w});
  @override
  Widget build(BuildContext context) => TransactionsScreen(initialWalletId: w.id, title: w.name, standalone: true);
}

class _WalletForm extends StatefulWidget {
  final Wallet? edit;
  const _WalletForm({this.edit});
  @override
  State<_WalletForm> createState() => _WalletFormState();
}

class _WalletFormState extends State<_WalletForm> {
  late final _name = TextEditingController(text: widget.edit?.name ?? '');
  final _initial = TextEditingController();
  late String _type = widget.edit?.type ?? 'bank';

  @override
  void dispose() {
    _name.dispose();
    _initial.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return showInfo(context, 'Nhập tên ví');
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    try {
      if (widget.edit == null) {
        await api.post('/wallets', {
          'name': _name.text.trim(),
          'type': _type,
          'initial_balance': parseMoney(_initial.text) ?? 0,
        });
      } else {
        await api.patch('/wallets/${widget.edit!.id}', {'name': _name.text.trim(), 'type': _type});
      }
      await data.reloadWallets();
      await data.afterTxChange();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.edit == null ? 'Thêm ví' : 'Sửa ví', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(controller: _name, maxLength: 30, decoration: const InputDecoration(labelText: 'Tên ví', hintText: 'vd: MoMo, Vietcombank')),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'cash', label: Text('Tiền mặt'), icon: Icon(Icons.payments_outlined)),
              ButtonSegment(value: 'bank', label: Text('Ngân hàng'), icon: Icon(Icons.account_balance_outlined)),
              ButtonSegment(value: 'ewallet', label: Text('Ví điện tử'), icon: Icon(Icons.phone_iphone)),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          if (widget.edit == null) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _initial,
              keyboardType: moneyKeyboard,
              textInputAction: TextInputAction.done,
              inputFormatters: [MoneyInputFormatter()],
              decoration: const InputDecoration(labelText: 'Số dư ban đầu', suffixText: 'đ', helperText: 'Ghi thành giao dịch "Số dư ban đầu"'),
            ),
          ],
          const SizedBox(height: 20),
          BusyButton(label: 'Lưu', onPressed: _save),
        ]),
      );
}
