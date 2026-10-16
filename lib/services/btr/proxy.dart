// Relative imports keep the standalone CDN harness usable without Flutter.
// ignore_for_file: always_use_package_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'cdn_pool.dart';
import 'range.dart';
import 'adaptive.dart';

enum BtrTakeover { full, compatible }

class BtrOptions {
  final int concurrency;
  final BtrCdnMode mode;
  final Duration timeout;
  final BtrTakeover takeover;
  final bool autoConcurrency;
  const BtrOptions({
    this.concurrency = 8,
    this.mode = BtrCdnMode.mainland,
    this.timeout = const Duration(seconds: 12),
    this.takeover = BtrTakeover.compatible,
    this.autoConcurrency = false,
  });
}

class BtrStats {
  int downloadedBytes = 0;
  int completedPieces = 0;
  int retries = 0;
  int fallbacks = 0;
  int activeRequests = 0;
  int peakRequests = 0;
  String lastHost = '';
  int concurrency = 0;
  int hedges = 0;
  int cacheHits = 0;
  int cacheBytes = 0;
  int connections = 0;
  int deliveredBytes = 0;
  double bufferedAhead = 0;
  int bufferingEvents = 0;
}

class _Cancelled implements Exception {}

/// A request's client is closed on seek/disconnect as well as session disposal.
/// This also cancels response streams after HTTP headers have arrived.
class _Job {
  final HttpClient client;
  final bool ownsClient;
  final Completer<void> _cancelled = Completer<void>();
  final List<void Function()> onCancel = [];
  final Set<_Job> children = {};
  bool cancelled = false;
  _Job({HttpClient? client})
    : ownsClient = client == null,
      client = client ?? (HttpClient()..autoUncompress = false);
  Future<T> guard<T>(Future<T> future) => Future.any([
    future,
    _cancelled.future.then<T>((_) => throw _Cancelled()),
  ]);
  void check() {
    if (cancelled) throw _Cancelled();
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
    for (final child in children.toList()) {
      child.cancel();
    }
    for (final callback in onCancel) {
      callback();
    }
    onCancel.clear();
    if (ownsClient) client.close(force: true);
  }
}

class _Waiter {
  final _Job job;
  int priority;
  final bool rescue;
  final Completer<void> ready = Completer<void>();
  _Waiter(this.job, this.priority, this.rescue);
}

class _Gate {
  int limit;
  final bool reserveRescue;
  int _active = 0;
  int _primary = 0;
  final List<_Waiter> _waiting = [];
  _Gate(this.limit, {this.reserveRescue = false});

  void setLimit(int value) {
    limit = value.clamp(1, 32);
    _drain();
  }

  void promote(_Job job) {
    for (final entry in _waiting) {
      if (entry.job == job || job.children.contains(entry.job)) {
        entry.priority = 0;
      }
    }
    _drain();
  }

  void _drain() {
    _waiting.sort((a, b) => a.priority.compareTo(b.priority));
    while (_active < limit) {
      final index = _waiting.indexWhere(
        (entry) =>
            entry.rescue || !reserveRescue || _primary < math.max(1, limit - 1),
      );
      if (index < 0) return;
      final entry = _waiting.removeAt(index);
      if (entry.job.cancelled) {
        entry.ready.completeError(_Cancelled());
        continue;
      }
      _active++;
      if (!entry.rescue) _primary++;
      entry.ready.complete();
    }
  }

  Future<T> run<T>(
    _Job job,
    Future<T> Function() action, {
    int priority = 1,
    bool rescue = false,
  }) async {
    job.check();
    final entry = _Waiter(job, priority, rescue);
    _waiting.add(entry);
    job.onCancel.add(() {
      if (_waiting.remove(entry)) entry.ready.completeError(_Cancelled());
    });
    _drain();
    await entry.ready.future;
    try {
      job.check();
      return await action();
    } finally {
      _active--;
      if (!rescue) _primary--;
      _drain();
    }
  }
}

