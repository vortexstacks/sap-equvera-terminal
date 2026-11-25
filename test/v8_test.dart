import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/emulator.dart';
import 'package:sap_terminal/keymap.dart';
import 'package:sap_terminal/models.dart';
import 'package:sap_terminal/session.dart';

void main() {
  test('black-background field (bold red on black) is detected as a field', () {
    final e = Emulator();
    e.write('\x1b[2J\x1b[3;1HProcess Order No\x1b[4;1H\x1b[0;1;31;40m          \x1b[0m');
    final m = e.fieldMask(3);
    expect(m.where((v) => v).length, 10);
    expect(e.isBlackField(m, 3, 2), isTrue);
    expect(e.fields(), [(3, 0, 9)]);
    // the label row is not a field
    expect(e.rowHasFields(2), isFalse);
  });

  test('a whole row painted black is not a field', () {
    final e = Emulator();
    e.write('\x1b[2J\x1b[40m\x1b[5;1H${' ' * 80}\x1b[0m');
    expect(e.rowHasFields(4), isFalse);
  });

  test('a black-background label (mostly text) is not a field', () {
    final e = Emulator();
    e.write('\x1b[2J\x1b[2;1H\x1b[0;37;40mDest. Storage Type\x1b[0m');
    expect(e.rowHasFields(1), isFalse);
  });

  test('field with value on black background keeps its box', () {
    final e = Emulator();
    e.write('\x1b[2J\x1b[4;1H\x1b[0;1;31;40m567       \x1b[0m');
    expect(e.fields(), [(3, 0, 9)]);
  });

  test('tapping the words in [F2 Clr] / [F3 Back] counts as the F-key', () {
    final s = TerminalSession(ConnectionConfig());
    const row = '[F1 Save][F2 Clear]';
    expect(s.fKeyAt(row, 2), 1);
    expect(s.fKeyAt(row, 6), 1); // "Save"
    expect(s.fKeyAt(row, 11), 2);
    expect(s.fKeyAt(row, 16), 2); // "Clear"
    const row2 = '[F3 Back] [ F4 Nxt]';
    expect(s.fKeyAt(row2, 7), 3); // "Back"
    expect(s.fKeyAt(row2, 16), 4); // "Nxt"
    expect(s.fKeyAt('F1 Save F2 Clear', 5), 1);
    expect(s.fKeyAt('F1 Save F2 Clear', 13), 2);
    expect(s.fKeyAt('Process Order No', 5), isNull);
    s.dispose();
  });

  test('F-key code sets', () {
    expect(KeyMap.bytes(TermKey.f2, TermType.vt220, style: FKeyStyle.sco), [0x1B, 0x5B, 0x4E]);
    expect(KeyMap.bytes(TermKey.f2, TermType.vt220, style: FKeyStyle.vt100), [0x1B, 0x4F, 0x51]);
    expect(KeyMap.bytes(TermKey.f2, TermType.vt220, style: FKeyStyle.linux), [0x1B, 0x5B, 0x5B, 0x42]);
    expect(KeyMap.bytes(TermKey.f2, TermType.vt220, style: FKeyStyle.escDigit), [0x1B, 0x32]);
    expect(KeyMap.bytes(TermKey.f10, TermType.vt220, style: FKeyStyle.escDigit), [0x1B, 0x30]);
    expect(KeyMap.bytes(TermKey.f2, TermType.vt220), [0x1B, 0x5B, 0x31, 0x32, 0x7E]);
    expect(KeyMap.bytes(TermKey.f3, TermType.ansi), [0x1B, 0x5B, 0x4F]);
  });
}

void _extra() {}
