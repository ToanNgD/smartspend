import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_data.dart';
import '../widgets/common.dart';
import '../widgets/tx_editor.dart';

/// 6.1 Nhập giao dịch bằng ngôn ngữ tự nhiên. App chỉ gửi câu lên server (không gọi thẳng AI).
class AiInputScreen extends StatefulWidget {
  const AiInputScreen({super.key});
  @override
  State<AiInputScreen> createState() => _AiInputScreenState();
}

class _AiInputScreenState extends State<AiInputScreen> {
  final _text = TextEditingController();
  static const _examples = ['trưa nay ăn phở 50k', 'cà phê 25k, gửi xe 5k', 'hôm qua đổ xăng 80 nghìn', 'nhận lương 15tr', 'tiền nhà 3 triệu rưỡi'];

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    try {
      final r = await context.read<ApiClient>().post('/ai/parse', {'text': t});
      final drafts = ((r['items'] as List?) ?? []).map((e) => TxDraft.fromJson(Map<String, dynamic>.from(e))).toList();
      if (!mounted) return;
      if (drafts.isEmpty) {
        showInfo(context, 'Chưa hiểu câu này, thử ghi rõ số tiền, vd "ăn phở 50k"');
        return;
      }
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => AiPreviewScreen(drafts: drafts, engine: r['engine'] as String?, remaining: r['remaining_today'])));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Nhập nhanh bằng AI')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 300,
            maxLines: 3,
            minLines: 2,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(hintText: 'Gõ như nói chuyện, vd: trưa nay ăn phở 50k, cà phê 25k'),
          ),
          const SizedBox(height: 8),
          BusyButton(label: 'Phân tích', icon: Icons.auto_awesome, onPressed: _send),
          const SizedBox(height: 20),
          Text('Thử các câu:', style: TextStyle(color: context.muted)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in _examples)
              ActionChip(label: Text(e), onPressed: () => setState(() => _text.text = e)),
          ]),
          const SizedBox(height: 24),
          Row(children: [
            Icon(Icons.privacy_tip_outlined, size: 18, color: context.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Chỉ câu bạn gõ cùng tên danh mục và ví được gửi đi phân tích. AI không tự lưu: bạn luôn xem và xác nhận trước.',
                  style: TextStyle(color: context.muted, fontSize: 12.5)),
            ),
          ]),
        ]),
      );
}

/// Bản xem trước: người dùng sửa nếu sai, có thể thêm ảnh, rồi xác nhận mới lưu (đi qua 4.1).
class AiPreviewScreen extends StatefulWidget {
  final List<TxDraft> drafts;
  final List<Uint8List>? images; // ảnh từ "chụp trước, nhập sau" gắn vào giao dịch đầu tiên
  final String? engine;
  final dynamic remaining;
  const AiPreviewScreen({super.key, required this.drafts, this.images, this.engine, this.remaining});
  @override
  State<AiPreviewScreen> createState() => _AiPreviewScreenState();
}

class _AiPreviewScreenState extends State<AiPreviewScreen> {
  late final List<TxDraft> _drafts = [...widget.drafts];
  late final List<List<Uint8List>> _images = [
    for (var i = 0; i < widget.drafts.length; i++) i == 0 ? [...?widget.images] : <Uint8List>[]
  ];
  final Set<int> _saved = {};

  bool _valid(TxDraft d) => (d.amount ?? 0) > 0 && d.categoryId != null && d.walletId != null;

  Future<void> _saveAll() async {
    final pending = [for (var i = 0; i < _drafts.length; i++) if (!_saved.contains(i)) i];
    if (pending.any((i) => !_valid(_drafts[i]))) {
      setState(() {});
      return showInfo(context, 'Còn trường bị trống, hãy chọn giúp AI nhé');
    }
    final data = context.read<AppData>();
    var failedImgs = 0;
    try {
      for (final i in pending) {
        final (_, _, failed) = await data.createTx(_drafts[i], source: 'ai', images: _images[i]);
        failedImgs += failed;
        setState(() => _saved.add(i));
      }
      if (!mounted) return;
      Navigator.pop(context);
      showInfo(context,
          'Đã lưu ${pending.length} giao dịch${failedImgs > 0 ? ' · $failedImgs ảnh chưa tải lên (mở giao dịch để thử lại)' : ''}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Xem trước (${_drafts.length})')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
          if (widget.engine == 'basic')
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Đang dùng bộ phân tích cơ bản (chưa kết nối AI). Kiểm tra kỹ trước khi lưu.',
                  style: TextStyle(color: context.warnColor, fontSize: 12.5)),
            ),
          for (var i = 0; i < _drafts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _saved.contains(i)
                      ? ListTile(leading: Icon(Icons.check_circle, color: context.incomeColor), title: const Text('Đã lưu'))
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Text('Giao dịch ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            const Spacer(),
                            if (_drafts.length > 1)
                              IconButton(
                                tooltip: 'Bỏ giao dịch này',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => setState(() {
                                  _drafts.removeAt(i);
                                  _images.removeAt(i);
                                }),
                              ),
                          ]),
                          TxEditor(
                            key: ObjectKey(_drafts[i]),
                            draft: _drafts[i],
                            images: _images[i],
                            compact: true,
                            onChanged: () => setState(() {}),
                          ),
                        ]),
                ),
              ),
            ),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: BusyButton(
              label: _drafts.length > 1 ? 'Xác nhận lưu ${_drafts.length - _saved.length} giao dịch' : 'Xác nhận lưu',
              onPressed: _saveAll,
            ),
          ),
        ),
      );
}
