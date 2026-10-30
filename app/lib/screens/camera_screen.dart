
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/images.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'ai_input_screen.dart';

/// Màn hình chụp nhanh phong cách "Locket" (UC06.1): khung vuông bo góc, nút chụp tròn,
/// đèn flash, đổi camera trước/sau, chuyển khung dọc 3:4 cho hóa đơn dài, chọn từ thư viện.
/// - Chế độ thường: trả về danh sách ảnh (đã nén, xóa EXIF) cho form giao dịch.
/// - quickInput = true ("chụp trước, nhập sau"): dưới ảnh có ô gõ câu, gửi đi để AI tạo bản xem trước.
class CameraScreen extends StatefulWidget {
  final bool quickInput;
  final int maxCount;
  const CameraScreen({super.key, this.quickInput = false, this.maxCount = 3});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _ctl;
  List<CameraDescription> _cams = [];
  int _camIndex = 0;
  FlashMode _flash = FlashMode.off;
  bool _tall = false; // false = vuông 1:1, true = dọc 3:4
  String? _camError;
  Uint8List? _shot; // ảnh vừa chụp, chờ "Dùng ảnh"
  bool _busy = false;
  final List<Uint8List> _taken = [];
  final _text = TextEditingController();

  double get _aspect => _tall ? 3 / 4 : 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctl?.dispose();
    super.dispose();
  }

  /// Tắt camera ngay khi app xuống nền; bật lại khi quay về.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final c = _ctl;
      _ctl = null;
      if (mounted) setState(() {});
      c?.dispose();
    } else if (state == AppLifecycleState.resumed && _ctl == null && _shot == null) {
      _start();
    }
  }

  Future<void> _start() async {
    try {
      _cams = _cams.isEmpty ? await availableCameras() : _cams;
      if (_cams.isEmpty) {
        setState(() => _camError = 'Không tìm thấy camera trên thiết bị này.');
        return;
      }
      final c = CameraController(_cams[_camIndex], ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      try {
        await c.setFlashMode(_flash);
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _ctl = c;
        _camError = null;
      });
    } on CameraException catch (e) {
      setState(() => _camError = e.code == 'CameraAccessDenied' || e.code.contains('Denied')
          ? 'Bạn chưa cấp quyền camera. Hãy bật trong Cài đặt của máy, hoặc chọn ảnh từ thư viện.'
          : 'Không mở được camera.');
    } catch (_) {
      setState(() => _camError = 'Không mở được camera.');
    }
  }

  Future<void> _switch() async {
    if (_cams.length < 2) return;
    _camIndex = (_camIndex + 1) % _cams.length;
    final old = _ctl;
    setState(() => _ctl = null);
    await old?.dispose();
    await _start();
  }

  Future<void> _toggleFlash() async {
    final next = {FlashMode.off: FlashMode.auto, FlashMode.auto: FlashMode.always, FlashMode.always: FlashMode.off}[_flash]!;
    try {
      await _ctl?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final c = _ctl;
    if (c == null || !c.value.isInitialized || _busy) return;
    HapticFeedback.mediumImpact();
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      final raw = await file.readAsBytes();
      final img = await prepareImage(raw, aspect: _aspect);
      if (img == null) throw Exception();
      setState(() => _shot = img);
    } catch (_) {
      if (mounted) showInfo(context, 'Chụp ảnh không thành công, thử lại nhé');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickGallery() async {
    final remain = widget.quickInput ? 1 : widget.maxCount - _taken.length;
    if (remain <= 0) return;
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final files = remain == 1
          ? [await picker.pickImage(source: ImageSource.gallery)].whereType<XFile>().toList()
          : await picker.pickMultiImage(limit: remain);
      for (final f in files.take(remain)) {
        final img = await prepareImage(await f.readAsBytes());
        if (img == null) {
          if (mounted) showInfo(context, 'Chỉ nhận ảnh JPEG, PNG hoặc WebP');
          continue;
        }
        if (img.length > maxImageBytes) {
          if (mounted) showInfo(context, 'Ảnh vượt quá 5 MB');
          continue;
        }
        if (widget.quickInput) {
          setState(() => _shot = img);
          return;
        }
        _taken.add(img);
      }
      if (!widget.quickInput && _taken.isNotEmpty && mounted) Navigator.pop(context, _taken);
    } catch (_) {
      if (mounted) showInfo(context, 'Không mở được thư viện ảnh');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _useShot() {
    final s = _shot!;
    if (widget.quickInput) return; // ở chế độ nhập nhanh, ảnh dùng kèm ô nhập câu bên dưới
    _taken.add(s);
    setState(() => _shot = null);
    if (_taken.length >= widget.maxCount) {
      Navigator.pop(context, _taken);
    }
  }

  Future<void> _sendQuick() async {
    final text = _text.text.trim();
    if (text.isEmpty) return showInfo(context, 'Gõ một câu, vd "bánh mì 20k"');
    setState(() => _busy = true);
    try {
      final r = await context.read<ApiClient>().post('/ai/parse', {'text': text});
      final drafts = ((r['items'] as List?) ?? []).map((e) => TxDraft.fromJson(Map<String, dynamic>.from(e))).toList();
      if (!mounted) return;
      if (drafts.isEmpty) {
        showInfo(context, 'Chưa hiểu câu này, thử ghi rõ số tiền, vd "bánh mì 20k"');
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => AiPreviewScreen(drafts: drafts, images: [_shot!], engine: r['engine'] as String?)),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final frameW = size.width - 32;
    final frame = AspectRatio(
      aspectRatio: _aspect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(36),
        child: ColoredBox(
          color: const Color(0xFF1E1E1E),
          child: _shot != null
              ? Image.memory(_shot!, fit: BoxFit.cover)
              : _ctl != null && _ctl!.value.isInitialized
                  ? FittedBox(
                      fit: BoxFit.cover,
                      clipBehavior: Clip.hardEdge,
                      child: SizedBox(
                        width: frameW,
                        height: frameW * (_ctl!.value.aspectRatio > 1 ? _ctl!.value.aspectRatio : 1 / _ctl!.value.aspectRatio),
                        child: CameraPreview(_ctl!),
                      ),
                    )
                  : Center(
                      child: _camError == null
                          ? const CircularProgressIndicator(color: Colors.white)
                          : Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(_camError!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                            ),
                    ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.quickInput ? 'Chụp trước, nhập sau' : 'Chụp ảnh giao dịch',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        actions: [
          if (!widget.quickInput && _taken.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, _taken),
              child: Text('Xong (${_taken.length})', style: const TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              const SizedBox(height: 8),
              frame,
              const SizedBox(height: 20),
              if (_shot == null) _controls() else _review(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final flashIcon = {FlashMode.off: Icons.flash_off, FlashMode.auto: Icons.flash_auto, FlashMode.always: Icons.flash_on}[_flash] ?? Icons.flash_off;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _round(icon: flashIcon, tip: 'Đèn flash', onTap: _toggleFlash),
        GestureDetector(
          onTap: _capture,
          child: Semantics(
            button: true,
            label: 'Chụp',
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFFF2C94C), width: 5)),
              padding: const EdgeInsets.all(5),
              child: Container(
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                child: _busy ? const Padding(padding: EdgeInsets.all(22), child: CircularProgressIndicator(strokeWidth: 3)) : null,
              ),
            ),
          ),
        ),
        _round(icon: Icons.cameraswitch_outlined, tip: 'Đổi camera', onTap: _switch),
      ]),
      const SizedBox(height: 22),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        TextButton.icon(
          onPressed: _busy ? null : _pickGallery,
          icon: const Icon(Icons.photo_library_outlined, color: Colors.white),
          label: const Text('Thư viện', style: TextStyle(color: Colors.white)),
        ),
        const SizedBox(width: 16),
        TextButton.icon(
          onPressed: () => setState(() => _tall = !_tall),
          icon: Icon(_tall ? Icons.crop_square : Icons.crop_portrait, color: Colors.white),
          label: Text(_tall ? 'Khung vuông' : 'Khung dọc 3:4', style: const TextStyle(color: Colors.white)),
        ),
      ]),
      if (!widget.quickInput && widget.maxCount > 1)
        Text('Tối đa ${widget.maxCount} ảnh · đã chụp ${_taken.length}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }

  Widget _review() {
    if (widget.quickInput) {
      return Column(children: [
        TextField(
          controller: _text,
          autofocus: true,
          maxLength: 300,
          style: const TextStyle(color: Colors.white, fontSize: 17),
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _sendQuick(),
          decoration: InputDecoration(
            hintText: 'Gõ nhanh, vd "bánh mì 20k"',
            hintStyle: const TextStyle(color: Colors.white54),
            filled: true,
            fillColor: Colors.white12,
            counterStyle: const TextStyle(color: Colors.white38),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            suffixIcon: IconButton(
              tooltip: 'Gửi',
              onPressed: _busy ? null : _sendQuick,
              icon: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded, color: Color(0xFFF2C94C)),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () {
            setState(() => _shot = null);
            if (_ctl == null) _start();
          },
          icon: const Icon(Icons.refresh, color: Colors.white),
          label: const Text('Chụp lại', style: TextStyle(color: Colors.white)),
        ),
      ]);
    }
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
          onPressed: () => setState(() => _shot = null),
          icon: const Icon(Icons.refresh),
          label: const Text('Chụp lại'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF2C94C), foregroundColor: Colors.black),
          onPressed: _useShot,
          icon: const Icon(Icons.check),
          label: const Text('Dùng ảnh'),
        ),
      ),
    ]);
  }

  Widget _round({required IconData icon, required String tip, required VoidCallback onTap}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        style: IconButton.styleFrom(backgroundColor: Colors.white12, fixedSize: const Size(52, 52)),
        icon: Icon(icon, color: Colors.white),
      );
}