class _Track {
  final Uri original;
  final CdnPool pool;
  int? total;
  String contentType = 'application/octet-stream';
  bool rangeUnsupported = false;
  final int? bitRate;
  final bool audio;
  final Map<int, _CacheEntry> cache = {};
  int demandBlock = 0;
  int generation = 0;
  bool awaitingSeek = false;
  final Set<_Job> readers = {};
  _Track(this.original, this.pool, {this.bitRate, this.audio = false});
  int get maxBlocks => audio ? 8 : 32;
}

class _Outcome {
  final Uint8List? bytes;
  final Object? error;
  const _Outcome.data(this.bytes) : error = null;
  const _Outcome.error(this.error) : bytes = null;
}

class _CacheEntry {
  final _Job job = _Job();
  late Future<_Outcome> result;
  Uint8List? bytes;
  int touched = 0;
}

class _Progress {
  int bytes = 0;
  final Stopwatch clock = Stopwatch()..start();
}

/// One session owns both tracks and a shared network concurrency limit.
/// Original player URLs remain outside this class for casting and URL refresh.
class BtrSession {
  final BtrProxy _proxy;
  final BtrOptions options;
  final BtrStats stats = BtrStats();
  final Set<_Job> _jobs = {};
  final List<String> _tokens = [];
  final Map<String, HttpClient> _clients = {};
  final Set<_Track> _tracks = {};
  late final _adaptive = BtrAdaptiveConcurrency(options.concurrency);
  late final _gate = _Gate(
    options.autoConcurrency
        ? _adaptive.current
        : options.concurrency.clamp(1, 32),
    reserveRescue: options.takeover == BtrTakeover.full,
  );
  final Stopwatch _clock = Stopwatch()..start();
  int _activeHedges = 0;
  bool _buffering = true;
  bool _disposed = false;
  BtrSession._(this._proxy, this.options) {
    stats.concurrency = _gate.limit;
  }

  void updatePlayback({
    required double bufferedAhead,
    required bool buffering,
    required bool playing,
  }) {
    if (_disposed) return;
    if (buffering && !_buffering) stats.bufferingEvents++;
    _buffering = buffering;
    stats.bufferedAhead = math.max(0, bufferedAhead);
    if (options.autoConcurrency) {
      _gate.setLimit(
        _adaptive.observe(
          ahead: stats.bufferedAhead,
          buffering: buffering,
          playing: playing,
          nowMs: _clock.elapsedMilliseconds,
        ),
      );
      stats.concurrency = _gate.limit;
    }
    if (options.takeover == BtrTakeover.full && (playing || buffering)) {
      for (final track in _tracks) {
        if (track.total != null && !track.rangeUnsupported) _prefetch(track);
      }
    }
  }

  void onSeek() {
    if (_disposed || options.takeover != BtrTakeover.full) return;
    for (final track in _tracks) {
      track.generation++;
      track.awaitingSeek = true;
      for (final reader in track.readers.toList()) {
        reader.cancel();
      }
      final obsolete = track.cache.entries
          .where((e) => e.value.bytes == null)
          .toList();
      for (final entry in obsolete) {
        entry.value.job.cancel();
        track.cache.remove(entry.key);
      }
    }
  }

  String register(String source, {int? bitRate, bool audio = false}) {
    if (_disposed) throw StateError('BTR session disposed');
    if (!isBtrMediaUrl(source)) return source;
    return registerCandidates(
      btrCandidates(source, options.mode),
      bitRate: bitRate,
      audio: audio,
    );
  }

