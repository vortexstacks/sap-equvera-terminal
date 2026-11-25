import 'package:flutter/material.dart';

import 'emulator.dart';
import 'models.dart';
import 'session.dart';

class TermColors {
  const TermColors(this.fg, this.bg);
  final Color fg;
  final Color bg;

  static TermColors of(TermTheme t) => switch (t) {
        TermTheme.green => const TermColors(Color(0xFF33FF33), Color(0xFF000000)),
        TermTheme.white => const TermColors(Color(0xFFE8E8E8), Color(0xFF000000)),
        TermTheme.amber => const TermColors(Color(0xFFFFB000), Color(0xFF000000)),
      };
}

const List<int> _ansi16 = [
  0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
  0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
];

Color paletteColor(int i) {
  if (i < 16) return Color(0xFF000000 | _ansi16[i]);
  if (i < 232) {
    final n = i - 16;
    int lv(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(255, lv(n ~/ 36), lv((n ~/ 6) % 6), lv(n % 6));
  }
  final g = 8 + (i - 232) * 10;
  return Color.fromARGB(255, g, g, g);
}

Color resolveColor(int c, Color def, {bool bright = false}) {
  if (c < 0) return def;
  if (c >= 0x1000000) return Color(0xFF000000 | (c & 0xFFFFFF));
  if (bright && c < 8) return paletteColor(c + 8);
  return paletteColor(c);
}

class _Metrics {
  _Metrics(this.fontSize, this.cellW, this.cellH, this.ox, this.oy);
  final double fontSize, cellW, cellH, ox, oy;
}

/// Cursor block colour (orange): distinct from the green text and white fields.
const Color kCursorColor = Color(0xFFFF6D00);

const String kMono = 'monospace';
const List<String> kMonoFallback = ['Roboto Mono', 'Courier New', 'Droid Sans Mono'];

class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.session, this.onTap});

  final TerminalSession session;
  final VoidCallback? onTap;

  static (double, double)? _ratio;

  /// Glyph width/height as a multiple of font size, measured once.
  static (double, double) _measure() {
    if (_ratio != null) return _ratio!;
    final tp = TextPainter(
      text: const TextSpan(
        text: 'MMMMMMMMMM',
        style: TextStyle(fontFamily: kMono, fontFamilyFallback: kMonoFallback, fontSize: 100),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _ratio = (tp.width / 10 / 100, tp.height / 100);
    return _ratio!;
  }

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  TerminalSession get session => widget.session;

  /// Fits [TextSize] columns across the width (and all rows down the height,
  /// whichever limits first). A wider grid is panned sideways; the view follows
  /// the cursor so typing never goes off screen.
  _Metrics _metrics(Size size, int cols, int rows) {
    final (rw, rh) = TerminalView._measure();
    final fitCols = textSizeCols(session.textSize).clamp(1, cols).toInt();
    final fs = [size.width / (fitCols * rw), size.height / (rows * rh)].reduce((a, b) => a < b ? a : b);
    final cw = fs * rw;
    final ch = fs * rh;
    final gridW = cw * cols;
    var ox = (size.width - gridW) / 2;
    if (gridW > size.width) {
      final minX = size.width - gridW - 2;
      var pan = session.panX.clamp(minX, 0).toDouble();
      // keep the cursor cell inside the window
      final curL = session.emu.cx * cw + pan;
      if (curL < 0) pan -= curL;
      final curR = (session.emu.cx + 1) * cw + pan;
      if (curR > size.width) pan -= curR - size.width + 2;
      session.panX = pan.clamp(minX, 0).toDouble();
      ox = 2 + session.panX;
    }
    return _Metrics(fs, cw, ch, ox, (size.height - ch * rows) / 2);
  }

  @override
  Widget build(BuildContext context) {
    final colors = TermColors.of(session.config.theme);
    final emu = session.emu;
    return ListenableBuilder(
      listenable: emu,
      builder: (context, _) => LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final m = _metrics(size, emu.cols, emu.rows);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            final gridW = m.cellW * emu.cols;
            if (gridW > size.width) session.panHorizontally(d.delta.dx, size.width - gridW - 2);
          },
          onTapUp: (d) {
            // Row as a fractional number, so a tap near the edge of a row can
            // be matched to the neighbouring menu item / field.
            final rowF = (d.localPosition.dy - m.oy) / m.cellH;
            final col = ((d.localPosition.dx - m.ox) / m.cellW).floor();
            final row = rowF.floor();
            if (col >= 0 && row >= 0 && col < emu.cols && row < emu.rows) {
              session.handleTap(col, row, rowFrac: rowF - row);
            }
            widget.onTap?.call();
          },
          child: CustomPaint(
            size: size,
            painter: _TerminalPainter(emu, m, colors),
          ),
        );
      }),
    );
  }
}

