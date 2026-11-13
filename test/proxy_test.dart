import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:btr_lan_proxy/src/addresses.dart';
import 'package:btr_lan_proxy/src/options.dart';
import 'package:btr_lan_proxy/src/server.dart';
import 'package:test/test.dart';

/// A stand-in for the CDN on loopback: one media file with Range support,
/// one plain page, and a path that always refuses.
class FakeCdn {
  late final HttpServer server;
  final file = Uint8List(3 * 1024 * 1024 + 123);
  final referers = <String?>[];
  final userAgents = <String?>[];
  int mediaRequests = 0;

  int get port => server.port;

  Future<void> start() async {
    final random = Random(7);
    for (var i = 0; i < file.length; i++) {
      file[i] = random.nextInt(256);
    }
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/plain.txt') {
        response.write('plain page');
        await response.close();
        return;
      }
      referers.add(request.headers.value(HttpHeaders.refererHeader));
      userAgents.add(request.headers.value(HttpHeaders.userAgentHeader));
      if (request.uri.path == '/refused.m4s') {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      mediaRequests++;
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (match == null) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }
      final start = int.parse(match[1]!);
      final end = min(int.parse(match[2]!), file.length - 1);
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${file.length}',
        )
        ..headers.contentLength = end - start + 1
        ..add(Uint8List.sublistView(file, start, end + 1));
      try {
        await response.close();
      } catch (_) {
        // The ripper cancels the copies it no longer needs.
      }
    });
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  group('options', () {
    test('defaults', () {
      final options = Options.parse([]);
      expect(options.port, 8080);
      expect(options.bind.address, '0.0.0.0');
      expect(options.overseas, isFalse);
      expect(options.concurrency, 16);
      expect(options.debug, isFalse);
      expect(options.dumpFailedUrls, isNull);
    });

    test('environment, overridden by arguments', () {
      final environment = {
        'BTR_PORT': '9000',
        'BTR_REGION': 'overseas',
        'BTR_CONCURRENCY': '32',
        'BTR_DEBUG': '1',
      };
      final fromEnvironment = Options.parse([], environment: environment);
      expect(fromEnvironment.port, 9000);
      expect(fromEnvironment.overseas, isTrue);
      expect(fromEnvironment.concurrency, 32);
      expect(fromEnvironment.debug, isTrue);
      final overridden = Options.parse([
        '--port=9100',
        '--region',
        'mainland',
      ], environment: environment);
      expect(overridden.port, 9100);
      expect(overridden.overseas, isFalse);
    });

    test('rejects bad input', () {
      for (final args in [
        ['--port', 'abc'],
        ['--port', '70000'],
        ['--region', 'mars'],
        ['--concurrency', '0'],
        ['--bind', 'not-an-address'],
        ['--nope'],
        ['stray'],
        ['--port'],
        ['--dump-failed-urls', 'x.txt'],
      ]) {
        expect(
          () => Options.parse(args),
          throwsA(isA<UsageException>()),
          reason: '$args',
        );
      }
    });

    test('help and version exit cleanly', () {
      for (final arg in ['--help', '--version']) {
        expect(
          () => Options.parse([arg]),
          throwsA(
            isA<UsageException>().having((e) => e.exitCode, 'exitCode', 0),
          ),
        );
      }
    });
  });

  test('public addresses', () {
    for (final address in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.10',
      '169.254.1.1',
      '100.64.0.1',
      '0.0.0.0',
      '224.0.0.1',
      '::1',
      '::',
      'fe80::1',
      'fd00::1',
      '::ffff:192.168.1.1',
    ]) {
      expect(
        isPublicAddress(InternetAddress(address)),
        isFalse,
        reason: address,
      );
    }
    for (final address in [
      '23.205.104.58',
      '172.32.0.1',
      '100.128.0.1',
      '2001:4860:4860::8888',
      '::ffff:8.8.8.8',
    ]) {
      expect(
        isPublicAddress(InternetAddress(address)),
        isTrue,
        reason: address,
      );
    }
  });

  test('audio tracks by stream id', () {
    expect(isAudioTrack('/a/b/123-1-30280.m4s?x=1'), isTrue);
    expect(isAudioTrack('/a/b/123-1-30257.m4s'), isTrue);
    expect(isAudioTrack('/a/b/123_hr1-1-30125.m4s?x=1'), isFalse);
    expect(isAudioTrack('/a/b/123-1-100080.m4s'), isFalse);
  });

  group('proxy', () {
    late FakeCdn cdn;
    late LanProxy proxy;
    late List<String> log;
    const mediaHost = 'upos-test.bilivideo.com';

    Future<void> startProxy({bool debug = false, bool relay = true}) async {
      log = [];
      proxy = LanProxy(
        Options(
          bind: InternetAddress.loopbackIPv4,
          port: 0,
          concurrency: 8,
          debug: debug,
        ),
        log: log.add,
        allowPrivateRelay: relay,
        // The real registrar derives CDN mirrors from the address; here every
        // track is the fake CDN's file, or its refusing path.
        register: (session, url, isAudio) => session.registerCandidates([
          Uri.parse(
            'http://127.0.0.1:${cdn.port}/'
            '${url.contains('refused') ? 'refused' : 'video'}.m4s',
          ),
        ], isAudio: isAudio),
      );
      await proxy.start();
    }

    setUp(() async {
      cdn = FakeCdn();
      await cdn.start();
    });

    tearDown(() async {
      await proxy.close();
      await cdn.stop();
    });

    // The proxy writes a request's summary after the client has its bytes.
    Future<void> logged(String prefix) async {
      for (var i = 0; i < 100 && !log.any((l) => l.startsWith(prefix)); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<(int, Uint8List, HttpHeaders)> get(
      String host,
      String path, {
      Map<String, String> headers = const {},
      int? hostPort,
    }) async {
      final client = HttpClient()..autoUncompress = false;
      try {
        final request = await client.get('127.0.0.1', proxy.port, path);
        request.headers
          ..host = host
          ..port = hostPort
          ..removeAll(HttpHeaders.userAgentHeader)
          ..removeAll(HttpHeaders.acceptEncodingHeader);
        headers.forEach(request.headers.set);
        final response = await request.close();
        final body = BytesBuilder();
        await response.forEach(body.add);
        return (response.statusCode, body.takeBytes(), response.headers);
      } finally {
        client.close(force: true);
      }
    }

    test('serves a whole media file unchanged', () async {
      await startProxy();
      final (status, body, _) = await get(
        mediaHost,
        '/upgcxcode/1/2/123-1-30125.m4s?deadline=1&upsig=secret',
        headers: {'user-agent': 'Player/1'},
      );
      expect(status, 200);
      expect(body, cdn.file);
      // More than one upstream request: the file came in pieces.
      expect(cdn.mediaRequests, greaterThan(2));
      await logged('served ');
      expect(log.where((l) => l.startsWith('served ')), hasLength(1));
      // The log names the file, never the signed query.
      expect(log.join('\n'), isNot(contains('secret')));
    });

    test('serves closed and open ranges', () async {
      await startProxy();
      final (status, body, headers) = await get(
        mediaHost,
        '/x/123-1-30125.m4s',
        headers: {'range': 'bytes=1000000-1999999'},
      );
      expect(status, 206);
      expect(body, cdn.file.sublist(1000000, 2000000));
      expect(
        headers.value('content-range'),
        'bytes 1000000-1999999/${cdn.file.length}',
      );
      final (openStatus, tail, _) = await get(
        mediaHost,
        '/x/123-1-30125.m4s',
        headers: {'range': 'bytes=3000000-'},
      );
      expect(openStatus, 206);
      expect(tail, cdn.file.sublist(3000000));
    });

    test(
      "sends the player's User-Agent and Referer, never the web one",
      () async {
        await startProxy();
        await get(
          mediaHost,
          '/x/1-1-30125.m4s',
          headers: {'user-agent': 'TvPlayer/2', 'range': 'bytes=0-99999'},
        );
        expect(cdn.userAgents.toSet(), {'TvPlayer/2'});
        // No Referer from the player: none of substance reaches the CDN.
        expect(cdn.referers.every((r) => r == null || r.isEmpty), isTrue);
        cdn.referers.clear();
        await get(
          mediaHost,
          '/x/2-1-30125.m4s',
          headers: {
            'user-agent': 'Browser/1',
            'referer': 'https://example.test/page',
            'range': 'bytes=0-99999',
          },
        );
        expect(cdn.referers.toSet(), {'https://example.test/page'});
      },
    );

    test('a player that goes away ends its download', () async {
      await startProxy();
      final socket = await Socket.connect('127.0.0.1', proxy.port);
      socket.write('GET /x/9-1-30125.m4s HTTP/1.1\r\nHost: $mediaHost\r\n\r\n');
      await socket.first;
      expect(proxy.activeRequests, 1);
      socket.destroy();
      for (var i = 0; i < 100 && proxy.activeRequests > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(proxy.activeRequests, 0);
    });

    test('reports a track the CDN refuses', () async {
      await startProxy();
      final (status, _, _) = await get(mediaHost, '/x/refused-1-30125.m4s');
      expect(status, 502);
      await logged('failed ');
      expect(log.where((l) => l.startsWith('failed ')), hasLength(1));
      expect(log.where((l) => l.startsWith('served ')), isEmpty);
      // No probe of the CDN unless debug is on.
      expect(log.where((l) => l.contains('debug')), isEmpty);
    });

    test('passes other requests on to their host', () async {
      await startProxy();
      final (status, body, _) = await get(
        '127.0.0.1',
        '/plain.txt',
        hostPort: cdn.port,
      );
      expect(status, 200);
      expect(String.fromCharCodes(body), 'plain page');
      expect(cdn.mediaRequests, 0);
    });

    test('answers for itself, and does not relay into the LAN', () async {
      await startProxy(relay: false);
      for (final host in ['127.0.0.1', '192.168.1.1', '10.0.0.5']) {
        final (status, body, _) = await get(
          host,
          '/plain.txt',
          hostPort: cdn.port,
        );
        expect(status, 200, reason: host);
        expect(String.fromCharCodes(body), contains('is running'));
      }
    });

    test('logs requests only with debug on', () async {
      await startProxy();
      await get(mediaHost, '/x/5-1-30125.m4s', headers: {'range': 'bytes=0-9'});
      await get('127.0.0.1', '/plain.txt', hostPort: cdn.port);
      expect(log.where((l) => l.startsWith('media ')), isEmpty);
      expect(log.where((l) => l.startsWith('relay ')), isEmpty);
      await proxy.close();

      await startProxy(debug: true);
      await get(mediaHost, '/x/5-1-30125.m4s', headers: {'range': 'bytes=0-9'});
      await get('127.0.0.1', '/plain.txt', hostPort: cdn.port);
      expect(log.where((l) => l.startsWith('media GET ')), hasLength(1));
      expect(log.where((l) => l.startsWith('relay GET ')), hasLength(1));
    });
  });
}
