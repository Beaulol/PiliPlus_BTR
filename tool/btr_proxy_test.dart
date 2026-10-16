// Standalone: dart tool/btr_proxy_test.dart. No Flutter/pub dependencies.
// ignore_for_file: avoid_relative_lib_imports, avoid_print, always_use_package_imports
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/btr/cdn_pool.dart';
import '../lib/services/btr/proxy.dart';
import '../lib/services/btr/range.dart';
import '../lib/services/btr/adaptive.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final data = Uint8List.fromList(
    List.generate(3 * 1024 * 1024 + 137, (i) => i % 251),
  );
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseData = data;
  final largeData = Uint8List.fromList(
    List.generate(12 * 1024 * 1024 + 137, (i) => i % 251),
  );
  final reusePorts = <int>{};
  var active = 0, peak = 0, badCalls = 0, stalls = 0;
  origin.listen((request) async {
    final data = request.uri.path == '/large' ? largeData : baseData;
    if (request.uri.path == '/reuse') {
      reusePorts.add(request.connectionInfo!.remotePort);
    }
    active++;
    if (active > peak) peak = active;
    try {
      check(
        request.headers.value('referer') == 'https://www.bilibili.com/',
        'Missing referer',
      );
      check(
        request.headers.value('accept-encoding') == 'identity',
        'Unexpected compression',
      );
      final path = request.uri.path;
      if (path == '/never') {
        await Completer<void>().future;
      }
      if (path == '/stall') {
        stalls++;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      if (path == '/slow-tail' &&
          (ByteRange.resolve(
                    request.headers.value('range'),
                    data.length,
                  )?.start ??
                  0) >=
              16384) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      if (path == '/forbidden') {
        request.response.statusCode = 403;
        return;
      }
      final header = request.headers.value('range');
      final range = ByteRange.resolve(header, data.length);
      if (range == null) {
        request.response.statusCode = 416;
        return;
      }
      if (path == '/hedge' && range.length >= 128 * 1024) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      if (path == '/no-range') {
        request.response.contentLength = data.length;
        if (request.method != 'HEAD') request.response.add(data);
        return;
      }
      request.response.statusCode = header == null ? 200 : 206;
      request.response.headers.set('content-type', 'video/mp4');
      if (header != null) {
        final wrong =
            (path == '/bad' && range.start != 0) ||
            (path == '/first-window' &&
                range.length > 1 &&
                range.length <= 131072);
        if (wrong) badCalls++;
        request.response.headers.set(
          'content-range',
          'bytes ${wrong ? range.start + 1 : range.start}-${range.end}/${data.length}',
        );
      }
      if (path == '/changing' && range.length > 1) {
        request.response.headers.set(
          'content-range',
          'bytes ${range.start}-${range.end}/${data.length + 1}',
        );
      }
      request.response.contentLength = range.length;
      if (request.method == 'HEAD') return;
      // Force pieces to complete in a different order.
      await Future<void>.delayed(
        Duration(milliseconds: 8 + (range.start ~/ 131072 % 4) * 8),
      );
      request.response.add(
        Uint8List.sublistView(data, range.start, range.end + 1),
      );
    } catch (_) {
      // Expected peer disconnects when a timeout cancels the upstream request.
    } finally {
      active--;
      try {
        await request.response.close();
      } catch (_) {}
    }
  });

  final proxy = BtrProxy(
    userAgent: 'BTR-test',
    referer: 'https://www.bilibili.com/',
  );
  final client = HttpClient()..autoUncompress = false;
  Uri upstream(String path) =>
      Uri.parse('http://127.0.0.1:${origin.port}$path');
  Future<(HttpClientResponse, Uint8List)> get(
    String url, {
    String? range,
    String method = 'GET',
  }) async {
    final req = await client.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set('range', range);
    final res = await req.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bytes.add(chunk);
    }
    return (res, bytes.takeBytes());
  }

  void equal(Uint8List actual, int start, int end) {
    check(
      actual.length == end - start + 1,
      'Length mismatch: ${actual.length}',
    );
    for (var i = 0; i < actual.length; i++) {
      check(actual[i] == (start + i) % 251, 'Byte mismatch at $i');
    }
  }

  try {
    check(ByteRange.resolve('bytes=-20', 100)!.start == 80, 'Suffix');
    check(ByteRange.resolve('bytes=90-200', 100)!.end == 99, 'Clamp');
    check(ByteRange.resolve('bytes=100-', 100) == null, 'Unsatisfiable');
    check(ByteRange.resolve('bytes=0-3,8-9', 100) == null, 'Multipart');
    check(ContentRange.parse('bytes 0-1/1') == null, 'Invalid total');
    check(!isBtrMediaUrl('https://evilbilivideo.com/a.m4s'), 'Domain boundary');
    check(!isBtrMediaUrl('https://www.bilibili.com/a.m4s'), 'Non-media');
    check(
      isBtrMediaUrl('https://upos-sz-mirrorali.bilivideo.com/upgcxcode/a.m4s'),
      'Media',
    );
    check(
      btrCandidates(
            'https://x.bilivideo.com/v1/resource/a.mp4',
            BtrCdnMode.mainland,
          ).length ==
          1,
      'PCDN rewrite',
    );
    final candidates = btrCandidates(
      'https://x.bilivideo.com:4483/upgcxcode/a.m4s?sign=abc%2Fdef',
      BtrCdnMode.mainland,
    );
    check(
      candidates.first.port == 443 &&
          candidates.first.query == 'sign=abc%2Fdef',
      'Signature or port changed',
    );
    print('PASS range parsing and CDN URL eligibility');

    final session = await proxy.createSession(const BtrOptions(concurrency: 4));
    final video = session.registerCandidates([upstream('/good')]);
    final audio = session.registerCandidates([upstream('/good')]);
    check(session.register('edl://a;b') == 'edl://a;b', 'EDL passthrough');
    final responses = await Future.wait([
      get(video, range: 'bytes=17-1700000'),
      get(audio, range: 'bytes=100-1300000'),
    ]);
    equal(responses[0].$2, 17, 1700000);
    equal(responses[1].$2, 100, 1300000);
    check(responses[0].$1.statusCode == 206, 'Status');
    check(
      responses[0].$1.headers.value('content-range') ==
          'bytes 17-1700000/${data.length}',
      'Response range',
    );
    check(
      session.stats.peakRequests <= 4 &&
          session.stats.peakRequests > 1 &&
          peak <= 4,
      'Shared concurrency',
    );
    print(
      'PASS concurrent audio/video, out-of-order completion, exact bytes, shared limit',
    );

    final fullResponse = await get(video);
    equal(fullResponse.$2, 0, data.length - 1);
    check(fullResponse.$1.statusCode == 200, 'Full GET');
    equal(
      (await get(video, range: 'bytes=3000000-')).$2,
      3000000,
      data.length - 1,
    );
    equal(
      (await get(video, range: 'bytes=-57')).$2,
      data.length - 57,
      data.length - 1,
    );
    final head = await get(video, method: 'HEAD');
    check(head.$1.contentLength == data.length && head.$2.isEmpty, 'HEAD');
    final invalid = await get(video, range: 'bytes=${data.length}-');
    check(
      invalid.$1.statusCode == 416 &&
          invalid.$1.headers.value('content-range') == 'bytes */${data.length}',
      '416',
    );
    print('PASS full/open/suffix ranges, HEAD and 416');

    final slowTail = session.registerCandidates([upstream('/slow-tail')]);
    final startupClock = Stopwatch()..start();
    final startupRequest = await client.getUrl(Uri.parse(slowTail));
    final startupResponse = await startupRequest.close();
    var firstByteMs = -1;
    final startupBytes = BytesBuilder(copy: false);
    await for (final chunk in startupResponse) {
      if (firstByteMs < 0) firstByteMs = startupClock.elapsedMilliseconds;
      startupBytes.add(chunk);
    }
    equal(startupBytes.takeBytes(), 0, data.length - 1);
    check(
      firstByteMs < 400,
      'Startup waited for slow bulk pieces: $firstByteMs ms',
    );
    print('PASS early startup bytes before slow tail (${firstByteMs}ms)');

    final repair = session.registerCandidates([
      upstream('/bad'),
      upstream('/good'),
    ]);
    equal((await get(repair, range: 'bytes=1-1100000')).$2, 1, 1100000);
    check(badCalls > 0 && session.stats.retries > 0, 'Bad range not tested');
    final refused = session.registerCandidates([
      upstream('/forbidden'),
      upstream('/good'),
    ]);
    equal((await get(refused, range: 'bytes=1-500000')).$2, 1, 500000);
    final change = session.registerCandidates([
      upstream('/changing'),
      upstream('/good'),
    ]);
    equal((await get(change, range: 'bytes=1-500000')).$2, 1, 500000);
    print('PASS incorrect ranges, inconsistent total and HTTP 403 retry');

    final native = session.registerCandidates([upstream('/no-range')]);
    final fallback = await get(native);
    equal(fallback.$2, 0, data.length - 1);
    check(
      fallback.$1.statusCode == 200 && session.stats.fallbacks > 0,
      'Non-Range fallback',
    );
    print('PASS upstream without Range falls back to native streaming');

    final timed = await proxy.createSession(
      const BtrOptions(concurrency: 2, timeout: Duration(milliseconds: 100)),
    );
    final delayed = timed.registerCandidates([
      upstream('/stall'),
      upstream('/good'),
    ]);
    equal((await get(delayed, range: 'bytes=1-250000')).$2, 1, 250000);
    check(stalls > 0 && timed.stats.retries > 0, 'Timeout retry');
    timed.dispose();
    print('PASS stalled CDN timeout and alternate-node recovery');

    final deadlineSession = await proxy.createSession(
      const BtrOptions(
        concurrency: 4,
        timeout: Duration(milliseconds: 150),
      ),
    );
    final raceUrl = deadlineSession.registerCandidates([
      upstream('/never'),
      upstream('/good'),
    ]);
    final raceClock = Stopwatch()..start();
    equal((await get(raceUrl, range: 'bytes=0-30000')).$2, 0, 30000);
    check(
      raceClock.elapsedMilliseconds < 120,
      'Unreachable probe stalled startup',
    );
    final noResponse = deadlineSession.registerCandidates([upstream('/never')]);
    final failureClock = Stopwatch()..start();
    check((await get(noResponse)).$1.statusCode == 502, 'No-response status');
    check(
      failureClock.elapsedMilliseconds < 700,
      'Deadline did not terminate request',
    );
    deadlineSession.dispose();
    print('PASS racing startup probes and hard deadlines for silent upstreams');

    final failure = await proxy.createSession(
      const BtrOptions(timeout: Duration(milliseconds: 60)),
    );
    final failedUrl = failure.registerCandidates([upstream('/stall')]);
    final failed = await get(failedUrl);
    check(
      failed.$1.statusCode == 502 && failed.$2.isEmpty,
      'Failed upstream must not look successful',
    );
    failure.dispose();
    final forbidden = session.registerCandidates([upstream('/forbidden')]);
    check(
      (await get(forbidden)).$1.statusCode == 403,
      'Native permission error',
    );
    print(
      'PASS exhausted upstream returns 502 and permission failure stays 403',
    );

    final recover = session.registerCandidates([upstream('/first-window')]);
    final recovered = await get(recover, range: 'bytes=1-500000');
    equal(recovered.$2, 1, 500000);
    check(recovered.$1.statusCode == 206, 'First-window native fallback');
    print('PASS first-window failure recovers through original Range');

    final cancelledSession = await proxy.createSession(const BtrOptions());
    final cancelUrl = cancelledSession.registerCandidates([upstream('/stall')]);
    final waiting = get(cancelUrl);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final clock = Stopwatch()..start();
    cancelledSession.dispose();
    await waiting.timeout(const Duration(milliseconds: 300));
    check(
      clock.elapsedMilliseconds < 300 &&
          cancelledSession.stats.activeRequests == 0,
      'Disposal did not abort in-flight transfer promptly',
    );
    print('PASS disposing a session aborts pending upstream work');

    final req = await client.getUrl(Uri.parse(video));
    final res = await req.close();
    final subscription = res.listen((_) {});
    await subscription.cancel();
    session.dispose();
    check((await get(video)).$1.statusCode == 404, 'Disposed token');
    check(
      (await get(video.replaceFirst('/btr/', '/wrong/'))).$1.statusCode == 404,
      'Route validation',
    );
    print('PASS disconnect/session cancellation and expired tokens');
    final reuse = await proxy.createSession(const BtrOptions(concurrency: 4));
    final reuseUrl = reuse.registerCandidates([upstream('/reuse')]);
    for (var i = 0; i < 8; i++) {
      equal((await get(reuseUrl, range: 'bytes=0-30000')).$2, 0, 30000);
    }
    check(
      reusePorts.length <= 2,
      'Connections not reused: ${reusePorts.length}',
    );
    reuse.dispose();
    print('PASS pooled keep-alive connections across repeated requests');

    final full = await proxy.createSession(
      const BtrOptions(
        concurrency: 4,
        takeover: BtrTakeover.full,
      ),
    );
    final fullUrl = full.registerCandidates([
      upstream('/large'),
    ], bitRate: 4000000);
    equal((await get(fullUrl)).$2, 0, largeData.length - 1);
    check(full.stats.cacheBytes <= 8 * 1024 * 1024, 'Unbounded takeover cache');
    check(
      full.stats.peakRequests <= 4,
      'Takeover exceeded concurrency ceiling',
    );
    final beforeReuse = full.stats.downloadedBytes;
    equal(
      (await get(fullUrl, range: 'bytes=12000000-12030000')).$2,
      12000000,
      12030000,
    );
    check(
      full.stats.cacheHits > 0 && full.stats.downloadedBytes == beforeReuse,
      'Cached range triggered another CDN download',
    );
    full.dispose();
    check(full.stats.cacheBytes == 0, 'Disposed cache retained accounting');
    print(
      'PASS full-mode byte integrity, bounded shared cache and cache reuse',
    );

    final hedge = await proxy.createSession(
      const BtrOptions(
        concurrency: 4,
        takeover: BtrTakeover.full,
      ),
    );
    final hedgeUrl = hedge.registerCandidates([
      upstream('/hedge'),
      upstream('/good'),
    ]);
    final hedgeClock = Stopwatch()..start();
    equal((await get(hedgeUrl, range: 'bytes=0-900000')).$2, 0, 900000);
    check(
      hedge.stats.hedges > 0 && hedgeClock.elapsedMilliseconds < 1400,
      'Urgent slow block was not rescued: ${hedgeClock.elapsedMilliseconds}ms',
    );
    check(hedge.stats.peakRequests <= 4, 'Hedge exceeded shared limit');
    hedge.dispose();
    print(
      'PASS urgent slow-block rescue, losing copy cancellation and shared ceiling',
    );

    final seeking = await proxy.createSession(
      const BtrOptions(
        concurrency: 4,
        takeover: BtrTakeover.full,
      ),
    );
    final seekUrl = seeking.registerCandidates([upstream('/slow-tail')]);
    final seekRequest = await client.getUrl(Uri.parse(seekUrl));
    final seekResponse = await seekRequest.close();
    final oldRead = seekResponse.drain<void>().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    seeking.onSeek();
    await oldRead.timeout(const Duration(milliseconds: 400));
    equal(
      (await get(seekUrl, range: 'bytes=2000000-2030000')).$2,
      2000000,
      2030000,
    );
    seeking.dispose();
    print(
      'PASS seek cancels obsolete readers/prefetch and new range stays correct',
    );

    final adaptive = BtrAdaptiveConcurrency(16);
    check(
      adaptive.observe(ahead: 1, buffering: true, playing: true, nowMs: 0) ==
          12,
      'Auto concurrency did not react to low buffer',
    );
    check(
      adaptive.observe(ahead: 1, buffering: true, playing: true, nowMs: 100) ==
          12,
      'Auto concurrency oscillated within cooldown',
    );
    check(
      adaptive.observe(ahead: 1, buffering: true, playing: true, nowMs: 3000) ==
          16,
      'Auto concurrency did not reach ceiling',
    );
    check(
      adaptive.observe(ahead: 1, buffering: true, playing: true, nowMs: 6000) ==
          16,
      'Auto concurrency exceeded ceiling',
    );
    for (var i = 0; i < 5; i++) {
      adaptive.observe(
        ahead: 45,
        buffering: false,
        playing: true,
        nowMs: 10000 + i * 1000,
      );
    }
    check(
      adaptive.current == 14,
      'Auto concurrency did not ease off with ample buffer',
    );
    final pausedLimit = adaptive.current;
    adaptive.observe(ahead: 0, buffering: false, playing: false, nowMs: 20000);
    check(
      adaptive.current == pausedLimit,
      'Paused playback raised concurrency',
    );
    print(
      'PASS adaptive buffer feedback, cooldown, ceiling and paused playback',
    );
    print('All BTR integration tests passed.');
  } finally {
    client.close(force: true);
    proxy.dispose();
    await origin.close(force: true);
  }
}