  /// Explicit candidates are also used by the local fake-CDN test harness.
  /// The HTTP endpoint itself never accepts upstream URLs from a caller.
  String registerCandidates(
    List<Uri> candidates, {
    int? bitRate,
    bool audio = false,
  }) {
    if (_disposed || candidates.isEmpty) {
      throw StateError('Invalid BTR session');
    }
    final token = _proxy._token();
    _tokens.add(token);
    final track = _Track(
      candidates.last,
      CdnPool(candidates),
      bitRate: bitRate,
      audio: audio,
    );
    _tracks.add(track);
    _proxy._routes[token] = (this, track);
    return 'http://127.0.0.1:${_proxy._server!.port}/btr/$token';
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final token in _tokens) {
      _proxy._routes.remove(token);
    }
    for (final job in _jobs.toList()) {
      job.cancel();
    }
    _jobs.clear();
    for (final client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
    _tracks.clear();
    stats.cacheBytes = 0;
    _proxy._sessions.remove(this);
  }

  Future<HttpClientResponse> _request(
    _Job job,
    Uri uri,
    String method,
    String? range,
  ) async {
    job.check();
    job.client.connectionTimeout = options.timeout;
    final request = await job.client.openUrl(method, uri);
    if (job.cancelled) request.abort();
    job.check();
    job.onCancel.add(request.abort);
    request.headers.set(HttpHeaders.userAgentHeader, _proxy.userAgent);
    request.headers.set(HttpHeaders.refererHeader, _proxy.referer);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    job.check();
    return response;
  }

  Future<T> _timed<T>(_Job job, Future<T> Function() action) async {
    stats.activeRequests++;
    stats.peakRequests = math.max(stats.peakRequests, stats.activeRequests);
    try {
      return await job
          .guard(action())
          .timeout(
            options.timeout,
            onTimeout: () {
              job.cancel();
              throw TimeoutException('BTR transfer deadline');
            },
          );
    } finally {
      stats.activeRequests--;
    }
  }

  Future<(Uint8List, int, String)> _piece(
    _Track track,
    ByteRange range,
    _Job parent, {
    int? total,
    int priority = 1,
    bool Function()? urgent,
  }) async {
    Object? lastError;
    final candidates = track.pool.ordered();
    final tried = <Uri>{};
    for (final uri in candidates) {
      if (!tried.add(uri)) continue;
      parent.check();
      try {
        final alternate = options.takeover == BtrTakeover.full
            ? candidates.where((u) => !tried.contains(u)).firstOrNull
            : null;
        final result = await _racePiece(
          track,
          range,
          parent,
          uri,
          alternate,
          total: total,
          priority: priority,
          urgent: urgent,
          onBackup: tried.add,
        );
        stats.completedPieces++;
        return result;
      } catch (error) {
        parent.check();
        lastError = error;
      }
    }
    throw lastError ?? const HttpException('No working BTR CDN');
  }

  Future<(Uint8List, int, String)> _attempt(
    _Track track,
    ByteRange range,
    _Job child,
    Uri uri,
    _Progress progress, {
    int? total,
    int priority = 1,
    bool rescue = false,
  }) => _gate.run(
    child,
    () async {
      final clock = Stopwatch()..start();
      track.pool.started(uri);
      try {
        final result = await _timed(child, () async {
          final response = await _request(child, uri, 'GET', range.header);
          final iterator = StreamIterator(response);
          child.onCancel.add(() {
            unawaited(iterator.cancel());
          });
          final content = ContentRange.parse(
            response.headers.value(HttpHeaders.contentRangeHeader),
          );
          if (response.statusCode != 206 ||
              content == null ||
              content.range.start != range.start ||
              content.range.end != range.end ||
              (total != null && content.total != total)) {
            throw HttpException('Invalid BTR range: ${response.statusCode}');
          }
          final bytes = BytesBuilder(copy: false);
          while (await iterator.moveNext()) {
            child.check();
            final chunk = iterator.current;
            bytes.add(chunk);
            progress.bytes += chunk.length;
            stats.downloadedBytes += chunk.length;
            if (bytes.length > range.length) {
              throw const HttpException('Oversized BTR range');
            }
          }
          if (bytes.length != range.length) {
            throw const HttpException('Truncated BTR range');
          }
          return (
            bytes.takeBytes(),
            content.total,
            response.headers.value(HttpHeaders.contentTypeHeader) ??
                track.contentType,
          );
        });
        child.check();
        track.pool.success(uri, result.$1.length, clock.elapsed);
        stats.lastHost = uri.host;
        return result;
      } catch (error) {
        if (error is! _Cancelled) {
          stats.retries++;
          track.pool.failure(uri);
        }
        rethrow;
      } finally {
        track.pool.finished(uri);
      }
    },
    priority: priority,
    rescue: rescue,
  );