class _TerminalPainter extends CustomPainter {
  _TerminalPainter(this.emu, this.m, this.colors) : super(repaint: emu);

  final Emulator emu;
  final _Metrics m;
  final TermColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.bg);
    canvas.save();
    canvas.translate(m.ox, m.oy);

    final bgPaint = Paint();
    for (var r = 0; r < emu.rows; r++) {
      final row = emu.grid[r];
      final y = r * m.cellH;
      final fmask = emu.fieldMask(r);

      // Backgrounds (only where non-default).
      for (var c = 0; c < emu.cols; c++) {
        final cell = row[c];
        final rev = cell.attr & kReverse != 0;
        Color? bg;
        if (rev) {
          bg = resolveColor(cell.fg, colors.fg, bright: cell.attr & kBold != 0);
        } else if (cell.bg >= 0) {
          bg = resolveColor(cell.bg, colors.bg);
        }
        if (emu.isBlackField(fmask, r, c)) {
          // Field the host draws on a black background: show it as a box.
          canvas.drawRect(Rect.fromLTWH(c * m.cellW, y, m.cellW + 0.5, m.cellH),
              bgPaint..color = const Color(0xFF33383D));
          canvas.drawRect(Rect.fromLTWH(c * m.cellW, y + m.cellH - 2, m.cellW + 0.5, 2),
              bgPaint..color = const Color(0xFFB0BEC5));
        } else if (bg != null) {
          canvas.drawRect(
            Rect.fromLTWH(c * m.cellW, y, m.cellW + 0.5, m.cellH),
            bgPaint..color = bg,
          );
        }
      }

      // Text, grouped into runs of identical style.
      var c = 0;
      while (c < emu.cols) {
        final cell = row[c];
        final style = _styleOf(cell);
        if (cell.ch < 0x20 || cell.ch > 0x7E) {
          if (cell.ch != 0x20 && cell.ch > 0x7E) {
            _drawText(canvas, String.fromCharCode(cell.ch), style, c * m.cellW, y);
          }
          c++;
          continue;
        }
        final start = c;
        final sb = StringBuffer();
        while (c < emu.cols) {
          final n = row[c];
          if (n.ch < 0x20 || n.ch > 0x7E || _styleOf(n) != style) break;
          sb.writeCharCode(n.ch);
          c++;
        }
        final s = sb.toString();
        if (s.trim().isNotEmpty || style.underline) {
          _drawText(canvas, s, style, start * m.cellW, y);
        }
      }
    }

    if (emu.cursorVisible) {
      final cell = emu.grid[emu.cy][emu.cx];
      // A colour the host never uses, so the cursor stands out on black and on
      // white / reverse-video field boxes alike.
      final cur = Paint()..color = kCursorColor;
      canvas.drawRect(Rect.fromLTWH(emu.cx * m.cellW, emu.cy * m.cellH, m.cellW, m.cellH), cur);
      if (cell.ch > 0x20) {
        _drawText(canvas, String.fromCharCode(cell.ch),
            _Style(const Color(0xFF000000), cell.attr & kBold != 0, false), emu.cx * m.cellW, emu.cy * m.cellH);
      }
    }
    canvas.restore();
  }

  _Style _styleOf(Cell cell) {
    final rev = cell.attr & kReverse != 0;
    final bold = cell.attr & kBold != 0;
    final Color fg = rev
        ? (cell.bg >= 0 ? resolveColor(cell.bg, colors.bg) : colors.bg)
        : resolveColor(cell.fg, colors.fg, bright: bold);
    return _Style(fg, bold, cell.attr & kUnderline != 0);
  }

  void _drawText(Canvas canvas, String s, _Style st, double x, double y) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: st.color,
          fontFamily: kMono,
          fontFamilyFallback: kMonoFallback,
          fontSize: m.fontSize,
          fontWeight: st.bold ? FontWeight.w700 : FontWeight.w400,
          decoration: st.underline ? TextDecoration.underline : TextDecoration.none,
          decorationColor: st.color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x, y + (m.cellH - tp.height) / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(covariant _TerminalPainter old) => true;
}

class _Style {
  const _Style(this.color, this.bold, this.underline);
  final Color color;
  final bool bold;
  final bool underline;

  @override
  bool operator ==(Object other) =>
      other is _Style && other.color == color && other.bold == bold && other.underline == underline;

  @override
  int get hashCode => Object.hash(color, bold, underline);
}
