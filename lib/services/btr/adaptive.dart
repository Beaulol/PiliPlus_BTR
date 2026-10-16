/// Bounded feedback controller. The user chooses the ceiling; stalls/low
/// buffer increase capacity, sustained ample buffer reduces it gradually.
class BtrAdaptiveConcurrency {
  final int maximum;
  int current;
  int _lastChangeMs = -10000;
  int _comfortableSamples = 0;
  BtrAdaptiveConcurrency(int maximum)
    : maximum = maximum.clamp(1, 32),
      current = maximum.clamp(1, 8);

  int observe({
    required double ahead,
    required bool buffering,
    required bool playing,
    required int nowMs,
  }) {
    if (!playing && !buffering) return current;
    if (nowMs - _lastChangeMs < 3000) return current;
    if (buffering || ahead < 6) {
      current = (current + 4).clamp(1, maximum);
      _comfortableSamples = 0;
      _lastChangeMs = nowMs;
    } else if (ahead > 35) {
      if (++_comfortableSamples >= 5) {
        current = (current - 2).clamp(maximum < 4 ? 1 : 4, maximum);
        _comfortableSamples = 0;
        _lastChangeMs = nowMs;
      }
    } else {
      _comfortableSamples = 0;
    }
    return current;
  }
}
