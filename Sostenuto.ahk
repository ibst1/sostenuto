#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; =============================================================================
;  Sostenuto - turns CapsLock and the Copilot key into ordinary modifiers
;  that every script and program on the machine understands.
;
;  Windows has exactly eight modifier keys and no way to add a ninth, and
;  AutoHotkey's prefix characters (#!^+<>*~$) are hardcoded in its parser - so
;  inventing a new one is impossible, and no script can teach another script
;  new syntax. What works is to express the key AS one of the eight.
;
;  Two layers, each with the same two settings:
;
;    1. A default modifier - what the key becomes, so other scripts can write
;       >^x or >#x for it.
;    2. Individual remappings - keys that mean something else while it is
;       held, overriding the default. These fire on the PHYSICAL key, which is
;       what separates CapsLock+J from a real Ctrl+J.
;
;  CapsLock is held like any modifier. The Copilot key cannot be held - it is
;  a tap, see "The Copilot key" below - so for it "held" means the two
;  seconds after a tap, until the next key.
;
;  A third layer, [AltGr], has only the second setting: AltGr is a modifier
;  already (<^>!x in any script), so there is nothing to make it become. Its
;  remaps work the same way - a left-hand number pad by default - and share
;  the ini table, the GUI and the variant rules with the other two.
;
;  Any other key gets a layer the same way: an ini section named after it -
;  [LShift], [RShift], [LWin] - is read like [AltGr], and its entries fire
;  while that key is PHYSICALLY held. That is what "LShift & -" was in the
;  old Keyboard assistant, without a line of code per key. Meant for the
;  eight modifiers, since a plain key would still type itself.
;
;  Prefer the RIGHT-hand modifiers. >^x is reachable only through this script;
;  ^x is also plain Ctrl, so the focused program's own shortcuts collide with
;  it.
; =============================================================================

; ── Layers ───────────────────────────────────────────────────────────────────
; One process owns the keyboard. That is the whole point: every problem this
; script exists to solve came from separate processes hooking the same keys
; and racing - first hook in the chain wins, the rest silently do nothing.
; Separate FILES cost nothing, separate PROCESSES cost correctness.
;
; The layers were Keyboard assistant's scripts\ folder until they moved here.
; The modifier engine below must be in place before them, since app-shortcuts.ahk
; reads the physical F23.
#Include "lib\WebView2.ahk"
#Include "lib\JSON.ahk"

