import 'dart:async';

import 'package:flutter/foundation.dart';

/// One character cell. Colors: -1 = default, 0..255 = palette, >=0x1000000 = 24-bit RGB.
class Cell {
  Cell([this.ch = 0x20, this.fg = -1, this.bg = -1, this.attr = 0]);
  int ch;
  int fg;
  int bg;
  int attr;
}

const int kBold = 1;
const int kUnderline = 2;
const int kReverse = 4;

/// A VT100/VT220/ANSI screen emulator with a fixed-size grid.
///
/// Escape sequences (cursor addressing, erase, scroll regions, SGR colours,
/// line-drawing charset...) are interpreted instead of being printed, which is
/// what stops raw text like "[2J" or "[17;1H" appearing on screen.
class Emulator extends ChangeNotifier {
  Emulator({this.cols = 80, this.rows = 24}) {
    _init();
  }

  int cols;
  int rows;
  late List<List<Cell>> grid;

  int cx = 0;
  int cy = 0;
  bool wrapPending = false;
  int top = 0;
  int bottom = 23;

  bool appCursor = false;
  bool autoWrap = true;
  bool cursorVisible = true;
  bool insertMode = false;

  /// When true, ESC is dropped so escape sequences print as plain text.
  /// Reproduces the old app's bug (raw "[17;1H" on screen) for demos.
  bool rawMode = false;

  int curFg = -1;
  int curBg = -1;
  int curAttr = 0;

  int _savedX = 0, _savedY = 0, _savedFg = -1, _savedBg = -1, _savedAttr = 0;

  bool _g0Gfx = false, _g1Gfx = false, _shifted = false;

  /// Answer sent for ESC[c / ESC Z.
  String deviceAttrs = '\x1b[?1;2c';

  /// Called with bytes the terminal must send back (cursor reports, DA).
  void Function(List<int> bytes)? onReply;
  VoidCallback? onBell;

  /// Called with escape sequences that are recognised as such but not implemented.
  void Function(String seq)? onUnhandled;

  int _st = 0; // 0 ground, 1 esc, 2 csi, 3 osc, 4 charset, 5 skip-one, 6 osc-esc
  int _charsetTarget = 0x28;
  final StringBuffer _buf = StringBuffer();
  Timer? _timer;

  static const String _gfx = '◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·';

  void _init() {
    top = 0;
    bottom = rows - 1;
    grid = List.generate(rows, (_) => _blankRow());
    cx = 0;
    cy = 0;
  }

  List<Cell> _blankRow() => List.generate(cols, (_) => Cell(0x20, -1, curBg, 0));

  String rowText(int r) => String.fromCharCodes(grid[r].map((c) => c.ch));

  /// Which cells of row [r] belong to input fields / highlighted buttons.
  ///
  /// Besides reverse-video, underlined and coloured-background cells, this also
  /// recognises fields the host draws on an explicit *black* background
  /// (`ESC[40m`) - those look empty on a black screen, so they used to be
  /// invisible. A black-background run counts as a field when it is short, mostly
  /// blank, and the rest of the row is not black-painted.
  List<bool> fieldMask(int r) {
    final row = grid[r];
    final m = List<bool>.filled(cols, false);
    var hasDefault = false;
    for (var x = 0; x < cols; x++) {
      final c = row[x];
      if (c.attr & (kReverse | kUnderline) != 0 || c.bg > 0) m[x] = true;
      if (c.bg < 0 && c.attr & kReverse == 0) hasDefault = true;
    }
    if (hasDefault) {
      var x = 0;
      while (x < cols) {
        final c = row[x];
        if (c.bg == 0 && c.attr & kReverse == 0 && !m[x]) {
          var e = x;
          while (e + 1 < cols && row[e + 1].bg == 0 && row[e + 1].attr & kReverse == 0) {
            e++;
          }
          final len = e - x + 1;
          var sp = 0;
          for (var i = x; i <= e; i++) {
            if (row[i].ch == 0x20) sp++;
          }
          if (len >= 2 && len <= 60 && sp * 10 >= len * 4) {
            for (var i = x; i <= e; i++) {
              m[i] = true;
            }
          }
          x = e + 1;
        } else {
          x++;
        }
      }
    }
    return m;
  }

