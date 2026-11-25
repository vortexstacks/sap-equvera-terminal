import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'applog.dart';
import 'keymap.dart';
import 'models.dart';

/// A byte pipe to the server.
abstract class Transport {
  Stream<Uint8List> get incoming;
  Future<void> connect(int cols, int rows);
  void send(List<int> data);
  void resize(int cols, int rows);
  Future<void> close();
}

Transport createTransport(ConnectionConfig c) {
  switch (c.protocol) {
    case Protocol.telnet:
      return TelnetTransport(c.host, c.port, c.termType.name);
    case Protocol.ssh:
      return SshTransport(c.host, c.port, c.username, c.password, c.termType.name);
    case Protocol.tcp:
      return TcpTransport(c.host, c.port);
    case Protocol.demo:
      return DemoTransport();
  }
}

/// Shared plumbing: a stream controller that tolerates late events.
abstract class _BaseTransport implements Transport {
  final StreamController<Uint8List> out = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get incoming => out.stream;

  void emit(List<int> data) {
    if (!out.isClosed && data.isNotEmpty) out.add(Uint8List.fromList(data));
  }

  void emitError(Object e) {
    if (!out.isClosed) out.addError(e);
  }

  void finish() {
    if (!out.isClosed) out.close();
  }
}

/// Raw TCP socket: bytes in, bytes out.
class TcpTransport extends _BaseTransport {
  TcpTransport(this.host, this.port);
  final String host;
  final int port;
  Socket? _socket;

  @override
  Future<void> connect(int cols, int rows) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    s.listen(emit, onError: emitError, onDone: finish, cancelOnError: true);
  }

  @override
  void send(List<int> data) => _socket?.add(data);

  @override
  void resize(int cols, int rows) {}

  @override
  Future<void> close() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket?.destroy();
    finish();
  }
}

/// Telnet client with option negotiation (TTYPE, NAWS, SGA, ECHO, BINARY).
class TelnetTransport extends _BaseTransport {
  TelnetTransport(this.host, this.port, this.termName);
  final String host;
  final int port;
  final String termName;

  static const int _iac = 255, _dont = 254, _do = 253, _wont = 252, _will = 251;
  static const int _sb = 250, _se = 240;
  static const int _optBinary = 0, _optEcho = 1, _optSga = 3, _optTtype = 24, _optNaws = 31;

  Socket? _socket;
  int _cols = 80, _rows = 24;

  // parser state: 0 data, 1 IAC, 2 option cmd, 3 subnegotiation, 4 IAC inside SB
  int _state = 0;
  int _cmd = 0;
  bool _afterCr = false;
  final List<int> _sbBuf = [];
  final Set<int> _local = {}; // options we enabled (WILL)
  final Set<int> _remote = {}; // options the server enabled (DO)