InstallKeybdHook()          ; once, for every layer
; Send is never SendInput on this machine: AutoHotkey drops to SendEvent whenever another AutoHotkey script
; holds a keyboard hook (Expanto, Encore, DalSegno...), and then pauses after every modifier change
; (KeyDelay -1, PressDuration 0 - keyboard_mouse.cpp). So RunEntry's "{RCtrl up}{Left}{RCtrl down}" was never
; the atomic burst it is written as: each pause let a repeating j or a physical Alt land in the middle of it.
; -1, -1 sends the burst back to back. SendInput itself, where it is used, is unaffected (2026-09-28).
SetKeyDelay -1, -1
; Whichever process hooks the keyboard LAST is called FIRST. If Glissando (the BLE KVM) starts after us, its
; hook runs ahead of ours and forwards CapsLock+j to the other PC RAW, before our layer remaps it -- so the
; navigation never reaches the other machine, since a remapper there cannot read the physical CapsLock of an
; injected key. Re-installing our hook a few seconds into startup puts us back in front, so we remap first and
; Glissando forwards the result. Confined to the startup window so it does not fight other long-lived hookers.
SetTimer(() => InstallKeybdHook(true, true), -4000)
SetTimer(() => InstallKeybdHook(true, true), -12000)
; ... and again whenever Glissando (re)starts later: its fresh hook lands in front of ours and CapsLock+j is
; forwarded raw once more (every Glissando update did this, 2026-09-14). Watch its process id; a new one gets
; 3 s to install its hook, then ours goes back in front - unless CapsLock is held right then, in which case the
; next tick tries again (a reinstall resets the hook's physical table mid-chord).
g_glissPid := ProcessExist("Glissando.exe")
SetTimer(GlissandoHookWatch, 2000)
GlissandoHookWatch() {
    global g_glissPid
    static pending := 0
    pid := ProcessExist("Glissando.exe")
    if (pid && pid != g_glissPid)
        pending := A_TickCount + 3000
    g_glissPid := pid
    if (pending && A_TickCount >= pending && !CapsHeld()) {
        pending := 0
        InstallKeybdHook(true, true)
        StuckLog("caps", "Glissando (re)started -> keyboard hook reinstalled to stay ahead of it")
    }
}
CoordMode "ToolTip", "Screen"   ; CopilotHint places its tooltip by screen corner

if FileExist(A_ScriptDir "\icons\tray.ico")
    TraySetIcon(A_ScriptDir "\icons\tray.ico")

g_configFile := A_ScriptDir "\Sostenuto.ini"
g_capsMod := "RCtrl"
g_capsAltIsCtrl := false    ; [Settings] CapsAltIsCtrl: while CapsLock is held, treat left Alt as Ctrl
g_altSwallowed := false     ; CapsAltIsCtrl: a left Alt went down under CapsLock and was kept from the OS
g_altReplayed := false      ; CapsAltIsCtrl: the Alt the OS holds is one WE put down (replay); its up is ours to send
g_copilotMod := ""         ; see LoadConfig - none by default
g_copilotDown := false     ; the Copilot layer is ARMED: a tap was seen and no key has used it yet
g_lastF23 := 0             ; tick of the last F23 down
g_copilotIh := 0           ; InputHook watching for the key that closes the window
g_copilotBound := 0        ; Map vk -> true of keys either Copilot layer binds; rebuilt lazily
g_copilotLastUse := 0      ; tick of the last arm or use - the watchdog's staleness clock
g_rawCapsDown := false     ; CapsLock according to Raw Input - the physical key, independent of every hook
g_rawCapsTick := 0         ; tick of the last Raw Input CapsLock event, 0 = none yet (or no Raw Input at all)
g_rawInputOn := false      ; Raw Input registered - the probe in KeepDown is meaningless without it
g_hookCapsDownTick := 0    ; when OUR hook last saw CapsLock down (typematic repeats included)
g_hookCapsUpTick := 0      ; when OUR hook last saw a real CapsLock up (KeepDown's probe excluded)
g_probeUpTick := 0         ; when KeepDown last injected its probe CapsLock up (see ~*CapsLock up)
g_rawMods := Map()         ; modifier name -> what Raw Input last saw of it, keyboard and injected apart (RawModBrief)
g_repeatBase := ""         ; the Copilot key currently repeating itself, "" = none
g_repeatFn := 0            ; its bound timer function, so it can be cancelled
g_repeatCount := 0         ; repeats in the current hold - logged when it ends
COPILOT_WINDOW := 2000     ; ms a tap keeps the layer armed; [Settings] CopilotWindow
g_remaps := Map()            ; layer name -> Map(key -> replacement)
g_layerOrder := []           ; layer names in display order: the three built in, then the ini's own
g_registered := []       ; [[hotkey, criterion]] so a reload can undo them
g_variants := Map()      ; "layer|basekey" -> [{mods, value}] modifier variants
g_uiWin := 0, g_uiCtrl := 0, g_uiCore := 0, g_uiReady := false

LoadConfig()
InitTray()

; ── Configuration ────────────────────────────────────────────────────────────
LoadConfig() {
    ; g_variants must be in this list: an undeclared assignment makes a LOCAL,
    ; so the global kept every variant ever loaded - and a key removed from
    ; the ini stayed "bound", which kept the app shortcut layer from serving
    ; it until a restart.
    global g_capsMod, g_copilotMod, g_remaps, g_registered, g_variants
        , COPILOT_WINDOW, g_copilotBound, g_layerOrder, g_capsAltIsCtrl
    if !FileExist(g_configFile)
        WriteDefaultConfig()

    ; the old single-layer names are still honoured, so an existing config
    ; keeps working without being rewritten
    ; none is allowed here too. The [CapsLock] remaps fire on the PHYSICAL
    ; key, so they keep working with no modifier at all - only the ability to
    ; address the key from other scripts goes away. A layer file that spells a
    ; prefix out (>^x) would stop matching, which is what the GUI warns about
    ; rather than leaving you to discover it silently.
    g_capsMod := ValidModifier(IniRead(g_configFile, "Settings", "CapsLockModifier"
        , IniRead(g_configFile, "Settings", "Modifier", "RCtrl")), "RCtrl", true)
    ; CapsAltIsCtrl: while CapsLock is held, left Alt acts as Ctrl. So caps+Alt+j sends a clean Ctrl+Left
    ; instead of lifting Alt and injecting Ctrl - which matters over Glissando, where the lift/swap sequence
    ; reorders and corrupts. It reuses the CapsLock modifier (already a Ctrl), so no extra key is held, and
    ; caps+X without Alt is untouched (>^x still works). caps+Alt+i/k become Ctrl+Up/Down, not PgUp/PgDn.
    g_capsAltIsCtrl := RegExMatch(Trim(IniRead(g_configFile, "Settings", "CapsAltIsCtrl", "0")), "i)^(1|true|yes|on)$") > 0
    ; none as the default, deliberately. The only modifier still free is right
    ; Win, and Win+L cannot be intercepted by any hook - it is handled at the
    ; secure-attention level, so Copilot+L would lock the machine. The app
    ; shortcut layer does not need a modifier anyway: it reads g_copilotDown,
    ; which the F23 hotkeys below maintain.
    g_copilotMod := ValidModifier(IniRead(g_configFile, "Settings", "CopilotModifier"
        , "none"), "", true)
    ; How long a Copilot tap keeps its layer armed, in ms (see "The Copilot key").
    COPILOT_WINDOW := 2000
    try COPILOT_WINDOW := Max(300, Integer(IniRead(g_configFile, "Settings", "CopilotWindow", "2000")))
    g_copilotBound := 0        ; the bound-key map follows the new layer contents

    for hk in g_registered {
        HotIf(hk[2])
        try Hotkey(hk[1], "Off")
    }
    HotIf()
    g_registered := []
    g_remaps := Map("CapsLock", Map(), "Copilot", Map(), "AltGr", Map())
    g_layerOrder := ["CapsLock", "Copilot", "AltGr"]
    g_variants := Map()
    ; An ini written before the AltGr layer existed has no [AltGr] section at
    ; all - as opposed to an empty one, which is a choice and is respected.
    ; Give it the defaults once, so the number pad turns up without a reset.
    try {
        if !InStr(FileRead(g_configFile, "UTF-16"), "[AltGr]")
            WriteDefaultKeys("AltGr", false)
    }
    LoadLayer("CapsLock", CapsHeld, IniRead(g_configFile, "Remap", , ""))
    LoadLayer("Copilot", CopilotHeld, "")
    LoadLayer("AltGr", AltGrHeld, "")

    ; Every other section is a layer for the key it is named after - [LShift],
    ; [RShift], [LWin]... - read exactly like [AltGr]: entries fire while the
    ; key is physically held, and are sent plainly. Nothing is declared
    ; anywhere else; the section IS the declaration.
    for name in ExtraLayerNames() {
        g_remaps[name] := Map()
        g_layerOrder.Push(name)
        LoadLayer(name, KeyHeld(name), "")
    }
}

; Section names the ini has beyond the fixed ones, in file order, skipping
; any that AutoHotkey does not know as a key - a typo would otherwise be a
; hotkey that never fires, with no message anywhere.
ExtraLayerNames() {
    static reserved := Map("Settings", 1, "Window", 1, "Remap", 1
        , "CapsLock", 1, "Copilot", 1, "AltGr", 1)
    names := []
    for name in StrSplit(IniRead(g_configFile), "`n", "`r") {
        name := Trim(name)
        if (name = "" || reserved.Has(name))
            continue
        try {
            GetKeyState(name, "P")
            names.Push(name)
        } catch
            TrayTip("[" name "] is not a key AutoHotkey knows - section ignored", "Sostenuto", "Iconx")
    }
    return names
}

; Reads one [<layer>] section; extra is a legacy section merged in for the
; CapsLock layer, whose entries used to live under [Remap].
LoadLayer(layer, criterion, extra) {
    global g_remaps, g_registered, g_variants
    text := IniRead(g_configFile, layer, , "")
    if (extra != "")
        text := extra "`n" text

    ; An entry may carry modifiers of its own: "j" is the bare case, "!j" the
    ; one with Alt, "!+j" with Alt and Shift. They are grouped by base key and
    ; served by ONE hotkey, which then picks the most specific entry matching
    ; the modifiers actually held.
    ;
    ; Registering "*j" and "*!j" as separate hotkeys and trusting AutoHotkey to
    ; pick between them was the obvious alternative, and it is exactly the kind
    ; of precedence assumption that has bitten us all day. Deciding it here
    ; makes the rule explicit and testable: most modifiers wins, ties go to the
    ; first one written.
    groups := Map()
    for line in StrSplit(text, "`n", "`r") {
        if !RegExMatch(line, "^\s*([^=;]+?)\s*=\s*(.+?)\s*$", &m)
            continue
        spec := m[1], value := m[2]
        g_remaps[layer][spec] := value
        if !RegExMatch(spec, "^([!^+#<>]*)(.+)$", &p)
            continue
        mods := p[1], base := p[2]
        if !groups.Has(base)
            groups[base] := []
        groups[base].Push(Map("mods", mods, "value", value))
    }

    HotIf(criterion)
    for base, entries in groups {
        g_variants[layer "|" base] := entries
        try {
            ; * so it fires whatever else is held: the layer's own modifier is
            ; down by definition, and Alt or Shift may be too - which entry
            ; that means is decided in RemapAction, not by the hotkey table.
            Hotkey("*" base, RemapAction.Bind(layer, base), "On")
            g_registered.Push(["*" base, criterion])
        } catch
            TrayTip("Not a valid key: " base, "Sostenuto", "Iconx")
    }
    HotIf()
}

; Which entry for this key applies right now. Modifiers are read PHYSICALLY:
; the layer modifier is synthetic and gets lifted around every send, so the
; logical state cannot be trusted between auto-repeats.
PickVariant(layer, base) {
    global g_variants, g_capsAltIsCtrl
    entries := g_variants.Has(layer "|" base) ? g_variants[layer "|" base] : []
    ; CapsAltIsCtrl: a held left Alt reads as Ctrl, not Alt, so the Ctrl-output entries are reached by their
    ; bare form (which keeps the CapsLock Ctrl held in RunEntry) instead of the Alt variant that lifts.
    altAsCtrl := layer = "CapsLock" && g_capsAltIsCtrl && GetKeyState("LAlt", "P")
    best := "", bestScore := -1
    for e in entries {
        mods := e["mods"], score := 0, ok := true
        for want, keyName in Map("!", "Alt", "+", "Shift", "^", "LCtrl", "#", "LWin") {
            need := InStr(mods, want) > 0
            has := GetKeyState(keyName, "P")
            if (altAsCtrl && keyName = "Alt")
                has := false            ; the held Alt does not count as Alt
            else if (altAsCtrl && keyName = "LCtrl")
                has := true             ; it counts as Ctrl instead
            if (need && !has)
                ok := false
            if need
                score += 1
        }
        if (ok && score > bestScore)
            best := e, bestScore := score
    }
    return best
}

ValidModifier(name, fallback, allowNone := false) {
    static valid := Map("LCtrl", 1, "RCtrl", 1, "LAlt", 1, "RAlt", 1
        , "LShift", 1, "RShift", 1, "LWin", 1, "RWin", 1)
    name := Trim(name)
    if (allowNone && (name = "" || name = "none"))
        return ""
    if valid.Has(name)
        return name
    TrayTip(name " is not a modifier key - using " fallback, "Sostenuto", "Iconx")
    return fallback
}

CapsHeld(*) {
    global g_rawCapsDown, g_rawCapsTick, g_hookCapsDownTick, g_hookCapsUpTick
    ; The hook's GetKeyState physical bit flickers to "up" during rapid key
    ; traffic (caps+j held, a fast caps+click), which dropped the layer and
    ; leaked literal characters. A Raw Input DOWN outranks that flicker. But
    ; Raw Input alone cannot carry the key: it sees only what no hook has
    ; swallowed, and the down is swallowed by our own hotkey - so on this
    ; machine it may never report a down at all, and "not down per Raw
    ; Input" must never mean "released". The hook keeps the final word on
    ; held; KeepDown holds the witnesses against a hook that missed the up.
    if g_rawCapsDown
        return true
    ; The flicker cure that works here: our hook saw CapsLock go down, and
    ; since then no release has been seen - not by the hook's own up-handler,
    ; not by Raw Input. A flickering physical bit is no release; a real one
    ; reaches at least one of the two. A release swallowed ahead of both is
    ; the phantom, and KeepDown's cure zeroes g_hookCapsDownTick for it.
    ; Held CapsLock+j in PowerPoint leaked literal j's without this (2026-09-28).
    if (g_hookCapsDownTick && g_hookCapsDownTick > g_hookCapsUpTick
        && g_hookCapsDownTick > g_rawCapsTick)
        return true
    try
        return GetKeyState("CapsLock", "P")
    catch
        return false
}

; Ini entries keep the Copilot window open (Down, Down, Down); RemapAction
; closes it for run: entries. The criterion gets the hotkey name, e.g. "*Down".
CopilotHeld(hk, *) => CopilotUse(hk, true)

; AltGr is right Alt, physically - on a layout that has AltGr, Windows presses
; left Ctrl along with it, which is why <^>! is its prefix. Read the physical
; key so that a synthetic RAlt (a script sending !x) never opens the layer.
AltGrHeld(*) {
    try
        return GetKeyState("RAlt", "P")
    catch
        return false
}

; The criterion for an ini-declared layer: the named key, physically. One
; closure per layer, kept in g_registered so the reload can turn the same
; hotkeys off again - HotIf tells criteria apart by object identity.
KeyHeld(name) {
    held(*) {
        try
            return GetKeyState(name, "P")
        catch
            return false
    }
    return held
}

; The built-in two hold a SYNTHETIC modifier that has to be lifted around
; every send; every other layer's key is physical and a plain Send handles it.
PhysicalLayer(layer) => (layer != "CapsLock" && layer != "Copilot")

; ── CapsLock ─────────────────────────────────────────────────────────────────
; * so it fires regardless of what else is held: Shift+CapsLock+A must reach a
; +>^a hotkey rather than being swallowed here.
;
; The DOWN is swallowed (no ~): the OS toggles capitals on the down, and a
; down it never sees toggles nothing. SetCapsLockState AlwaysOff used to do
; this, but it swallows the UP as well - for us and for every hook behind
; ours - and that took away the only witness the phantom cure in KeepDown
; can have. The UP passes through (~): the OS shrugs at the release of a key
; it never saw pressed, and Raw Input gets to see it. (Hooks behind ours saw
; nothing of CapsLock under AlwaysOff either; now they at least see the up.)
;
; The toggle can still be set by other means - an on-screen keyboard, a
; remote session, a state left over from before this script started, or a
; press that slipped past a slow hook - and the watchdog turns it off again.
;
; g_hookCapsDownTick: when our hook last saw the key down. Typematic repeat
; fires this hotkey again every 31 ms for as long as no other key is pressed,
; so through a real hold the tick stays fresh.
*CapsLock:: {
    global g_hookCapsDownTick := A_TickCount
    if (g_capsMod != "" && !GetKeyState(g_capsMod))
        PressDown(g_capsMod)
    ; CapsAltIsCtrl: the chord landed Alt-first. *LAlt:: only swallows an Alt that goes down while CapsLock
    ; is already held, so an Alt pressed a few ms earlier reached the OS - and Glissando, which forwarded it -
    ; and every caps+Alt+j after that arrived as Ctrl+ALT+Left on the other PC (2026-09-24). Take it back the
    ; moment CapsLock arrives: an injected up, with the unassigned vkE8 in between so neither PC reads the
    ; press-release as an Alt tap and opens a menu bar. From here on it is a swallowed Alt like any other:
    ; its repeats are dropped, its physical up is swallowed, and it is replayed if still held when CapsLock
    ; lets go. A replayed Alt (CapsLock released and pressed again mid-hold) is taken back the same way.
    TakeBackAlt("Alt was down before CapsLock")
}

; CapsAltIsCtrl: an Alt the OS holds while a caps chord is under way is taken back - an injected up, with
; the unassigned vkE8 in front so the press-release is no bare Alt tap (menu bar, Office key tips). From
; then on it is a swallowed Alt like any other. Returns true if it took one back.
TakeBackAlt(why) {
    global g_capsAltIsCtrl, g_altSwallowed, g_altReplayed
    if !(g_capsAltIsCtrl && !g_altSwallowed && GetKeyState("LAlt", "P") && GetKeyState("LAlt"))
        return false
    g_altSwallowed := true, g_altReplayed := false, PublishAltSwallowed()
    Send "{Blind}{vkE8}{LAlt up}"
    StuckLog("caps", why " -> taken back from the OS")
    return true
}
~*CapsLock up:: {
    ; KeepDown's chain probe is an injected CapsLock up at send level 1, which
    ; lands here like a real one. It must not drop the modifier mid-hold. A
    ; real release inside the same 100 ms is not lost: the hook has seen it,
    ; CapsHeld() is false, and KeepDown's last branch lets go within 120 ms.
    if (A_TickCount - g_probeUpTick < 100)
        return
    global g_hookCapsUpTick := A_TickCount
    if (g_capsMod != "")
        Send "{Blind}{" g_capsMod " up}"
    ReplaySwallowedAlt()        ; after the modifier is up, so the OS never sees Ctrl+Alt overlap
}

; CapsAltIsCtrl: while CapsLock is held, keep left Alt from the OS, other scripts and Glissando. The key is
; still physically down, so PickVariant reads it (as Ctrl) and the layer fires the bare entry with the
; CapsLock Ctrl kept down -- a clean Ctrl+key with no Alt in it. Right Alt (AltGr) is untouched. The hotkeys
; exist only when the switch is on, so default behaviour is unchanged.
;
; Down and up are judged separately, and CapsHeld() lags a real release by up to ~120 ms (the probe window,
; KeepDown's let-go), so the pair is kept symmetric by a flag, not by re-reading CapsLock: an up is swallowed
; only if its down was, or the OS is left holding an Alt it never sees released. And an Alt swallowed inside
; that lag but still held once CapsLock is up was a plain Alt after all - Alt+Tab straight after a caps
; chord - which, without the replay below, reached the OS as Ctrl+Tab (the modifier still down, no Alt).
#HotIf g_capsAltIsCtrl && CapsHeld()
*LAlt:: {
    global g_altSwallowed
    if (!g_altSwallowed && GetKeyState("LAlt"))
        return                  ; auto-repeat of an Alt the OS already holds: drop it, leave its up alone
    g_altSwallowed := true, PublishAltSwallowed()
}
#HotIf g_capsAltIsCtrl && (g_altSwallowed || g_altReplayed)
*LAlt up:: {
    global g_altSwallowed, g_altReplayed
    ; AutoHotkey suppresses the UP of any key whose down a hotkey suppressed, whatever this hotkey's #HotIf
    ; says - so after a replay the OS never saw the Alt go up: a stuck Alt for the watchdog's 60 s guard to
    ; free (2026-09-12 07:58). The down was ours, so the up is ours to send as well.
    ; vkE8 first: the replayed down and this up are otherwise a bare Alt tap, and Office answers one with its
    ; menu-bar key tips - caps released before Alt let Alt "through" that way (2026-09-28).
    if g_altReplayed
        Send "{Blind}{vkE8}{LAlt up}"
    g_altSwallowed := false, g_altReplayed := false, PublishAltSwallowed()
}
#HotIf

; Other scripts cannot see a swallowed Alt at all - not their hook, not GetKeyState(, "P"), not even Raw Input,
; which Windows only generates for keys no low-level hook has eaten. Expanto's CapsLock+Alt+x hotkey asks here:
; GetProp(<this script's hidden window>, "Sostenuto.AltSwallowed") is nonzero while a left Alt is held and kept
; from the OS. Called after every change of g_altSwallowed.
PublishAltSwallowed() {
    DllCall("SetProp", "Ptr", A_ScriptHwnd, "Str", "Sostenuto.AltSwallowed", "Ptr", g_altSwallowed ? 1 : 0)
}

; Called wherever the CapsLock modifier is let go. If the swallowed Alt is still held, hand the OS the down it
; never saw, and remember that we did: the physical up will be swallowed (see *LAlt up), so we send that too.
; If Alt is already up there is nothing to undo.
ReplaySwallowedAlt() {
    global g_altSwallowed, g_altReplayed
    if !g_altSwallowed
        return
    g_altSwallowed := false, PublishAltSwallowed()
    if GetKeyState("LAlt", "P") {
        g_altReplayed := true
        Send "{Blind}{LAlt down}"
    }
}

; A rescue (ReleaseModifiersNow) must never put an Alt DOWN: forget a swallowed one - the OS never saw it -
; and lift one we replayed.
ForgetSwallowedAlt() {
    global g_altSwallowed, g_altReplayed
    g_altSwallowed := false, PublishAltSwallowed()
    if g_altReplayed {
        g_altReplayed := false
        Send "{Blind}{vkE8}{LAlt up}"
    }
}

; ── The physical keys, by Raw Input ──────────────────────────────────────────
; Everything above learns about CapsLock from the keyboard hook, and the hook
; can be lied to: its key-up can be swallowed by a hook installed ahead of
; ours, or lost with the session lock, and from then on CapsHeld() claims a
; key that is up - the phantom KeepDown cures. Curing it needs a second
; witness, and Raw Input is one - with a limit found the hard way (2026-09-07):
; it does NOT see an event that a low-level hook swallowed. So it sees the
; CapsLock up, which our hook lets through, but only when no hook ahead of
; ours swallows CapsLock outright - which is why KeepDown also probes the
; chain with an injected up of its own. The OS toggle state is no witness at
; all: the down is suppressed, so the OS reads CapsLock as up throughout a
; real hold.
;
; hDevice is 0 for injected input (SendInput, keybd_event), which never
; counts as the keyboard: the state must be the keyboard's alone, so that a
; script's synthetic CapsLock - AlwaysOff toggling the light off, for one -
; never masks it.
;
; The other modifiers get the same witness, for the watchdog's benefit. When
; it finds LWin logically down with no physical press, the question is who
; pressed it: the keyboard (and the hook missed it), or some process that
; injected it (and lost the up). Raw Input answers, and for an injected key
; even says whether an AutoHotkey script sent it - AutoHotkey stamps its own
; keystrokes with a signature in dwExtraInfo (KEY_IGNORE and friends).
;
; MaxThreads above 1 because a handler still running when the next event
; lands would otherwise DROP that event (the up half of a down/up pair, in
; the probe); Critical keeps the events in order instead.
RegisterRawCapsLock()

RegisterRawCapsLock() {
    static RIDEV_INPUTSINK := 0x100      ; deliver even when we are not the focus
    ; RAWINPUTDEVICE: usUsagePage, usUsage (generic desktop 1, keyboard 6), dwFlags, hwndTarget
    rid := Buffer(A_PtrSize = 8 ? 16 : 12, 0)
    NumPut("UShort", 1, "UShort", 6, "UInt", RIDEV_INPUTSINK, rid)
    NumPut("Ptr", A_ScriptHwnd, rid, 8)
    ; TrayTip, not StuckLog: this runs before core\watchdog.ahk has set the log path.
    if !DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 1, "UInt", rid.Size) {
        TrayTip("Raw Input registration failed (error " A_LastError ") - the CapsLock phantom cure is off", "Sostenuto", "Iconx")
        return
    }
    OnMessage(0x00FF, OnRawInput, 8)     ; WM_INPUT
    global g_rawInputOn := true
}

OnRawInput(wParam, lParam, msg, hwnd) {
    Critical
    global g_rawCapsDown, g_rawCapsTick, g_rawMods
    static RID_INPUT := 0x10000003, HDR := (A_PtrSize = 8 ? 24 : 16)   ; sizeof(RAWINPUTHEADER)
    static buf := Buffer(64)             ; header + RAWKEYBOARD is 40 bytes on x64
    size := buf.Size
    if (DllCall("GetRawInputData", "Ptr", lParam, "UInt", RID_INPUT, "Ptr", buf, "UInt*", &size, "UInt", HDR) = -1)
        return
    if (NumGet(buf, 0, "UInt") != 1)     ; dwType: RIM_TYPEKEYBOARD
        return
    ; RAWKEYBOARD: MakeCode, Flags, Reserved, VKey (UShort each), Message, ExtraInformation
    flags := NumGet(buf, HDR + 2, "UShort")
    name := RawKeyName(NumGet(buf, HDR + 6, "UShort"), NumGet(buf, HDR, "UShort"), flags)
    if (name = "")
        return
    down := !(flags & 1)                 ; RI_KEY_BREAK
    if !g_rawMods.Has(name)
        g_rawMods[name] := {phys: false, physTick: 0, injTick: 0, injDown: false, injExtra: 0}
    m := g_rawMods[name]
    if !NumGet(buf, 8, "Ptr") {          ; hDevice 0: injected - remembered, never counted as the keyboard
        m.injTick := A_TickCount, m.injDown := down, m.injExtra := NumGet(buf, HDR + 12, "UInt")
        return
    }
    m.phys := down, m.physTick := A_TickCount
    if (name = "CapsLock")
        g_rawCapsDown := down, g_rawCapsTick := A_TickCount
}

; Raw Input reports the generic VK_SHIFT / VK_CONTROL / VK_MENU; the side
; comes from the scan code (right Shift is 0x36) or the E0 prefix (right
; Ctrl and Alt). The Win keys and CapsLock have codes of their own.
RawKeyName(vk, make, flags) {
    e0 := flags & 2                      ; RI_KEY_E0
    switch vk {
        case 0x14: return "CapsLock"
        case 0x10, 0xA0, 0xA1: return (make = 0x36 || vk = 0xA1) ? "RShift" : "LShift"
        case 0x11, 0xA2, 0xA3: return (e0 || vk = 0xA3) ? "RCtrl" : "LCtrl"
        case 0x12, 0xA4, 0xA5: return (e0 || vk = 0xA5) ? "RAlt" : "LAlt"
        case 0x5B: return "LWin"
        case 0x5C: return "RWin"
    }
    return ""
}

; One clause for the watchdog log: what the keyboard last did with the key,
; and what was injected, so a stuck modifier can be laid at the right door.
RawModBrief(name) {
    global g_rawMods
    if !g_rawMods.Has(name)
        return "raw: nothing seen"
    m := g_rawMods[name]
    s := "raw: keyboard " (m.physTick ? (m.phys ? "DOWN" : "up") " " (A_TickCount - m.physTick) " ms ago" : "never")
    if m.injTick
        s .= ", injected " (m.injDown ? "down" : "up") " " (A_TickCount - m.injTick) " ms ago" RawInjector(m.injExtra)
    return s
}

; AutoHotkey's dwExtraInfo signatures: KEY_IGNORE 0xFFC3D44F,
; KEY_PHYS_IGNORE 0xFFC3D44E, KEY_IGNORE_ALL_EXCEPT_MODIFIER 0xFFC3D44D, and
; KEY_IGNORE_LEVEL(n) = 0xFFC3D44D - n for a SendLevel of 1..100.
RawIsAhk(extra) => extra >= 0xFFC3D44D - 100 && extra <= 0xFFC3D44F

RawInjector(extra) {
    if RawIsAhk(extra)
        return " by an AutoHotkey script"
    return extra ? Format(" (extra 0x{:X})", extra) : ""
}

; ── The Copilot key ──────────────────────────────────────────────────────────
; Measured 2026-09-01 with a raw WH_KEYBOARD_LL logger placed first in the
; hook chain: the key is a TAP, never a hold. However long it is pressed, the
; keyboard sends LWin down, LShift down, F23 down, LWin up, LShift up, F23 up
; - all six within the same millisecond - and nothing more while it stays
; down. Not injected (LLKHF_INJECTED clear), so this is the keyboard or its
; filter driver, not a service. The earlier "repeats every 31 ms" note was
; wrong, and so was everything built on holding the key.
;
; So "Copilot + s" cannot be a chord. It is a SEQUENCE: tap Copilot, then
; press s - a leader key, as in vim. The tap ARMS the layer (g_copilotDown)
; for COPILOT_WINDOW ms ([Settings] CopilotWindow). While it is armed:
;   - a key the layer binds runs its entry and, if that entry sends keys or
;     calls a function, keeps the window open and restarts the clock - so
;     Copilot, Down, Down, Down lowers the volume three times, and holding
;     Down auto-repeats until it is released, as if Copilot were held;
;   - an entry that launches something (run:, or the app shortcut layer)
;     closes the window - nobody wants Spotify twice;
;   - any key neither layer binds closes it and is typed as usual;
;   - COPILOT_WINDOW ms of silence closes it.
; A configured layer modifier is held for exactly as long as the window is
; open - which is what makes a modifier on a tap key hazardous: with RWin,
; every unbound key in the window is Win+key. none is the safe setting.
;
; Windows opens the Copilot app on the full Shift+Win+F23 chord, so F23 is
; swallowed: binding it without ~ does that. What Windows then sees is a
; Win+Shift tap with nothing else pressed, and a lone Win tap opens Start -
; vkE8 marks the press as used. The LWin/LShift ups are belt and braces: the
; chord releases them itself, but the trace also showed a hook in the chain
; re-injecting LWin down right after the physical up (AutoHotkey's KEY_IGNORE
; marking), which is the kind of thing that leaves LWin logically stuck.
; CopilotSettle looks again once the burst is over and releases raw.
*F23:: CopilotArm()
*F23 up:: return     ; same millisecond as the down; nothing to do with it

CopilotArm() {
    global g_copilotDown, g_lastF23, g_copilotIh, g_copilotLastUse
    g_lastF23 := A_TickCount
    g_copilotLastUse := A_TickCount
    Send "{Blind}{vkE8}{LWin up}{LShift up}"
    SetTimer(CopilotSettle, -60)
    if !g_copilotDown {
        g_copilotDown := true
        if (g_copilotMod != "" && !GetKeyState(g_copilotMod))
            PressDown(g_copilotMod)
        ; The InputHook sees every key press without hiding any (V) and tells
        ; CopilotKeyDown, which closes the window on a key neither layer binds.
        ; Bound keys are the hotkey criteria's business (CopilotUse). Modifiers
        ; are exempt, so Shift for a capital is not "the key". Our own sends
        ; are level 0 and invisible to it (MinSendLevel 1). T is only a safety
        ; net - the real clock is CopilotTimeout.
        ih := InputHook("V T60")
        ih.MinSendLevel := 1
        ih.KeyOpt("{All}", "N")
        ih.KeyOpt("{LShift}{RShift}{LCtrl}{RCtrl}{LAlt}{RAlt}{LWin}{RWin}{F23}", "-N")
        ih.OnKeyDown := (ih, vk, sc) => CopilotKeyDown(vk)
        ih.OnEnd := (*) => CopilotDisarm()
        g_copilotIh := ih
        ih.Start()
    }
    SetTimer(CopilotTimeout, -COPILOT_WINDOW)
    CopilotHint(true)
}

; Called from the #HotIf criteria of both Copilot layers when a bound key is
; pressed while the layer is armed. It must stay cheap: the hook thread is
; waiting for the answer, and a Send here would queue an event behind that
; wait - so every cleanup runs from a timer, right after the hotkey.
;   keep = true   the window stays open and the clock restarts: ini entries
;                 that send keys or call a function. Down, Down, Down works,
;                 and so does holding Down - each auto-repeat comes here.
;   keep = false  the window closes: the app shortcut layer. RemapAction
;                 closes it for run: entries itself.
CopilotUse(hk, keep) {
    global g_copilotDown, g_copilotLastUse
    if !g_copilotDown
        return false
    g_copilotLastUse := A_TickCount
    if keep
        SetTimer(CopilotTimeout, -COPILOT_WINDOW)
    else {
        g_copilotDown := false
        SetTimer(CopilotDisarm, -1)
    }
    return true
}

; A key neither layer binds ends the sequence. A bound key is left to its
; hotkey, whichever order the hook delivers the two notifications in.
CopilotKeyDown(vk) {
    if CopilotBoundMap().Has(vk)
        return
    CopilotDisarm()
}

; vk -> true for every key the Copilot layer binds, so a key that ends the
; sequence can be told from one that uses it. Rebuilt after a config reload.
CopilotBoundMap() {
    global g_copilotBound
    if IsObject(g_copilotBound)
        return g_copilotBound
    m := Map()
    for key in g_variants
        if (SubStr(key, 1, 8) = "Copilot|")
            try m[GetKeyVK(SubStr(key, 9))] := true
    return g_copilotBound := m
}

CopilotTimeout() {
    if g_copilotDown
        CopilotDisarm()
}

CopilotDisarm(*) {
    global g_copilotDown, g_copilotIh
    g_copilotDown := false
    StopRepeat()
    SetTimer(CopilotTimeout, 0)
    if IsObject(g_copilotIh) {
        ih := g_copilotIh
        g_copilotIh := 0
        try ih.Stop()     ; fires OnEnd -> re-enters here, harmlessly
    }
    if (g_copilotMod != "" && GetKeyState(g_copilotMod))
        Send "{Blind}{" g_copilotMod " up}"
    CopilotHint(false)
}

; A Copilot tap leaves LWin/LShift logically down now and then - a hook in
; the chain re-injects the down after the physical up, so the release in
; CopilotArm can come too early. Look again after the burst and correct raw,
; past every hook, the way the watchdog does.
CopilotSettle() {
    global MODS
    for m in MODS
        if ((m.name = "LWin" || m.name = "LShift") && GetKeyState(m.name) && !GetKeyState(m.name, "P")) {
            RawRelease(m)
            StuckLog("copilot", m.name " still logically down after the Copilot tap -> released (raw key-up)")
        }
}

; A small sign that the tap registered, in a screen corner: a tooltip under
; the pointer would swallow the next click.
CopilotHint(show) {
    if show {
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        ToolTip("Copilot + ?", r - 140, b - 70, 5)
    } else
        ToolTip(, , , 5)
}

; ── Shared machinery ─────────────────────────────────────────────────────────
PressDown(mod) {
    Send "{Blind}{" mod " down}"
    ; A Win key pressed and released with nothing in between opens the Start
    ; menu - which is exactly what a tapped CapsLock is. One keystroke on the
    ; unassigned vkE8 reaches nothing and means nothing, but it is enough for
    ; the shell to count the press as used. Ctrl and Alt need it too: a lone
    ; Alt tap opens the menu bar, and a lone Ctrl tap opens Office's Paste
    ; Options menu while its button is still up after a paste - CapsLock+j
    ; in PowerPoint opened it now and then, since j itself is swallowed and
    ; the Ctrl we press and lift around it reads as a bare tap (2026-09-28).
    ; Only Shift does nothing on its own.
    if !InStr(mod, "Shift")
        Send "{Blind}{vkE8}"
}

; The same mask for a Send that ends by putting a modifier back down: its
; eventual release must not be a lone tap either.
MaskFor(mod, restore := "") => (restore != "" || (mod != "" && !InStr(mod, "Shift"))) ? "{vkE8}" : ""

; The layer's modifier is released around the replacement and pressed again
; afterwards, inside ONE Send. Sending plainly would not work: AutoHotkey
; releases held modifiers before sending and restores only those held
; PHYSICALLY - and ours is synthetic, so it would never come back. The timer
; below notices and re-asserts it, but a key that auto-repeats every 31 ms is
; faster than any timer, and the repeats leaked through as literal characters.
; One atomic burst leaves no gap for a repeat to slip into.
; A held key in the Copilot layer has to keep going - hold Down and the volume
; should keep falling until you let go. CapsLock's layer gets that from the
; keyboard itself: CapsLock is bound with ~, so it reaches the input stack and
; Windows' typematic repeat fires the hotkey again every 31 ms (measured). The
; Copilot layer's keys are swallowed by their own hotkey, and a key the input
; stack never sees is a key Windows never repeats.
;
; So the layer repeats the action itself while the key is PHYSICALLY held:
; 400 ms before the first repeat and 60 ms between the rest, close to the
; system's own rates. Should a firing arrive anyway - the hardware repeating
; after all - it is ignored while a repeat is running, so the rate is the same
; either way and nothing is counted twice.
;
; Launchers are excluded: nobody wants Spotify started sixty times a second.
; A launcher is run:<command>, or call: to a function named Launch… - the
; naming convention core\functions.ahk keeps for exactly this reason. They are
; one-shot in both senses: they never repeat, and they close the Copilot
; window, so one tap starts one program.
IsLauncher(value) => (SubStr(value, 1, 4) = "run:") || RegExMatch(value, "i)^call:\s*Launch")
RepeatableValue(value) => !IsLauncher(value)

StartRepeat(layer, base) {
    global g_repeatBase, g_repeatFn, g_repeatCount
    g_repeatBase := base
    g_repeatCount := 0
    g_repeatFn := RepeatTick.Bind(layer, base)
    SetTimer(g_repeatFn, -400)
}

RepeatTick(layer, base) {
    global g_repeatBase, g_repeatFn, g_repeatCount
    if (g_repeatBase != base)          ; a newer key took over
        return
    held := false
    try held := GetKeyState(base, "P")
    if (!held || !g_copilotDown) {
        StopRepeat()
        return
    }
    CopilotUse(base, true)             ; a held key keeps the window open
    RunEntry(layer, base)
    g_repeatCount++
    SetTimer(g_repeatFn, -60)
}

; One line per hold, not per repeat: enough to tell "held and repeated 23
; times" from "fired once and stopped" without filling the log.
StopRepeat() {
    global g_repeatBase, g_repeatFn, g_repeatCount
    if g_repeatFn
        SetTimer(g_repeatFn, 0)
    if (g_repeatBase != "" && g_repeatCount > 0)
        StuckLog("copilot", g_repeatBase " held -> repeated " g_repeatCount " time(s)")
    g_repeatBase := "", g_repeatFn := 0, g_repeatCount := 0
}

RemapAction(layer, base, *) {
    ; While we are repeating this key ourselves, extra firings are the
    ; hardware's auto-repeat arriving after all - ignore them.
    if (layer = "Copilot" && g_repeatBase = base)
        return
    RunEntry(layer, base)
    if (layer = "Copilot") {
        entry := PickVariant(layer, base)
        if (IsObject(entry) && RepeatableValue(entry["value"]))
            StartRepeat(layer, base)
    }
}

RunEntry(layer, base) {
    entry := PickVariant(layer, base)
    ; No entry fits the modifiers held - a layer with only "^l" and plain
    ; Alt+L pressed. The hotkey has already swallowed the key, so put it
    ; back as it was pressed rather than eat it. Sent at level 0, so it
    ; cannot re-enter this hotkey.
    if !IsObject(entry) {
        Send "{Blind}{" base "}"
        return
    }
    value := entry["value"]
    ; With CapsAltIsCtrl and left Alt held, DON'T lift the CapsLock Ctrl: leaving it down turns the bare entry
    ; (e.g. {Left}) into Ctrl+Left, a single held Ctrl that survives the lossy link, instead of the fragile
    ; lift-Alt/inject-Ctrl dance. The swallowed Alt (below) keeps Alt out of the sent chord.
    global g_capsAltIsCtrl
    ; CapsAltIsCtrl: the Alt of this chord should have been swallowed by *LAlt::, but it reached the OS -
    ; its #HotIf lost a race (a hook timeout, CapsLock read as up for a moment). Left there it rides along
    ; as Ctrl+ALT+Left, and its release after the swallowed letter is a bare Alt tap: the menu bar came up
    ; now and then on caps+Alt+letter in PowerPoint (2026-09-28). Take it back before sending.
    if (layer = "CapsLock")
        TakeBackAlt("Alt reached the OS under a caps chord")
    mod := (layer = "CapsLock")
        ? ((g_capsAltIsCtrl && GetKeyState("LAlt", "P")) ? "" : g_capsMod)
        : (layer = "Copilot") ? g_copilotMod : ""

    ; One tap, one program - and the window closes before the launch, so a
    ; slow start cannot leave the layer armed behind it.
    if (layer = "Copilot" && IsLauncher(value))
        CopilotDisarm()

    if (SubStr(value, 1, 4) = "run:") {
        try Run(Trim(SubStr(value, 5)))
        catch as e
            TrayTip("Could not run " Trim(SubStr(value, 5)) "`n" e.Message, "Sostenuto", "Iconx")
        return
    }
    if (SubStr(value, 1, 5) = "call:") {
        ; %fn%() resolves the name to the function of that name. A missing
        ; function and a function that throws look the same from here, so
        ; the message carries what actually went wrong.
        ; call:Fn(M, Snabbanteckning) passes literal strings - comma
        ; separated, trimmed, quotes optional - so one function can serve
        ; several keys (one Obsidian vault each) without a wrapper per key.
        ; There is no expression here: an argument is never evaluated.
        fn := Trim(SubStr(value, 6)), args := []
        if RegExMatch(fn, "^([^(]+)\((.*)\)$", &m) {
            fn := Trim(m[1])
            if (Trim(m[2]) != "")
                for a in StrSplit(m[2], ",")
                    args.Push(Trim(Trim(a), "`"'"))
        }
        try %fn%(args*)
        catch as e
            TrayTip(fn "(): " e.Message, "Sostenuto", "Iconx")
        return
    }

    ; The AltGr layer is the simple case, and it is simple for the reason the
    ; others are not: its modifier is PHYSICAL. A plain Send lifts every held
    ; modifier - AltGr's Ctrl+Alt, and Shift - types the value, and puts back
    ; the ones that are physically down, which is exactly right. {Blind} would
    ; carry Ctrl+Alt through and turn "1" into Ctrl+Alt+1 in the focused
    ; program; and Shift is not kept either, since the layer spells its Shift
    ; variants out (+q is "(", not Shift+1). This is what the old
    ; "RAlt & q::Send 1" did, and it never needed anything more. The same
    ; holds for every ini-declared layer: [LShift] with "-=?" is the old
    ; "LShift & -::Send ?" - Shift is physical, so Send sorts it out.
    if PhysicalLayer(layer) {
        Send value
        return
    }

    ; ALT is lifted along with the layer modifier whenever an entry asked for
    ; it: Alt is the "word-wise" selector, so the value already spells out ^.
    ; Leaving Alt down would let {Blind} carry it through and turn Ctrl+Left
    ; into Ctrl+Alt+Left. SHIFT is deliberately kept - that is how selection
    ; works without every entry needing a Shift twin.
    ; The lift is preceded by vkE8: the letter that brought us here was swallowed, so to the OS the Alt went
    ; down and straight up again - a bare Alt tap, which opens the menu bar or Office's key tips (2026-09-28).
    lift := "", restore := ""
    if InStr(entry["mods"], "!") {
        if GetKeyState("LAlt", "P")
            lift .= "{LAlt up}", restore .= "{LAlt down}"
        if GetKeyState("RAlt", "P")
            lift .= "{RAlt up}", restore .= "{RAlt down}"
        if (lift != "")
            lift := "{vkE8}" lift
    }
    if (mod = "") {
        Send "{Blind}" lift value restore MaskFor("", restore)
        return
    }
    Send "{Blind}{" mod " up}" lift value "{Blind}{" mod " down}" restore MaskFor(mod, restore)
}

; ── Keeping the modifiers down, and unstuck ──────────────────────────────────
; The fast timer is a safety net for hotkeys in OTHER scripts that send
; keystrokes without the release/restore idiom: they drop the modifier and
; nothing puts it back. It cannot win against auto-repeat, but it restores the
; state before the next deliberate keypress.
;
; The slow one is the opposite failure: if a key-up is ever swallowed - another
; hook, a locked session, a dropped RDP connection - the modifier stays down
; and every keystroke becomes a chord. A held modifier is a seconds-long
; gesture, so ten seconds of "down" with the physical key up is a lost event.
SetTimer(KeepDown, 25)
SetTimer(StuckWatchdog, 1000)

; Glissando (the sibling BLE KVM) holds this named Event while THIS PC is
; actively controlling the other one. Optional and one-directional: no Glissando
; means no Event and this is always false, so nothing here depends on it. While
; it is set, our keystrokes - including KeepDown's chain probe - are swallowed by
; Glissando's hook and forwarded to the other PC. The probe is meant to loop back
; through Raw Input; Glissando eating it is legitimate, not a stuck-key blocker,
; so the probe is suspended while this is true. Without that it releases the
; synthetic modifier mid-hold (the CapsLock+J,J,J failure, now over Bluetooth).
; The handle is cached for 50 ms so a key repeating 30x/s does not reopen it.
GlissControllingRemote() {
    static tick := 0, state := false
    now := A_TickCount
    if (now - tick < 50)
        return state
    tick := now
    h := DllCall("OpenEventW", "UInt", 0x00100000, "Int", false, "Str", "Glissando.ControllingRemote", "Ptr")
    if h {
        DllCall("CloseHandle", "Ptr", h)
        return state := true
    }
    return state := false
}

KeepDown() {
    global g_rawCapsDown, g_rawCapsTick, g_rawInputOn, g_rawMods, g_hookCapsDownTick, g_probeUpTick
    static capsUpSince := 0, heldSince := 0, probeTick := 0, probeDue := 0, probeLogged := false
    if (g_capsMod != "" && CapsHeld() && !GetKeyState(g_capsMod))
        PressDown(g_capsMod)
    if (g_copilotDown && g_copilotMod != "" && !GetKeyState(g_copilotMod))
        PressDown(g_copilotMod)

    ; The phantom: the HOOK believes CapsLock is physically down while the
    ; key is up - its key-up never reached our hook. Swallowed by a hook
    ; installed ahead of ours (Expanto's "read CapsLock itself" did exactly
    ; that: its ~*CapsLock let the down through, set AlwaysOff, and ate the
    ; up - 2026-09-06 08:00 and 2026-09-09 06:45, both right after an Expanto
    ; restart put its hook first), or lost on the secure desktop. Nothing
    ; below can cure it on its own: CapsHeld() is true, so the branch above
    ; re-presses the modifier every 25 ms, the release path is never reached,
    ; and even the tray's release is undone at once. Every keystroke is a
    ; Ctrl chord until the hook is reinstalled - which is what the cure does:
    ; that resets its physical table and puts it first in the chain again.
    ;
    ; Telling a phantom from a real hold took several attempts. The OS's
    ; logical state is no witness: the down is suppressed, so the OS reads
    ; CapsLock as up throughout a real hold, and judged that way the cure
    ; released RCtrl in the middle of CapsLock+J, J, J (2026-09-06 09:34).
    ; Nor is the keyboard's auto-repeat on its own: it follows the LAST key
    ; pressed, so the moment J goes down CapsLock stops repeating, and "no
    ; CapsLock repeat for 1.5 s" fired on every held CapsLock+J after the
    ; first second (2026-09-07 09:29) - one step left, then a row of literal
    ; j. Three witnesses now, one per way of losing the up:
    ;  1. Raw Input saw a CapsLock RELEASE after the last down our hook saw.
    ;     Our hook lets the up through, so Raw Input sees it whenever no hook
    ;     ahead of ours swallows it. Compared by tick, not by state: Raw Input
    ;     may only ever see ups, so "last seen up" alone means nothing.
    ;  2. A hook ahead of ours swallows CapsLock outright (the Expanto case):
    ;     then a CapsLock up injected from here never reaches Raw Input
    ;     either. Sent once a second while the key counts as held - level 0,
    ;     so no hotkey anywhere fires on it, and the release of a key the OS
    ;     never saw pressed is nothing to it. Meaningless without Raw Input.
    ;  3. Silence: no down and no repeat for 30 s. A real hold stops repeating
    ;     as soon as another key is pressed, so this is the last resort with
    ;     a long fuse, not the first line.
    if !CapsHeld() {
        heldSince := 0, probeTick := 0
    } else {
        if !heldSince
            heldSince := A_TickCount, probeTick := 0, probeDue := A_TickCount + 1000
        if (g_rawCapsTick && !g_rawCapsDown && g_rawCapsTick > g_hookCapsDownTick
            && A_TickCount - g_rawCapsTick > 150) {
            ReleaseModifiersNow("hook says CapsLock down, Raw Input saw it released "
                . (A_TickCount - g_rawCapsTick) " ms ago")
        } else if probeTick {
            if (A_TickCount - probeTick > 300) {
                m := g_rawMods.Get("CapsLock", 0)
                if (m && m.injTick >= probeTick) {
                    ; Logged once per run: proof that the probe travels the
                    ; chain and comes back, without a line per second of hold.
                    if !probeLogged
                        probeLogged := true, StuckLog("caps", "chain probe: injected CapsLock up reached Raw Input after "
                            . (m.injTick - probeTick) " ms - the chain is clear")
                    probeTick := 0, probeDue := A_TickCount + 1000
                } else if !GlissControllingRemote()
                    ReleaseModifiersNow("hook says CapsLock down, but a CapsLock up injected "
                        . (A_TickCount - probeTick) " ms ago never reached Raw Input"
                        . " - a hook ahead of ours swallows the key")
                else
                    ; Glissando is forwarding our keys to the other PC and swallowed the probe on the way -
                    ; expected, not a blocker. Abandon this probe and try again after the usual pause.
                    probeTick := 0, probeDue := A_TickCount + 1000
            }
        } else if (g_rawInputOn && A_TickCount >= probeDue && !GlissControllingRemote()) {
            ; Level 1, not 0: an AutoHotkey hook passes its own kind's level-0
            ; events through untouched, AlwaysOff or not (probe 2026-09-09
            ; 07:08 - the blocker never swallowed a level-0 up), so only a
            ; level-1 up is treated like a real one and swallowed by a blocker.
            ; That also makes our own ~*CapsLock up fire on it - g_probeUpTick
            ; tells that handler to leave the modifier alone.
            probeTick := A_TickCount, g_probeUpTick := A_TickCount
            SendLevel 1
            SendEvent "{CapsLock up}"
            SendLevel 0
        } else if (A_TickCount - heldSince > 30000 && A_TickCount - g_hookCapsDownTick > 30000) {
            ReleaseModifiersNow("hook says CapsLock down, but it saw no CapsLock down or repeat for "
                . Round((A_TickCount - g_hookCapsDownTick) / 1000) " s")
        }
    }

    ; The opposite failure, and the one that actually bites. CapsLock's key-UP
    ; can be swallowed - a menu's modal loop in ANOTHER process does it, which
    ; is how DalSegno's window menu left CapsLock "stuck": our synthetic
    ; modifier was never released, so every keystroke stayed a chord.
    ;
    ; StuckWatchdog already catches this, but only after ten seconds, and ten
    ; seconds of it is exactly what being stuck feels like. Nor can the other
    ; scripts fix it themselves: DalSegno and DeskPilot both watch the
    ; modifier's PHYSICAL state, which by then is up, so they see nothing
    ; wrong. The modifier is ours; releasing it is our job.
    ;
    ; Once the physical key is up there is no reason to hold the modifier at
    ; all, so the wait only has to outlast the race with our own up-handler -
    ; a few ticks, not ten seconds. g_capsMod's own key is read physically too,
    ; so a genuinely held RCtrl is never taken away from the user.
    if (g_capsMod = "" || CapsHeld() || !GetKeyState(g_capsMod)
        || GetKeyState(g_capsMod, "P")) {
        capsUpSince := 0
        return
    }
    if !capsUpSince {
        capsUpSince := A_TickCount
        return
    }
    if (A_TickCount - capsUpSince > 120) {
        Send "{Blind}{" g_capsMod " up}"
        ReplaySwallowedAlt()
        StuckLog("caps", g_capsMod " still down with CapsLock physically up"
            . " -> released after " (A_TickCount - capsUpSince) " ms")
        capsUpSince := 0
    }
}

; The manual escape, and the phantom cure. The hook is reinstalled FIRST:
; that resets its physical-state table, so CapsHeld() stops claiming a key
; that is up and KeepDown stops re-pressing the modifier - without that the
; release below would last 25 ms. Reason is logged so the cause can be found.
ReleaseModifiersNow(reason := "tray") {
    global g_hookSince, g_rawCapsDown, g_hookCapsDownTick
    InstallKeybdHook(true, true)
    g_hookSince := A_TickCount      ; the watchdog's fast path waits 3 s after every reinstall
    ; Raw Input's last word may be a down whose up a hook ahead of ours ate -
    ; left standing, CapsHeld() would stay true and undo this release at once.
    g_rawCapsDown := false
    g_hookCapsDownTick := 0
    if (g_capsMod != "")
        Send "{Blind}{" g_capsMod " up}"
    if (g_copilotMod != "")
        Send "{Blind}{" g_copilotMod " up}"
    ForgetSwallowedAlt()
    StuckLog("caps", reason " -> hook reinstalled, "
        . g_capsMod (g_copilotMod != "" ? " and " g_copilotMod : "") " released")
}

StuckWatchdog() {
    global g_copilotDown
    static since := Map()
    ; The Copilot window closes itself - InputHook timeout, next key, or use.
    ; If it is somehow still open well past COPILOT_WINDOW, close it here.
    if (g_copilotDown && A_TickCount - g_copilotLastUse > COPILOT_WINDOW + 2000) {
        StuckLog("watchdog", "Copilot window still open "
            . Round((A_TickCount - g_copilotLastUse) / 1000) " s after its last use -> closed")
        CopilotDisarm()
    }
    for layer, entry in Map("CapsLock", [g_capsMod, CapsHeld()]
        , "Copilot", [g_copilotMod, g_copilotDown]) {
        mod := entry[1], held := entry[2]
        if (mod = "" || !GetKeyState(mod) || held) {
            since[layer] := 0
            continue
        }
        if !since.Get(layer, 0) {
            since[layer] := A_TickCount
            continue
        }
        if (A_TickCount - since[layer] > 10000) {
            Send "{Blind}{" mod " up}"
            since[layer] := 0
        }
    }
}

; ── Tray ─────────────────────────────────────────────────────────────────────
InitTray() {
    A_IconTip := "Sostenuto`nCapsLock = " g_capsMod
        . "`nCopilot = " (g_copilotMod != "" ? g_copilotMod : "off")
    A_TrayMenu.Delete()
    lines := ["CapsLock  ->  " g_capsMod " (" g_remaps["CapsLock"].Count " remaps)"
        , "Copilot   ->  " (g_copilotMod != "" ? g_copilotMod : "off")
            " (" g_remaps["Copilot"].Count " remaps)"
        , "AltGr     ->  <^>!  (" g_remaps["AltGr"].Count " remaps)"]
    for name in g_layerOrder
        if PhysicalLayer(name) && name != "AltGr"
            lines.Push(name "  ->  held  (" g_remaps[name].Count " remaps)")
    for line in lines {
        A_TrayMenu.Add(line, (*) => 0)
        A_TrayMenu.Disable(line)
    }
    A_TrayMenu.Add()
    A_TrayMenu.Add("Open Sostenuto…", (*) => OpenUi())
    A_TrayMenu.Default := "Open Sostenuto…"
    A_TrayMenu.Add("Edit settings…", (*) => Run('notepad.exe "' g_configFile '"'))
    A_TrayMenu.Add("Reload settings", (*) => (LoadConfig(), InitTray()
        , TrayTip("Settings reloaded", "Sostenuto")))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Release the modifiers now", (*) => ReleaseModifiersNow())
    A_TrayMenu.Add("Restart", (*) => Reload())
    A_TrayMenu.Add("Exit", (*) => ExitApp())
}

WriteDefaultConfig() {
    text := "
(
; ═══════════════════════════════════════════════════════════════════════════
;  Sostenuto - settings
;
;  After editing: tray icon -> Reload settings. No restart needed.
; ═══════════════════════════════════════════════════════════════════════════

[Settings]
; What each key becomes, and therefore how other scripts address it. One of
; LCtrl RCtrl LAlt RAlt LShift RShift LWin RWin.
;
;   RCtrl  ->  other scripts write  >^x
;   RWin   ->  other scripts write  >#x
;
; Prefer the right-hand ones: >^x is reachable only through this script, while
; ^x is also plain Ctrl and collides with the focused program's own shortcuts.
; Note that a Win modifier inherits every Windows shortcut - CapsLock+L would
; lock the computer.
CapsLockModifier = RCtrl

; CapsAltIsCtrl: while CapsLock is held, treat left Alt as Ctrl. CapsLock+Alt+j
; then sends a single clean Ctrl+Left, instead of lifting Alt and injecting
; Ctrl around the arrow. That matters when a software KVM forwards the keys
; to another computer: the lift/inject dance reorders over a lossy link, one
; held Ctrl does not. Costs the Alt variants of CapsLock entries (CapsLock+
; Alt+i/k become Ctrl+Up/Down, not PgUp/PgDn). Also in the settings window.
CapsAltIsCtrl = 0

; CopilotModifier: none (default) means the Copilot key asserts no modifier
; of its own. It still works as a layer - the app shortcuts read its PHYSICAL
; key state - and Windows still cannot open the Copilot app, since that needs
; the F23 this script swallows either way.
;
; Setting a modifier here is possible but think first. The Copilot key is a
; tap, not a hold, so the modifier is held for the two seconds after a tap:
; every key you press in that window that the layer does not bind becomes
; Win+key with RWin - and Win+L cannot be intercepted by any hook, so
; Copilot, L would lock the machine.
CopilotModifier = none

; How long a Copilot tap keeps its layer armed, in milliseconds. The key
; cannot be held - its whole chord arrives within a millisecond - so
; "Copilot + Down" is Copilot, then Down within this window. Entries that
; send keys keep the window open for the next press; launchers close it.
CopilotWindow = 2000

[CapsLock]
; Individual remappings, overriding the modifier while CapsLock is held.
; Left: any key name, with modifiers in AutoHotkey syntax (!j = Alt+CapsLock+J).
; Right: keys to send in AutoHotkey syntax, run:<command> to launch
; something, or call:<function> from core\functions.ahk. A bare word is
; typed as text. Holding Shift as well still works - the replacement is sent
; blind, so Shift+CapsLock+J extends the selection.
; The rows below are the defaults; the GUI can put them back.

[Copilot]
; The same, for the Copilot key - which is a tap: tap it, then press the key.

[AltGr]
; The same, while AltGr is held. AltGr is a modifier already (<^>!x in any
; script), so it has no setting above - only these keys. The defaults make
; the left hand a number pad: q w e / a s d / < z x are 1-9, f is 0, and
; Shift+key gives the F-key or bracket the old Keyboard assistant had there.
; Unlike the CapsLock layer, Shift is NOT carried through: every Shift
; variant is spelled out as +key.

; Any other key can have a layer of its own: add a section named after it
; and fill it in the same way. [LShift] with "-=?" makes left Shift + minus
; type a question mark while right Shift + minus still gives an underscore.
; Meant for the eight modifiers - LShift RShift LCtrl RCtrl LAlt LWin RWin
; (RAlt is the AltGr section above) - since any other key still types itself.
)"
    FileAppend(text "`n", g_configFile, "UTF-16")
    for layer in ["CapsLock", "Copilot", "AltGr"]
        WriteDefaultKeys(layer, false)
}

; Rewrites one [layer] section with the defaults; everything else in the file
; is left alone. clear removes the section first - a fresh ini has only the
; comment lines there and keeps them.
WriteDefaultKeys(layer, clear := true) {
    if clear
        try IniDelete(g_configFile, layer)
    for pair in DefaultKeys(layer)
        IniWrite(pair[2], g_configFile, layer, pair[1])
}

; The layout a fresh ini starts with, and what "Restore defaults" puts back.
; Ordered pairs rather than a Map: a Map enumerates sorted, and the ini reads
; better grouped by purpose. CapsLock: ijkl navigation with Alt for word- and
; page-wise moves, editing keys on the home row. Copilot: volume, media and
; brightness. AltGr: the left-hand number pad from Keyboard assistant's
; special-characters.ahk - digits on q w e / a s d / < z x, 0 on f, the
; operators around them, and F-keys or brackets on the Shift variants.
DefaultKeys(layer) {
    static caps := [
        ["i", "{Up}"], ["j", "{Left}"], ["k", "{Down}"], ["l", "{Right}"],
        ["u", "{Home}"], ["o", "{End}"], ["m", "{Enter}"],
        ["h", "{Backspace}"], ["sc027", "{Delete}"],
        [",", "{Wheelup}{Wheelup}{Wheelup}"], [".", "{Wheeldown}{Wheeldown}{Wheeldown}"],
        ["!i", "{PgUp}"], ["!k", "{PgDn}"], ["!j", "^{Left}"], ["!l", "^{Right}"],
        ["!u", "^{Home}"], ["!o", "^{End}"],
        ["!+i", "+{PgUp}"], ["!+k", "+{PgDn}"], ["!+j", "^+{Left}"], ["!+l", "^+{Right}"],
        ["!+u", "^+{Home}"], ["!+o", "^+{End}"],
        ["!h", "^{Backspace}"], ["^h", "^{Backspace}"], ["+h", "^{Backspace}"],
        ["!sc027", "^{Delete}"], ["^sc027", "^{Delete}"], ["+sc027", "^{Delete}"],
        ["v", "call:PasteShortPN"], ["d", "📅"], ["q", "?"]
    ], copilot := [
        ; Volume, media and brightness - these repeat, so the window stays open
        ["Up", "{Volume_Up}"], ["Down", "{Volume_Down}"], ["-", "{Volume_Mute}"],
        ["i", "{Volume_Up}"], ["k", "{Volume_Down}"], ["m", "{Volume_Mute}"],
        ["j", "{Media_Prev}"], ["l", "{Media_Next}"],
        ["p", "{Media_Play_Pause}"], ["Space", "{Media_Play_Pause}"],
        ["PgUp", "call:BrightnessUp"], ["PgDn", "call:BrightnessDown"],
        ; Programs - these close the window: one tap, one program
        ["s", "run:Spotify"], ["x", "run:Excel"], ["e", "call:LaunchEdge"],
        ["f", "call:LaunchSecureFolderFS"], ["c", "call:LaunchCalculator"],
        ["y", "call:LaunchStore"], ["t", "call:LaunchTeams"],
        ["o", "call:LaunchObsidian"], ["n", "call:LaunchObsidianNote"],
        ["+n", "call:LaunchObsidianNoteWindow"]
    ], altgr := [
        ; Digits: three rows of three, top row q w e, and 0 on f
        ["q", "1"], ["w", "2"], ["e", "3"],
        ["a", "4"], ["s", "5"], ["d", "6"],
        ["sc056", "7"], ["z", "8"], ["x", "9"],     ; sc056 is the < > | key
        ["f", "0"],
        ; Operators and editing around the digits
        ["r", "."], ["v", "."], ["t", "{+}"], ["g", "-"], ["b", "="],
        ["c", "{Enter}"], ["h", "{Backspace}"],
        ; Shift variants: brackets and F-keys where the digits are
        ["+q", "("], ["+w", ")"], ["+e", "{F3}"],
        ["+a", "{F4}"], ["+s", "{F5}"], ["+d", "{F6}"],
        ["+sc056", "|"], ["+z", "|"], ["+x", "{F9}"],
        ["+f", "{F10}"], ["+c", "{F11}"], ["+b", "{F12}"],
        ["+r", "/"], ["+v", ","],
        ; Characters
        ["i", "{U+1D62}"], ["y", "ŷ"]              ; subscript i, y with circumflex
    ]
    ; An ini-declared layer has no defaults: restoring it empties it, which
    ; is what removing the section means.
    return (layer = "CapsLock") ? caps : (layer = "Copilot") ? copilot
        : (layer = "AltGr") ? altgr : []
}

; Everything the Start menu can launch: display name plus AppUserModelID. That
; id is what makes a Store app launchable at all - it has no exe path to point
; at - and "explorer shell:AppsFolder\<id>" works for ordinary programs too, so
; the GUI can offer one list for both. Enumerated on demand (a few hundred
; items) rather than at startup, since only the Insert… menu ever needs it.
; Measured: 195 apps in 1.8 s, and that runs on the script's own thread - so it
; is done once per session and kept. The GUI shows "Reading the Start menu…"
; meanwhile; the second open is instant. A program installed after this ran
; shows up when Sostenuto is restarted.
InstalledApps() {
    static cache := 0
    if IsObject(cache)
        return cache
    list := []
    try {
        for app in ComObject("Shell.Application").NameSpace("shell:AppsFolder").Items
            list.Push(Map("name", app.Name, "id", app.Path))
    }
    return cache := list
}

; Functions the ini can name with call:, read from core\functions.ahk - and
; from functions.local.ahk beside it, if there is one - so the GUI's insert
; menu cannot drift from what exists. Parameterless ones only - call: passes
; nothing - and only those above the "Shared machinery" heading: what
; follows it is plumbing the other functions use (Launch, runApp,
; ModsBrief…), not something to put on a key.
FunctionList() {
    list := []
    for file in ["functions.ahk", "functions.local.ahk"] {
        try {
            for line in StrSplit(FileRead(A_ScriptDir "\core\" file, "UTF-8"), "`n", "`r") {
                if InStr(line, "Shared machinery")
                    break
                if RegExMatch(line, "^([A-Za-z_]\w*)\(\)\s*(\{|=>)", &m)
                    list.Push(m[1])
            }
        }
    }
    return list
}

; ── Layer includes ───────────────────────────────────────────────────────────
; Last, so everything above is defined when they load. #HotIf is reset after
; them: a layer that leaves a criterion active would silently apply it to
; anything defined later.


; ── Settings GUI (WebView2) ──────────────────────────────────────────────────
;  Same architecture as DeskPilot and DalSegno: one state object pushed into
;  window.receiveState, {action:...} messages posted back.
;
;  The window owns the INI FILE ONLY. The layer scripts are shown but not
;  edited here: they hold real logic - falling back from a Start menu name to
;  a path, resolving version-numbered install folders, Alt for word-wise
;  movement - which a table cannot express without becoming an editor for
;  code. The Layers tab reads the files so the overview cannot drift from
;  what actually applies.

OpenUi(*) {
    global g_uiWin, g_uiCtrl, g_uiCore
    if g_uiWin {
        g_uiWin.Show()
        FitUiToScreen()
        PushUiState()
        return
    }
    DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "str", "Sostenuto.App.1")
    g_uiWin := Gui("+Resize +MinSize640x460", "Sostenuto")
    g_uiWin.OnEvent("Close", (*) => (SaveUiGeometry(), g_uiWin.Hide()))
    g_uiWin.OnEvent("Size", UiResize)
    g_uiWin.Show(ReadUiGeometry())
    FitUiToScreen()
    DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g_uiWin.hwnd, "uint", 20, "int*", 1, "uint", 4)
    try {
        ico := LoadPicture(A_ScriptDir "\icons\tray.ico", "Icon1 w32 h32", &_t)
        SendMessage(0x80, 1, ico, , g_uiWin.hwnd)
        DllCall("SetClassLongPtr", "ptr", g_uiWin.hwnd, "int", -14, "ptr", ico)
    }
    try {
        ; Own user data folder. An empty one falls back to Edge's own profile,
        ; which cannot be shared with a running browser.
        dataDir := EnvGet("LOCALAPPDATA") "\Sostenuto\WebView2"
        try DirCreate(dataDir)
        g_uiCtrl := WebView2.create(g_uiWin.hwnd, , 0, dataDir, "", 0
            , A_ScriptDir "\lib\WebView2Loader.dll")
        g_uiCtrl.Fill()
        g_uiCore := g_uiCtrl.CoreWebView2
        g_uiCore.add_WebMessageReceived(UiMessage)
        g_uiCore.Navigate("file:///" StrReplace(A_ScriptDir "\ui\index.html", "\", "/"))
    } catch as e {
        g_uiWin.Destroy()
        g_uiWin := 0, g_uiCtrl := 0, g_uiCore := 0
        TrayTip("Could not start the GUI (" e.Message ")", "Sostenuto", "Iconx")
    }
}

UiResize(gui, minMax, w, h) {
    global g_uiCtrl
    if (minMax != -1 && IsObject(g_uiCtrl))
        try g_uiCtrl.Fill()
}

ReadUiGeometry() {
    w := 900, h := 640
    try {
        w := Integer(IniRead(g_configFile, "Window", "W", "900"))
        h := Integer(IniRead(g_configFile, "Window", "H", "640"))
    }
    x := IniRead(g_configFile, "Window", "X", "")
    y := IniRead(g_configFile, "Window", "Y", "")
    opt := "w" Max(640, w) " h" Max(460, h)
    return (x != "" && y != "") ? "x" x " y" y " " opt : opt
}

SaveUiGeometry() {
    global g_uiWin
    if !g_uiWin
        return
    try {
        if (WinGetMinMax(g_uiWin.hwnd) != 0)
            return
        ; position from the window rect, size from the CLIENT rect - Show("w...")
        ; sizes the client area, so storing the outer size grows the window
        WinGetPos(&x, &y, , , g_uiWin.hwnd)
        WinGetClientPos(, , &w, &h, g_uiWin.hwnd)
        IniWrite(x, g_configFile, "Window", "X"), IniWrite(y, g_configFile, "Window", "Y")
        IniWrite(w, g_configFile, "Window", "W"), IniWrite(h, g_configFile, "Window", "H")
    }
}

FitUiToScreen() {
    global g_uiWin
    if !g_uiWin
        return
    try {
        if (WinGetMinMax(g_uiWin.hwnd) != 0)
            return
        WinGetPos(&x, &y, &w, &h, g_uiWin.hwnd)
        MonitorGetWorkArea(MonitorOfWindow(g_uiWin.hwnd), &l, &t, &r, &b)
        w := Min(w, r - l), h := Min(h, b - t)
        WinMove(Min(Max(x, l), r - w), Min(Max(y, t), b - h), w, h, g_uiWin.hwnd)
    }
}

MonitorOfWindow(hwnd) {
    try {
        WinGetPos(&x, &y, &w, &h, hwnd)
        cx := x + w // 2, cy := y + h // 2
        loop MonitorGetCount() {
            MonitorGet(A_Index, &l, &t, &r, &b)
            if (cx >= l && cx < r && cy >= t && cy < b)
                return A_Index
        }
    }
    return MonitorGetPrimary()
}

UiSend(script) {
    global g_uiReady, g_uiCore
    if (!g_uiReady || !IsObject(g_uiCore))
        return
    try g_uiCore.ExecuteScriptAsync(script)
    catch
        g_uiReady := false
}

PushUiState() {
    global g_uiReady, g_capsMod, g_copilotMod, g_remaps, g_capsAltIsCtrl
    if !g_uiReady
        return
    remaps := Map()
    for layer, entries in g_remaps {
        m := Map()
        for k, v in entries
            m[k] := v
        remaps[layer] := m
    }
    state := Map(
        "caps", (g_capsMod != "" ? g_capsMod : "none")
        , "copilot", (g_copilotMod != "" ? g_copilotMod : "none")
        , "capsAltIsCtrl", (g_capsAltIsCtrl ? true : false)
        , "remaps", remaps
        , "order", g_layerOrder
        , "layers", LayerOverview()
        , "mismatch", PrefixMismatch()
        , "functions", FunctionList()
        , "window", COPILOT_WINDOW)
    UiSend("window.receiveState(" JSON.Dump(state) ")")
}

; Reads each layer file and lists what it binds. Parsed from the files rather
; than kept in a table here, so the overview cannot drift from what applies.
LayerOverview() {
    static notes := Map(
        "app-shortcuts.ahk", "Applications and web shortcuts. Two independent"
            . " layers: Alt+Win / Ctrl+Win, and the Copilot key.",
        "paste.ahk", "Paste helpers.",
        "local.ahk", "Your own hotkeys and hotstrings - one workplace's programs. Not in git.",
        "watchdog.ahk", "Releases stuck modifiers, and the Win+F5..F8 rescue keys.")
    list := []
    loop files A_ScriptDir "\layers\*.ahk" {
        binds := []
        try {
            for line in StrSplit(FileRead(A_LoopFileFullPath, "UTF-8"), "`n", "`r") {
                line := Trim(line)
                if (line = "" || SubStr(line, 1, 1) = ";")
                    continue
                ; a hotkey or hotstring is "<something>::" at the start of a line
                if RegExMatch(line, "^(:[^:]*:[^:]+|[^;\s][^:]*?)::", &m)
                    binds.Push(SubStr(m[1], 1, 24))
            }
        }
        list.Push(Map("file", A_LoopFileName, "count", binds.Length
            , "note", notes.Has(A_LoopFileName) ? notes[A_LoopFileName] : ""
            , "binds", binds))
    }
    return list
}

; A layer file spells its prefix out once and for all - >^x for RCtrl. Change
; CapsLockModifier away from that and every one of those hotkeys stops matching,
; silently, since an unmatched hotkey is not an error. Compare what the files
; bind against what is configured and say so.
;
; No layer does this today: navigation.ahk was the one that did, and its keys
; are [Keys] entries now, which follow the setting on their own. The check is
; kept for the next file that hardcodes a prefix.
PrefixMismatch() {
    static prefixOf := Map("LCtrl", "^", "RCtrl", ">^", "LAlt", "!", "RAlt", ">!"
        , "LShift", "+", "RShift", ">+", "LWin", "<#", "RWin", ">#")
    want := prefixOf.Has(g_capsMod) ? prefixOf[g_capsMod] : ""
    for layer in LayerOverview() {
        for b in layer["binds"] {
            ; only look at binds that start with a modifier prefix at all
            if !RegExMatch(b, "^\*?([<>]?[\^!+#]+)", &m)
                continue
            used := m[1]
            if (used = ">^" || used = "^") {
                if (used != want)
                    return Map("file", layer["file"], "used", used
                        , "want", (want != "" ? want : "none"))
                break
            }
        }
    }
    return ""
}

UiMessage(sender, args) {
    global g_uiReady
    try msg := JSON.Load(args.WebMessageAsJson)
    catch
        return
    switch msg["action"] {
        case "ready":
            g_uiReady := true
            PushUiState()
        case "setModifier":
            key := (msg["which"] = "CapsLock") ? "CapsLockModifier" : "CopilotModifier"
            IniWrite(msg["value"], g_configFile, "Settings", key)
            LoadConfig()
            InitTray()
            PushUiState()
        case "setCapsAltIsCtrl":
            IniWrite(msg["value"] ? "1" : "0", g_configFile, "Settings", "CapsAltIsCtrl")
            LoadConfig()
            PushUiState()
        case "saveKeys":
            UiSaveKeys(msg)
        case "resetKeys":
            layer := g_remaps.Has(msg["layer"]) ? msg["layer"] : "CapsLock"
            WriteDefaultKeys(layer)
            LoadConfig()
            InitTray()
            PushUiState()
            TrayTip("Defaults restored for " layer, "Sostenuto")
        case "listApps":
            UiSend("window.appList(" JSON.Dump(Map("rid", msg["rid"], "apps", InstalledApps())) ")")
        case "browse":
            ; A modal dialog: hotkeys and timers wait while it is open, so the
            ; CapsLock modifier is not re-asserted until it closes.
            path := ""
            try path := FileSelect(3, , "Program or file to run"
                , "Programs (*.exe; *.lnk; *.bat; *.cmd; *.ahk)")
            if (path != "")
                UiSend("window.browsed(" JSON.Dump(Map("layer", msg["layer"]
                    , "rid", msg["rid"], "value", 'run:"' path '"')) ")")
        case "openIni":
            try Run('notepad.exe "' g_configFile '"')
        case "openLayer":
            try Run('notepad.exe "' A_ScriptDir "\layers\" msg["file"] '"')
    }
}

; The sections are rewritten wholesale: a key removed in the GUI has to
; disappear from the file, and IniWrite alone only ever adds or replaces.
; The same goes for whole layers: every section that was a layer is removed
; first, so a layer the GUI no longer sends is gone from the file too.
UiSaveKeys(msg) {
    for name in g_layerOrder
        try IniDelete(g_configFile, name)
    for name in msg["order"] {
        try IniDelete(g_configFile, name)
        rows := msg["layers"][name]
        ; An empty built-in section is a choice (the AltGr defaults would
        ; otherwise come back on the next load); an empty extra one is not
        ; worth a header.
        if (rows.Length = 0 && !DefaultKeys(name).Length)
            continue
        IniWrite("", g_configFile, name)
        for row in rows
            IniWrite(row["value"], g_configFile, name, row["key"])
    }
    LoadConfig()
    InitTray()
    PushUiState()
    TrayTip("Keys saved", "Sostenuto")
}

; Infrastructure first, then the key layers. The two .local files hold what
; belongs to one workplace or machine; git ignores them, *i makes them
; optional, and each comes right after the generic file it extends.
#Include "core\watchdog.ahk"
#Include "core\functions.ahk"
#Include *i "core\functions.local.ahk"
#Include "layers\app-shortcuts.ahk"
#Include *i "layers\local.ahk"
#Include "layers\paste.ahk"
#HotIf
