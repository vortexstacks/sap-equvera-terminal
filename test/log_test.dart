import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/applog.dart';
import 'package:sap_terminal/keymap.dart';
import 'package:sap_terminal/models.dart';
import 'package:sap_terminal/session.dart';

void main() {
  Future<void> pause([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

  test('exported log records keys, taps and unknown sequences, but never typed text', () async {
    AppLog.instance.clear();
    final s = TerminalSession(ConnectionConfig(protocol: Protocol.demo, termType: TermType.vt220));
    await s.connect();
    s.fkeyStyle = FKeyStyle.auto; // these tests use the per-terminal-type tables
    await pause(100);
    s.sendKey(TermKey.f1);
    final menuRow = [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains('1.Goods'));
    s.handleTap(3, menuRow);
    await pause(1200);
    s.sendText('hunter2'); // pretend this is a password
    s.emu.write('\x1b[?9999z'); // a sequence the emulator does not implement
    await pause();

    final log = s.exportLog();
    final events = log.substring(0, log.indexOf('--- current screen ---'));
    expect(events.contains('connected'), isTrue);
    expect(events.contains('F1'), isTrue); // key press recorded with its bytes
    expect(events.contains('1B 5B 31 31 7E'), isTrue);
    expect(events.contains('TAP'), isTrue);
    expect(events.contains('menu item 1'), isTrue);
    expect(events.contains('typed text, 7 bytes (not recorded)'), isTrue);
    expect(events.contains('hunter2'), isFalse); // typed text is not in the event log
    expect(events.contains('68 75 6E'), isFalse); // ...nor its bytes
    expect(events.contains('CSI ?9999z'), isTrue); // unknown sequence listed
    expect(log.contains('app $kBuildTag'), isTrue);
    expect(log.contains('--- current screen ---'), isTrue);
    s.dispose();
  });
}
