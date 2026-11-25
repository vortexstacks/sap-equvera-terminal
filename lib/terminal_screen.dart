import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fkey_dialog.dart';
import 'key_panel.dart';
import 'keymap.dart';
import 'models.dart';
import 'session.dart';
import 'terminal_view.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.config});
  final ConnectionConfig config;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _sentinel = '  ';

  late final TerminalSession session;
  final FocusNode focus = FocusNode();
  final TextEditingController ctl = TextEditingController(text: _sentinel);
  bool keyboardOn = false;

  static final Map<LogicalKeyboardKey, TermKey> _hw = {
    LogicalKeyboardKey.arrowUp: TermKey.up,
    LogicalKeyboardKey.arrowDown: TermKey.down,
    LogicalKeyboardKey.arrowLeft: TermKey.left,
    LogicalKeyboardKey.arrowRight: TermKey.right,
    LogicalKeyboardKey.enter: TermKey.enter,
    LogicalKeyboardKey.numpadEnter: TermKey.enter,
    LogicalKeyboardKey.tab: TermKey.tab,
    LogicalKeyboardKey.escape: TermKey.esc,
    LogicalKeyboardKey.backspace: TermKey.backspace,
    LogicalKeyboardKey.delete: TermKey.delete,
    LogicalKeyboardKey.home: TermKey.home,
    LogicalKeyboardKey.end: TermKey.end,
    LogicalKeyboardKey.pageUp: TermKey.pageUp,
    LogicalKeyboardKey.pageDown: TermKey.pageDown,
    LogicalKeyboardKey.insert: TermKey.insert,
    LogicalKeyboardKey.f1: TermKey.f1,
    LogicalKeyboardKey.f2: TermKey.f2,
    LogicalKeyboardKey.f3: TermKey.f3,
    LogicalKeyboardKey.f4: TermKey.f4,
    LogicalKeyboardKey.f5: TermKey.f5,
    LogicalKeyboardKey.f6: TermKey.f6,
    LogicalKeyboardKey.f7: TermKey.f7,
    LogicalKeyboardKey.f8: TermKey.f8,
    LogicalKeyboardKey.f9: TermKey.f9,
    LogicalKeyboardKey.f10: TermKey.f10,
    LogicalKeyboardKey.f11: TermKey.f11,
    LogicalKeyboardKey.f12: TermKey.f12,
  };

  @override
  void initState() {
    super.initState();
    session = TerminalSession(widget.config);
    focus.onKeyEvent = _onKey;
    session.connect();
  }

  @override
  void dispose() {
    session.dispose();
    focus.dispose();
    ctl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ input

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final tk = _hw[e.logicalKey];
    if (tk != null) {
      session.sendKey(tk);
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed && e.character != null && e.character!.isNotEmpty) {
      final c = e.character!.toUpperCase().codeUnitAt(0);
      if (c >= 0x40 && c <= 0x5F) {
        session.sendBytes([c & 0x1F], label: 'Ctrl+${String.fromCharCode(c)}');
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _resetField() {
    ctl.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  void _onChanged(String v) {
    if (v.length < _sentinel.length) {
      session.sendKey(TermKey.backspace);
    } else if (v.length > _sentinel.length) {
      session.sendText(v.substring(_sentinel.length));
    }
    _resetField();
  }

  void _onSubmitted(String _) {
    session.sendKey(TermKey.enter);
    _resetField();
    focus.requestFocus();
  }

  void _toggleKeyboard() {
    setState(() => keyboardOn = !keyboardOn);
    if (keyboardOn) {
      focus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      focus.unfocus();
    }
  }

  // ------------------------------------------------------------- menu

  Future<void> _menu(String v) async {
    switch (v) {
      case 'keys':
        final saved = await showDialog<bool>(
          context: context,
          builder: (_) => FKeyDialog(type: widget.config.termType),
        );
        if (saved == true) await session.reloadOverrides();
        break;
      case 'fstyle':
        final picked = await showDialog<FKeyStyle>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('F-key codes sent to the host'),
            children: [
              for (final st in FKeyStyle.values)
                RadioListTile<FKeyStyle>(
                  dense: true,
                  value: st,
                  groupValue: session.fkeyStyle,
                  title: Text(fkeyStyleLabel(st), style: const TextStyle(fontSize: 13)),
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text(
                  'If F2 / F3 type characters into a field instead of working, pick another set and press F2 again.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ],
          ),
        );
        if (picked != null) await session.setFKeyStyle(picked);
        break;
      case 'bytes':
        session.toggleShowBytes();
        break;
      case 'touch':
        session.cycleTouchMode();
        break;
      case 'reconnect':
        await session.reconnect();
        break;
      case 'raw':
        session.toggleRawEscapes();
        break;
      case 'size':
        await session.cycleTextSize();
        break;
      case 'log':
        await Clipboard.setData(ClipboardData(text: session.exportLog()));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Log copied. Paste it into WhatsApp or email and send it to support.')),
          );
        }
        break;
      case 'dump':
        await Clipboard.setData(ClipboardData(text: session.emu.dumpScreen()));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Screen text copied. Paste it in a message to support.')),
          );
        }
        break;
      case 'disconnect':
        await session.disconnect();
        break;
    }
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            return Column(
              children: [
                _statusBar(context),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: TerminalView(
                          session: session,
                          onTap: () {
                            if (keyboardOn && !focus.hasFocus) focus.requestFocus();
                          },
                        ),
                      ),
                      // Hidden field that receives soft-keyboard text.
                      Positioned(
                        left: 0,
                        top: 0,
                        width: 1,
                        height: 1,
                        child: Opacity(
                          opacity: 0,
                          child: TextField(
                            controller: ctl,
                            focusNode: focus,
                            maxLines: 1,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.visiblePassword,
                            textInputAction: TextInputAction.send,
                            onChanged: _onChanged,
                            onSubmitted: _onSubmitted,
                            decoration: const InputDecoration(border: InputBorder.none),
                          ),
                        ),
                      ),
                      if (session.state == SessionState.connecting)
                        const Center(child: CircularProgressIndicator()),
                      if (session.state == SessionState.error || session.state == SessionState.closed)
                        _overlay(context),
                    ],
                  ),
                ),
                KeyPanel(session: session, keyboardOn: keyboardOn, onToggleKeyboard: _toggleKeyboard),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _statusBar(BuildContext context) {
    final c = widget.config;
    final (color, text) = switch (session.state) {
      SessionState.connected => (const Color(0xFF66FF66), 'connected'),
      SessionState.connecting => (Colors.amber, 'connecting…'),
      SessionState.error => (Colors.redAccent, 'error'),
      SessionState.closed => (Colors.grey, 'disconnected'),
      SessionState.idle => (Colors.grey, 'idle'),
    };
    return Container(
      color: const Color(0xFF101010),
      padding: const EdgeInsets.only(left: 4),
      height: 40,
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              session.showBytes && session.lastSent.isNotEmpty
                  ? session.lastSent
                  : '${c.title} · ${termLabel(c.termType)} · $text',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'monospace'),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: _menu,
            itemBuilder: (_) => [
              PopupMenuItem(value: 'fstyle', child: Text('F-key code set: ${session.fkeyStyle.name}')),
              const PopupMenuItem(value: 'keys', child: Text('F-key codes (edit)…')),
              PopupMenuItem(
                value: 'bytes',
                child: Text(session.showBytes ? 'Hide sent bytes' : 'Show sent bytes'),
              ),
              PopupMenuItem(value: 'touch', child: Text('Touch: ${touchLabel(session.touchMode)}')),
              PopupMenuItem(value: 'size', child: Text('Text size: ${textSizeLabel(session.textSize)}')),
              const PopupMenuItem(value: 'log', child: Text('Send log to support (copies it)')),
              const PopupMenuItem(value: 'dump', child: Text('Copy screen text (for support)')),
              PopupMenuItem(
                value: 'raw',
                child: Text(session.emu.rawMode
                    ? 'Escape codes OFF (old bug) - turn ON'
                    : 'Escape codes ON - turn OFF to show old bug'),
              ),
              const PopupMenuItem(value: 'reconnect', child: Text('Reconnect')),
              const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final isError = session.state == SessionState.error;
    return Container(
      color: Colors.black.withOpacity(0.75),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isError ? 'Connection failed' : 'Connection closed',
            style: const TextStyle(fontSize: 18, color: Colors.white),
          ),
          if (isError && session.error != null) ...[
            const SizedBox(height: 8),
            Text(session.error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, children: [
            FilledButton(onPressed: session.reconnect, child: const Text('Reconnect')),
            OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back')),
          ]),
        ],
      ),
    );
  }
}
