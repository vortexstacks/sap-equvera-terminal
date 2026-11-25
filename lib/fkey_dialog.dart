import 'package:flutter/material.dart';

import 'keymap.dart';
import 'models.dart';

/// Lets the user see and change the bytes each F-key sends, per terminal type.
/// Notation: \e = ESC, \r = CR, \xNN = hex byte. Example F3 = \e[13~
class FKeyDialog extends StatefulWidget {
  const FKeyDialog({super.key, required this.type});
  final TermType type;

  @override
  State<FKeyDialog> createState() => _FKeyDialogState();
}

class _FKeyDialogState extends State<FKeyDialog> {
  final Map<TermKey, TextEditingController> _ctl = {};
  Map<String, String> _overrides = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _overrides = await KeyOverrideStore.load(widget.type);
    for (var i = 0; i < 12; i++) {
      final k = TermKey.values[i];
      final text = _overrides[k.name] ?? KeyMap.formatEscapes(KeyMap.defaults(k, widget.type));
      _ctl[k] = TextEditingController(text: text);
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final m = <String, String>{};
    for (var i = 0; i < 12; i++) {
      final k = TermKey.values[i];
      final text = _ctl[k]!.text.trim();
      final def = KeyMap.formatEscapes(KeyMap.defaults(k, widget.type));
      if (text.isNotEmpty && text != def) m[k.name] = text;
    }
    await KeyOverrideStore.save(widget.type, m);
    if (mounted) Navigator.pop(context, true);
  }

  void _reset() {
    for (var i = 0; i < 12; i++) {
      final k = TermKey.values[i];
      _ctl[k]!.text = KeyMap.formatEscapes(KeyMap.defaults(k, widget.type));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('F-key codes (${termLabel(widget.type)})'),
      content: SizedBox(
        width: double.maxFinite,
        child: !_loaded
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      r'Notation: \e = ESC, \r = Enter, \xNN = hex byte. '
                      'Change a code if your server (e.g. Georgia SoftWorks) expects another one.',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                  for (var i = 0; i < 12; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        SizedBox(width: 36, child: Text('F${i + 1}')),
                        Expanded(
                          child: TextField(
                            controller: _ctl[TermKey.values[i]],
                            autocorrect: false,
                            enableSuggestions: false,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: _loaded ? _reset : null, child: const Text('Defaults')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _loaded ? _save : null, child: const Text('Save')),
      ],
    );
  }
}
