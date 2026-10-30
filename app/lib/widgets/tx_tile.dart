import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import 'common.dart';

class TxTile extends StatelessWidget {
  final Tx tx;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  const TxTile({super.key, required this.tx, this.onTap, this.onLongPress, this.selected = false});

  @override
  Widget build(BuildContext context) => ListTile(
        selected: selected,
        onTap: onTap,
        onLongPress: onLongPress,
        leading: selected
            ? CircleAvatar(backgroundColor: context.cs.primary, child: Icon(Icons.check, color: context.cs.onPrimary))
            : CategoryIcon(icon: tx.categoryIcon, color: tx.categoryColor),
        title: Text(tx.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Row(children: [
          Flexible(
            child: Text('${tx.categoryName} · ${tx.walletName} · ${fmtTime(tx.occurredAt)}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.muted, fontSize: 12.5)),
          ),
          if (tx.attachmentCount > 0) ...[
            const SizedBox(width: 6),
            Icon(Icons.photo_outlined, size: 14, color: context.muted),
            Text('${tx.attachmentCount}', style: TextStyle(color: context.muted, fontSize: 12)),
          ],
          if (tx.source == 'ai') ...[
            const SizedBox(width: 6),
            Icon(Icons.auto_awesome, size: 13, color: context.muted),
          ],
        ]),
        trailing: Money(tx.signed, colored: true, sign: true, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
}
