# Sostenuto

Named after the piano's sostenuto pedal, which acts only on the keys held while it is down.

Makes **CapsLock** and the **Copilot key** usable as ordinary modifiers in every
script and program on the machine.

## Why

Windows has exactly eight modifier keys — left and right Shift, Ctrl, Alt and
Win — and no way to add a ninth. AutoHotkey's prefix characters (`# ! ^ + < >
* ~ $`) are hardcoded in its parser, so no script can teach other scripts a new
one: `¤a::` or `§a::` cannot be made to work, however the script is written.

What *can* be done is to express the key as one of the eight. Then every script
understands it with ordinary syntax, with no shared library and no cooperation
between scripts.

| Key | Becomes | Written as |
| --- | --- | --- |
| CapsLock | right Ctrl (configurable in `Sostenuto.ini`) | `>^x` |
| Copilot | a leader key: tap it, then press the next key within 2 s | `[Copilot]` entries in the ini, or the Copilot layer in `layers\app-shortcuts.ahk` |
| AltGr | already a modifier, so it only gets remaps: an `[AltGr]` section in the ini, a left-hand number pad by default (q w e / a s d / < z x are 1–9, f is 0, Shift+key gives F-keys and brackets) | `<^>!x` |
| any other modifier | an ini section named after the key — `[LShift]`, `[RShift]`, `[LWin]` — read exactly like `[AltGr]`: its entries fire while that key is physically held | its own prefix (`+x`, `>+x`, `<#x`…) |

Note `>^` and not `^`: the angle bracket picks right Ctrl specifically, so the
left Ctrl key keeps working normally and the focused program's own Ctrl
shortcuts do not collide.

## Layers for other keys

Anything that was `LShift & -::Send "?"` in a script is one ini line now:

```ini
[LShift]
-=?

[RShift]
-=_

[AltGr]
e=3
+e==
p=(){Left}
```

The left side is the key with optional modifiers in AutoHotkey syntax (`+e`
is Shift+e), the right side is what to send, or `run:` / `call:` as in the
other layers. `call:` may pass literal strings, `call:LaunchObsidianVault(M)`
or `call:LaunchObsidianCapture(M)`, so one function serves several keys.
A section named after a key AutoHotkey does not know is
reported in a tray tip and skipped. The GUI's Keys tab shows every layer and
has an *Add layer* control for the rest of the eight modifiers. Meant for
modifiers only: a plain key would still type itself.

### AltGr is not Ctrl+Alt

Every layer reads its key *physically*. AltGr is the right Alt key, and the
Ctrl that Windows presses along with it is logical only — so `[AltGr]` never
sees left Ctrl + left Alt, and a `[LAlt]` or `[LCtrl]` layer never sees AltGr.
Ctrl+Alt+L and AltGr+L are therefore two different things:

```ini
[AltGr]
l=…            ; AltGr + L

[LAlt]
^l=…           ; left Ctrl + left Alt + L
```

A modifier prefix inside an entry (`^l`) is read physically too. If no entry
fits the modifiers actually held — `[LAlt]` has only `^l` and plain Alt+L is
pressed — the key is passed through as pressed, not swallowed.

The one place the two still meet is a hotkey in a *script* written `^!l`:
AutoHotkey matches that on AltGr as well, since AltGr is Ctrl+Alt to it.
Write `<^<!l` to keep such a hotkey to the left-hand keys.

## What it handles

- **The modifier survives a `Send`.** AutoHotkey releases held modifiers before
  sending, so a script that reacts to `>#x` and then sends a keystroke drops
  the modifier — it is synthetic, so nothing puts it back, and it survives
  exactly one hotkey. A 25 ms timer re-asserts it while the physical key is
  held. Without this, remapping "works on the first press only", which is also
  why PowerToys Keyboard Manager is not enough here.
- **No Start menu.** Windows opens Start when a Win key is pressed and released
  with nothing in between — which a tapped CapsLock is. Each press is followed
  by one keystroke on the unassigned `vkE8`, enough for the shell to treat the
  press as used. The same goes for Ctrl and Alt: a lone Ctrl tap opens Office's
  Paste Options menu after a paste, and CapsLock+j is exactly that to Office,
  since the j is swallowed.
- **No Copilot app, and a usable Copilot key.** Windows watches for
  `Shift+Win+F23`; swallowing F23 stops that. The key itself cannot be held:
  its whole chord, downs and ups, arrives within one millisecond however long
  it is pressed (measured with a raw hook logger). So it is a *leader* key: a
  tap arms the layer for two seconds (`CopilotWindow` in the ini) and shows
  "Copilot + ?" in the screen corner. A key with a `[Copilot]` entry runs it
  and, if it sends keys, keeps the layer armed for the next press - so
  Copilot, Down, Down, Down lowers the volume three times and holding Down
  keeps lowering it, as if Copilot were held. Launchers close the layer, and
  so does any unbound key, which is typed as usual.
- **No stuck modifier.** If a key-up is ever swallowed — another hook, a locked
  session, a dropped RDP connection — the layer modifier stays down and every
  keystroke becomes a chord. A watchdog releases it, and the tray menu has a
  manual escape.

## Site-specific files

Three files are yours alone and are not tracked by git:

| File | Holds | Template |
| --- | --- | --- |
| `Sostenuto.ini` | the settings and every layer's entries; written with defaults on first start | — |
| `core\functions.local.ahk` | `call:` targets for one workplace's programs, addresses and paths | `functions.local.ahk.example` |
| `layers\local.ahk` | hotkeys and hotstrings for the same | `local.ahk.example` |

The two `.ahk` files are included if they exist, after their generic
counterparts, so `Launch`, `NewestApp`, `runApp`, `RunAhk`, `WinHeld()` and
`class Cfg` are available in them. The GUI's Insert… menu lists the functions
of both `functions.ahk` and `functions.local.ahk`, and the Layers tab shows
`local.ahk` like any other layer file.

## Requirements

AutoHotkey v2. Nothing else — no administrator rights, no driver, no reboot.
The registry's `Scancode Map` would do the CapsLock half without any running
program, but it lives in HKLM and needs administrator rights.

## Conflicts

Only one program may own a key. If another script also binds CapsLock (for
example `*CapsLock::SetCapsLockState "AlwaysOff"`), or PowerToys Keyboard
Manager remaps it, they race: whichever hook comes first in the chain wins and
the other silently does nothing.
Software KVMs are a subtler case. One that hooks the keyboard *after* Sostenuto
sits ahead of it in the hook chain and forwards CapsLock+j to the other computer
raw, before the layer has remapped it - and a remapper on the far side cannot
see the physical CapsLock behind an injected key, so the combo does nothing
there. Sostenuto re-installs its hook a few seconds after startup to get back
in front; if the KVM starts later, restart Sostenuto (or use its tray Reload).
Word navigation over such a link wants **CapsAltIsCtrl** (Modifiers tab): with
it on, CapsLock+Alt+j sends one clean Ctrl+Left, which survives a lossy link,
rather than lifting Alt and injecting Ctrl around the arrow, which does not.
