/// Giới hạn tần suất đơn giản trong bộ nhớ (cửa sổ trượt cố định).
/// Đủ dùng cho một server; nếu chạy nhiều server thì chuyển sang Redis.
class RateLimiter {
  final int limit;
  final Duration window;
  final _hits = <String, List<DateTime>>{};
  RateLimiter(this.limit, this.window);

  /// true nếu còn được phép, đồng thời ghi nhận một lượt.
  bool hit(String key) {
    final now = DateTime.now();
    final list = _hits.putIfAbsent(key, () => []);
    list.removeWhere((t) => now.difference(t) > window);
    if (list.length >= limit) return false;
    list.add(now);
    if (_hits.length > 20000) _gc(now);
    return true;
  }

  int count(String key) {
    final now = DateTime.now();
    final list = _hits[key];
    if (list == null) return 0;
    list.removeWhere((t) => now.difference(t) > window);
    return list.length;
  }

  void reset(String key) => _hits.remove(key);

  void _gc(DateTime now) {
    _hits.removeWhere((_, v) {
      v.removeWhere((t) => now.difference(t) > window);
      return v.isEmpty;
    });
  }
}