  /// True when the cell at ([r],[c]) is a field cell that has no visible
  /// background of its own (black-background field) and so needs a drawn box.
  bool isBlackField(List<bool> mask, int r, int c) {
    final cell = grid[r][c];
    return mask[c] && cell.bg == 0 && cell.attr & kReverse == 0;
  }

  /// Contiguous field run on [r] that contains or touches column [c]:
  /// returns (start, end) inclusive, or null.
  (int, int)? fieldSpan(int r, int c) {
    final m = fieldMask(r);
    int? hit;
    for (final d in [0, -1, 1]) {
      final x = c + d;
      if (x >= 0 && x < cols && m[x]) {
        hit = x;
        break;
      }
    }
    if (hit == null) return null;
    var s = hit, e = hit;
    while (s > 0 && m[s - 1]) {
      s--;
    }
    while (e < cols - 1 && m[e + 1]) {
      e++;
    }
    return e - s >= 79 ? null : (s, e);
  }

  /// Whether row [r] has any field run (i.e. looks like it holds fields).
  bool rowHasFields(int r) {
    var n = 0;
    for (final v in fieldMask(r)) {
      if (v) n++;
    }
    return n > 0 && n < cols - 2;
  }

  /// All fields on screen in reading order: (row, startCol, endCol).
  List<(int, int, int)> fields() {
    final out = <(int, int, int)>[];
    for (var r = 0; r < rows; r++) {
      final m = fieldMask(r);
      var n = 0;
      for (final v in m) {
        if (v) n++;
      }
      if (n == 0 || n >= cols - 2) continue;
      var x = 0;
      while (x < cols) {
        if (m[x]) {
          var e = x;
          while (e + 1 < cols && m[e + 1]) {
            e++;
          }
          out.add((r, x, e));
          x = e + 1;
        } else {
          x++;
        }
      }
    }
    return out;
  }

  /// Plain-text dump of the screen for support: text, plus a line marking
  /// reverse (R), underline (U) and bold (B) cells under each row that has any.
  String dumpScreen() {
    final b = StringBuffer('screen ${cols}x$rows  cursor col=$cx row=$cy\n');
    for (var r = 0; r < rows; r++) {
      final row = grid[r];
      final text = rowText(r).trimRight();
      final marks = StringBuffer();
      final fm = fieldMask(r);
      var any = false;
      for (var x = 0; x < row.length; x++) {
        final c = row[x];
        final ch = c.attr & kReverse != 0
            ? 'R'
            : c.attr & kUnderline != 0
                ? 'U'
                : fm[x]
                    ? 'F'
                    : c.attr & kBold != 0
                        ? 'B'
                        : ' ';
        if (ch != ' ') any = true;
        marks.write(ch);
      }
      final rr = r.toString().padLeft(2, '0');
      if (text.isEmpty && !any) continue;
      b.writeln('$rr|$text');
      if (any) b.writeln('  |${marks.toString().trimRight()}');
    }
    return b.toString();
  }

  void reset() {
    curFg = curBg = -1;
    curAttr = 0;
    appCursor = false;
    autoWrap = true;
    cursorVisible = true;
    insertMode = false;
    _g0Gfx = _g1Gfx = _shifted = false;
    wrapPending = false;
    _init();
    _touch();
  }

