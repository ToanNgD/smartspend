import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/vault.dart';
import '../state/session.dart';

/// Bàn phím PIN 6 số.
class PinPad extends StatelessWidget {
  final int length;
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onBiometric;
  final bool error;
  const PinPad({super.key, required this.value, required this.onChanged, this.length = 6, this.onBiometric, this.error = false});

  void _tap(String d) {
    if (value.length >= length) return;
    HapticFeedback.selectionClick();
    onChanged(value + d);
  }

  @override
  Widget build(BuildContext context) {
    final dots = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final filled = i < value.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? (error ? context.expenseColor : context.cs.primary) : Colors.transparent,
            border: Border.all(color: error ? context.expenseColor : context.cs.outline, width: 1.6),
          ),
        );
      }),
    );
    Widget key(String d) => _Key(label: d, onTap: () => _tap(d));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      dots,
      const SizedBox(height: 36),
      for (final row in [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
        Row(mainAxisAlignment: MainAxisAlignment.center, children: row.map(key).toList()),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        onBiometric == null
            ? const SizedBox(width: 88, height: 76)
            : _Key(icon: Icons.fingerprint, onTap: onBiometric!, semantic: 'Mở bằng sinh trắc học'),
        key('0'),
        _Key(
          icon: Icons.backspace_outlined,
          semantic: 'Xóa',
          onTap: () => value.isEmpty ? null : onChanged(value.substring(0, value.length - 1)),
        ),
      ]),
    ]);
  }
}

class _Key extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final String? semantic;
  const _Key({this.label, this.icon, required this.onTap, this.semantic});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(6),
        child: Semantics(
          button: true,
          label: semantic ?? label,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 76,
              height: 64,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 28)
                    : Text(label!, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ),
      );
}

/// Màn hình khóa: mỗi lần mở app hoặc quay lại sau hơn 60 giây.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _msg;
  bool _error = false, _busy = false, _bio = false;

  @override
  void initState() {
    super.initState();
    final v = context.read<Session>().vault;
    v.biometricEnabled().then((on) async {
      if (!on || !await v.biometricAvailable()) return;
      if (!mounted) return;
      setState(() => _bio = true);
      _tryBio();
    });
  }

  Future<void> _tryBio() async {
    if (_busy) return;
    _busy = true;
    await context.read<Session>().unlockWithBiometric();
    _busy = false;
  }

  Future<void> _onChanged(String v) async {
    setState(() {
      _pin = v;
      _error = false;
    });
    if (v.length < 6 || _busy) return;
    setState(() => _busy = true);
    final left = await context.read<Session>().unlockWithPin(v);
    if (mounted) setState(() => _busy = false);
    if (!mounted || left == null) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _error = true;
      _pin = '';
      _msg = 'Sai mã PIN. Còn $left lần thử.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<Session>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(children: [
              Icon(Icons.lock_rounded, size: 40, color: context.cs.primary),
              const SizedBox(height: 12),
              Text('Nhập mã PIN', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(_msg ?? 'Để mở SmartSpend', style: TextStyle(color: _error ? context.expenseColor : context.muted)),
              SizedBox(
                height: 32,
                child: _busy
                    ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
              PinPad(value: _pin, onChanged: _onChanged, error: _error, onBiometric: _bio ? _tryBio : null),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => s.logout(message: 'Đăng nhập lại để đặt mã PIN mới.'),
                child: const Text('Quên PIN? Đăng nhập lại'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Thiết lập khóa sau lần đăng nhập đầu tiên: PIN 6 số + sinh trắc học (nếu máy hỗ trợ).
class SetupLockScreen extends StatefulWidget {
  /// Dùng lại để đổi PIN trong Cài đặt.
  final bool changeOnly;
  const SetupLockScreen({super.key, this.changeOnly = false});
  @override
  State<SetupLockScreen> createState() => _SetupLockScreenState();
}

class _SetupLockScreenState extends State<SetupLockScreen> {
  String _first = '', _pin = '';
  bool _confirming = false, _error = false, _bioAvailable = false, _bio = true, _saving = false;

  @override
  void initState() {
    super.initState();
    Vault v = context.read<Session>().vault;
    v.biometricAvailable().then((a) => mounted ? setState(() => _bioAvailable = a) : null);
  }

  Future<void> _onChanged(String v) async {
    setState(() {
      _pin = v;
      _error = false;
    });
    if (v.length < 6) return;
    if (!_confirming) {
      if (RegExp(r'^(\d)\1{5}$').hasMatch(v) || '0123456789'.contains(v) || '9876543210'.contains(v)) {
        setState(() {
          _pin = '';
          _error = true;
        });
        return;
      }
      setState(() {
        _first = v;
        _pin = '';
        _confirming = true;
      });
      return;
    }
    if (v != _first) {
      HapticFeedback.heavyImpact();
      setState(() {
        _pin = '';
        _first = '';
        _confirming = false;
        _error = true;
      });
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    final s = context.read<Session>();
    try {
      if (widget.changeOnly) {
        await s.vault.setPin(v);
        if (mounted) Navigator.pop(context, true);
      } else {
        await s.completeLockSetup(v, biometric: _bioAvailable && _bio);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _confirming ? 'Nhập lại mã PIN' : (widget.changeOnly ? 'Mã PIN mới' : 'Tạo mã PIN 6 số');
    final sub = _error
        ? (_confirming ? '' : 'PIN quá dễ đoán hoặc không khớp, hãy thử lại')
        : 'PIN dùng để mở khóa app và bảo vệ dữ liệu trên máy';
    return Scaffold(
      appBar: widget.changeOnly ? AppBar(title: const Text('Đổi mã PIN')) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(children: [
              Icon(Icons.shield_rounded, size: 40, color: context.cs.primary),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(sub, textAlign: TextAlign.center, style: TextStyle(color: _error ? context.expenseColor : context.muted)),
              ),
              SizedBox(
                height: 28,
                child: _saving
                    ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
              PinPad(value: _pin, onChanged: _onChanged, error: _error),
              if (_bioAvailable && !widget.changeOnly)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  child: SwitchListTile(
                    value: _bio,
                    onChanged: (v) => setState(() => _bio = v),
                    title: const Text('Mở khóa bằng vân tay / khuôn mặt'),
                    secondary: const Icon(Icons.fingerprint),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
