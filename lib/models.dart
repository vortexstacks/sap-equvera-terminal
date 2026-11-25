import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum Protocol { telnet, ssh, tcp, demo }

enum TermType { vt100, vt220, ansi }

enum TermTheme { green, white, amber }

enum TouchMode { smart, cursorOnly, off }

/// How many columns are fitted across the screen width. Fewer columns = bigger text.
enum TextSize { normal, large, huge }

int textSizeCols(TextSize t) => switch (t) {
      TextSize.normal => 80,
      TextSize.large => 40,
      TextSize.huge => 30,
    };

String textSizeLabel(TextSize t) => switch (t) {
      TextSize.normal => 'Normal (80 columns)',
      TextSize.large => 'Large (40 columns)',
      TextSize.huge => 'Extra large (30 columns)',
    };

String protocolLabel(Protocol p) => switch (p) {
      Protocol.telnet => 'Telnet',
      Protocol.ssh => 'SSH',
      Protocol.tcp => 'TCP Socket',
      Protocol.demo => 'Demo (offline mock SAP)',
    };

String termLabel(TermType t) => switch (t) {
      TermType.vt100 => 'VT100',
      TermType.vt220 => 'VT220',
      TermType.ansi => 'ANSI',
    };

String themeLabel(TermTheme t) => switch (t) {
      TermTheme.green => 'Green on black',
      TermTheme.white => 'White on black',
      TermTheme.amber => 'Amber on black',
    };

String touchLabel(TouchMode t) => switch (t) {
      TouchMode.smart => 'Smart (labels, menus, cursor)',
      TouchMode.cursorOnly => 'Cursor move only',
      TouchMode.off => 'Off',
    };

int defaultPort(Protocol p) => p == Protocol.ssh ? 22 : 23;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

class ConnectionConfig {
  ConnectionConfig({
    this.name = '',
    this.host = '',
    this.port = 23,
    this.protocol = Protocol.telnet,
    this.termType = TermType.vt220,
    this.username = '',
    this.password = '',
    this.cols = 80,
    this.rows = 24,
    this.utf8 = false,
    this.backspaceDel = false,
    this.theme = TermTheme.green,
    this.touchMode = TouchMode.smart,
  });

  String name;
  String host;
  int port;
  Protocol protocol;
  TermType termType;
  String username;
  String password; // never persisted
  int cols;
  int rows;
  bool utf8; // false = Latin-1 / 8-bit
  bool backspaceDel; // true = Backspace sends 0x7F, false = 0x08
  TermTheme theme;
  TouchMode touchMode;

  String get title => name.isNotEmpty ? name : '$host:$port';

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'protocol': protocol.name,
        'termType': termType.name,
        'username': username,
        'cols': cols,
        'rows': rows,
        'utf8': utf8,
        'backspaceDel': backspaceDel,
        'theme': theme.name,
        'touchMode': touchMode.name,
      };

  factory ConnectionConfig.fromJson(Map<String, dynamic> j) => ConnectionConfig(
        name: (j['name'] ?? '') as String,
        host: (j['host'] ?? '') as String,
        port: (j['port'] ?? 23) as int,
        protocol: _enumByName(Protocol.values, j['protocol'], Protocol.telnet),
        termType: _enumByName(TermType.values, j['termType'], TermType.vt220),
        username: (j['username'] ?? '') as String,
        cols: (j['cols'] ?? 80) as int,
        rows: (j['rows'] ?? 24) as int,
        utf8: (j['utf8'] ?? false) as bool,
        backspaceDel: (j['backspaceDel'] ?? false) as bool,
        theme: _enumByName(TermTheme.values, j['theme'], TermTheme.green),
        touchMode: _enumByName(TouchMode.values, j['touchMode'], TouchMode.smart),
      );
}

/// Saved connection profiles (passwords are NOT stored).
class ProfileStore {
  static const _key = 'profiles_v1';

  static Future<List<ConnectionConfig>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_key) ?? const [];
      return list
          .map((s) => ConnectionConfig.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<ConnectionConfig> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, profiles.map((p) => jsonEncode(p.toJson())).toList());
  }
}
