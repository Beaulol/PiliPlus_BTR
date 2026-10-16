enum BtrCdnMode { original, mainland, overseas }

bool isBtrMediaUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return (host.endsWith('.bilivideo.com') ||
          host.endsWith('.bilivideo.cn') ||
          host.endsWith('.bilivideo.net') ||
          host.endsWith('.akamaized.net')) &&
      (uri.path.endsWith('.m4s') || uri.path.endsWith('.mp4'));
}

/// Host rewriting is limited to the ordinary upgcxcode media path. A PCDN
/// resource path or a proxy URL is not transferable to an UPOS mirror.
List<Uri> btrCandidates(String source, BtrCdnMode mode) {
  final original = Uri.parse(source);
  if (mode == BtrCdnMode.original || !original.path.startsWith('/upgcxcode/')) {
    return [original];
  }
  const mainland = [
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  ];
  const overseas = [
    'upos-sz-mirrorcosov.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
  ];
  final hosts = mode == BtrCdnMode.mainland ? mainland : overseas;
  return {
    ...hosts.map(
      (host) => original.replace(scheme: 'https', host: host, port: 443),
    ),
    original,
  }.toList();
}

class CdnPool {
  final List<Uri> candidates;
  final Map<Uri, int> _failures = {};
  final Map<Uri, double> _speeds = {};
  final Map<Uri, int> _active = {};
  int _cursor = 0;
  Uri? _startupNode;
  CdnPool(this.candidates);

  void preferOnce(Uri uri) => _startupNode = uri;
  void started(Uri uri) => _active[uri] = (_active[uri] ?? 0) + 1;
  void finished(Uri uri) =>
      _active[uri] = ((_active[uri] ?? 1) - 1).clamp(0, 32);

  List<Uri> ordered() {
    final available = candidates.where((u) => (_failures[u] ?? 0) < 2).toList();
    if (available.isEmpty) return [candidates.last];
    double score(Uri uri) => (_speeds[uri] ?? 0) / ((_active[uri] ?? 0) + 1);
    available.sort((a, b) => score(b).compareTo(score(a)));
    // Distribute primaries across the best measured nodes, retaining an
    // exploration slot so an unmeasured node can demonstrate its throughput.
    final slot = _cursor++;
    final preferredCount = available.length > 3 ? 3 : available.length;
    final hasMeasurements = _speeds.isNotEmpty;
    final index = slot % 8 == 7
        ? (slot ~/ 4) % available.length
        : hasMeasurements
        ? 0
        : slot % preferredCount;
    final preferred = _startupNode;
    _startupNode = null;
    if (preferred != null && available.contains(preferred)) {
      return [preferred, ...available.where((uri) => uri != preferred)];
    }
    return [available[index], ...available.where((u) => u != available[index])];
  }

  void success(Uri uri, int bytes, Duration elapsed) {
    _failures.remove(uri);
    if (bytes < 32 * 1024) return;
    final speed = bytes * 1000000 / (elapsed.inMicroseconds + 1);
    _speeds[uri] = (_speeds[uri] ?? speed) * 0.7 + speed * 0.3;
  }

  void failure(Uri uri) => _failures[uri] = (_failures[uri] ?? 0) + 1;
}
