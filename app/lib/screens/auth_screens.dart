import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Kiểm tra mật khẩu ngay trên máy (server vẫn kiểm tra lại): tối thiểu 8 ký tự, có chữ và số.
String? passwordRule(String? v) {
  final s = v ?? '';
  if (s.length < 8) return 'Mật khẩu tối thiểu 8 ký tự';
  if (!RegExp(r'[A-Za-zÀ-ỹ]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) return 'Mật khẩu phải gồm cả chữ và số';
  return null;
}

class _AuthFrame extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> children;
  const _AuthFrame({required this.title, required this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/images/logo.png', width: 48, height: 48),
                    ),
                    const SizedBox(width: 12),
                    Text('SmartSpend', style: Theme.of(context).textTheme.titleLarge),
                  ]),
                  const SizedBox(height: 28),
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(subtitle, style: TextStyle(color: context.muted)),
                  const SizedBox(height: 24),
                  ...children,
                ]),
              ),
            ),
          ),
        ),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pw = TextEditingController();
  bool _show = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _error = null);
    try {
      await context.read<Session>().login(_email.text, _pw.text);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = context.watch<Session>().message;
    return _AuthFrame(
      title: 'Đăng nhập',
      subtitle: 'Chào mừng bạn quay lại.',
      children: [
        if (msg != null && _error == null) _Banner(msg),
        if (_error != null) _Banner(_error!, error: true),
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(children: [
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                validator: (v) => _emailRe.hasMatch((v ?? '').trim()) ? null : 'Email không đúng định dạng',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pw,
                obscureText: !_show,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
                validator: (v) => (v ?? '').isEmpty ? 'Nhập mật khẩu' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        BusyButton(label: 'Đăng nhập', onPressed: _submit),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
          child: const Text('Chưa có tài khoản? Đăng ký'),
        ),
      ],
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _error = null);
    try {
      await context.read<Session>().register(_name.text, _email.text, _pw.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Tạo tài khoản',
        subtitle: 'Dữ liệu tài chính của bạn được tách riêng và bảo vệ.',
        children: [
          if (_error != null) _Banner(_error!, error: true),
          Form(
            key: _form,
            child: Column(children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Họ tên', prefixIcon: Icon(Icons.person_outline)),
                textCapitalization: TextCapitalization.words,
                maxLength: 100,
                validator: (v) => (v ?? '').trim().isEmpty ? 'Nhập họ tên' : null,
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                keyboardType: TextInputType.emailAddress,
                validator: (v) => _emailRe.hasMatch((v ?? '').trim()) ? null : 'Email không đúng định dạng',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pw,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Mật khẩu', helperText: 'Tối thiểu 8 ký tự, gồm cả chữ và số', prefixIcon: Icon(Icons.lock_outline)),
                validator: passwordRule,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pw2,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Xác nhận mật khẩu', prefixIcon: Icon(Icons.lock_outline)),
                validator: (v) => v == _pw.text ? null : 'Mật khẩu xác nhận không khớp',
              ),
            ]),
          ),
          const SizedBox(height: 20),
          BusyButton(label: 'Đăng ký', onPressed: _submit),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đã có tài khoản? Đăng nhập')),
        ],
      );
}

class _Banner extends StatelessWidget {
  final String text;
  final bool error;
  const _Banner(this.text, {this.error = false});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (error ? context.expenseColor : context.warnColor).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(error ? Icons.error_outline : Icons.info_outline, color: error ? context.expenseColor : context.warnColor),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ]),
      );
}
