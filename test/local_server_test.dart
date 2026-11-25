import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/keymap.dart';
import 'package:sap_terminal/models.dart';
import 'package:sap_terminal/session.dart';

// End-to-end check against test_server/sap_telnet_server.py (real Telnet over TCP).
//   python sap_telnet_server.py 2323
//   SAP_LOCAL_PORT=2323 flutter test test/local_server_test.dart
void main() {
  final port = int.tryParse(Platform.environment['SAP_LOCAL_PORT'] ?? '');
  Future<void> pause([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<TerminalSession> connect(TermType t) async {
    final s = TerminalSession(ConnectionConfig(
      host: '127.0.0.1',
      port: port!,
      protocol: Protocol.telnet,
      termType: t,
    ));
    await s.connect();
    s.fkeyStyle = FKeyStyle.auto; // these tests use the per-terminal-type tables
    await pause(600);
    return s;
  }

  String status(TerminalSession s) => s.emu.rowText(23).trim();
  int rowOf(TerminalSession s, String needle) =>
      [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains(needle));

  for (final t in TermType.values) {
    test('${termLabel(t)}: all 12 F-keys are recognised by the host', () async {
      final s = await connect(t);
      expect(s.emu.rowText(17).contains(termLabel(t).toUpperCase()), isTrue,
          reason: 'host should have learned the terminal type');
      for (final n in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12]) {
        s.sendKey(TermKey.values[n - 1]);
        await pause();
        expect(status(s).startsWith('F$n  OK'), isTrue, reason: 'F$n -> "${status(s)}"');
      }
      // F4 = Exit: the host ends the session
      s.sendKey(TermKey.f4);
      await pause(800);
      expect(s.state, SessionState.closed);
      s.dispose();
    }, skip: port == null ? 'set SAP_LOCAL_PORT' : false);
  }

  test('taps: menu item, fields (arrows jump), typing lands in the tapped field', () async {
    final s = await connect(TermType.vt220);
    // tap on the blank row just below "1.Goods Receipt" (lower half -> nearer item is 2)
    s.handleTap(3, rowOf(s, '1.Goods') + 1, rowFrac: 0.8);
    await pause(1500);
    expect(s.emu.rowText(0).contains('PROCESS ORDERS'), isTrue, reason: s.emu.rowText(0));

    // forms: tap Quantity, type, tap Plant, type, tap Document no., type
    final qRow = 12, pRow = 6, dRow = 3; // 0-based rows of the three fields
    s.handleTap(4, qRow);
    await pause(1500);
    expect(s.emu.cy, qRow);
    s.sendText('99');
    await pause();
    s.handleTap(3, pRow);
    await pause(1500);
    expect(s.emu.cy, pRow);
    s.sendText('P100');
    await pause();
    s.handleTap(2, dRow);
    await pause(1500);
    expect(s.emu.cy, dRow);
    s.sendText('4711');
    await pause();
    // empty fields: the cursor stays at the start of the field (col 1), so the
    // text lands there, not scattered where the finger happened to be
    expect(s.emu.rowText(qRow).substring(1, 3), '99');
    expect(s.emu.rowText(pRow).substring(1, 5), 'P100');
    expect(s.emu.rowText(dRow).substring(1, 5), '4711');

    // tap back on Plant, inside the field: cursor moves within it
    s.handleTap(5, pRow);
    await pause(1500);
    expect([s.emu.cy, s.emu.cx], [pRow, 5]);

    // F3 returns to the menu
    s.sendKey(TermKey.f3);
    await pause(400);
    expect(s.emu.rowText(3).contains('1.Goods'), isTrue);
    s.dispose();
  }, skip: port == null ? 'set SAP_LOCAL_PORT' : false);

  test('field concepts screen: invisible fields, prefilled values, dead Up/Down', () async {
    final s = await connect(TermType.vt100);
    s.handleTap(3, rowOf(s, '5.Field'));
    await pause(1500);
    expect(s.emu.rowText(0).contains('FIELD CONCEPTS'), isTrue, reason: s.emu.rowText(0));
    // the two bold-red-on-black fields are found as fields (they have no box)
    final f = s.emu.fields();
    expect(f.any((x) => x.$1 == 6), isTrue, reason: 'Phase Number (empty, no box): $f');
    expect(f.any((x) => x.$1 == 12), isTrue, reason: 'Dest. Stor. Bin (no box): $f');

    // empty field: cursor goes to the start even when tapped in the middle
    s.handleTap(6, 6);
    await pause(1500);
    expect([s.emu.cy, s.emu.cx], [6, 0]);

    // prefilled value "548": tap between 4 and 8 -> cursor there; typing inserts there
    s.handleTap(2, 3);
    await pause(1500);
    expect([s.emu.cy, s.emu.cx], [3, 2]);
    s.sendText('X');
    await pause();
    expect(s.emu.rowText(3).substring(0, 4), '54X ');

    // value in a field with no box: tap inside, then past the end (stops after the text)
    s.handleTap(2, 12);
    await pause(1500);
    expect([s.emu.cy, s.emu.cx], [12, 2]);
    s.handleTap(8, 12);
    await pause(1500);
    expect([s.emu.cy, s.emu.cx], [12, 4]);

    // F2 clears the field under the cursor
    s.sendKey(TermKey.f2);
    await pause(600);
    expect(s.emu.rowText(12).substring(0, 10).trim(), '');

    // F5 refresh keeps the screen; F4 exit ends the session
    s.sendKey(TermKey.f5);
    await pause(600);
    expect(s.emu.rowText(0).contains('FIELD CONCEPTS'), isTrue);
    s.sendKey(TermKey.f4);
    await pause(800);
    expect(s.state, SessionState.closed);
    s.dispose();
  }, skip: port == null ? 'set SAP_LOCAL_PORT' : false);
}
