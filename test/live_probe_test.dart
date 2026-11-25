import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/emulator.dart';
import 'package:sap_terminal/transport.dart';

// Live check against a public Telnet host. Run:
//   PROBE_HOST=telehack.com PROBE_PORT=23 PROBE_CMDS='help\r' flutter test test/live_probe_test.dart
void main() {
  final host = Platform.environment['PROBE_HOST'];
  test('live probe', () async {
    final port = int.parse(Platform.environment['PROBE_PORT'] ?? '23');
    final cmds = (Platform.environment['PROBE_CMDS'] ?? '').split('|').where((s) => s.isNotEmpty);
    final t = TelnetTransport(host!, port, 'vt220');
    final e = Emulator();
    var n = 0;
    t.incoming.listen((d) {
      n += d.length;
      e.write(utf8.decode(d, allowMalformed: true));
    }, onError: (x) => print('ERR $x'), onDone: () => print('[closed]'));
    await t.connect(80, 24);
    await Future<void>.delayed(const Duration(seconds: 4));
    for (final c in cmds) {
      t.send(utf8.encode(c.replaceAll('~', '\r')));
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    print('--- $n bytes; screen ---');
    for (var r = 0; r < 24; r++) {
      print('|${e.rowText(r).trimRight()}');
    }
    await t.close();
    e.dispose();
  }, skip: host == null ? 'set PROBE_HOST' : false, timeout: const Timeout(Duration(seconds: 60)));
}