  _Job _transport(Uri uri) {
    final client = _clients.putIfAbsent(uri.origin, () {
      stats.connections++;
      return HttpClient()
        ..autoUncompress = false
        ..maxConnectionsPerHost = options.concurrency.clamp(1, 32)
        ..idleTimeout = const Duration(seconds: 45);
    });
    return _Job(client: client);
  }

  Future<(Uint8List, int, String)> _racePiece(
    _Track track,
    ByteRange range,
    _Job parent,
    Uri primary,
    Uri? alternate, {
    int? total,
    int priority = 1,
    bool Function()? urgent,
    required void Function(Uri) onBackup,
  }) async {
    final winner = Completer<(Uint8List, int, String)>();
    final attempts = <_Job>[];
    final progress = _Progress();
    var primaryDone = false, backupStarted = false;
    var pending = 0;
    Object? lastError;
    Timer? timer;
    void launch(Uri uri, {bool rescue = false}) {
      pending++;
      final child = _transport(uri);
      attempts.add(child);
      parent.children.add(child);
      _jobs.add(child);
      unawaited(
        _attempt(
              track,
              range,
              child,
              uri,
              rescue ? _Progress() : progress,
              total: total,
              priority: rescue ? 0 : priority,
              rescue: rescue,
            )
            .then<void>(
              (value) {
                if (!winner.isCompleted) winner.complete(value);
              },
              onError: (Object error, StackTrace stack) {
                lastError = error;
              },
            )
            .whenComplete(() {
              pending--;
              if (!rescue) primaryDone = true;
              if (rescue) _activeHedges--;
              if (pending == 0 && !winner.isCompleted) {
                // Immediate failure is retried by _piece; hedges are reserved for
                // still-running slow primaries rather than every failing request.
                winner.completeError(lastError ?? _Cancelled());
              }
            }),
      );
    }

    launch(primary);
    if (alternate != null) {
      timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (winner.isCompleted ||
            primaryDone ||
            backupStarted ||
            parent.cancelled ||
            !(urgent?.call() ?? false)) {
          return;
        }
        final age = progress.clock.elapsedMilliseconds;
        final delay = stats.bufferedAhead < 6 ? 600 : 1500;
        if (age < delay || _activeHedges >= math.max(1, _gate.limit ~/ 8)) {
          return;
        }
        final rate = progress.bytes * 1000 / math.max(1, age);
        final remainingMs = rate == 0
            ? double.infinity
            : (range.length - progress.bytes) * 1000 / rate;
        if (remainingMs < 350) return;
        backupStarted = true;
        _activeHedges++;
        stats.hedges++;
        onBackup(alternate);
        launch(alternate, rescue: true);
      });
    }
    try {
      return await parent.guard(winner.future);
    } finally {
      timer?.cancel();
      for (final child in attempts) {
        child.cancel();
        parent.children.remove(child);
        _jobs.remove(child);
      }
    }
  }

  Future<(Uint8List, int, String)> _probe(_Track track, _Job parent) async {
    // An unreachable first mirror must not hold up startup for every candidate
    // in sequence. Race a few mirrors and the original under the shared gate.
    final candidates = {
      ...track.pool.candidates.take(3),
      track.original,
    };
    final result = Completer<(Uint8List, int, String)>();
    final probes = <_Job>[];
    var remaining = candidates.length;
    for (final uri in candidates) {
      final probe = _Job();
      probes.add(probe);
      parent.children.add(probe);
      _jobs.add(probe);
      unawaited(
        _piece(
          _Track(uri, CdnPool([uri])),
          const ByteRange(0, 0),
          probe,
        ).then<void>(
          (value) {
            if (!result.isCompleted) {
              track.pool.preferOnce(uri);
              result.complete(value);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!probe.cancelled) track.pool.failure(uri);
            if (--remaining == 0 && !result.isCompleted) {
              result.completeError(error, stack);
            }
          },
        ),
      );
    }
    try {
      return await result.future.timeout(options.timeout);
    } finally {
      for (final probe in probes) {
        probe.cancel();
        parent.children.remove(probe);
        _jobs.remove(probe);
      }
    }
  }

  Future<void> _passthrough(
    HttpRequest request,
    _Track track,
    _Job job,
    void Function() onHeaders,
  ) async {
    stats.fallbacks++;
    await _gate.run(job, () async {
      // Bound connection/header waiting. Body uses an inactivity timeout, so a
      // long video is not cut off merely because it takes over 12 s to stream.
      final response =
          await _request(
            job,
            track.original,
            request.method,
            request.headers.value(HttpHeaders.rangeHeader),
          ).timeout(
            options.timeout,
            onTimeout: () {
              job.cancel();
              throw TimeoutException('BTR upstream');
            },
          );
      request.response.statusCode = response.statusCode;
      for (final header in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
      ]) {
        final value = response.headers.value(header);
        if (value != null) request.response.headers.set(header, value);
      }
      request.response.contentLength = response.contentLength;
      onHeaders();
      if (request.method == 'HEAD') return;
      await request.response.addStream(response.timeout(options.timeout));
    });
  }

  static const _blockSize = 256 * 1024;

  void _removeCache(_Track track, int index) {
    final entry = track.cache.remove(index);
    if (entry == null) return;
    stats.cacheBytes -= entry.bytes?.length ?? 0;
    entry.job.cancel();
  }

  _CacheEntry _cacheBlock(_Track track, int index) {
    final existing = track.cache[index];
    if (existing != null) {
      existing.touched = _clock.elapsedMicroseconds;
      if (index == track.demandBlock) _gate.promote(existing.job);
      return existing;
    }
    while (track.cache.length >= track.maxBlocks) {
      final keys =
          track.cache.keys.where((key) => key != track.demandBlock).toList()
            ..sort(
              (a, b) => (b - track.demandBlock).abs().compareTo(
                (a - track.demandBlock).abs(),
              ),
            );
      if (keys.isEmpty) break;
      _removeCache(track, keys.first);
    }
    final entry = _CacheEntry()..touched = _clock.elapsedMicroseconds;
    track.cache[index] = entry;
    _jobs.add(entry.job);
    final range = ByteRange(
      index * _blockSize,
      math.min(track.total! - 1, (index + 1) * _blockSize - 1),
    );
    entry.result =
        _piece(
              track,
              range,
              entry.job,
              total: track.total,
              priority: index == track.demandBlock
                  ? 0
                  : track.audio
                  ? 1
                  : 5,
              urgent: () => index == track.demandBlock,
            )
            .then<_Outcome>(
              (value) {
                if (identical(track.cache[index], entry) &&
                    !entry.job.cancelled) {
                  entry.bytes = value.$1;
                  stats.cacheBytes += value.$1.length;
                }
                return _Outcome.data(value.$1);
              },
              onError: (Object error, StackTrace _) {
                if (identical(track.cache[index], entry)) {
                  track.cache.remove(index);
                }
                return _Outcome.error(error);
              },
            )
            .whenComplete(() {
              entry.job.cancel();
              _jobs.remove(entry.job);
            });
    return entry;
  }

  void _prefetch(_Track track) {
    if (_disposed || track.total == null || track.awaitingSeek) return;
    final targetSeconds = stats.bufferedAhead < 8 ? 45 : 20;
    final count =
        (((track.bitRate ?? (track.audio ? 192000 : 2000000)) / 8) *
                targetSeconds /
                _blockSize)
            .ceil()
            .clamp(
              math.min(_gate.limit, track.maxBlocks - 2),
              track.maxBlocks - 2,
            );
    final last = (track.total! - 1) ~/ _blockSize;
    for (
      var index = track.demandBlock;
      index <= math.min(last, track.demandBlock + count);
      index++
    ) {
      _cacheBlock(track, index);
    }
  }

  Future<void> _fullStream(
    HttpRequest request,
    _Track track,
    ByteRange range,
    _Job job,
  ) async {
    var cursor = range.start;
    while (cursor <= range.end) {
      job.check();
      final index = cursor ~/ _blockSize;
      track
        ..awaitingSeek = false
        ..demandBlock = index;
      final entry = _cacheBlock(track, index);
      if (entry.bytes != null) stats.cacheHits++;
      _prefetch(track);
      final result = await job.guard(entry.result);
      job.check();
      if (result.error case final error?) throw error;
      final bytes = result.bytes!;
      final first = cursor - index * _blockSize;
      final length = math.min(bytes.length - first, range.end - cursor + 1);
      request.response.add(Uint8List.sublistView(bytes, first, first + length));
      await request.response.flush();
      stats.deliveredBytes += length;
      cursor += length;
    }
  }

  Future<void> _compatibleStream(
    HttpRequest request,
    _Track track,
    ByteRange range,
    _Job job,
  ) async {
    const pieceSize = 128 * 1024;
    final pending = <int, Future<_Outcome>>{};
    var next = range.start;
    var cursor = range.start;
    while (cursor <= range.end) {
      job.check();
      // Refill on every delivered piece, rather than letting all connections
      // drain at the boundary of each fixed batch.
      while (pending.length < math.min(16, _gate.limit) && next <= range.end) {
        final start = next;
        final end = math.min(range.end, start + pieceSize - 1);
        pending[start] =
            _piece(
              track,
              ByteRange(start, end),
              job,
              total: track.total,
            ).then<_Outcome>(
              (value) => _Outcome.data(value.$1),
              onError: (Object error, StackTrace _) => _Outcome.error(error),
            );
        next = end + 1;
      }
      final result = await job.guard(pending.remove(cursor)!);
      job.check();
      if (result.error case final error?) throw error;
      request.response.add(result.bytes!);
      await request.response.flush();
      stats.deliveredBytes += result.bytes!.length;
      cursor += result.bytes!.length;
    }
  }

  Future<void> _serve(HttpRequest request, _Track track) async {
    final job = _Job();
    _jobs.add(job);
    track.readers.add(job);
    // response.done reports peer disconnects, allowing a seek to cancel work.
    unawaited(
      request.response.done.then<void>(
        (_) => job.cancel(),
        onError: (Object _, StackTrace _) {
          job.cancel();
        },
      ),
    );
    var committed = false;
    var fallbackAttempted = false;
    Future<void> nativeFallback() async {
      fallbackAttempted = true;
      request.response.headers.removeAll(HttpHeaders.contentRangeHeader);
      await _passthrough(request, track, job, () {
        committed = true;
      });
    }

    try {
      if (_disposed) throw _Cancelled();
      if (track.rangeUnsupported) {
        await nativeFallback();
        return;
      }
      if (track.total == null) {
        try {
          final probe = await _probe(track, job);
          track
            ..total = probe.$2
            ..contentType = probe.$3;
        } catch (_) {
          job.check();
          // Servers without a usable Range response keep their native behavior.
          track.rangeUnsupported = true;
          await nativeFallback();
          return;
        }
      }
      final total = track.total!;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      final range = ByteRange.resolve(header, total);
      if (range == null) {
        request.response.statusCode = 416;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$total',
        );
        request.response.contentLength = 0;
        return;
      }
      request.response.statusCode = header == null ? 200 : 206;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        track.contentType,
      );
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (header != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$total',
        );
      }
      request.response.contentLength = range.length;
      if (request.method == 'HEAD') return;

      // Only one bounded window is downloaded ahead; full files and open-ended
      // ranges never become a single giant in-memory buffer.
      // Deliver a small validated prefix before scheduling bulk data. mpv's
      // HTTP open otherwise times out while waiting for the slowest piece of
      // a whole 1 MiB window, even though faster pieces are already downloaded.
      final prefixEnd = math.min(range.end, range.start + 16 * 1024 - 1);
      final cached = options.takeover == BtrTakeover.full
          ? track.cache[range.start ~/ _blockSize]?.bytes
          : null;
      final prefixOffset = range.start % _blockSize;
      final prefixLength = prefixEnd - range.start + 1;
      Uint8List prefix;
      if (cached != null && prefixOffset + prefixLength <= cached.length) {
        prefix = Uint8List.sublistView(
          cached,
          prefixOffset,
          prefixOffset + prefixLength,
        );
        stats.cacheHits++;
      } else {
        prefix = (await _piece(
          track,
          ByteRange(range.start, prefixEnd),
          job,
          total: total,
          priority: 0,
          urgent: () => true,
        )).$1;
      }
      job.check();
      committed = true;
      request.response.add(prefix);
      await request.response.flush();
      stats.deliveredBytes += prefix.length;

      if (prefixEnd < range.end) {
        final remainder = ByteRange(prefixEnd + 1, range.end);
        if (options.takeover == BtrTakeover.full) {
          await _fullStream(request, track, remainder, job);
        } else {
          await _compatibleStream(request, track, remainder, job);
        }
      }
    } catch (_) {
      if (!committed) {
        // Nothing has been delivered: native upstream Range can still replace
        // the accelerated response. Never splice unchecked data into a partial
        // response; after delivery starts a truncated response lets mpv retry.
        if (!job.cancelled && !_disposed && !fallbackAttempted) {
          try {
            await nativeFallback();
          } catch (_) {}
        }
        if (!committed) {
          request.response.headers.removeAll(HttpHeaders.contentRangeHeader);
          request.response.statusCode = 502;
          request.response.contentLength = 0;
        }
      }
    } finally {
      job.cancel();
      _jobs.remove(job);
      track.readers.remove(job);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }
}

