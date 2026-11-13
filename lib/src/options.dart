import 'dart:io';

const version = '0.1.0';

const usage =
    '''
btr-lan-proxy $version
Bilibili thread ripper as a LAN proxy for an unmodified player.

Usage: btr-lan-proxy [options]

  --port <n>              Port to listen on (default 8080; env BTR_PORT)
  --bind <address>        Address to listen on (default 0.0.0.0; env BTR_BIND)
  --region <name>         CDN nodes to use: mainland (default) or overseas
                          (env BTR_REGION)
  --concurrency <n>       Parallel CDN connections per player, 1-128
                          (default 16; env BTR_CONCURRENCY)
  --debug                 Log every request, and when a media request fails,
                          ask the CDN directly and log its answer
                          (env BTR_DEBUG=1)
  --dump-failed-urls <f>  With --debug: append the full address of each failed
                          media request to this file. These addresses carry
                          account tokens; delete the file after use.
  --version               Print the version
  --help                  Print this help
''';

class UsageException implements Exception {
  UsageException(this.message, {this.exitCode = 64});
  final String message;
  final int exitCode;
}

class Options {
  Options({
    InternetAddress? bind,
    this.port = 8080,
    this.overseas = false,
    this.concurrency = 16,
    this.debug = false,
    this.dumpFailedUrls,
  }) : bind = bind ?? InternetAddress.anyIPv4;

  final InternetAddress bind;
  final int port;
  final bool overseas;
  final int concurrency;
  final bool debug;
  final String? dumpFailedUrls;

  /// Command-line arguments win over [environment].
  static Options parse(
    List<String> args, {
    Map<String, String> environment = const {},
  }) {
    final values = <String, String>{
      'port': ?environment['BTR_PORT'],
      'bind': ?environment['BTR_BIND'],
      'region': ?environment['BTR_REGION'],
      'concurrency': ?environment['BTR_CONCURRENCY'],
    };
    var debug = const {
      '1',
      'true',
      'yes',
    }.contains(environment['BTR_DEBUG']?.toLowerCase());
    const valued = {
      'port',
      'bind',
      'region',
      'concurrency',
      'dump-failed-urls',
    };
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--help' || arg == '-h') {
        throw UsageException(usage, exitCode: 0);
      }
      if (arg == '--version') {
        throw UsageException('btr-lan-proxy $version', exitCode: 0);
      }
      if (arg == '--debug') {
        debug = true;
        continue;
      }
      // The first version took --overseas; keep it working.
      if (arg == '--overseas') {
        values['region'] = 'overseas';
        continue;
      }
      if (!arg.startsWith('--')) {
        throw UsageException('Unexpected argument "$arg".\n\n$usage');
      }
      final equals = arg.indexOf('=');
      final name = arg.substring(2, equals < 0 ? arg.length : equals);
      if (!valued.contains(name)) {
        throw UsageException('Unknown option "--$name".\n\n$usage');
      }
      if (equals >= 0) {
        values[name] = arg.substring(equals + 1);
      } else if (i + 1 < args.length) {
        values[name] = args[++i];
      } else {
        throw UsageException('Option "--$name" needs a value.');
      }
    }

    int number(String name, int fallback, int min, int max) {
      final text = values[name];
      if (text == null) return fallback;
      final value = int.tryParse(text);
      if (value == null || value < min || value > max) {
        throw UsageException('"$name" must be a number from $min to $max.');
      }
      return value;
    }

    final region = values['region'] ?? 'mainland';
    if (region != 'mainland' && region != 'overseas') {
      throw UsageException('"region" must be mainland or overseas.');
    }
    final bind = InternetAddress.tryParse(values['bind'] ?? '0.0.0.0');
    if (bind == null) {
      throw UsageException('"bind" must be an IP address.');
    }
    final dump = values['dump-failed-urls'];
    if (dump != null && !debug) {
      throw UsageException('--dump-failed-urls needs --debug.');
    }
    return Options(
      bind: bind,
      port: number('port', 8080, 0, 65535),
      overseas: region == 'overseas',
      concurrency: number('concurrency', 16, 1, 128),
      debug: debug,
      dumpFailedUrls: dump,
    );
  }
}
