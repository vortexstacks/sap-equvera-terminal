import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/emulator.dart';
import 'package:sap_terminal/keymap.dart';
import 'package:sap_terminal/models.dart';
import 'package:sap_terminal/session.dart';
import 'package:sap_terminal/transport.dart';

void main() {
  test('demo host rejects ANSI F1 and accepts VT220 F1', () async {
    final t = DemoTransport();
    final out = StringBuffer();
    t.incoming.listen((d) => out.write(utf8.decode(d)));
    await t.connect(80, 24);

    t.send(KeyMap.defaults(TermKey.f1, TermType.ansi));
    await Future<void>.delayed(Duration.zero);
    expect(out.toString().contains('NOT RECOGNISED'), isTrue);

    t.send(KeyMap.defaults(TermKey.f1, TermType.vt220));
    await Future<void>.delayed(Duration.zero);
    expect(out.toString().contains('F1  OK'), isTrue);
    await t.close();
  });

  test('escape codes OFF prints the raw sequence (old bug)', () {
    final e = Emulator();
    e.rawMode = true;
    e.write('\x1b[17;1HHi');
    expect(e.rowText(0).startsWith('[17;1HHi'), isTrue);
    e.dispose();
  });

  Future<void> pause([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<TerminalSession> demoSession() async {
    final s = TerminalSession(ConnectionConfig(protocol: Protocol.demo, termType: TermType.vt220));
    await s.connect();
    s.fkeyStyle = FKeyStyle.auto; // these tests use the per-terminal-type tables
    await pause(80);
    return s;
  }

  test('demo host: arrows jump field to field (like SAP), they do not move cell by cell', () async {
    final t = DemoTransport();
    final e = Emulator();
    t.incoming.listen((d) => e.write(utf8.decode(d)));
    await t.connect(80, 24);
    await pause();
    expect(e.cy, 11); // Slct field, row 12
    t.send([0x1B, 0x5B, 0x41]); // Up -> previous item (F4 Nxt button)
    await pause();
    expect(e.cy, 1); // row 2
    await t.close();
    e.dispose();
  });

  test('tap on a numbered menu line selects it, even when the cursor is on a button', () async {
    final s = await demoSession();
    // move focus off the Slct field first
    s.sendKey(TermKey.up);
    await pause(100);
    expect(s.emu.cy, 1);
    final menuRow = [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains('2.Process'));
    s.handleTap(3, menuRow);
    await pause(1500);
    expect(s.emu.rowText(0).contains('PROCESS ORDERS'), isTrue);
    s.dispose();
  });

  test('tap on a form field reaches it even though arrows jump between fields', () async {
    final s = await demoSession();
    final menuRow = [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains('1.Goods'));
    s.handleTap(3, menuRow);
    await pause(1200);
    expect(s.emu.rowText(0).contains('GOODS RECEIPT'), isTrue);
    expect(s.emu.cy, 3); // first field, row 4
    // tap inside "Storage loc." (row 10 -> index 9), 4 cells into the field
    s.handleTap(5, 9);
    await pause(1500);
    expect(s.emu.cy, 9);
    expect(s.emu.cx >= 1 && s.emu.cx <= 12, isTrue); // inside the field
    s.sendText('A7');
    await pause(200);
    expect(s.emu.rowText(9).contains('A7'), isTrue);
    // tap on the "Plant" field above
    s.handleTap(2, 6);
    await pause(1500);
    expect(s.emu.cy, 6);
    s.dispose();
  });

  test('tap on the blank row between menu items snaps to the nearer item', () async {
    // Menu items sit on rows 4,6,8,10 (index 3,5,7,9); row index 4 is blank.
    final s1 = await demoSession();
    s1.handleTap(3, 4, rowFrac: 0.2); // upper part of the gap -> item above (1.Goods Receipt)
    await pause(1500);
    expect(s1.emu.rowText(0).contains('GOODS RECEIPT'), isTrue);
    s1.dispose();

    final s2 = await demoSession();
    s2.handleTap(3, 4, rowFrac: 0.8); // lower part of the gap -> item below (2.Process Orders)
    await pause(1500);
    expect(s2.emu.rowText(0).contains('PROCESS ORDERS'), isTrue);
    s2.dispose();
  });

  test('copy-screen dump lists text and highlight marks', () {
    final e = Emulator();
    e.write('\x1b[2;1H[F3 Back] [ F4 Nxt]\x1b[4;1H[1.Movements   >]\x1b[7m   \x1b[0m');
    final d = e.dumpScreen();
    expect(d.contains('[1.Movements'), isTrue);
    expect(d.contains('R'), isTrue);
    e.dispose();
  });

  test('tap on a field label (row above the field) goes to that field, without back-and-forth', () async {
    final s = await demoSession();
    final menuRow = [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains('1.Goods'));
    s.handleTap(3, menuRow);
    await pause(1200);
    expect(s.emu.cy, 3);
    final labelRow = [for (var r = 0; r < 24; r++) r].firstWhere((r) => s.emu.rowText(r).contains('Storage loc.'));
    s.handleTap(4, labelRow); // label sits one row above its field (row index 8 -> field 9)
    await pause(1500);
    expect(s.emu.cy, labelRow + 1);
    s.dispose();
  });
}
