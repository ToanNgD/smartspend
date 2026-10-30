import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';

/// UC05 Quản lý danh mục: mặc định chỉ ẩn/hiện; danh mục riêng được sửa, xóa
/// (đang có giao dịch thì bắt buộc chọn danh mục khác để chuyển sang).
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  String _type = 'expense';

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppData>();
    final list = d.categories.where((c) => c.type == _type).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Danh mục')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(context, type: _type),
        icon: const Icon(Icons.add),
        label: const Text('Thêm danh mục'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 100), children: [
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'expense', label: Text('Khoản chi')), ButtonSegment(value: 'income', label: Text('Khoản thu'))],
          selected: {_type},
          onSelectionChanged: (s) => setState(() => _type = s.first),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            for (final c in list)
              ListTile(
                leading: Opacity(opacity: c.isHidden ? 0.4 : 1, child: CategoryIcon(icon: c.icon, color: c.color)),
                title: Text(c.name, style: TextStyle(color: c.isHidden ? context.muted : null)),
                subtitle: Text([
                  if (c.isDefault) 'Mặc định',
                  if (c.isHidden) 'Đang ẩn',
                  '${c.txCount} giao dịch',
                ].join(' · ')),
                trailing: c.isDefault
                    ? IconButton(
                        tooltip: c.isHidden ? 'Hiện' : 'Ẩn',
                        icon: Icon(c.isHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => _toggleHidden(context, c),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: c.isDefault ? null : () => _open(context, edit: c),
              ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _toggleHidden(BuildContext context, TxCategory c) async {
    try {
      await context.read<ApiClient>().patch('/categories/${c.id}', {'is_hidden': !c.isHidden});
      if (context.mounted) await context.read<AppData>().reloadCategories();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _open(BuildContext context, {TxCategory? edit, String? type}) => showModalBottomSheet(
      context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _CategoryForm(edit: edit, type: type ?? edit!.type));
}

const _palette = ['#D9822B', '#3B7DD8', '#B4508F', '#7A62C9', '#5D7A6E', '#D1495B', '#2A9D8F', '#8A6D3B', '#1E8A5A', '#C9A227', '#6F4E37', '#8B9590'];

class _CategoryForm extends StatefulWidget {
  final TxCategory? edit;
  final String type;
  const _CategoryForm({this.edit, required this.type});
  @override
  State<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<_CategoryForm> {
  late final _name = TextEditingController(text: widget.edit?.name ?? '');
  late String _icon = widget.edit?.icon ?? 'dots';
  late String _color = widget.edit?.color ?? _palette.first;

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return showInfo(context, 'Nhập tên danh mục');
    if (name.contains('<') || name.contains('>')) return showInfo(context, 'Tên chứa ký tự không cho phép');
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    try {
      if (widget.edit == null) {
        await api.post('/categories', {'name': name, 'type': widget.type, 'icon': _icon, 'color': _color});
      } else {
        await api.patch('/categories/${widget.edit!.id}', {'name': name, 'icon': _icon, 'color': _color});
      }
      await data.reloadCategories();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete() async {
    final c = widget.edit!;
    final api = context.read<ApiClient>();
    final data = context.read<AppData>();
    String? moveTo;
    if (c.txCount > 0) {
      final others = data.categories.where((x) => x.type == c.type && x.id != c.id).toList();
      moveTo = await showDialog<String>(
        context: context,
        builder: (dc) => SimpleDialog(
          title: Text('Chuyển ${c.txCount} giao dịch sang danh mục nào?'),
          children: [
            for (final o in others)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dc, o.id),
                child: Row(children: [CategoryIcon(icon: o.icon, color: o.color, size: 30), const SizedBox(width: 10), Text(o.name)]),
              ),
          ],
        ),
      );
      if (moveTo == null) return;
    } else {
      if (!mounted || !await confirm(context, 'Xóa danh mục ${c.name}?', 'Không thể hoàn tác.', ok: 'Xóa', danger: true)) return;
    }
    try {
      await api.delete('/categories/${c.id}', query: {if (moveTo != null) 'move_to': moveTo});
      await data.reloadCategories();
      await data.afterTxChange();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CategoryIcon(icon: _icon, color: _color, size: 44),
              const SizedBox(width: 12),
              Text(widget.edit == null ? 'Thêm danh mục ${widget.type == 'expense' ? 'chi' : 'thu'}' : 'Sửa danh mục',
                  style: Theme.of(context).textTheme.titleLarge),
            ]),
            const SizedBox(height: 16),
            TextField(controller: _name, maxLength: 30, decoration: const InputDecoration(labelText: 'Tên danh mục')),
            Text('Biểu tượng', style: TextStyle(color: context.muted)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in iconMap.entries)
                ChoiceChip(
                  label: Icon(e.value, size: 20),
                  selected: _icon == e.key,
                  onSelected: (_) => setState(() => _icon = e.key),
                ),
            ]),
            const SizedBox(height: 12),
            Text('Màu', style: TextStyle(color: context.muted)),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: hexColor(c),
                    child: _color == c ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                  ),
                ),
            ]),
            const SizedBox(height: 20),
            BusyButton(label: 'Lưu', onPressed: _save),
            if (widget.edit != null)
              TextButton(
                onPressed: _delete,
                style: TextButton.styleFrom(foregroundColor: context.expenseColor),
                child: const Text('Xóa danh mục'),
              ),
          ]),
        ),
      );
}
