import 'dart:async';
import 'dart:io';

import 'package:btr_lan_proxy/src/options.dart';
import 'package:btr_lan_proxy/src/server.dart';

Future<void> main(List<String> args) async {
  final Options options;
  try {
    options = Options.parse(args, environment: Platform.environment);
  } on UsageException catch (error) {
    (error.exitCode == 0 ? stdout : stderr).writeln(error.message);
    exit(error.exitCode);
  }
  final proxy = LanProxy(options);
  try {
    await proxy.start();
  } on SocketException catch (error) {
    stderr.writeln(
      'Cannot listen on ${options.bind.address}:${options.port}: '
      '${error.osError?.message ?? error.message}',
    );
    exit(1);
  }

  Future<void> stop(ProcessSignal signal) async {
    await proxy.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  // Windows has no SIGTERM.
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(stop);
}