  void _touch() {
    if (_timer != null) return;
    _timer = Timer(const Duration(milliseconds: 16), () {
      _timer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _reply(String s) => onReply?.call(s.codeUnits);

  // ---------------------------------------------------------------- input

  void write(String s) {
    for (final r in s.runes) {
      _feed(r);
    }
    _touch();
  }

  void _feed(int c) {
    switch (_st) {
      case 0:
        if (c == 0x1B && rawMode) {
          // dropped: sequence is printed as text
        } else if (c == 0x1B) {
          _st = 1;
        } else if (c < 0x20) {
          _control(c);
        } else if (c == 0x7F) {
          // ignore DEL
        } else {
          _put(c);
        }
        break;
      case 1:
        _st = 0;
        switch (c) {
          case 0x5B: // [
            _buf.clear();
            _st = 2;
            break;
          case 0x5D: // ]
            _st = 3;
            break;
          case 0x28: // (
          case 0x29: // )
            _charsetTarget = c;
            _st = 4;
            break;
          case 0x23: // #
          case 0x20:
          case 0x25:
            _st = 5;
            break;
          case 0x44: // D index
            _lineFeed();
            break;
          case 0x45: // E next line
            cx = 0;
            _lineFeed();
            break;
          case 0x4D: // M reverse index
            _reverseIndex();
            break;
          case 0x37: // 7
            _save();
            break;
          case 0x38: // 8
            _restore();
            break;
          case 0x63: // c
            reset();
            break;
          case 0x5A: // Z
            _reply(deviceAttrs);
            break;
          case 0x1B:
            _st = 1;
            break;
          default:
            break; // = > H etc. ignored
        }
        break;
      case 2:
        if (c >= 0x40 && c <= 0x7E) {
          _st = 0;
          _csi(c);
        } else if (c == 0x1B) {
          _st = 1;
        } else if (c < 0x20) {
          _control(c);
        } else {
          _buf.writeCharCode(c);
        }
        break;
      case 3:
        if (c == 0x07) {
          _st = 0;
        } else if (c == 0x1B) {
          _st = 6;
        }
        break;
      case 6:
        _st = 0;
        break;
      case 4:
        final gfx = c == 0x30; // '0' = DEC special graphics
        if (_charsetTarget == 0x28) {
          _g0Gfx = gfx;
        } else {
          _g1Gfx = gfx;
        }
        _st = 0;
        break;
      case 5:
        _st = 0;
        break;
    }
  }

  void _control(int c) {
    switch (c) {
      case 0x07:
        onBell?.call();
        break;
      case 0x08:
        if (cx > 0) cx--;
        wrapPending = false;
        break;
      case 0x09:
        cx = ((cx ~/ 8) + 1) * 8;
        if (cx > cols - 1) cx = cols - 1;
        wrapPending = false;
        break;
      case 0x0A:
      case 0x0B:
      case 0x0C:
        _lineFeed();
        break;
      case 0x0D:
        cx = 0;
        wrapPending = false;
        break;
      case 0x0E:
        _shifted = true;
        break;
      case 0x0F:
        _shifted = false;
        break;
    }
  }

  // ------------------------------------------------------------ primitives

  void _put(int c) {
    if (wrapPending && autoWrap) {
      cx = 0;
      _lineFeed();
    }
    wrapPending = false;
    if ((_shifted ? _g1Gfx : _g0Gfx) && c >= 0x60 && c <= 0x7E) {
      c = _gfx.runes.elementAt(c - 0x60);
    }
    final row = grid[cy];
    if (insertMode) {
      row.insert(cx, Cell());
      row.removeLast();
    }
    final cell = row[cx];
    cell.ch = c;
    cell.fg = curFg;
    cell.bg = curBg;
    cell.attr = curAttr;
    if (cx >= cols - 1) {
      wrapPending = true;
    } else {
      cx++;
    }
  }

  void _lineFeed() {
    wrapPending = false;
    if (cy == bottom) {
      _scrollUp(1);
    } else if (cy < rows - 1) {
      cy++;
    }
  }

  void _reverseIndex() {
    wrapPending = false;
    if (cy == top) {
      _scrollDown(1);
    } else if (cy > 0) {
      cy--;
    }
  }

  void _scrollUp(int n) {
    for (var i = 0; i < n; i++) {
      grid.removeAt(top);
      grid.insert(bottom, _blankRow());
    }
  }

  void _scrollDown(int n) {
    for (var i = 0; i < n; i++) {
      grid.removeAt(bottom);
      grid.insert(top, _blankRow());
    }
  }

  void _save() {
    _savedX = cx;
    _savedY = cy;
    _savedFg = curFg;
    _savedBg = curBg;
    _savedAttr = curAttr;
  }

  void _restore() {
    cx = _savedX.cl(0, cols - 1);
    cy = _savedY.cl(0, rows - 1);
    curFg = _savedFg;
    curBg = _savedBg;
    curAttr = _savedAttr;
    wrapPending = false;
  }

  void _erase(int r, int c0, int c1) {
    final row = grid[r];
    for (var c = c0; c <= c1 && c < cols; c++) {
      if (c < 0) continue;
      final cell = row[c];
      cell.ch = 0x20;
      cell.fg = -1;
      cell.bg = curBg;
      cell.attr = 0;
    }
  }

  // ------------------------------------------------------------------ CSI

  void _csi(int fin) {
    var s = _buf.toString();
    _buf.clear();
    var prefix = '';
    if (s.isNotEmpty && '?>=<!'.contains(s[0])) {
      prefix = s[0];
      s = s.substring(1);
    }
    final ps = s.isEmpty ? <int>[] : s.split(';').map((e) => int.tryParse(e) ?? -1).toList();
    int a(int i, int d) => (i < ps.length && ps[i] > 0) ? ps[i] : d;
    final f = String.fromCharCode(fin);

    if (f != 'm') wrapPending = false;

    switch (f) {
      case 'A':
        cy = (cy - a(0, 1)).cl(cy >= top ? top : 0, rows - 1);
        break;
      case 'B':
        cy = (cy + a(0, 1)).cl(0, cy <= bottom ? bottom : rows - 1);
        break;
      case 'C':
        cx = (cx + a(0, 1)).cl(0, cols - 1);
        break;
      case 'D':
        cx = (cx - a(0, 1)).cl(0, cols - 1);
        break;
      case 'E':
        cy = (cy + a(0, 1)).cl(0, rows - 1);
        cx = 0;
        break;
      case 'F':
        cy = (cy - a(0, 1)).cl(0, rows - 1);
        cx = 0;
        break;
      case 'G':
      case '`':
        cx = (a(0, 1) - 1).cl(0, cols - 1);
        break;
      case 'd':
        cy = (a(0, 1) - 1).cl(0, rows - 1);
        break;
      case 'H':
      case 'f':
        cy = (a(0, 1) - 1).cl(0, rows - 1);
        cx = (a(1, 1) - 1).cl(0, cols - 1);
        break;
      case 'J':
        final m = ps.isEmpty || ps[0] < 0 ? 0 : ps[0];
        if (m == 0) {
          _erase(cy, cx, cols - 1);
          for (var r = cy + 1; r < rows; r++) {
            _erase(r, 0, cols - 1);
          }
        } else if (m == 1) {
          for (var r = 0; r < cy; r++) {
            _erase(r, 0, cols - 1);
          }
          _erase(cy, 0, cx);
        } else {
          for (var r = 0; r < rows; r++) {
            _erase(r, 0, cols - 1);
          }
        }
        break;
      case 'K':
        final m = ps.isEmpty || ps[0] < 0 ? 0 : ps[0];
        if (m == 0) {
          _erase(cy, cx, cols - 1);
        } else if (m == 1) {
          _erase(cy, 0, cx);
        } else {
          _erase(cy, 0, cols - 1);
        }
        break;
      case 'L':
        if (cy >= top && cy <= bottom) {
          for (var i = 0; i < a(0, 1); i++) {
            grid.removeAt(bottom);
            grid.insert(cy, _blankRow());
          }
        }
        break;
      case 'M':
        if (cy >= top && cy <= bottom) {
          for (var i = 0; i < a(0, 1); i++) {
            grid.removeAt(cy);
            grid.insert(bottom, _blankRow());
          }
        }
        break;
      case 'P':
        final n = a(0, 1).cl(1, cols - cx);
        final row = grid[cy];
        row.removeRange(cx, cx + n);
        row.addAll(List.generate(n, (_) => Cell(0x20, -1, curBg, 0)));
        break;
      case '@':
        final n = a(0, 1).cl(1, cols - cx);
        final row = grid[cy];
        row.insertAll(cx, List.generate(n, (_) => Cell(0x20, -1, curBg, 0)));
        row.removeRange(cols, row.length);
        break;
      case 'X':
        _erase(cy, cx, cx + a(0, 1) - 1);
        break;
      case 'S':
        _scrollUp(a(0, 1));
        break;
      case 'T':
        _scrollDown(a(0, 1));
        break;
      case 'r':
        final t = a(0, 1) - 1;
        final b = a(1, rows) - 1;
        if (t < b && b < rows) {
          top = t;
          bottom = b;
        } else {
          top = 0;
          bottom = rows - 1;
        }
        cx = 0;
        cy = 0;
        break;
      case 'm':
        _sgr(ps);
        break;
      case 's':
        _save();
        break;
      case 'u':
        _restore();
        break;
      case 'n':
        if (prefix.isEmpty) {
          final m = ps.isEmpty ? 0 : ps[0];
          if (m == 5) _reply('\x1b[0n');
          if (m == 6) _reply('\x1b[${cy + 1};${cx + 1}R');
        }
        break;
      case 'c':
        if (prefix == '>') {
          _reply('\x1b[>0;0;0c');
        } else if (prefix.isEmpty) {
          _reply(deviceAttrs);
        }
        break;
      case 'h':
      case 'l':
        final on = f == 'h';
        for (final p in ps) {
          if (prefix == '?') {
            if (p == 1) appCursor = on;
            if (p == 7) autoWrap = on;
            if (p == 25) cursorVisible = on;
          } else if (p == 4) {
            insertMode = on;
          }
        }
        break;
      default:
        onUnhandled?.call('CSI $prefix$s$f');
        break;
    }
  }

  void _sgr(List<int> ps) {
    if (ps.isEmpty) ps = [0];
    for (var i = 0; i < ps.length; i++) {
      final p = ps[i] < 0 ? 0 : ps[i];
      if (p == 0) {
        curFg = -1;
        curBg = -1;
        curAttr = 0;
      } else if (p == 1) {
        curAttr |= kBold;
      } else if (p == 4) {
        curAttr |= kUnderline;
      } else if (p == 7) {
        curAttr |= kReverse;
      } else if (p == 22) {
        curAttr &= ~kBold;
      } else if (p == 24) {
        curAttr &= ~kUnderline;
      } else if (p == 27) {
        curAttr &= ~kReverse;
      } else if (p >= 30 && p <= 37) {
        curFg = p - 30;
      } else if (p == 39) {
        curFg = -1;
      } else if (p >= 40 && p <= 47) {
        curBg = p - 40;
      } else if (p == 49) {
        curBg = -1;
      } else if (p >= 90 && p <= 97) {
        curFg = p - 90 + 8;
      } else if (p >= 100 && p <= 107) {
        curBg = p - 100 + 8;
      } else if (p == 38 || p == 48) {
        int? color;
        if (i + 2 < ps.length && ps[i + 1] == 5) {
          color = ps[i + 2].cl(0, 255);
          i += 2;
        } else if (i + 4 < ps.length && ps[i + 1] == 2) {
          color = 0x1000000 |
              (ps[i + 2].cl(0, 255) << 16) |
              (ps[i + 3].cl(0, 255) << 8) |
              ps[i + 4].cl(0, 255);
          i += 4;
        }
        if (color != null) {
          if (p == 38) {
            curFg = color;
          } else {
            curBg = color;
          }
        }
      }
    }
  }
}

extension _IntClamp on int {
  int cl(int lo, int hi) => this < lo ? lo : (this > hi ? hi : this);
}
