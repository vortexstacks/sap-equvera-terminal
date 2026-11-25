import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io' show Platform;

import 'applog.dart';
import 'emulator.dart';
import 'keymap.dart';
import 'models.dart';
import 'transport.dart';

enum SessionState { idle, connecting, connected, closed, error }

/// Glue between transport, emulator and input handling.
class TerminalSession extends ChangeNotifier {
  TerminalSession(this.config) : emu = Emulator(cols: config.cols, rows: config.rows) {
    emu.deviceAttrs = config.termType == TermType.vt220 ? '\x1b[?62;1;2c' : '\x1b[?1;2c';
    emu.onReply = (b) => sendBytes(b, label: 'reply');
    emu.onUnhandled = AppLog.instance.sequence;
  }

  final ConnectionConfig config;
  final Emulator emu;

  Transport? _transport;
  StreamSubscription<String>? _sub;

  SessionState state = SessionState.idle;
  String? error;
  bool ctrlArmed = false;
  bool showBytes = true;
  String lastSent = '';
  Map<String, String> overrides = {};
  FKeyStyle fkeyStyle = FKeyStyle.vt100;
  late TouchMode touchMode = config.touchMode;

  Future<void> connect() async {
    state = SessionState.connecting;
    error = null;
    notifyListeners();
    overrides = await KeyOverrideStore.load(config.termType);
    fkeyStyle = await FKeyStyleStore.load();
    await _loadTextSize();
    AppLog.instance.add('CONN', 'connecting  ${_summary()}');
    try {
      final t = createTransport(config);
      _transport = t;
      await t.connect(config.cols, config.rows);
      final bytes = t.incoming.map((d) {
        AppLog.instance.rx(d);
        return d;
      });
      final Stream<String> text = config.utf8
          ? const Utf8Decoder(allowMalformed: true).bind(bytes)
          : const Latin1Decoder(allowInvalid: true).bind(bytes);
      _sub = text.listen(
        emu.write,
        onError: (Object e) => _fail(e.toString()),
        onDone: () {
          if (state == SessionState.connected) {
            AppLog.instance.add('CONN', 'host closed the connection');
            state = SessionState.closed;
            notifyListeners();
          }
        },
      );
      state = SessionState.connected;
      AppLog.instance.add('CONN', 'connected');
      notifyListeners();
    } catch (e) {
      _fail(e.toString());
    }
  }

  void _fail(String msg) {
    AppLog.instance.add('ERROR', msg);
    error = msg;
    state = SessionState.error;
    notifyListeners();
  }

  Future<void> setFKeyStyle(FKeyStyle st) async {
    fkeyStyle = st;
    AppLog.instance.add('KEYS', 'F-key codes set to ${fkeyStyleLabel(st)}');
    notifyListeners();
    await FKeyStyleStore.save(st);
  }

  Future<void> reloadOverrides() async {
    overrides = await KeyOverrideStore.load(config.termType);
    notifyListeners();
  }

  Future<void> disconnect() async {
    AppLog.instance.add('CONN', 'disconnect');
    await _sub?.cancel();
    _sub = null;
    await _transport?.close();
    _transport = null;
    if (state == SessionState.connected || state == SessionState.connecting) {
      state = SessionState.closed;
    }
    notifyListeners();
  }