  @override
  Future<void> connect(int cols, int rows) async {
    _cols = cols;
    _rows = rows;
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 15));
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    s.listen(_onData, onError: emitError, onDone: finish, cancelOnError: true);
  }

  void _raw(List<int> b) => _socket?.add(b);

  void _onData(Uint8List data) {
    final out = <int>[];
    for (final b in data) {
      switch (_state) {
        case 0:
          if (b == _iac) {
            _state = 1;
          } else if (_afterCr && b == 0) {
            _afterCr = false; // CR NUL -> CR
          } else {
            _afterCr = b == 13;
            out.add(b);
          }
          break;
        case 1:
          if (b == _iac) {
            out.add(255);
            _state = 0;
          } else if (b >= _will && b <= _dont) {
            _cmd = b;
            _state = 2;
          } else if (b == _sb) {
            _sbBuf.clear();
            _state = 3;
          } else {
            _state = 0;
          }
          break;
        case 2:
          _option(_cmd, b);
          _state = 0;
          break;
        case 3:
          if (b == _iac) {
            _state = 4;
          } else {
            _sbBuf.add(b);
          }
          break;
        case 4:
          if (b == _se) {
            _subneg();
            _state = 0;
          } else if (b == _iac) {
            _sbBuf.add(255);
            _state = 3;
          } else {
            _state = 3;
          }
          break;
      }
    }
    emit(out);
  }

  void _option(int cmd, int opt) {
    AppLog.instance.add('NEG', 'host ${const ['WILL', 'WONT', 'DO', 'DONT'][cmd - _will]} option $opt');
    switch (cmd) {
      case _do:
        if (opt == _optTtype || opt == _optNaws || opt == _optSga || opt == _optBinary) {
          if (_local.add(opt)) {
            _raw([_iac, _will, opt]);
            if (opt == _optNaws) _sendNaws();
          }
        } else {
          _raw([_iac, _wont, opt]);
        }
        break;
      case _dont:
        if (_local.remove(opt)) _raw([_iac, _wont, opt]);
        break;
      case _will:
        if (opt == _optEcho || opt == _optSga || opt == _optBinary) {
          if (_remote.add(opt)) _raw([_iac, _do, opt]);
        } else {
          _raw([_iac, _dont, opt]);
        }
        break;
      case _wont:
        if (_remote.remove(opt)) _raw([_iac, _dont, opt]);
        break;
    }
  }

  void _subneg() {
    // IAC SB TTYPE SEND IAC SE  ->  IAC SB TTYPE IS <name> IAC SE
    if (_sbBuf.length >= 2 && _sbBuf[0] == _optTtype && _sbBuf[1] == 1) {
      AppLog.instance.add('NEG', 'sent terminal type ${termName.toUpperCase()}');
      _raw([_iac, _sb, _optTtype, 0, ...ascii.encode(termName.toUpperCase()), _iac, _se]);
    }
  }

  void _sendNaws() {
    AppLog.instance.add('NEG', 'sent window size ${_cols}x$_rows');
    _raw([_iac, _sb, _optNaws, _cols >> 8, _cols & 0xFF, _rows >> 8, _rows & 0xFF, _iac, _se]);
  }

  @override
  void send(List<int> data) {
    final binary = _local.contains(_optBinary);
    final b = <int>[];
    for (final v in data) {
      if (v == 255) {
        b.addAll([255, 255]);
      } else if (v == 13 && !binary) {
        b.addAll([13, 0]);
      } else {
        b.add(v);
      }
    }
    _raw(b);
  }

  @override
  void resize(int cols, int rows) {
    _cols = cols;
    _rows = rows;
    if (_local.contains(_optNaws)) _sendNaws();
  }

  @override
  Future<void> close() async {
    try {
      await _socket?.close();
    } catch (_) {}
    _socket?.destroy();
    finish();
  }
}

/// SSH shell session with a PTY.
class SshTransport extends _BaseTransport {
  SshTransport(this.host, this.port, this.user, this.password, this.termName);
  final String host;
  final int port;
  final String user;
  final String password;
  final String termName;

  SSHClient? _client;
  SSHSession? _shell;

  @override
  Future<void> connect(int cols, int rows) async {
    final socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
    final client = SSHClient(socket, username: user, onPasswordRequest: () => password);
    _client = client;
    await client.authenticated;
    final shell = await client.shell(
      pty: SSHPtyConfig(type: termName, width: cols, height: rows),
    );
    _shell = shell;
    shell.stdout.listen(emit, onError: emitError);
    shell.stderr.listen(emit, onError: emitError);
    shell.done.then((_) => finish(), onError: (Object e) {
      emitError(e);
      finish();
    });
  }

  @override
  void send(List<int> data) => _shell?.write(Uint8List.fromList(data));

  @override
  void resize(int cols, int rows) => _shell?.resizeTerminal(cols, rows);

  @override
  Future<void> close() async {
    _shell?.close();
    _client?.close();
    finish();
  }
}

/// Offline mock SAP host. It behaves like a server set up for VT220 function
/// keys: F-keys sent with the matching codes are accepted, F-keys sent with the
/// codes of another terminal type are shown as NOT RECOGNISED. This reproduces
/// the "some F-keys don't work" problem and shows the fix (pick the right type
/// or edit the code under menu > F-key codes).
///
/// The menu and form screens work like SAP RF screens on a real host: the
/// cursor sits on one field or button at a time, and Up/Down/Tab JUMP to the
/// previous/next one (they do not move cell by cell). Tapping a field has to
/// cope with that.
class DemoTransport extends _BaseTransport {
  int _screen = 0;
  String _status = 'Press F1-F12 to test the keys';
  bool _ok = true;

  static const TermType _serverType = TermType.vt220;

  // Focusable things on the current screen, in reading order.
  List<_DemoItem> _items = [];
  int _it = 0; // focused item
  int _off = 0; // cursor offset inside a field
  final Map<int, List<String>> _vals = {};

  void _p(String s) => emit(utf8.encode(s));

  @override
  Future<void> connect(int cols, int rows) async {
    _render();
  }

