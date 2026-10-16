import 'dart:math' as math;

/// Inclusive byte range. No multipart responses are produced by BTR.
class ByteRange {
  final int start;
  final int end;
  const ByteRange(this.start, this.end);
  int get length => end - start + 1;
  String get header => 'bytes=$start-$end';

  static ByteRange? resolve(String? header, int total) {
    if (total <= 0) return null;
    if (header == null) return ByteRange(0, total - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final first = match[1]!;
    final last = match[2]!;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      return suffix == null || suffix <= 0
          ? null
          : ByteRange(math.max(0, total - suffix), total - 1);
    }
    final start = int.tryParse(first);
    final end = last.isEmpty ? total - 1 : int.tryParse(last);
    if (start == null || end == null || start >= total || end < start) {
      return null;
    }
    return ByteRange(start, math.min(end, total - 1));
  }
}

class ContentRange {
  final ByteRange range;
  final int total;
  const ContentRange(this.range, this.total);

  static ContentRange? parse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        total == null ||
        start > end ||
        end >= total) {
      return null;
    }
    return ContentRange(ByteRange(start, end), total);
  }
}
