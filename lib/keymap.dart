import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

enum TermKey {
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  up, down, left, right,
  enter, tab, esc, backspace,
  home, end, pageUp, pageDown, insert, delete,
}

extension TermKeyX on TermKey {
  bool get isFunction => index < 12;

  String get label {
    if (isFunction) return 'F${index + 1}';
    switch (this) {
      case TermKey.up:
        return '↑';
      case TermKey.down:
        return '↓';
      case TermKey.left:
        return '←';
      case TermKey.right:
        return '→';
      case TermKey.enter:
        return 'Enter';
      case TermKey.tab:
        return 'Tab';
      case TermKey.esc:
        return 'Esc';
      case TermKey.backspace:
        return 'Bksp';
      case TermKey.home:
        return 'Home';
      case TermKey.end:
        return 'End';
      case TermKey.pageUp:
        return 'PgUp';
      case TermKey.pageDown:
        return 'PgDn';
      case TermKey.insert:
        return 'Ins';
      case TermKey.delete:
        return 'Del';
      default:
        return name;
    }
  }
}

/// Which escape codes F1..F12 send. "auto" follows the terminal type; the others
/// force one table, because a host can expect a different set than the one it
/// negotiated (Georgia SoftWorks did not accept the VT220 codes).
enum FKeyStyle { auto, vt220, vt100, sco, linux, escDigit }

String fkeyStyleLabel(FKeyStyle s) => switch (s) {
      FKeyStyle.auto => 'Automatic (follow terminal type)',
      FKeyStyle.vt220 => 'VT220  F2 = ESC [ 1 2 ~',
      FKeyStyle.vt100 => 'VT100 / xterm  F2 = ESC O Q',
      FKeyStyle.sco => 'SCO ANSI  F2 = ESC [ N',
      FKeyStyle.linux => 'Linux console  F2 = ESC [ [ B',
      FKeyStyle.escDigit => 'Esc + digit  F2 = ESC 2',
    };

