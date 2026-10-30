import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../state/app_data.dart';

/// Tải dữ liệu GET một lần; chỉ tải lại khi tham số đổi hoặc giao dịch thay đổi (txVersion).
class Fetch extends StatefulWidget {
  final String path;
  final Map<String, dynamic>? query;
  final Widget Function(BuildContext context, dynamic data) builder;
  final double loadingHeight;
  const Fetch({super.key, required this.path, this.query, required this.builder, this.loadingHeight = 120});
  @override
  State<Fetch> createState() => _FetchState();
}

class _FetchState extends State<Fetch> {
  Future<dynamic>? _f;
  String _sig = '';
  dynamic _last;

  @override
  Widget build(BuildContext context) {
    final v = context.select<AppData, int>((d) => d.txVersion);
    final sig = '${widget.path}|${widget.query}|$v';
    if (sig != _sig) {
      _sig = sig;
      _f = context.read<ApiClient>().get(widget.path, query: widget.query == null ? null : Map.of(widget.query!)).then((d) => _last = d);
    }
    return FutureBuilder(
      future: _f,
      builder: (c, s) {
        if (s.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const Icon(Icons.error_outline),
              const SizedBox(width: 8),
              Expanded(child: Text(s.error.toString())),
              TextButton(onPressed: () => setState(() => _sig = ''), child: const Text('Thử lại')),
            ]),
          );
        }
        final data = s.hasData ? s.data : _last;
        if (data == null) {
          return SizedBox(height: widget.loadingHeight, child: const Center(child: CircularProgressIndicator()));
        }
        return widget.builder(c, data);
      },
    );
  }
}