  void _openScreen(int n) {
    _screen = n;
    _vals.clear();
    _off = 0;
    if (n == 0) {
      _items = [
        _DemoItem.button(2, 1, 9, 'F3 Back'),
        _DemoItem.button(2, 12, 10, 'F4 Nxt'),
        _DemoItem.field(12, 8, 4, 'Slct'),
        _DemoItem.button(14, 1, 9, 'F8 Off'),
      ];
      _it = 2;
    } else if (n >= 1 && n <= 3) {
      _items = [
        _DemoItem.button(2, 1, 9, 'F3 Back'),
        _DemoItem.button(2, 12, 10, 'F4 Nxt'),
        _DemoItem.field(4, 2, 12, 'Document no.'),
        _DemoItem.field(7, 2, 12, 'Plant'),
        _DemoItem.field(10, 2, 12, 'Storage loc.'),
        _DemoItem.field(13, 2, 12, 'Quantity'),
      ];
      _it = 2;
    } else {
      _items = [];
      _it = 0;
    }
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].isField) _vals[i] = List.filled(_items[i].w, ' ');
    }
  }

  _DemoItem? get _cur => _items.isEmpty ? null : _items[_it];

  void _place() {
    final c = _cur;
    if (c != null) _p('\x1b[${c.row};${c.col + (c.isField ? _off : 0)}H');
  }

  void _render() {
    if (_items.isEmpty && _screen != 4) _openScreen(_screen);
    _p('\x1b[2J\x1b[H');
    if (_screen == 0) {
      _p('\x1b[1;12H[ F2 Clr]');
      _p('\x1b[2;1H[F3 Back] [ F4 Nxt]');
      _p('\x1b[4;1H[1.Goods Receipt     >]');
      _p('\x1b[6;1H[2.Process Orders    >]');
      _p('\x1b[8;1H[3.Stock Overview    >]');
      _p('\x1b[10;1H[4.Terminal Test     >]');
      _p('\x1b[12;1HSlct \x1b[4m    \x1b[0m');
      _p('\x1b[14;1H[F8 Off]');
      _p('\x1b[17;1HThis host expects ${termLabel(_serverType)} function keys.');
      _p('\x1b[18;1HConnect as VT100 or ANSI to see keys rejected.');
      _p('\x1b[19;1HArrows and Tab jump between fields, like SAP RF.');
    } else if (_screen == 4) {
      _p('\x1b[1;1H\x1b[7m TERMINAL TEST \x1b[0m');
      _p('\x1b[3;2HThis screen positions text with ESC[17;1H.');
      _p('\x1b[4;2HWith escape codes ON the line appears on row 17.');
      _p('\x1b[5;2HWith them OFF (menu) you see raw text, the old bug.');
      _p('\x1b[17;1H>>> ROW 17: cursor command obeyed');
      _p('\x1b[22;1H[F3 Back]');
    } else {
      final titles = ['', 'GOODS RECEIPT', 'PROCESS ORDERS', 'STOCK OVERVIEW'];
      _p('\x1b[1;1H${titles[_screen]}');
      _p('\x1b[2;1H[F3 Back] [ F4 Nxt]');
      for (var i = 0; i < _items.length; i++) {
        final it = _items[i];
        if (!it.isField) continue;
        _p('\x1b[${it.row - 1};2H${it.label}');
        _p('\x1b[${it.row};${it.col}H\x1b[4m${_vals[i]!.join()}\x1b[0m');
      }
      _p('\x1b[16;1HTap a field to move the cursor there.');
      _p('\x1b[17;1HUp/Down/Tab jump field to field.');
    }
    _p('\x1b[22;1HF3 Back    F4 Exit    F5 Refresh');
    _place();
    _showStatus();
  }

  void _showStatus() {
    final style = _ok ? '\x1b[1m' : '\x1b[1;31m';
    final text = _status.length > 78 ? _status.substring(0, 78) : _status;
    _p('\x1b7\x1b[24;1H\x1b[2K$style$text\x1b[0m\x1b8');
  }

  /// Finds which F-key (and terminal type's table) these bytes belong to.
  (int, TermType)? _identify(String s) {
    final order = [_serverType, ...TermType.values.where((t) => t != _serverType)];
    for (final t in order) {
      for (var n = 1; n <= 12; n++) {
        if (s == String.fromCharCodes(KeyMap.defaults(TermKey.values[n - 1], t))) {
          return (n, t);
        }
      }
    }
    for (final st in FKeyStyle.values) {
      if (st == FKeyStyle.auto) continue;
      for (var n = 1; n <= 12; n++) {
        if (s == String.fromCharCodes(KeyMap.defaults(TermKey.values[n - 1], _serverType, style: st))) {
          return (n, _serverType);
        }
      }
    }
    return null;
  }

  @override
  void send(List<int> data) {
    final s = String.fromCharCodes(data);
    final id = _identify(s);
    if (id != null) {
      final (n, from) = id;
      if (from == _serverType || from == TermType.vt100) {
        _ok = true;
        _status = 'F$n  OK  (${hexBytes(data)} understood)';
        if (n == 3 && _screen != 0) {
          _openScreen(0);
          _render();
          return;
        }
        if (n == 5) {
          _status = 'F5  Refresh - screen redrawn';
          _render();
          return;
        }
        if (n == 4) {
          _p('[2J[H[12;1HF4 Exit - session ended by host.');
          finish();
          return;
        }
      } else {
        _ok = false;
        _status = 'F$n sent as ${termLabel(from)}: NOT RECOGNISED '
            '(host expects ${termLabel(_serverType)})';
      }
      _showStatus();
      return;
    }

    _ok = true;
    _status = 'RX: ${hexBytes(data)}';
    var i = 0;
    while (i < data.length) {
      final b = data[i];
      if (b == 0x1B) {
        if (i + 1 < data.length && (data[i + 1] == 0x5B || data[i + 1] == 0x4F)) {
          var j = i + 2;
          while (j < data.length && !(data[j] >= 0x40 && data[j] <= 0x7E)) {
            j++;
          }
          if (j < data.length) _arrow(data[j]);
          i = j + 1;
        } else {
          i++;
        }
        continue;
      }
      if (_key(b)) return; // screen was redrawn
      i++;
    }
    final c = _cur;
    if (c != null) _status = '$_status   focus: ${c.label}';
    _showStatus();
  }

  void _jump(int d) {
    if (_items.isEmpty) return;
    _it = (_it + d + _items.length) % _items.length; // wraps around, as on the real host
    _off = 0;
  }

  void _arrow(int f) {
    final c = _cur;
    if (c == null) return;
    switch (f) {
      case 0x41: // up: previous field / button
        _jump(-1);
        break;
      case 0x42: // down: next field / button
        _jump(1);
        break;
      case 0x5A: // shift+tab
        _jump(-1);
        break;
      case 0x43: // right
        if (c.isField && _off < c.w - 1) _off++;
        break;
      case 0x44: // left
        if (c.isField && _off > 0) _off--;
        break;
    }
    _place();
  }

  /// Handles one byte. Returns true when the screen was redrawn.
  bool _key(int b) {
    final c = _cur;
    if (c == null) return false;
    if (b == 9) {
      _jump(1);
      _place();
      return false;
    }
    if (b == 13) {
      if (_screen == 0 && c.label == 'Slct') {
        final n = int.tryParse(_vals[_it]!.join().trim());
        if (n != null && n >= 1 && n <= 4) {
          _openScreen(n);
          _render();
          return true;
        }
        _vals[_it] = List.filled(c.w, ' ');
        _off = 0;
        _p('\x1b[${c.row};${c.col}H\x1b[4m${_vals[_it]!.join()}\x1b[0m');
      } else if (c.isField || c.label.startsWith('F4')) {
        _jump(1);
      }
      _place();
      return false;
    }
    if (!c.isField) return false; // typing on a button does nothing
    final v = _vals[_it]!;
    if (b == 8 || b == 127) {
      if (_off > 0) _off--;
      v[_off] = ' ';
      _p('\x1b[${c.row};${c.col + _off}H\x1b[4m \x1b[0m');
    } else if (b >= 32 && b < 127) {
      final ch = String.fromCharCode(b);
      v[_off] = ch;
      _p('\x1b[${c.row};${c.col + _off}H\x1b[4m$ch\x1b[0m');
      if (_off < c.w - 1) _off++;
    }
    _place();
    return false;
  }

  @override
  void resize(int cols, int rows) {}

  @override
  Future<void> close() async => finish();
}

class _DemoItem {
  _DemoItem.field(this.row, this.col, this.w, this.label) : isField = true;
  _DemoItem.button(this.row, this.col, this.w, this.label) : isField = false;
  final int row, col, w;
  final String label;
  final bool isField;
}
