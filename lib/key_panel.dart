import 'dart:async';

import 'package:flutter/material.dart';

import 'keymap.dart';
import 'session.dart';

/// A touch key. Uses GestureDetector (not InkWell) so it never steals focus
/// from the hidden text field and therefore never closes the soft keyboard.
class KeyButton extends StatefulWidget {
  const KeyButton({
    super.key,
    required this.label,
    required this.onPress,
    this.repeat = false,
    this.active = false,
    this.minWidth = 44,
    this.minHeight = 40,
  });

  final String label;
  final VoidCallback onPress;
  final bool repeat; // press-and-hold auto repeat (arrows, backspace)
  final bool active;
  final double minWidth;
  final double minHeight;

  @override
  State<KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<KeyButton> {
  Timer? _delay;
  Timer? _periodic;
  bool _down = false;

  void _stop() {
    _delay?.cancel();
    _periodic?.cancel();
    if (_down) setState(() => _down = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.active
        ? const Color(0xFF1B5E20)
        : _down
            ? const Color(0xFF2E2E2E)
            : const Color(0xFF181818);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.repeat ? null : widget.onPress,
      onTapDown: (_) {
        setState(() => _down = true);
        if (widget.repeat) {
          widget.onPress();
          _delay = Timer(const Duration(milliseconds: 400), () {
            _periodic = Timer.periodic(const Duration(milliseconds: 70), (_) => widget.onPress());
          });
        }
      },
      onTapUp: (_) => _stop(),
      onTapCancel: _stop,
      child: Container(
        constraints: BoxConstraints(minWidth: widget.minWidth, minHeight: widget.minHeight),
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: widget.active ? const Color(0xFF66FF66) : const Color(0xFF3A3A3A)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          widget.label,
          style: const TextStyle(color: Color(0xFFDDDDDD), fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class KeyPanel extends StatelessWidget {
  const KeyPanel({super.key, required this.session, required this.onToggleKeyboard, required this.keyboardOn});

  final TerminalSession session;
  final VoidCallback onToggleKeyboard;
  final bool keyboardOn;

  // Slimmer keys while the soft keyboard is up, so the terminal keeps its height.
  double get _kh => keyboardOn ? 30 : 40;

  KeyButton _k(TermKey k, {bool repeat = false, double minWidth = 44}) => KeyButton(
        label: k.label,
        repeat: repeat,
        minWidth: minWidth,
        minHeight: _kh,
        onPress: () => session.sendKey(k),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0B0B0B),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _kh + 6,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < 12; i++) _k(TermKey.values[i], minWidth: 46),
                _k(TermKey.home),
                _k(TermKey.end),
                _k(TermKey.pageUp),
                _k(TermKey.pageDown),
                _k(TermKey.insert),
                _k(TermKey.delete),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(child: _wrap(_k(TermKey.esc))),
              Expanded(child: _wrap(_k(TermKey.tab))),
              Expanded(
                child: _wrap(KeyButton(
                  label: 'Ctrl',
                  minHeight: _kh,
                  active: session.ctrlArmed,
                  onPress: session.toggleCtrl,
                )),
              ),
              Expanded(child: _wrap(_k(TermKey.left, repeat: true))),
              Expanded(child: _wrap(_k(TermKey.up, repeat: true))),
              Expanded(child: _wrap(_k(TermKey.down, repeat: true))),
              Expanded(child: _wrap(_k(TermKey.right, repeat: true))),
              Expanded(child: _wrap(_k(TermKey.backspace, repeat: true))),
              Expanded(child: _wrap(_k(TermKey.enter))),
              Expanded(
                child: _wrap(KeyButton(
                  label: '⌨',
                  minHeight: _kh,
                  active: keyboardOn,
                  onPress: onToggleKeyboard,
                )),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _wrap(Widget w) => SizedBox(height: _kh + 4, child: FittedBox(fit: BoxFit.scaleDown, child: w));
}