  Future<void> reconnect() async {
    await disconnect();
    emu.reset();
    await connect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _transport?.close();
    emu.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- sending

  void sendBytes(List<int> bytes, {String? label, bool secret = false}) {
    if (state != SessionState.connected || bytes.isEmpty) return;
    _transport?.send(bytes);
    final shown = bytes.length > 24 ? bytes.sublist(0, 24) : bytes;
    AppLog.instance.add(
      'TX',
      secret
          ? 'typed text, ${bytes.length} bytes (not recorded)'
          : '${label ?? 'raw'}  ${hexBytes(shown)}${bytes.length > 24 ? ' ... (${bytes.length} bytes)' : ''}',
    );
    if (label != null) {
      lastSent = '$label  →  ${hexBytes(bytes)}';
      notifyListeners();
    }
  }

  void sendKey(TermKey k) {
    final bytes = KeyMap.bytes(
      k,
      config.termType,
      appCursor: emu.appCursor,
      backspaceDel: config.backspaceDel,
      overrides: overrides,
      style: fkeyStyle,
    );
    sendBytes(bytes, label: k.label);
    if (k.isFunction && state == SessionState.connected) _watchReaction(k.label);
  }

  /// After an F-key, records what the host did. If the only change is extra
  /// characters in the field under the cursor, the host did not recognise the
  /// key codes and typed them as text (the "[13" problem) - say so.
  Future<void> _watchReaction(String label) async {
    final before = [for (var r = 0; r < emu.rows; r++) emu.rowText(r)];
    final cy0 = emu.cy;
    await _settle();
    final changed = <int>[];
    for (var r = 0; r < emu.rows; r++) {
      if (emu.rowText(r) != before[r]) changed.add(r);
    }
    if (changed.isEmpty) {
      AppLog.instance.add('HOST', '$label: screen did not change');
      return;
    }
    int ink(String t) => t.replaceAll(' ', '').length;
    if (changed.length == 1 && changed.first == cy0 && ink(emu.rowText(cy0)) > ink(before[cy0])) {
      AppLog.instance.add('HOST', '$label: host TYPED characters into the field - key codes not recognised');
      lastSent = '$label not recognised by host - menu > F-key codes, try another set';
      notifyListeners();
    } else {
      AppLog.instance.add('HOST', '$label: screen changed (${changed.length} rows)');
    }
  }

  void sendText(String text) {
    if (text.isEmpty) return;
    if (ctrlArmed) {
      ctrlArmed = false;
      final c = text.codeUnitAt(0);
      if (c >= 0x40 && c <= 0x7F) {
        sendBytes([c & 0x1F], label: 'Ctrl+${text[0].toUpperCase()}');
        return;
      }
      notifyListeners();
    }
    final bytes = config.utf8 ? utf8.encode(text) : latin1.encode(_latin1Safe(text));
    sendBytes(bytes, secret: true);
  }

  String _latin1Safe(String s) =>
      String.fromCharCodes(s.runes.map((r) => r < 256 ? r : 0x3F));

  void toggleCtrl() {
    ctrlArmed = !ctrlArmed;
    notifyListeners();
  }

  void cycleTouchMode() {
    touchMode = TouchMode.values[(touchMode.index + 1) % TouchMode.values.length];
    notifyListeners();
  }

  void toggleRawEscapes() {
    emu.rawMode = !emu.rawMode;
    notifyListeners();
  }

  void toggleShowBytes() {
    showBytes = !showBytes;
    notifyListeners();
  }

  // --------------------------------------------------------------- touch

  static final RegExp _fKey = RegExp(r'(?<![A-Za-z0-9])F(1[0-2]|[1-9])(?![0-9])');
  // A numbered menu item such as "[2.Process Orders >]" or "2) Orders",
  // within the first few columns of the row.
  static final RegExp _menuLine = RegExp(r'^\s{0,4}[\[\(]?\s*(\d{1,2})\s*[\.\)\]:]\s*\S');
  static final RegExp _selectRow = RegExp(r'\b(slct|select|selection|choice|option)\b', caseSensitive: false);

  bool _navBusy = false;

  static final RegExp _nextF = RegExp(r'^F(1[0-2]|[1-9])(?![0-9])');

  /// The F-key whose whole label ("[F2 Clear]", "F3 Back") covers [col], or null.
  /// The label is the F-number plus the words after it, up to "]", the next
  /// label, or a double space - so tapping "Clear" works as well as "F2".
  int? fKeyAt(String text, int col) {
    final zones = <(int, int, int)>[];
    for (final m in _fKey.allMatches(text)) {
      var s = m.start;
      if (s > 1 && text[s - 1] == ' ' && text[s - 2] == '[') {
        s -= 2;
      } else if (s > 0 && text[s - 1] == '[') {
        s -= 1;
      }
      var e = m.end;
      while (e < text.length) {
        final ch = text[e];
        if (ch == ']') {
          e++;
          break;
        }
        if (ch == '[') break;
        if (ch == ' ') {
          if (e + 1 < text.length && text[e + 1] == ' ') break;
          if (_nextF.hasMatch(text.substring(e + 1))) break;
        }
        e++;
      }
      zones.add((int.parse(m.group(1)!), s, e - 1));
    }
    for (final z in zones) {
      if (col >= z.$2 && col <= z.$3) return z.$1;
    }
    for (final z in zones) {
      if (col >= z.$2 - 1 && col <= z.$3 + 1) return z.$1;
    }
    return null;
  }

  /// Handles a tap on terminal cell ([col],[row]).
  /// Smart mode, in order: tapped "F3" style label -> that F-key;
  /// numbered menu line -> go to the select field, type its number + Enter;
  /// otherwise move the cursor there.
  void handleTap(int col, int row, {double rowFrac = 0.5}) {
    if (state != SessionState.connected || touchMode == TouchMode.off) return;
    if (_navBusy) return;
    col = col.clamp(0, emu.cols - 1).toInt();
    final tapped = row;
    row = _snapRow(row, rowFrac);
    AppLog.instance.add('TAP', 'col $col row $tapped'
        '${row != tapped ? ' snapped to row $row' : ''}  (cursor now ${emu.cx},${emu.cy})');

    if (touchMode == TouchMode.smart) {
      final text = emu.rowText(row);

      final fk = fKeyAt(text, col);
      if (fk != null) {
        AppLog.instance.add('TAP', 'F$fk label');
        sendKey(TermKey.values[fk - 1]);
        return;
      }

      final menu = _menuLine.firstMatch(text);
      if (menu != null && !text.contains('_') && !text.contains(':')) {
        AppLog.instance.add('TAP', 'menu item ${menu.group(1)}');
        _menuSelect(menu.group(1)!);
        return;
      }
    }

    _navigateTo(col, row);
  }

  /// True when row [r] holds something worth tapping: a numbered menu line,
  /// an F-key label, or a field / highlighted button.
  bool _isTarget(int r) {
    if (r < 0 || r >= emu.rows) return false;
    final t = emu.rowText(r);
    return _menuLine.hasMatch(t) || _fKey.hasMatch(t) || emu.rowHasFields(r);
  }

  /// A finger is much bigger than one terminal row, and SAP screens leave blank
  /// rows between items and put a label on the row above each field. So a tap
  /// that misses is moved to the item it was meant for:
  ///  - a label row directly above a field -> that field;
  ///  - a blank row next to an item -> the nearer item (up to 2 rows away).
  int _snapRow(int row, double frac) {
    row = row.clamp(0, emu.rows - 1).toInt();
    if (_isTarget(row)) return row;
    final text = emu.rowText(row).trim();
    if (text.isNotEmpty) {
      // "Plant" label, field on the next row
      if (row + 1 < emu.rows && emu.rowHasFields(row + 1)) return row + 1;
      return row;
    }
    final up = _isTarget(row - 1), down = _isTarget(row + 1);
    if (up && down) return frac < 0.5 ? row - 1 : row + 1;
    if (up) return row - 1;
    if (down) return row + 1;
    final up2 = _isTarget(row - 2), down2 = _isTarget(row + 2);
    if (up2 && down2) return frac < 0.5 ? row - 2 : row + 2;
    if (up2) return row - 2;
    if (down2) return row + 2;
    return row;
  }

  int? _findSelectRow() {
    for (var r = 0; r < emu.rows; r++) {
      final t = emu.rowText(r);
      if (_selectRow.hasMatch(t) && _menuLine.firstMatch(t) == null) return r;
    }
    return null;
  }

  Future<void> _menuSelect(String digits) async {
    _navBusy = true;
    try {
      final sel = _findSelectRow();
      if (sel != null && emu.cy != sel) {
        final m = _selectRow.firstMatch(emu.rowText(sel));
        final ok = emu.fields().isNotEmpty
            ? await _gotoField(sel, (m?.end ?? 0) + 1)
            : (await _stepToRow(sel));
        if (!ok && emu.cy != sel) {
          lastSent = 'Menu $digits  →  could not reach the select field';
          notifyListeners();
          return;
        }
      }
      sendBytes(digits.codeUnits, label: 'Menu $digits');
      sendKey(TermKey.enter);
    } finally {
      _navBusy = false;
    }
  }

  /// Waits for the host to answer a key: up to 450 ms for the first change on
  /// screen, then until the screen has been quiet for 80 ms.
  Future<void> _settle() {
    final done = Completer<void>();
    Timer? quiet;
    Timer? first;
    late VoidCallback listener;
    void finish() {
      if (done.isCompleted) return;
      quiet?.cancel();
      first?.cancel();
      emu.removeListener(listener);
      done.complete();
    }

    listener = () {
      quiet?.cancel();
      quiet = Timer(const Duration(milliseconds: 80), finish);
    };
    first = Timer(const Duration(milliseconds: 450), finish);
    emu.addListener(listener);
    return done.future;
  }

  /// Moves the cursor vertically to [target] one key at a time, checking where
  /// the host actually put it after each key. This is what makes it work on
  /// forms where an arrow key jumps to the next field instead of one cell.
  Future<bool> _stepToRow(int target) async {
    var useTab = false;
    var triedTab = false;
    var steps = 0;
    while (steps < 12) {
      final cx0 = emu.cx, cy0 = emu.cy;
      if (cy0 == target) return true;
      final down = target > cy0;
      if (useTab) {
        sendBytes(down ? const [9] : const [0x1B, 0x5B, 0x5A], label: 'Touch → ${down ? 'Tab' : 'Shift+Tab'}');
      } else {
        sendKey(down ? TermKey.down : TermKey.up);
      }
      steps++;
      await _settle();
      final cx1 = emu.cx, cy1 = emu.cy;
      AppLog.instance.add('NAV', 'step ${useTab ? 'tab' : down ? 'down' : 'up'}: cursor $cx0,$cy0 -> $cx1,$cy1 (target row $target)');
      if (cx1 == cx0 && cy1 == cy0) {
        // Host ignored the key: try Tab once, otherwise give up.
        if (!triedTab && !useTab) {
          triedTab = true;
          useTab = true;
          continue;
        }
        return false;
      }
      final before = (cy0 - target).abs();
      final after = (cy1 - target).abs();
      if (cy1 != cy0 && after >= before && cy1 != target) {
        // Went the wrong way or past the target: step back once and stop.
        if (useTab) {
          sendBytes(down ? const [0x1B, 0x5B, 0x5A] : const [9], label: 'Touch → back');
        } else {
          sendKey(down ? TermKey.up : TermKey.down);
        }
        await _settle();
        return emu.cy == target;
      }
    }
    return emu.cy == target;
  }

  static const List<int> _shiftTab = [0x1B, 0x5B, 0x5A];

  /// Index of the field the cursor is in (or the last one before it), -1 if none.
  int _fieldIndexAt(List<(int, int, int)> f, int cx, int cy) {
    var idx = -1;
    for (var i = 0; i < f.length; i++) {
      final (r, s, e) = f[i];
      if (r == cy && cx >= s && cx <= e) return i;
      if (r < cy || (r == cy && s <= cx)) idx = i;
    }
    return idx;
  }

  /// Moves to the field on [row] nearest [col] with Tab / Shift+Tab, checking
  /// where the cursor really is after every key. SAP RF hosts ignore the arrow
  /// keys on many screens but always honour Tab, and Tab visits the fields in
  /// reading order, so this is the reliable way to get to a field.
  Future<bool> _gotoField(int row, int col) async {
    var fields = emu.fields();
    (int, int, int)? target;
    var best = 1 << 30;
    for (final f in fields) {
      if (f.$1 != row) continue;
      final d = col < f.$2 ? f.$2 - col : (col > f.$3 ? col - f.$3 : 0);
      if (d < best) {
        best = d;
        target = f;
      }
    }
    if (target == null) {
      AppLog.instance.add('NAV', 'no field on row $row');
      return false;
    }
    bool inTarget() => emu.cy == target!.$1 && emu.cx >= target.$2 && emu.cx <= target.$3;
    final seen = <int>{};
    var failedKeys = 0;
    for (var step = 0; step < fields.length + 4 && !inTarget(); step++) {
      fields = emu.fields();
      final t = fields.indexWhere((f) => f.$1 == target!.$1 && f.$2 == target.$2);
      if (t < 0) break;
      final cur = _fieldIndexAt(fields, emu.cx, emu.cy);
      // Always go in reading order, never "the short way round": the host can
      // have focus stops we cannot see (unhighlighted buttons), so wrapping
      // around would count wrong.
      var useTab = cur < t;
      if (failedKeys == 1) useTab = !useTab; // first direction did nothing: try the other
      final cx0 = emu.cx, cy0 = emu.cy;
      sendBytes(useTab ? const [9] : _shiftTab, label: 'Touch → ${useTab ? 'Tab' : 'Shift+Tab'}');
      await _settle();
      AppLog.instance.add('NAV', '${useTab ? 'tab' : 'shift-tab'}: cursor $cx0,$cy0 -> ${emu.cx},${emu.cy} (target row ${target.$1} field $t)');
      if (emu.cx == cx0 && emu.cy == cy0) {
        failedKeys++;
        if (failedKeys >= 2) break;
        continue;
      }
      failedKeys = 0;
      if (!seen.add(emu.cy * 1000 + emu.cx) && !inTarget()) {
        // visiting the same place twice: the host's order differs from ours
        if (!seen.add(-(emu.cy * 1000 + emu.cx))) break;
      }
    }
    return inTarget();
  }

  /// Puts the cursor on the tapped column inside a field that already has text,
  /// so a value can be edited in the middle. Empty fields keep the cursor at the
  /// start. Checks where the cursor really is and corrects up to twice; if a key
  /// ever pushes the cursor out of the field, goes back to the field start.
  Future<int> _placeInField(int row, int col) async {
    final span = emu.fieldSpan(row, col);
    if (span == null) return 0;
    final content = emu.rowText(row).substring(span.$1, span.$2 + 1).trim();
    if (content.isEmpty) return 0;
    // Do not go past the end of the typed text.
    final lastChar = span.$1 + emu.rowText(row).substring(span.$1, span.$2 + 1).trimRight().length;
    final target = col.clamp(span.$1, lastChar.clamp(span.$1, span.$2)).toInt();
    var total = 0;
    for (var pass = 0; pass < 3; pass++) {
      final dx = target - emu.cx;
      if (emu.cy != row || dx == 0) break;
      final k = dx < 0 ? TermKey.left : TermKey.right;
      final b = KeyMap.bytes(k, config.termType, appCursor: emu.appCursor, overrides: overrides);
      final seq = <int>[];
      for (var i = 0; i < dx.abs().clamp(0, 60); i++) {
        seq.addAll(b);
      }
      final x0 = emu.cx;
      sendBytes(seq, label: 'Touch → ${dx.abs()}x ${dx < 0 ? 'left' : 'right'}');
      total += dx.abs();
      await _settle();
      AppLog.instance.add('NAV', 'in-field move: cursor $x0 -> ${emu.cx},${emu.cy} (wanted col $target)');
      if (emu.cx == x0 && emu.cy == row) break; // host ignores left/right here
    }
    if (emu.cy != row || emu.cx < span.$1 || emu.cx > span.$2) {
      AppLog.instance.add('NAV', 'cursor left the field - returning');
      await _gotoField(row, span.$1);
    }
    return total;
  }

  Future<void> _navigateTo(int col, int row) async {
    _navBusy = true;
    var sent = 0;
    try {
      if (emu.fields().isNotEmpty) {
        // Form screen: Tab between fields, never guess with arrow keys.
        if (!emu.rowHasFields(row)) {
          lastSent = 'Touch ($col,$row)  →  no field here';
          AppLog.instance.add('NAV', 'no field at col $col row $row - ignored');
          notifyListeners();
          return;
        }
        final ok = await _gotoField(row, col);
        if (ok) {
          sent = await _placeInField(row, col);
        }
        lastSent = 'Touch ($col,$row)  →  cursor ${emu.cx},${emu.cy}${sent > 0 ? '  ($sent moves)' : ''}';
        AppLog.instance.add('NAV', 'done: wanted col $col row $row, cursor is ${emu.cx},${emu.cy}${ok ? '' : '  (MISSED)'}');
        notifyListeners();
        return;
      }
      if (row != emu.cy) {
        await _stepToRow(row);
      }
      if (emu.cy == row) {
        // Stay inside the field under the finger when there is one.
        final span = emu.fieldSpan(row, col);
        var target = col;
        var ok = true;
        if (span != null) {
          target = col.clamp(span.$1, span.$2).toInt();
          ok = emu.cx >= span.$1 && emu.cx <= span.$2;
        } else if (emu.rowHasFields(row)) {
          ok = false; // tapped between fields: stay on the field we reached
        }
        final dx = target - emu.cx;
        if (ok && dx != 0) {
          final k = dx < 0 ? TermKey.left : TermKey.right;
          final b = KeyMap.bytes(k, config.termType, appCursor: emu.appCursor, overrides: overrides);
          final seq = <int>[];
          for (var i = 0; i < dx.abs().clamp(0, 80); i++) {
            seq.addAll(b);
          }
          sendBytes(seq);
          sent = dx.abs();
          await _settle();
        }
      }
      lastSent = 'Touch ($col,$row)  →  cursor ${emu.cx},${emu.cy}${sent > 0 ? '  ($sent moves)' : ''}';
      AppLog.instance.add('NAV', 'done: wanted col $col row $row, cursor is ${emu.cx},${emu.cy}${emu.cy == row ? '' : '  (MISSED)'}');
      notifyListeners();
    } finally {
      _navBusy = false;
    }
  }

  // ----------------------------------------------------------- text size

  TextSize textSize = TextSize.large;
  double panX = 0;

  Future<void> _loadTextSize() async {
    try {
      final p = await SharedPreferences.getInstance();
      final i = p.getInt('text_size');
      if (i != null && i >= 0 && i < TextSize.values.length) textSize = TextSize.values[i];
    } catch (_) {}
  }

  Future<void> cycleTextSize() async {
    textSize = TextSize.values[(textSize.index + 1) % TextSize.values.length];
    panX = 0;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('text_size', textSize.index);
    } catch (_) {}
  }

  void panHorizontally(double dx, double minX) {
    final v = (panX + dx).clamp(minX < 0 ? minX : 0, 0).toDouble();
    if (v != panX) {
      panX = v;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- support log

  String _summary() =>
      '${protocolLabel(config.protocol)} ${config.host}:${config.port}  terminal ${termLabel(config.termType)}'
      '  ${config.cols}x${config.rows}  touch ${touchLabel(touchMode)}  text ${textSizeLabel(textSize)}';

  /// Text at the top of an exported log (no passwords).
  String logHeader() => 'app $kBuildTag\nandroid ${Platform.operatingSystemVersion}\n${_summary()}\n'
      'state $state  cursor ${emu.cx},${emu.cy}  utf8 ${config.utf8}  backspace ${config.backspaceDel ? '7F' : '08'}';

  String exportLog() => AppLog.instance.export(header: logHeader(), screen: emu.dumpScreen());
}
