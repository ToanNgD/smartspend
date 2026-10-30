import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/tx_editor.dart';

/// 4.1 Thêm giao dịch thủ công (có đính kèm ảnh) và 4.2 Sửa giao dịch.
class TxFormScreen extends StatefulWidget {
  final Tx? edit;
  final List<Uint8List>? initialImages;
  const TxFormScreen({super.key, this.edit, this.initialImages});
  @override
  State<TxFormScreen> createState() => _TxFormScreenState();
}

class _TxFormScreenState extends State<TxFormScreen> {
  late final TxDraft _d;
  late final List<Uint8List> _images = [...?widget.initialImages];

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _d = e == null
        ? TxDraft()
        : TxDraft(type: e.type, amount: e.amount, categoryId: e.categoryId, walletId: e.walletId, note: e.note, occurredAt: e.occurredAt);
  }

  Future<void> _save() async {
    if (_d.amount == null || _d.amount! <= 0) return showInfo(context, 'Nhập số tiền lớn hơn 0');
    if (_d.categoryId == null) return showInfo(context, 'Chọn danh mục');
    if (_d.walletId == null) return showInfo(context, 'Chọn ví');
    final data = context.read<AppData>();
    try {
      if (widget.edit == null) {
        final (_, warnings, failed) = await data.createTx(_d, images: _images);
        if (!mounted) return;
        Navigator.pop(context, true);
        showInfo(
            context,
            [
              'Đã lưu giao dịch',
              if (warnings.contains('over_balance')) 'khoản chi vượt số dư ví',
              if (failed > 0) '$failed ảnh chưa tải lên (mở giao dịch để thử lại)',
            ].join(' · '));
      } else {
        await context.read<ApiClient>().patch('/transactions/${widget.edit!.id}', {
          'type': _d.type,
          'amount': _d.amount,
          'category_id': _d.categoryId,
          'wallet_id': _d.walletId,
          'occurred_at': _d.occurredAt.toUtc().toIso8601String(),
          'note': (_d.note ?? '').trim().isEmpty ? null : _d.note!.trim(),
        });
        await data.afterTxChange();
        if (!mounted) return;
        Navigator.pop(context, true);
        showInfo(context, 'Đã cập nhật giao dịch');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.edit == null ? 'Thêm giao dịch' : 'Sửa giao dịch')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          TxEditor(draft: _d, images: widget.edit == null ? _images : null),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BusyButton(label: widget.edit == null ? 'Lưu giao dịch' : 'Lưu thay đổi', onPressed: _save),
          ),
        ),
      );
}