String hexBytes(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

/// Escape-code tables for each terminal type.
///
/// IMPORTANT: these are the usual codes. Servers (e.g. Georgia SoftWorks) can be
/// configured differently, so every key can be overridden in the app
/// (menu > F-key mapping) and the override is stored per terminal type.
class KeyMap {
  static const _esc = '\x1b';

  static const Map<int, String> _vt100F = {
    1: '\x1bOP', 2: '\x1bOQ', 3: '\x1bOR', 4: '\x1bOS',
    5: '\x1b[15~', 6: '\x1b[17~', 7: '\x1b[18~', 8: '\x1b[19~',
    9: '\x1b[20~', 10: '\x1b[21~', 11: '\x1b[23~', 12: '\x1b[24~',
  };

  static const Map<int, String> _vt220F = {
    1: '\x1b[11~', 2: '\x1b[12~', 3: '\x1b[13~', 4: '\x1b[14~',
    5: '\x1b[15~', 6: '\x1b[17~', 7: '\x1b[18~', 8: '\x1b[19~',
    9: '\x1b[20~', 10: '\x1b[21~', 11: '\x1b[23~', 12: '\x1b[24~',
  };

  // SCO ANSI: F1..F12 = ESC [ M .. ESC [ X
  static Map<int, String> get _ansiF => {
        for (var i = 1; i <= 12; i++) i: '$_esc[${String.fromCharCode(76 + i)}',
      };

  static const Map<int, String> _linuxF = {
    1: '\x1b[[A', 2: '\x1b[[B', 3: '\x1b[[C', 4: '\x1b[[D', 5: '\x1b[[E',
    6: '\x1b[17~', 7: '\x1b[18~', 8: '\x1b[19~', 9: '\x1b[20~',
    10: '\x1b[21~', 11: '\x1b[23~', 12: '\x1b[24~',
  };

  static const Map<int, String> _escDigitF = {
    1: '\x1b1', 2: '\x1b2', 3: '\x1b3', 4: '\x1b4', 5: '\x1b5', 6: '\x1b6',
    7: '\x1b7', 8: '\x1b8', 9: '\x1b9', 10: '\x1b0', 11: '\x1b-', 12: '\x1b=',
  };

  /// Default bytes (before user overrides).
  static List<int> defaults(
    TermKey k,
    TermType t, {
    bool appCursor = false,
    bool backspaceDel = false,
    FKeyStyle style = FKeyStyle.auto,
  }) {
    if (k.isFunction) {
      final n = k.index + 1;
      final eff = style != FKeyStyle.auto
          ? style
          : switch (t) {
              TermType.vt100 => FKeyStyle.vt100,
              TermType.vt220 => FKeyStyle.vt220,
              TermType.ansi => FKeyStyle.sco,
            };
      final table = switch (eff) {
        FKeyStyle.vt100 => _vt100F,
        FKeyStyle.vt220 || FKeyStyle.auto => _vt220F,
        FKeyStyle.sco => _ansiF,
        FKeyStyle.linux => _linuxF,
        FKeyStyle.escDigit => _escDigitF,
      };
      return table[n]!.codeUnits;
    }
    final ansi = t == TermType.ansi;
    switch (k) {
      case TermKey.up:
      case TermKey.down:
      case TermKey.right:
      case TermKey.left:
        final ch = const {
          TermKey.up: 'A',
          TermKey.down: 'B',
          TermKey.right: 'C',
          TermKey.left: 'D',
        }[k]!;
        return (appCursor && !ansi ? '${_esc}O$ch' : '$_esc[$ch').codeUnits;
      case TermKey.enter:
        return [13];
      case TermKey.tab:
        return [9];
      case TermKey.esc:
        return [27];
      case TermKey.backspace:
        return [backspaceDel ? 127 : 8];
      case TermKey.home:
        return (ansi ? '$_esc[H' : '$_esc[1~').codeUnits;
      case TermKey.end:
        return (ansi ? '$_esc[F' : '$_esc[4~').codeUnits;
      case TermKey.pageUp:
        return (ansi ? '$_esc[I' : '$_esc[5~').codeUnits;
      case TermKey.pageDown:
        return (ansi ? '$_esc[G' : '$_esc[6~').codeUnits;
      case TermKey.insert:
        return (ansi ? '$_esc[L' : '$_esc[2~').codeUnits;
      case TermKey.delete:
        return ansi ? [127] : '$_esc[3~'.codeUnits;
      default:
        return const [];
    }
  }

  /// Bytes for a key, honouring user overrides (keyed by TermKey.name).
  static List<int> bytes(
    TermKey k,
    TermType t, {
    bool appCursor = false,
    bool backspaceDel = false,
    Map<String, String> overrides = const {},
    FKeyStyle style = FKeyStyle.auto,
  }) {
    final o = overrides[k.name];
    if (o != null && o.isNotEmpty) return parseEscapes(o);
    return defaults(k, t, appCursor: appCursor, backspaceDel: backspaceDel, style: style);
  }

  /// Parses notation such as `\e[13~`, `\x1bOR`, `\r`, `\t`.
  static List<int> parseEscapes(String s) {
    final out = <int>[];
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        final n = s[i + 1];
        if (n == 'e' || n == 'E') {
          out.add(27);
          i += 2;
        } else if (n == 'r') {
          out.add(13);
          i += 2;
        } else if (n == 'n') {
          out.add(10);
          i += 2;
        } else if (n == 't') {
          out.add(9);
          i += 2;
        } else if (n == '\\') {
          out.add(92);
          i += 2;
        } else if (n == 'x' && i + 4 <= s.length) {
          final v = int.tryParse(s.substring(i + 2, i + 4), radix: 16);
          if (v != null) {
            out.add(v);
            i += 4;
          } else {
            out.add(92);
            i += 1;
          }
        } else {
          out.add(92);
          i += 1;
        }
      } else {
        out.add(c.codeUnitAt(0) & 0xFF);
        i += 1;
      }
    }
    return out;
  }

  /// Inverse of [parseEscapes].
  static String formatEscapes(List<int> b) {
    final sb = StringBuffer();
    for (final v in b) {
      if (v == 27) {
        sb.write(r'\e');
      } else if (v == 13) {
        sb.write(r'\r');
      } else if (v == 10) {
        sb.write(r'\n');
      } else if (v == 9) {
        sb.write(r'\t');
      } else if (v == 92) {
        sb.write(r'\\');
      } else if (v >= 0x20 && v < 0x7F) {
        sb.writeCharCode(v);
      } else {
        sb.write('\\x${v.toRadixString(16).padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }
}

/// Persisted per-terminal-type key overrides.
class KeyOverrideStore {
  static String _k(TermType t) => 'keymap_${t.name}';

  static Future<Map<String, String>> load(TermType t) async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_k(t));
      if (s == null) return {};
      return (jsonDecode(s) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(TermType t, Map<String, String> m) async {
    final p = await SharedPreferences.getInstance();
    if (m.isEmpty) {
      await p.remove(_k(t));
    } else {
      await p.setString(_k(t), jsonEncode(m));
    }
  }
}

/// Persisted choice of F-key code table (shared by all connections).
class FKeyStyleStore {
  static const _key = 'fkey_style';

  static Future<FKeyStyle> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final n = p.getString(_key);
      for (final v in FKeyStyle.values) {
        if (v.name == n) return v;
      }
    } catch (_) {}
    // Default: the codes the client's original app sends (F1-F4 = ESC O P..S).
    return FKeyStyle.vt100;
  }

  static Future<void> save(FKeyStyle s) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, s.name);
    } catch (_) {}
  }
}
