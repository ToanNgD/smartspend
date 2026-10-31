import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/push.dart';
import 'core/secure_cache.dart';
import 'core/theme.dart';
import 'core/token_store.dart';
import 'core/vault.dart';
import 'screens/auth_screens.dart';
import 'screens/lock_screens.dart';
import 'screens/shell.dart';
import 'state/app_data.dart';
import 'state/session.dart';
import 'widgets/secure_image.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bản phát hành: nếu một ô giao diện lỗi thì hiện thông báo nhỏ thay vì vùng trống.
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => const Material(
          color: Colors.transparent,
          child: Center(child: Padding(padding: EdgeInsets.all(16), child: Text('Không hiển thị được nội dung này'))),
        );
  }
  await initializeDateFormatting('vi');
  final tokens = TokenStore();
  final api = ApiClient(tokens);
  final vault = Vault();
  final cache = SecureCache(vault);
  final push = PushService(api);
  final session = Session(tokens: tokens, api: api, vault: vault, cache: cache, push: push);
  final data = AppData(api, cache);

  push.onOpen = session.openLink;
  push.onForeground = (title, body, d) => messengerKey.currentState?.showSnackBar(SnackBar(
        content: Text('$title\n$body'),
        duration: const Duration(seconds: 6),
      ));

  runApp(MultiProvider(
    providers: [
      Provider.value(value: api),
      ChangeNotifierProvider.value(value: session),
      ChangeNotifierProvider.value(value: data),
    ],
    child: const SmartSpendApp(),
  ));
  session.init();
}

class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SmartSpend',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('vi'),
        supportedLocales: const [Locale('vi'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const HomeShell(),
        // Chạm ra ngoài ô nhập để ẩn bàn phím (iOS không tự có nút đóng bàn phím số).
        builder: (context, child) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: _Gate(child: child!),
        ),
      );
}

/// Cổng điều hướng theo trạng thái phiên: đăng nhập -> thiết lập khóa -> khóa -> app.
class _Gate extends StatefulWidget {
  final Widget child;
  const _Gate({required this.child});
  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool _everReady = false;
  SessionStatus? _last;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    if (s.status != _last) {
      if (s.status == SessionStatus.loggedOut && _last != null) {
        // Đăng xuất: xóa dữ liệu trong bộ nhớ.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          context.read<AppData>().clear();
          SecureImage.clearMemory();
        });
        _everReady = false;
      }
      _last = s.status;
    }
    Widget body;
    switch (s.status) {
      case SessionStatus.loading:
        body = const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionStatus.loggedOut:
        body = Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const LoginScreen()));
      case SessionStatus.setupLock:
        body = const SetupLockScreen();
      case SessionStatus.locked:
        // Màn hình khóa phủ lên toàn bộ app; nội dung bên dưới không được vẽ.
        body = _everReady
            ? Stack(children: [Offstage(child: widget.child), const LockScreen()])
            : const LockScreen();
      case SessionStatus.ready:
        _everReady = true;
        body = widget.child;
    }
    return Stack(children: [
      Positioned.fill(child: body),
      // Che nội dung trong màn hình đa nhiệm (danh sách ứng dụng gần đây).
      if (s.obscured && s.status != SessionStatus.loggedOut)
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset('assets/images/logo.png', width: 88, height: 88),
              ),
            ),
          ),
        ),
    ]);
  }
}
