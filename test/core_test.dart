import 'package:flutter_test/flutter_test.dart';
import 'package:sap_terminal/emulator.dart';
import 'package:sap_terminal/keymap.dart';
import 'package:sap_terminal/models.dart';

void main() {
  test('VT220 F3 sends ESC [ 1 3 ~', () {
    expect(KeyMap.bytes(TermKey.f3, TermType.vt220), [0x1B, 0x5B, 0x31, 0x33, 0x7E]);
  });

  test('ANSI F1 sends ESC [ M and F12 sends ESC [ X', () {
    expect(KeyMap.bytes(TermKey.f1, TermType.ansi), [0x1B, 0x5B, 0x4D]);
    expect(KeyMap.bytes(TermKey.f12, TermType.ansi), [0x1B, 0x5B, 0x58]);
  });

  test('override notation round-trips', () {
    final b = KeyMap.parseEscapes(r'\e[13~');
    expect(b, [0x1B, 0x5B, 0x31, 0x33, 0x7E]);
    expect(KeyMap.formatEscapes(b), r'\e[13~');
  });

  test('cursor addressing is obeyed, not printed', () {
    final e = Emulator();
    e.write('\x1b[2J\x1b[17;1HHello');
    expect(e.rowText(16).startsWith('Hello'), isTrue);
    expect(e.rowText(0).contains('['), isFalse);
    e.dispose();
  });

  test('backspace and erase line', () {
    final e = Emulator();
    e.write('AB\x08C');
    expect(e.rowText(0).startsWith('AC'), isTrue);
    e.write('\x1b[2K');
    expect(e.rowText(0).trim(), isEmpty);
    e.dispose();
  });

  test('line drawing charset maps to box characters', () {
    final e = Emulator();
    e.write('\x1b(0q\x1b(B');
    expect(String.fromCharCode(e.grid[0][0].ch), '─');
    e.dispose();
  });
}
