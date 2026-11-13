import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'addresses.dart';
import 'options.dart';
import 'thread_ripper/cdn_resolver.dart';
import 'thread_ripper/range_proxy.dart';

/// Registers [url] with a ripper session and returns the local address that
/// serves it. Tests replace this to point a track at a local server.
typedef TrackRegistrar =
    String Function(RipperRangeProxy session, String url, bool isAudio);

String _defaultRegistrar(RipperRangeProxy session, String url, bool isAudio) =>
    session.register([url], isAudio: isAudio);

/// Serves plain-HTTP requests that a router redirected here.
///
/// A request for Bilibili media is answered by a thread ripper session, which
/// fetches the file over many connections. Anything else is passed on to the
/// host it was meant for.
class LanProxy {
  LanProxy(
    this.options, {
    void Function(String line)? log,
    TrackRegistrar register = _defaultRegistrar,
    this.allowPrivateRelay = false,
  }) : _register = register,
       _write = log ?? _stdout;

  final Options options;
  final TrackRegistrar _register;

  /// Only for tests, whose upstream is on loopback.
  final bool allowPrivateRelay;
  final void Function(String line) _write;
  final _sessions = <String, _Session>{};
  final _clients = <Socket>{};
  ServerSocket? _server;
  Timer? _sweeper;
  DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);

  static const _idle = Duration(minutes: 10);

  int get port => _server!.port;
  int get activeRequests => _sessions.values.fold(0, (n, s) => n + s.active);

  static void _stdout(String line) {
    final time = DateTime.now().toIso8601String().substring(0, 23);
    stdout.writeln('$time $line');
  }

  void _debug(String line) {
    if (options.debug) _write(line);
  }

  Future<void> start() async {
    final server = await ServerSocket.bind(options.bind, options.port);
    _server = server;
    server.listen((client) => _handle(client).ignore());
    _sweeper = Timer.periodic(const Duration(minutes: 1), (_) => _sweep());
    _write(
      'listening on ${options.bind.address}:${server.port}, '
      'region ${options.overseas ? 'overseas' : 'mainland'}, '
      '${options.concurrency} connections'
      '${options.debug ? ', debug on' : ''}',
    );
  }

  Future<void> close() async {
    _sweeper?.cancel();
    await _server?.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    for (final session in _sessions.values) {
      session.ripper.close();
    }
    _sessions.clear();
  }

  // A session never drops a track, so sessions are replaced once idle.
  void _sweep() {
    final now = DateTime.now();
    _sessions.removeWhere((_, session) {
      final stale =
          session.active == 0 &&
          (now.difference(session.lastUsed) > _idle ||
              session.tracks.length >= 64);
      if (stale) session.ripper.close();
      return stale;
    });
  }

  // The CDN checks the User-Agent and the Referer, and a session sends one of
  // each, so every pair a player sends gets its own session. The CDN refuses
  // a TV-signed address sent with the web Referer (403), so the Referer is
  // the player's own, which may be none.
  Future<(_Session, Uri)?> _track(
    String host,
    String target,
    String userAgent,
    String referer,
  ) async {
    final url = 'https://$host$target';
    final Uri parsed;
    try {
      parsed = Uri.parse(url);
    } on FormatException {
      return null;
    }
    if (!RipperCdnResolver.supports(parsed)) return null;
    final key = '$userAgent\n$referer';
    var session = _sessions[key];
    if (session == null) {
      final ripper = RipperRangeProxy(
        concurrency: options.concurrency,
        overseas: options.overseas,
        userAgent: userAgent,
        referer: referer,
      );
      await ripper.start();
      session = _sessions[key] ??= _Session(ripper);
      if (!identical(session.ripper, ripper)) ripper.close();
    }
    session.lastUsed = DateTime.now();
    final track = session.tracks[url] ??= Uri.parse(
      _register(session.ripper, url, isAudioTrack(target)),
    );
    return (session, track);
  }

  Future<void> _handle(Socket client) async {
    _clients.add(client);
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } on SocketException {
      // Already gone.
    }
    Socket? upstream;
    _Session? session;
    var sent = 0;
    var failed = false;
    final clock = Stopwatch()..start();
    var label = 'request';
    try {
      // Players send one request per connection.
      final head = BytesBuilder();
      final incoming = StreamIterator(client);
      var end = -1;
      while (end < 0 &&
          await incoming.moveNext().timeout(const Duration(seconds: 15))) {
        head.add(incoming.current);
        end = _headEnd(head.toBytes());
        if (head.length > 32 * 1024) {
          throw const FormatException('request head too long');
        }
      }
      if (end < 0) return;
      final bytes = head.takeBytes();
      final lines = latin1.decode(bytes.sublist(0, end)).split('\r\n');
      final request = lines.first.split(' ');
      if (request.length < 3) throw const FormatException('bad request line');
      final method = request[0];
      final headers = <String, String>{
        for (final line in lines.skip(1))
          if (line.contains(':'))
            line.substring(0, line.indexOf(':')).toLowerCase(): line
                .substring(line.indexOf(':') + 1)
                .trim(),
      };
      final hostHeader = headers['host'] ?? '';
      final (host, hostPort) = _hostOf(hostHeader);
      var target = request[1];
      if (target.startsWith('http://')) {
        final slash = target.indexOf('/', 7);
        target = slash < 0 ? '/' : target.substring(slash);
      }
      final range = headers['range'];
      final file = target.split('?').first.split('/').last;
      label =
          '$host ${file.isEmpty ? '/' : file}${range == null ? '' : ' $range'}';

      final media = method == 'GET' || method == 'HEAD'
          ? await _track(
              host,
              target,
              headers['user-agent'] ?? '',
              headers['referer'] ?? '',
            )
          : null;
      if (media != null) {
        session = media.$1;
        session.active++;
        _debug('media $method $label');
        upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          media.$2.port,
        );
        upstream.add(
          latin1.encode(
            '$method ${media.$2.path} HTTP/1.1\r\n'
            'Host: 127.0.0.1\r\n'
            '${range == null ? '' : 'Range: $range\r\n'}'
            '\r\n',
          ),
        );
      } else {
        final address = await _relayAddress(host);
        if (address == null) {
          // Asked for by its own address: someone checking that it runs.
          _debug('status page for $label');
          _reply(
            client,
            200,
            'btr-lan-proxy $version is running, '
            '$activeRequests media requests in progress.\n',
          );
          await client.flush();
          return;
        }
        _debug('relay $method $label');
        upstream = await Socket.connect(
          address,
          hostPort,
          timeout: const Duration(seconds: 10),
        );
        upstream.add(bytes);
      }

      final source = upstream;
      // The player closing its side (a seek, a stop) must end the download.
      unawaited(() async {
        try {
          while (await incoming.moveNext()) {
            if (media == null) source.add(incoming.current);
          }
        } catch (_) {}
        source.destroy();
      }());
      await client.addStream(
        source.map((chunk) {
          if (sent == 0 && media != null) {
            final status = latin1.decode(chunk.take(12).toList());
            if (!status.startsWith('HTTP/1.1 2')) {
              failed = true;
              _write('failed $label: the thread ripper answered "$status"');
              if (options.debug) {
                _probe(host, target, headers).ignore();
              }
            }
          }
          sent += chunk.length;
          return chunk;
        }),
      );
      await client.flush();
    } on SocketException catch (error) {
      // The usual end of a media request: the player seeks or stops.
      _debug('closed $label: ${error.osError?.message ?? error.message}');
    } on TimeoutException {
      _debug('closed $label: no request arrived');
    } on FormatException catch (error) {
      _debug('refused $label: ${error.message}');
    } catch (error) {
      _write('error $label: $error');
    } finally {
      session?.active--;
      session?.lastUsed = DateTime.now();
      upstream?.destroy();
      client.destroy();
      _clients.remove(client);
      if (session != null && !failed && sent > 0) {
        final seconds = clock.elapsedMilliseconds / 1000;
        _write(
          'served $label: ${(sent / 1048576).toStringAsFixed(2)} MiB in '
          '${seconds.toStringAsFixed(1)} s, '
          '${(sent * 8 / 1e6 / (seconds == 0 ? 1 : seconds)).toStringAsFixed(1)} Mbit/s',
        );
      }
    }
  }

  /// The host and port of a Host header; the port is 80 when it has none.
  static (String, int) _hostOf(String header) {
    final value = header.trim().toLowerCase();
    var host = value;
    var port = '';
    if (value.startsWith('[')) {
      final close = value.indexOf(']');
      if (close > 0) {
        host = value.substring(1, close);
        port = value.substring(close + 1).replaceFirst(':', '');
      }
    } else if (value.indexOf(':') == value.lastIndexOf(':') &&
        value.contains(':')) {
      host = value.substring(0, value.indexOf(':'));
      port = value.substring(value.indexOf(':') + 1);
    }
    final number = int.tryParse(port);
    return (host, number != null && number > 0 && number < 65536 ? number : 80);
  }

  /// Where to pass a non-media request, or null when it was meant for the
  /// proxy itself or for an address the proxy must not relay to.
  Future<InternetAddress?> _relayAddress(String host) async {
    if (host.isEmpty) return null;
    final List<InternetAddress> addresses;
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        );
      } on SocketException {
        return null;
      }
    }
    for (final address in addresses) {
      if (allowPrivateRelay || isPublicAddress(address)) return address;
    }
    return null;
  }

  void _reply(Socket client, int status, String body) {
    final text = utf8.encode(body);
    client
      ..add(
        ascii.encode(
          'HTTP/1.1 $status ${status == 200 ? 'OK' : 'Error'}\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          'Content-Length: ${text.length}\r\n'
          'Connection: close\r\n'
          '\r\n',
        ),
      )
      ..add(text);
  }

  /// Debug only: what the CDN itself answers for a track that failed.
  Future<void> _probe(
    String host,
    String target,
    Map<String, String> headers,
  ) async {
    if (DateTime.now().difference(_lastProbe).inSeconds < 5) return;
    _lastProbe = DateTime.now();
    final url = Uri.parse('https://$host$target');
    final file = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
    if (options.dumpFailedUrls case final path?) {
      try {
        File(path).writeAsStringSync(
          '${headers['user-agent'] ?? ''}\t${headers['referer'] ?? ''}\t$url\n',
          mode: FileMode.append,
        );
      } on FileSystemException catch (error) {
        _write('debug: cannot write $path: ${error.message}');
      }
    }
    // Names only: the values are the account's signed tokens.
    _write(
      'debug probe $file: query keys ${url.queryParameters.keys.join(',')}',
    );
    for (final (scheme, referer) in [
      ('https', headers['referer'] ?? ''),
      ('https', 'https://www.bilibili.com/'),
      ('http', headers['referer'] ?? ''),
    ]) {
      final client = HttpClient()..autoUncompress = false;
      final what = '$scheme, Referer "${referer.isEmpty ? 'none' : referer}"';
      try {
        // Not from byte 0: the CDN was seen to refuse an address's
        // start-of-file requests after many of them.
        final request = await client
            .getUrl(
              url.replace(scheme: scheme, port: scheme == 'http' ? 80 : 443),
            )
            .timeout(const Duration(seconds: 6));
        request.headers
          ..set(HttpHeaders.rangeHeader, 'bytes=1024-2047')
          ..set(HttpHeaders.acceptEncodingHeader, 'identity')
          ..set(HttpHeaders.userAgentHeader, headers['user-agent'] ?? '')
          ..set(HttpHeaders.refererHeader, referer);
        final response = await request.close().timeout(
          const Duration(seconds: 6),
        );
        final length = await response
            .fold<int>(0, (n, chunk) => n + chunk.length)
            .timeout(const Duration(seconds: 6));
        _write(
          'debug probe $file ($what): HTTP ${response.statusCode}, '
          'Content-Range ${response.headers.value(HttpHeaders.contentRangeHeader)}, '
          '$length bytes',
        );
      } catch (error) {
        _write('debug probe $file ($what): $error');
      } finally {
        client.close(force: true);
      }
    }
  }
}

class _Session {
  _Session(this.ripper);
  final RipperRangeProxy ripper;
  final tracks = <String, Uri>{};
  int active = 0;
  DateTime lastUsed = DateTime.now();
}

int _headEnd(Uint8List bytes) {
  for (var i = 3; i < bytes.length; i++) {
    if (bytes[i] == 10 &&
        bytes[i - 1] == 13 &&
        bytes[i - 2] == 10 &&
        bytes[i - 3] == 13) {
      return i - 3;
    }
  }
  return -1;
}