/// Loopback only, ephemeral port, unguessable registered media tokens.
class BtrProxy {
  final String userAgent;
  final String referer;
  HttpServer? _server;
  Future<void>? _starting;
  final _routes = <String, (BtrSession, _Track)>{};
  final _sessions = <BtrSession>{};
  final _random = math.Random.secure();
  bool _disposed = false;
  BtrProxy({required this.userAgent, required this.referer});

  String _token() =>
      base64Url.encode(List.generate(24, (_) => _random.nextInt(256)));

  Future<void> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_disposed) {
      await server.close(force: true);
      throw StateError('BTR disposed');
    }
    _server = server;
    server.listen((request) async {
      final parts = request.uri.pathSegments;
      final route = parts.length == 2 && parts[0] == 'btr'
          ? _routes[parts[1]]
          : null;
      if (route == null || !['GET', 'HEAD'].contains(request.method)) {
        request.response.statusCode = route == null ? 404 : 405;
        try {
          await request.response.close();
        } catch (_) {}
        return;
      }
      await route.$1._serve(request, route.$2);
    });
  }

  Future<BtrSession> createSession(BtrOptions options) async {
    if (_disposed) throw StateError('BTR disposed');
    await (_starting ??= _start());
    if (_disposed) throw StateError('BTR disposed');
    final session = BtrSession._(this, options);
    _sessions.add(session);
    return session;
  }

  void dispose() {
    _disposed = true;
    for (final session in _sessions.toList()) {
      session.dispose();
    }
    unawaited(_server?.close(force: true));
    _server = null;
  }
}
