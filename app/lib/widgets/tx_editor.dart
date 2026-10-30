
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../screens/camera_screen.dart';
import '../state/app_data.dart';
import 'common.dart';

/// Bàn phím nhập số tiền. Bàn phím số thuần của iOS không có nút "Xong" để đóng,
/// nên trên iOS dùng bàn phím số có phím Return (Xong).
TextInputType get moneyKeyboard => defaultTargetPlatform == TargetPlatform.iOS
    ? const TextInputType.numberWithOptions(signed: true)
    : TextInputType.number;

/// Định dạng số tiền khi gõ: 50000 -> 50.000
class MoneyInputFormatter extends TextInputFormatter {
  final _f = NumberFormat.decimalPattern('vi');
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue(text: '');
    final n = int.parse(digits.length > 11 ? digits.substring(0, 11) : digits);
    final t = _f.format(n);
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

/// Bộ chỉnh sửa một giao dịch dùng chung cho form thêm/sửa (4.1, 4.2) và bản xem trước của AI (6.1).
class TxEditor extends StatefulWidget {
  final TxDraft draft;
  final List<Uint8List>? images; // null = không cho thêm ảnh tại đây
  final bool compact;
  final VoidCallback? onChanged;
  const TxEditor({super.key, required this.draft, this.images, this.compact = false, this.onChanged});
  @override
  State<TxEditor> createState() => _TxEditorState();
}

class _TxEditorState extends State<TxEditor> {
  late final TextEditingController _amount;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final d = widget.draft;
    _amount = TextEditingController(text: d.amount == null ? '' : NumberFormat.decimalPattern('vi').format(d.amount));
    _note = TextEditingController(text: d.note ?? '');
  }

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _pickDate() async {
    final d = widget.draft;
    final now = DateTime.now();
    final date = await showDatePicker(
        context: context, initialDate: d.occurredAt, firstDate: DateTime(now.year - 5), lastDate: now);
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(d.occurredAt));
    var dt = DateTime(date.year, date.month, date.day, time?.hour ?? d.occurredAt.hour, time?.minute ?? d.occurredAt.minute);
    if (dt.isAfter(now)) dt = now;
    d.occurredAt = dt;
    _changed();
  }

  Future<void> _addPhoto() async {
    final imgs = widget.images!;
    final res = await Navigator.push<List<Uint8List>>(
        context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => CameraScreen(maxCount: 3 - imgs.length)));
    if (res != null) {
      imgs.addAll(res.take(3 - imgs.length));
      _changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final data = context.watch<AppData>();
    final cats = data.visibleCategories(d.type);
    final wallets = data.activeWallets;
    if (d.walletId == null && wallets.isNotEmpty) d.walletId = wallets.first.id;
    final wallet = data.walletById(d.walletId);
    final overBalance = d.type == 'expense' && wallet != null && (d.amount ?? 0) > 0 && d.amount! > wallet.balance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'expense', label: Text('Khoản chi'), icon: Icon(Icons.north_east_rounded)),
          ButtonSegment(value: 'income', label: Text('Khoản thu'), icon: Icon(Icons.south_west_rounded)),
        ],
        selected: {d.type},
        onSelectionChanged: (s) {
          d.type = s.first;
          if (data.categoryById(d.categoryId)?.type != d.type) d.categoryId = null;
          _changed();
        },
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _amount,
        keyboardType: moneyKeyboard,
        textInputAction: TextInputAction.done,
        inputFormatters: [MoneyInputFormatter()],
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: d.type == 'income' ? context.incomeColor : context.expenseColor, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          labelText: 'Số tiền',
          suffixText: 'đ',
          errorText: d.amount == null && widget.compact ? 'Nhập số tiền' : null,
        ),
        onChanged: (v) {
          d.amount = parseMoney(v);
          _changed();
        },
      ),
      if (overBalance)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text('Khoản chi lớn hơn số dư ví ${wallet.name}. Bạn vẫn có thể lưu.',
              style: TextStyle(color: context.warnColor, fontSize: 12.5)),
        ),
      const SizedBox(height: 14),
      Text('Danh mục', style: TextStyle(color: context.muted, fontSize: 13)),
      if (d.categoryId == null && widget.compact)
        Text('Chọn danh mục', style: TextStyle(color: context.cs.error, fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in cats)
          ChoiceChip(
            avatar: Icon(iconMap[c.icon] ?? Icons.more_horiz, size: 18, color: hexColor(c.color)),
            label: Text(c.name),
            selected: d.categoryId == c.id,
            onSelected: (_) {
              d.categoryId = c.id;
              _changed();
            },
          ),
      ]),
      const SizedBox(height: 14),
      Text('Ví', style: TextStyle(color: context.muted, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final w in wallets)
          ChoiceChip(
            avatar: Icon(walletIcon(w.type), size: 18),
            label: Text(w.name),
            selected: d.walletId == w.id,
            onSelected: (_) {
              d.walletId = w.id;
              _changed();
            },
          ),
      ]),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
        icon: const Icon(Icons.event_outlined),
        label: Text(fmtDateTime(d.occurredAt)),
        onPressed: _pickDate,
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _note,
        maxLength: 200,
        maxLines: widget.compact ? 1 : 2,
        minLines: 1,
        decoration: const InputDecoration(labelText: 'Ghi chú (không bắt buộc)'),
        onChanged: (v) => d.note = v,
      ),
      if (widget.images != null) ...[
        Row(children: [
          Text('Ảnh (${widget.images!.length}/3)', style: TextStyle(color: context.muted, fontSize: 13)),
          const Spacer(),
          if (widget.images!.length < 3)
            TextButton.icon(onPressed: _addPhoto, icon: const Icon(Icons.add_a_photo_outlined), label: const Text('Thêm ảnh')),
        ]),
        if (widget.images!.isNotEmpty)
          SizedBox(
            height: 88,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (var i = 0; i < widget.images!.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.memory(widget.images![i], width: 88, height: 88, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: 2,
                      top: 2,
                      child: InkWell(
                        onTap: () {
                          widget.images!.removeAt(i);
                          _changed();
                        },
                        child: const CircleAvatar(radius: 12, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
      ],
    ]);
  }
}
