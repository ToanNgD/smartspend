import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/app_data.dart';

/// Số tiền tôn trọng chế độ ẩn số tiền ("••••••", chạm để hiện) - 7.1.
class Money extends StatelessWidget {
  final num amount;
  final TextStyle? style;
  final bool colored;
  final bool sign;
  final bool short;
  const Money(this.amount, {super.key, this.style, this.colored = false, this.sign = false, this.short = false});

  @override
  Widget build(BuildContext context) {
    final hide = context.select<AppData, bool>((d) => d.hideAmounts);
    final color = colored ? (amount >= 0 ? context.incomeColor : context.expenseColor) : null;
    final text = hide ? hiddenMoney : (short ? vndShort(amount) : vnd(amount, sign: sign));
    final w = Text(text, style: (style ?? const TextStyle()).copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]));
    if (!hide) return w;
    return GestureDetector(onTap: () => context.read<AppData>().toggleHide(), child: w);
  }
}

const iconMap = <String, IconData>{
  'food': Icons.restaurant_rounded,
  'car': Icons.directions_car_rounded,
  'bag': Icons.shopping_bag_rounded,
  'bolt': Icons.bolt_rounded,
  'home': Icons.home_rounded,
  'play': Icons.sports_esports_rounded,
  'health': Icons.favorite_rounded,
  'book': Icons.menu_book_rounded,
  'dots': Icons.more_horiz_rounded,
  'wallet': Icons.account_balance_wallet_rounded,
  'star': Icons.star_rounded,
  'gift': Icons.card_giftcard_rounded,
  'coffee': Icons.local_cafe_rounded,
  'pet': Icons.pets_rounded,
  'baby': Icons.child_friendly_rounded,
  'phone': Icons.smartphone_rounded,
  'plane': Icons.flight_rounded,
  'shirt': Icons.checkroom_rounded,
  'gym': Icons.fitness_center_rounded,
  'heart': Icons.volunteer_activism_rounded,
  'tool': Icons.build_rounded,
  'chart': Icons.trending_up_rounded,
};

Color hexColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x8B9590;
  return Color(0xFF000000 | v);
}

class CategoryIcon extends StatelessWidget {
  final String icon;
  final String color;
  final double size;
  const CategoryIcon({super.key, required this.icon, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final c = hexColor(color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(iconMap[icon] ?? Icons.more_horiz_rounded, color: c, size: size * 0.55),
    );
  }
}

IconData walletIcon(String type) => switch (type) {
      'bank' => Icons.account_balance_rounded,
      'ewallet' => Icons.phone_iphone_rounded,
      _ => Icons.payments_rounded,
    };

/// Thanh tiến độ ngân sách: xanh < 80%, vàng 80-99%, đỏ >= 100% (5.1).
class BudgetBar extends StatelessWidget {
  final double percent;
  final double height;
  const BudgetBar({super.key, required this.percent, this.height = 10});

  @override
  Widget build(BuildContext context) {
    final color = percent >= 100
        ? context.expenseColor
        : percent >= 80
            ? context.warnColor
            : context.incomeColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: (percent / 100).clamp(0, 1),
        minHeight: height,
        color: color,
        backgroundColor: color.withValues(alpha: 0.15),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          if (trailing != null) trailing!,
        ]),
      );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: context.muted),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      );
}

void showError(BuildContext context, Object e) {
  final msg = e is ApiException ? e.message : 'Có lỗi xảy ra, vui lòng thử lại.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

void showInfo(BuildContext context, String msg, {SnackBarAction? action, Duration? duration}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), action: action, duration: duration ?? const Duration(seconds: 4)));
}

Future<bool> confirm(BuildContext context, String title, String message,
    {String ok = 'Đồng ý', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Hủy')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: c.expenseColor) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

/// Nút có trạng thái đang xử lý, chống bấm nhiều lần.
class BusyButton extends StatefulWidget {
  final String label;
  final Future<void> Function()? onPressed;
  final IconData? icon;
  const BusyButton({super.key, required this.label, required this.onPressed, this.icon});
  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
        : Text(widget.label);
    final onTap = widget.onPressed == null || busy
        ? null
        : () async {
            setState(() => busy = true);
            try {
              await widget.onPressed!();
            } finally {
              if (mounted) setState(() => busy = false);
            }
          };
    return SizedBox(
      width: double.infinity,
      child: widget.icon == null || busy
          ? FilledButton(onPressed: onTap, child: child)
          : FilledButton.icon(onPressed: onTap, icon: Icon(widget.icon), label: child),
    );
  }
}
