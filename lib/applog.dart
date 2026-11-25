/// Build label shown at the top of every exported log.
const String kBuildTag = 'v8.1 (2026-11-25)';

/// In-app activity log. Kept in memory (last ~3000 events) and exported with
/// menu > "Send log to support", which copies a ready-to-paste report.
///
/// Privacy: typed text is never recorded (only "text N bytes"), passwords are
/// never recorded. The export does include the current screen text, because that
/// is usually what is needed to understand a problem.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _maxLines = 3000;
  static const int _maxRx = 800;

  final List<String> _lines = [];
  final List<int> _rx = [];
  final Map<String, int> unhandled = {};

  int get length => _lines.length;

  static String _two(int n) => n.toString().padLeft(2, '0');

  void add(String tag, String msg) {
    final t = DateTime.now();
    _lines.add('${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} ${tag.padRight(5)} $msg');
    if (_lines.length > _maxLines) _lines.removeRange(0, 500);
  }

  /// Raw bytes from the host (only the most recent ones are kept).
  void rx(List<int> data) {
    _rx.addAll(data);
    if (_rx.length > _maxRx) _rx.removeRange(0, _rx.length - _maxRx);
  }

  /// An escape sequence the emulator does not implement.
  void sequence(String s) {
    unhandled[s] = (unhandled[s] ?? 0) + 1;
  }

  void clear() {
    _lines.clear();
    _rx.clear();
    unhandled.clear();
  }

  String export({required String header, required String screen}) {
    final b = StringBuffer()
      ..writeln('=== SAP Terminal log ===')
      ..writeln(header)
      ..writeln()
      ..writeln('--- events (oldest first) ---');
    final start = _lines.length > 1500 ? _lines.length - 1500 : 0;
    for (var i = start; i < _lines.length; i++) {
      b.writeln(_lines[i]);
    }
    b
      ..writeln()
      ..writeln('--- escape sequences the app did not understand ---');
    if (unhandled.isEmpty) {
      b.writeln('(none)');
    } else {
      unhandled.forEach((k, v) => b.writeln('$k  x$v'));
    }
    b
      ..writeln()
      ..writeln('--- last bytes received from the host (hex) ---')
      ..writeln(_rx.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' '))
      ..writeln()
      ..writeln('--- current screen ---')
      ..write(screen);
    return b.toString();
  }
}
