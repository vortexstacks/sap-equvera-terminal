import 'package:flutter/material.dart';

import 'models.dart';
import 'terminal_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '23');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _cols = TextEditingController(text: '80');
  final _rows = TextEditingController(text: '24');

  Protocol _protocol = Protocol.telnet;
  TermType _term = TermType.vt220;
  TermTheme _theme = TermTheme.green;
  TouchMode _touch = TouchMode.smart;
  bool _utf8 = false;
  bool _bsDel = false;
  List<ConnectionConfig> _profiles = [];

  @override
  void initState() {
    super.initState();
    ProfileStore.load().then((p) {
      if (mounted) setState(() => _profiles = p);
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _pass, _cols, _rows]) {
      c.dispose();
    }
    super.dispose();
  }

  ConnectionConfig _read() => ConnectionConfig(
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? defaultPort(_protocol),
        protocol: _protocol,
        termType: _term,
        username: _user.text.trim(),
        password: _pass.text,
        cols: (int.tryParse(_cols.text) ?? 80).clamp(20, 200).toInt(),
        rows: (int.tryParse(_rows.text) ?? 24).clamp(10, 100).toInt(),
        utf8: _utf8,
        backspaceDel: _bsDel,
        theme: _theme,
        touchMode: _touch,
      );

  void _load(ConnectionConfig c) {
    setState(() {
      _name.text = c.name;
      _host.text = c.host;
      _port.text = '${c.port}';
      _user.text = c.username;
      _pass.clear();
      _cols.text = '${c.cols}';
      _rows.text = '${c.rows}';
      _protocol = c.protocol;
      _term = c.termType;
      _theme = c.theme;
      _touch = c.touchMode;
      _utf8 = c.utf8;
      _bsDel = c.backspaceDel;
    });
  }

  Future<void> _saveProfile() async {
    if (!_form.currentState!.validate()) return;
    final c = _read();
    if (c.name.isEmpty) c.name = c.host.isEmpty ? protocolLabel(c.protocol) : c.host;
    final list = [..._profiles.where((p) => p.name != c.name), c];
    await ProfileStore.save(list);
    setState(() => _profiles = list);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved "${c.name}"')));
    }
  }

  Future<void> _delete(ConnectionConfig c) async {
    final list = _profiles.where((p) => p != c).toList();
    await ProfileStore.save(list);
    setState(() => _profiles = list);
  }

  void _connect() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TerminalScreen(config: _read())));
  }

  String? _req(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  Widget _dropdown<T>(String label, T value, List<T> items, String Function(T) text, ValueChanged<T> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(text(i)))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final needsHost = _protocol != Protocol.demo;
    return Scaffold(
      appBar: AppBar(title: const Text('SAP Terminal')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_profiles.isNotEmpty) ...[
                const Text('Saved connections', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final p in _profiles)
                  Card(
                    child: ListTile(
                      dense: true,
                      title: Text(p.name),
                      subtitle: Text(
                        '${protocolLabel(p.protocol)} · ${p.host}:${p.port} · ${termLabel(p.termType)}',
                      ),
                      onTap: () => _load(p),
                      trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(p)),
                    ),
                  ),
                const Divider(height: 24),
              ],
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name (optional)', border: OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 12),
              _dropdown<Protocol>('Protocol', _protocol, Protocol.values, protocolLabel, (v) {
                setState(() {
                  _protocol = v;
                  _port.text = '${defaultPort(v)}';
                });
              }),
              const SizedBox(height: 12),
              if (needsHost)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _host,
                        validator: _req,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(labelText: 'Host / IP', border: OutlineInputBorder(), isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return (n == null || n < 1 || n > 65535) ? 'Invalid' : null;
                        },
                        decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder(), isDense: true),
                      ),
                    ),
                  ],
                ),
              if (_protocol == Protocol.ssh) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _user,
                  validator: _req,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Username', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (not saved)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _dropdown<TermType>('Terminal type', _term, TermType.values, termLabel, (v) => setState(() => _term = v)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _cols,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Columns', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: _rows,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Rows', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              _dropdown<TermTheme>('Colours', _theme, TermTheme.values, themeLabel, (v) => setState(() => _theme = v)),
              const SizedBox(height: 12),
              _dropdown<TouchMode>('Touch', _touch, TouchMode.values, touchLabel, (v) => setState(() => _touch = v)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('UTF-8 text'),
                subtitle: const Text('Off = 8-bit Latin-1 (typical for legacy hosts)'),
                value: _utf8,
                onChanged: (v) => setState(() => _utf8 = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Backspace sends DEL (0x7F)'),
                subtitle: const Text('Off = sends BS (0x08)'),
                value: _bsDel,
                onChanged: (v) => setState(() => _bsDel = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saveProfile,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Connect'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
