# SAP Terminal (Flutter)

Android terminal emulator for SAP RF/terminal sessions. Rebuild of the existing
Emergent app with the same flow (connection screen -> terminal screen) and two fixes:

1. **F1-F12 work** - every key sends a code that depends on the terminal type
   (VT100 / VT220 / ANSI), every code is shown in the status bar after a press, and
   every code can be edited in the app (menu > F-key codes) to match the server.
2. **Touch works inside the terminal** - tap an `F3`-style label to send that F-key,
   tap a numbered menu line (`[2.Process Orders >]`) to send `2` + Enter, tap anywhere
   else to move the cursor there (sent as arrow keys).

> Status: written without access to a Flutter SDK, so it has **never been compiled or
> run**. Expect a small round of fixes on the first build.

## Set up

Needs Flutter 3.16+ (Dart 3).

```bash
cd sap_terminal
flutter create --platforms=android --project-name sap_terminal .
flutter pub get
```

`flutter create .` keeps the existing `lib/` and `pubspec.yaml` and adds the `android/`
folder. Delete the generated `test/widget_test.dart` (it refers to a default app).

**Add internet permission** - open `android/app/src/main/AndroidManifest.xml` and put this
line inside `<manifest>`, above `<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

(Release builds have no network without it. Plain Telnet is cleartext TCP, which is not
affected by Android's HTTP cleartext rule.)

## Run / build

```bash
flutter test                 # emulator + key-code unit tests
flutter run                  # on a connected phone
flutter build apk --release  # build/app/outputs/flutter-apk/app-release.apk
```

## Try it without a server (demo for the client)

On the connection screen choose **Protocol: Demo (offline mock SAP)**. The demo host
behaves like a server set up for **VT220** function keys, and it prints what it received on
the bottom line.

**1. Show the "F-keys don't work" problem and the fix**

1. Set **Terminal type: ANSI**, connect, press F1-F12. The bottom line turns red:
   `F1 sent as ANSI: NOT RECOGNISED (host expects VT220)`.
2. Go back, set **VT220**, connect, press the same keys. It now says
   `F1  OK (1B 5B 31 31 7E understood)`. F3 on a sub-screen returns to the menu.
3. **VT100** is the middle case: F1-F4 are rejected, F5-F12 are accepted.
4. Real-world fix: menu (three dots) > **F-key codes**, edit a code, press the key again.

**2. Show the terminal bug (`[17;1H` printed as text) and the fix**

1. Tap menu line **4. Terminal Test**. The text appears on row 17: the cursor command is obeyed.
2. Menu > **Escape codes ON - turn OFF to show old bug**, then open Terminal Test again.
   Raw text such as `[2J` and `[17;1H` appears, as in the old app. Turn it back ON to show the fix.

**3. Show touch**

Tap an `F3` or `[F4 Nxt]` label to send that key. Tap a numbered line such as
`[2.Process Orders >]`: the app moves the cursor to the `Slct` field if needed, types the number
and presses Enter. Tap a field (menu 1-3): the cursor goes there, and you can type.

The demo host behaves like SAP RF screens: Up/Down/Tab **jump** from field to field (they do not
move one cell). The app therefore steps one key at a time and checks where the cursor landed, until
it reaches the field you touched. Inside a field, a tap moves the cursor within that field only.
A tap on the blank row between two menu items snaps to the nearer item, because one terminal row is
very small under a finger.
On a plain line-prompt server (telehack.com) there are no fields, so the cursor cannot go back to
an earlier line.

**4. Show the larger text**

Menu > **Text size** cycles Normal (80 columns across the screen), Large (40, the default) and Extra
large (30). Large and Extra large make each character about 2x and 2.7x bigger. SAP RF screens only use
the left part of the grid, so they fit; a wider screen (the 80-column login banner) can be dragged
sideways, and the view follows the cursor while you type. The choice is remembered.

**Support:** menu > **Send log to support (copies it)** copies a report (app version, settings, every key and
tap with its bytes, the host's negotiation, escape sequences the app did not understand, and the current
screen). Typed text and passwords are never recorded. Paste it into WhatsApp or email.
Menu > **Copy screen text** copies only the screen text and highlight marks.

## Features

| Area | Detail |
| --- | --- |
| Protocols | Telnet (full option negotiation: TTYPE, NAWS, SGA, ECHO, BINARY), SSH (password, PTY via `dartssh2`), raw TCP socket |
| Terminal types | VT100, VT220, ANSI (SCO) - sent as the terminal type to the server too |
| Emulation | cursor addressing, erase, scroll regions, insert/delete, SGR colours (16/256/RGB), line-drawing charset, DSR/DA replies. Escape codes are interpreted, never printed |
| Keys | F1-F12, arrows, Enter, Tab, Esc, Backspace, Home/End/PgUp/PgDn/Ins/Del, Ctrl toggle, hardware keyboard, soft keyboard (toggle with the keyboard button) |
| Touch | smart (labels, menus, cursor), cursor-only, or off |
| Screen | fixed grid (default 80x24), font auto-scaled to fit, green / white / amber on black |
| Profiles | save and reload connections (passwords are never stored) |

## Verifying against Georgia SoftWorks

Key codes are the usual ones for each terminal type. They are **not yet checked against the
client's Georgia SoftWorks server**. To check:

1. Connect, press F1...F12 and read the hex in the status bar.
2. If a key does nothing on the server, change its code under menu > F-key codes
   (stored per terminal type), or fix the defaults in `lib/keymap.dart`.
3. Typical suspects: ANSI vs VT220 terminal type, and Backspace (0x08 vs 0x7F, a switch on
   the connection screen).

## Layout

```
lib/main.dart            app entry, theme
lib/connect_screen.dart  connection form + saved profiles
lib/terminal_screen.dart terminal page, soft/hardware keyboard, menu
lib/terminal_view.dart   grid renderer and tap handling
lib/key_panel.dart       on-screen F-keys, arrows, Esc/Tab/Ctrl/Enter
lib/fkey_dialog.dart     F-key code editor
lib/session.dart         connects transport + emulator, sends keys, touch logic
lib/transport.dart       Telnet / SSH / TCP / Demo
lib/emulator.dart        VT100/VT220/ANSI screen emulator
lib/keymap.dart          key codes per terminal type + overrides
lib/models.dart          config, enums, saved profiles
test/core_test.dart      key-code and emulator tests
```

## Known limits

- Field-aware touch is checked on the demo host only; it still needs a test on the Georgia SoftWorks server.
- If the host uses Tab (not arrows) between fields, the app tries Tab when an arrow does nothing.
- No scrollback and no alternate screen; the grid is fixed to the configured size.
- SSH supports password login only (no keys yet).
- Touch cursor move sends arrow keys, so it only works where the host accepts them.
- If `dartssh2` changes its API, adjust `SshTransport` in `lib/transport.dart`.
