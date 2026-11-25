import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/models.dart';
import 'package:sap_terminal/session.dart';
import 'package:sap_terminal/terminal_view.dart';

void main() {
  Future<TerminalSession> show(WidgetTester t, TextSize size, String text) async {
    final s = TerminalSession(ConnectionConfig());
    s.textSize = size;
    s.emu.write(text);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(width: 360, height: 340, child: TerminalView(session: s))),
    ));
    await t.pump(const Duration(milliseconds: 50));
    return s;
  }

  testWidgets('normal fits all 80 columns, no sideways pan', (t) async {
    final s = await show(t, TextSize.normal, '\x1b[2;1Hhello');
    expect(s.panX, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('large and huge pan sideways to keep the cursor in view', (t) async {
    final s = await show(t, TextSize.large, '\x1b[2;75Hx');
    expect(s.panX < 0, isTrue); // cursor at column ~76 is beyond the 40 visible columns
    final big = await show(t, TextSize.huge, '\x1b[2;75Hx');
    expect(big.panX < s.panX, isTrue); // bigger text -> wider grid -> more pan
    expect(t.takeException(), isNull);
  });

  testWidgets('text near the left stays put at large size', (t) async {
    final s = await show(t, TextSize.large, '\x1b[4;1H[1.Movements   >]');
    expect(s.panX, 0);
    expect(t.takeException(), isNull);
  });
}
