#Requires AutoHotkey v2.0

; =============================================================================
;  Hook watchdog and rescue keys
;
;  Lifted from Keyboard assistant.ahk when its layers moved here. It is the
;  one piece of that script worth keeping: synthetic modifier combinations can
;  lose their key-up half when the machine is loaded, and a modifier stuck
;  down turns every keystroke into a chord. Today's session hit exactly that
;  more than once.
;
;  NOTE: CapsLock is deliberately absent from MODS below, and the configured
;  layer modifiers (g_capsMod / g_copilotMod, e.g. RCtrl and RWin) are
;  skipped in the loop. Sostenuto holds them down on purpose for as long
;  as the layer key is held, and has its own watchdog for them - a second
;  one here would read that intended state as stuck and drop the modifier
;  mid-navigation.
; =============================================================================

; --- Global keys -------------------------------------------------------
#SuspendExempt                           ; F5/F6 work even while hotkeys are paused
; F5/F6 require a PHYSICAL Win press. With a stuck (logical) Win key, an
; ordinary F5 - a browser refresh! - would otherwise become a reload that
; kills the watchdog mid-cleanup, and F6 would pause every hotkey. Without
; physical Win, the Win keys are released instead and the key is forwarded.
_PhysWin() => GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
_ReleaseWinsAndForward(key) {
    global MODS
    for m in MODS
        if ((m.name = "LWin" || m.name = "RWin") && GetKeyState(m.name))
            RawRelease(m)
    StuckLog("watchdog", "stuck Win at " key " -> released, key forwarded")
    Send "{" key "}"
}
#F5:: _PhysWin() ? ReloadApp() : _ReleaseWinsAndForward("F5")   ; Win+F5 = reload the script
#F6:: {                                  ; Win+F6 = pause/resume all hotkeys
    if !_PhysWin() {
        _ReleaseWinsAndForward("F6")
        return
    }
    Suspend(-1)
    ToolTip(A_IsSuspended ? "Hotkeys PAUSED  (Win+F6 resumes)" : "Hotkeys active again")
    SetTimer(() => ToolTip(), -2000)
}
#F7:: {                                  ; Win+F7 = modifier diagnosis
    ; Shows three layers per modifier: logical (what the active window
    ; believes), physical according to AHK's hook, and the OS async state. A
    ; row where they disagree is a stuck key - the triple says in which layer.
    global g_stuckLog, g_lastWdTick
    txt := ModStateText()
    ; Opening the diagnosis with a PHYSICAL Win+F7 naturally shows the Win
    ; rows as DOWN because of the gesture itself - flag it, or every
    ; diagnosis looks like a stuck Win.
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        txt .= "(NOTE: Win is physically held right now - by the Win+F7 press itself?)`n"
    txt .= "watchdog last tick: "
        . (g_lastWdTick ? A_TickCount - g_lastWdTick " ms ago" : "NEVER") "`n"
    StuckLog("diagnosis Win+F7", "`n" txt)
    ToolTip(txt "`n(logged in " g_stuckLog ")")
    SetTimer(() => ToolTip(), -8000)
}
#F8::_Rescue("Win+F8")                   ; Win+F8 = manual rescue
; Triple F8 within 1.2 s = the same rescue WITHOUT a modifier. Win+F8 needs
; Win, of course - but if the watchdog releases the stuck Win key first
; (case 1 takes 300 ms) a lone F8 becomes useless, and the CapsLock phantom
; holds no modifier at all. The ~ lets F8 through to the app as usual.
~F8:: {
    static hits := [], MAXAGE := 1200
    now := A_TickCount
    hits.Push(now)
    while (hits.Length && now - hits[1] > MAXAGE)
        hits.RemoveAt(1)
    if (hits.Length >= 3) {
        hits := []
        _Rescue("triple F8")
    }
}
_Rescue(source) {
    ; Releases everything logically down, reinstalls the hook (clearing the
    ; phantom state that case 3 would otherwise wait out) and turns caps off.
    global MODS, g_hookSince
    released := ""
    for m in MODS
        if GetKeyState(m.name) {
            RawRelease(m)
            released .= (released = "" ? "" : ", ") m.name
        }
    InstallKeybdHook(true, true)
    g_hookSince := A_TickCount
    if GetKeyState("CapsLock", "T")
        SetCapsLockState "Off"
    StuckLog("manual", source ": hook restart"
        . (released != "" ? ", released " released : ", nothing logically down"))
    ToolTip("Hook restarted" (released != "" ? " - released " released : ""))
    SetTimer(() => ToolTip(), -2500)
}
#SuspendExempt False

; CapsLock belongs to Sostenuto.ahk, which turns it into right Ctrl and
; swallows the down itself. No SetCapsLockState AlwaysOff anywhere any more:
; it would make the hook swallow the UP too, and that up is the witness the
; phantom cure in KeepDown lives on. The toggle is turned off below instead,
; whenever it is found on.

; --- Watchdog for stuck modifiers --------------------------------------
; Synthetic modifier combinations (Send "^{Left}", "{Blind}^c" and friends)
; can lose their key-up half when several scripts hold keyboard hooks at the
; same time (Expanto, DeskPilot, this script). Two variants:
;   1) The OS believes the modifier is down but AHK's hook saw the release.
;      Released with a raw keybd_event after two checks in a row (<= 300 ms):
;      a Send sequence in progress never holds a modifier that long.
;      Known source: DeskPilot's desktop switch sends ^#{Right}/^#{Left} - if
;      the up half is lost in the hook chain, LWin/LCtrl stick (the log's
;      pattern). Exempt: a key some process injected and still holds (a
;      software KVM driving this PC) - that is a hold, not a stuck key; see
;      the loop. Guard (2) still covers an injector that lost its up.
;   2) Long-term guard: a modifier that has been LOGICALLY down longer than
;      its limit is released whatever the hook claims about the physical
;      state - nobody holds Win for 15 s (Alt 60 s; Ctrl/Shift 120 s, so a
;      genuinely long Ctrl+click selection survives). The age is measured on
;      logically-down precisely because the hook's physical reading has
;      proven able to both phantom AND FLICKER: an earlier version counted
;      both-down time and reset it in the case (1) branch, so the flicker let
;      the two mechanisms reset each other forever (the morning log at 06:09:
;      every layer DOWN, watchdog alive, and still no action). If the hook
;      claimed physically-down at release time, it is reinstalled so the
;      phantom state is cleared.
;   3) The inverted phantom: the hook believes in a physical press but the OS
;      has the key UP. For a prefix key such as CapsLock that is normal WHILE
;      it is held (suppressed from the OS) - but if the state sticks, every d
;      becomes "Capslock & d" (the calendar-emoji symptom). A genuine prefix
;      hold does not last 45/60 s, after which the hook is reinstalled.
; Win+F8 OR three quick F8 = manual rescue: release + hook restart.
; Everything the watchdog does is logged to stuck-modifiers.log beside the
; script. Win+F7 shows the three state layers per modifier (diagnosis).
global MODS := [
    {name: "LCtrl" , vk: 0xA2, sc: 0x1D, ext: false},
    {name: "LShift", vk: 0xA0, sc: 0x2A, ext: false},
    {name: "RShift", vk: 0xA1, sc: 0x36, ext: false},
    {name: "LAlt"  , vk: 0xA4, sc: 0x38, ext: false},
    {name: "RAlt"  , vk: 0xA5, sc: 0x38, ext: true },
    {name: "LWin"  , vk: 0x5B, sc: 0x5B, ext: true },
    {name: "RWin"  , vk: 0x5C, sc: 0x5C, ext: true }
    ; RCtrl and CapsLock are deliberately NOT watched. Sostenuto holds
    ; right Ctrl down on purpose for as long as CapsLock is held, and has its
    ; own watchdog for it. A second watchdog here would read that intended
    ; state as stuck and drop the modifier mid-navigation.
]
; Per machine, NOT in the synced folder. Two computers share this directory
; through OneDrive, and an interleaved log sent the Encore hunt after the
; wrong cause twice before error.log was moved for the same reason.
global g_stuckLog := StuckLogPath()

StuckLogPath() {
    dir := EnvGet("LOCALAPPDATA") "\Sostenuto"
    try DirCreate(dir)
    catch
        return A_ScriptDir "\stuck-modifiers.log"
    return dir "\stuck-modifiers.log"
}
global g_lastWdTick := 0    ; when the watchdog last ran - Win+F7 shows the age
global g_hookSince := A_TickCount   ; hook (re)install time - the fast path waits 3 s after it
global g_downSince := Map() ; modifier -> tick when LOGICALLY-down began
global g_physSince := Map() ; modifier -> tick when hook-physical-without-logical began
StuckLog("start", "script started, PID " DllCall("GetCurrentProcessId"))
SetTimer(ReleaseStuckModifiers, 150)

; =====================================================================
;  Functions
; =====================================================================
ReleaseStuckModifiers() {
    global MODS, g_lastWdTick, g_downSince, g_physSince, g_hookSince
    g_lastWdTick := A_TickCount
    static stuck := Map()
    hookRestart := false
    ; Encore holds modifiers down synthetically at human pace during macro
    ; playback - the fast path (case 1) tore Ctrl out of a replayed Ctrl+C
    ; (the log at 09:18). Encore announces playback through a mutex: if it
    ; exists, the fast path pauses. The long-term guards (cases 2 and 3) keep
    ; counting.
    playing := false
    h := DllCall("OpenMutexW", "uint", 0x100000, "int", 0, "str", "Local\EncorePlayback", "ptr")
    if h {
        DllCall("CloseHandle", "ptr", h)
        playing := true
    }
    ; Ctrl+Alt+Delete, the lock screen and a UAC prompt run on another
    ; desktop. The hook sees the downs but not the ups, and a keybd_event from
    ; here does not reach that desktop - so the fast path fired every 150 ms
    ; for the whole visit without effect (65 lines in ten seconds after a
    ; Ctrl+Alt+Delete, 2026-09-07 08:55). If the input desktop cannot be
    ; opened it is not ours: wait, and release the moment it is back.
    static away := false
    hDesk := DllCall("OpenInputDesktop", "uint", 0, "int", 0, "uint", 0x1, "ptr")   ; DESKTOP_READOBJECTS
    if hDesk {
        DllCall("CloseDesktop", "ptr", hDesk)
        ; Back from the secure desktop. The hook saw every down before the
        ; switch and none of the ups on the other side - CapsLock pressed
        ; before Win+L and released on the lock screen is a phantom in the
        ; making. Nobody holds a key through a password: reinstall now.
        if away {
            away := false
            InstallKeybdHook(true, true)
            g_hookSince := A_TickCount
            StuckLog("watchdog", "input desktop back -> hook reinstalled (ups lost on the secure desktop)")
        }
    } else {
        playing := true
        away := true
    }
    ; Caps lock must never be ON: Sostenuto swallows the down that would toggle
    ; it. Windows silently bypasses slow hooks under load - a CapsLock press
    ; then slips through and the state sticks on until something turns it off.
    ; Do that here. (Off, not AlwaysOff: AlwaysOff swallows the up as well, and
    ; the up is the witness Sostenuto's phantom cure needs.)
    if GetKeyState("CapsLock", "T") {
        SetCapsLockState("Off")
        StuckLog("watchdog", "caps lock was ON -> turned off (a press slipped past the hook?)")
    }
    for m in MODS {
        k := m.name
        ; The layer modifiers are held down synthetically ON PURPOSE for as
        ; long as CapsLock / the Copilot key is held, and Sostenuto's own
        ; StuckWatchdog releases them. Read from the config, not hardcoded:
        ; with CopilotModifier=RWin this loop raw-released RWin every 300 ms
        ; while KeepDown re-pressed it every 25 ms - a fight the log showed as
        ; a burst of "RWin logically down" lines (2026-08-31 13:32).
        if (k = g_capsMod || k = g_copilotMod)
            continue
        logical := GetKeyState(k)
        physical := GetKeyState(k, "P")
        if !logical {
            if g_downSince.Has(k)
                g_downSince.Delete(k)
            stuck[k] := 0
            ; Case 3: hook-physical down without logical down. Normal for a
            ; suppressed prefix key WHILE it is held - but nobody holds
            ; CapsLock for 45 s (60 s for the rest). If the state sticks,
            ; every d becomes "Capslock & d". The only cure is to reset the
            ; hook.
            if physical {
                if !g_physSince.Has(k)
                    g_physSince[k] := A_TickCount
                ; 15 s for CapsLock: a genuine prefix hold (caps plus
                ; navigation) rarely lasts even that long, and the price of a
                ; false positive is only that the prefix lets go until caps is
                ; pressed again.
                if (A_TickCount - g_physSince[k] > (k = "CapsLock" ? 15000 : 60000)) {
                    hookRestart := true
                    StuckLog("watchdog", k " physical-per-hook down for "
                        . Round((A_TickCount - g_physSince[k]) / 1000)
                        . " s without logical down -> hook restart (phantom state)")
                    g_physSince.Delete(k)
                    ; Case 3 is the one the user EXPERIENCES (d -> calendar
                    ; emoji) - say that it was cleaned up, or the sudden fix
                    ; looks like magic.
                    ToolTip("Keyboard phantom cleared (" k ")")
                    SetTimer(() => ToolTip(), -2500)
                }
            } else if g_physSince.Has(k)
                g_physSince.Delete(k)
            continue
        }
        if g_physSince.Has(k)
            g_physSince.Delete(k)
        if !g_downSince.Has(k)
            g_downSince[k] := A_TickCount
        ; AltGr = RAlt + LCtrl injected by Windows: LCtrl is then legitimately
        ; logically down without a physical press. The exception applies ONLY
        ; to the fast path - the long-term guard below keeps counting, or
        ; LCtrl would go entirely unwatched if RAlt phantom-sticks in the hook.
        altgr := (k = "LCtrl" && GetKeyState("RAlt", "P"))
        ; A key that some process INJECTED and has not released is held, not
        ; stuck: a software KVM driving this PC (Glissando - the other
        ; computer's Alt+Tab arrives as an injected Alt, and this path cut it
        ; after two ticks, closing the switcher, 2026-09-11), or a script mid-
        ; sequence. The hook reads injected keys as physically UP, so it cannot
        ; tell the two apart; Raw Input can: an injected DOWN newer than the
        ; keyboard's last word on the key is a hold in progress. Fast path
        ; only, like AltGr - the long-term guard below still frees an injector
        ; that lost its up (and caps a remote Alt+Tab at a minute).
        ; Only for a key injected by something OTHER than an AutoHotkey script: an AutoHotkey injection is
        ; ours or a sibling's, and a lost up there is a bug to clean up in 300 ms as before - the replayed
        ; Alt that sat for 60 s on 2026-09-12 was exactly that.
        rawM := g_rawMods.Get(k, 0)
        injHeld := rawM && rawM.injDown && rawM.injTick > rawM.physTick && !RawIsAhk(rawM.injExtra)
        ; A key already held when the hook is installed is unknown to it and
        ; reads as physically UP - the LAlt "release" one second after the
        ; 2026-09-01 14:03 start was the user's Alt+Tab, not a stuck key. So
        ; the fast path waits 3 s after every (re)install of the hook.
        if (!physical && !altgr && !injHeld && !playing && A_TickCount - g_hookSince > 3000) {
            ; Case 1, the fast path: the hook saw the release but the OS
            ; missed it. Two ticks (no longer required to be consecutive - the
            ; hook's flicker must not reset the counter; it resets on key-up).
            stuck[k] := stuck.Get(k, 0) + 1
            if (stuck[k] >= 2) {
                RawRelease(m)   ; raw keybd_event: bypasses the whole hook chain
                stuck[k] := 0
                g_downSince.Delete(k)
                ; Context for finding the source: what was pressed last, which
                ; hotkey ran last and how long ago, and the two layer keys.
                ; The raw clause is the one that assigns blame: "keyboard
                ; never, injected down 300 ms ago by an AutoHotkey script" is
                ; a script that lost its up; "keyboard DOWN" is a hook that
                ; missed a real press.
                StuckLog("watchdog", k " logically down without physical press -> released (raw key-up)"
                    . "  [" RawModBrief(k) "; foreground " ForegroundExe()
                    . "; prior key " A_PriorKey ", last hotkey " A_ThisHotkey " " A_TimeSinceThisHotkey " ms ago"
                    . ", copilot=" (g_copilotDown ? 1 : 0) ", caps phys=" (GetKeyState("CapsLock", "P") ? 1 : 0) "]")
                continue
            }
        }
        ; Case 1b: the hook claims a PHYSICAL press, but Raw Input - which sees the keyboard itself - says the
        ; keyboard let go (or never pressed the key), and the last press came from an AutoHotkey script, ours or
        ; a sibling's, that never sent its up. A SendEvent through a long hook chain can lose its up AND leave the
        ; hook believing in a physical press; the fast path above then stays silent and the long-term guard below
        ; left Ctrl stuck for two minutes (LCtrl, 2026-09-28 15:29, "injected down by an AutoHotkey script,
        ; keyboard up"). The hook reads a sibling's injected keys as physically up, so "physical DOWN" together
        ; with a script's press is its phantom state, not a hand on the key: 3 s after both the keyboard's last
        ; word and the script's press, the key is released and the hook reset.
        if (physical && !altgr && !playing && rawM && !rawM.phys && rawM.injDown && RawIsAhk(rawM.injExtra)
            && rawM.injTick > rawM.physTick && A_TickCount - rawM.injTick > 3000
            && (!rawM.physTick || A_TickCount - rawM.physTick > 3000) && A_TickCount - g_hookSince > 3000) {
            RawRelease(m)
            hookRestart := true
            StuckLog("watchdog", k " held by a script's lost key-up (hook claims a physical press, the keyboard says up)"
                . " -> raw key-up + hook restart  [" RawModBrief(k) "; foreground " ForegroundExe() "]")
            g_downSince.Delete(k)
            stuck[k] := 0
            continue
        }
        ; Case 2, the long-term guard: logically down for longer than the limit.
        limitMs := (k = "LWin" || k = "RWin") ? 15000
                 : (k = "LAlt" || k = "RAlt") ? 60000
                 : (k = "CapsLock") ? 60000 : 120000   ; prefix navigation can be held a while
        if (A_TickCount - g_downSince[k] > limitMs) {
            RawRelease(m)
            if physical
                hookRestart := true   ; the hook lied - clear the phantom state
            StuckLog("watchdog", k " logically down for " Round((A_TickCount - g_downSince[k]) / 1000)
                . " s (physical per hook: " (physical ? "DOWN" : "up") ") -> raw key-up"
                . (physical ? " + hook restart" : "") "  [" RawModBrief(k) "; foreground " ForegroundExe() "]")
            g_downSince.Delete(k)
            stuck[k] := 0
        }
    }
    if hookRestart {
        InstallKeybdHook(true, true)
        g_hookSince := A_TickCount
    }
}

; Raw key-up event through keybd_event: bypasses every hook in the chain and
; corrects the OS logical state even when a hook swallowed the real release.
;
; A Win or Alt key released with nothing pressed in between is a Start-menu
; tap (or menu-bar activation) to Windows - so the rescue itself popped the
; Start menu, which reads as "the Win key is stuck" even after it was freed.
; A raw tap on the unassigned vkE8 first marks the press as used, the same
; trick PressDown uses for a tapped CapsLock. Raw as well, so no hook sees it.
RawRelease(m) {
    static KEYUP := 0x0002, EXTENDED := 0x0001
    if (InStr(m.name, "Win") || InStr(m.name, "Alt")) {
        DllCall("keybd_event", "UChar", 0xE8, "UChar", 0, "UInt", 0, "UPtr", 0)
        DllCall("keybd_event", "UChar", 0xE8, "UChar", 0, "UInt", KEYUP, "UPtr", 0)
    }
    DllCall("keybd_event", "UChar", m.vk, "UChar", m.sc
          , "UInt", KEYUP | (m.ext ? EXTENDED : 0), "UPtr", 0)
}

AsyncDown(vk) {
    return (DllCall("GetAsyncKeyState", "Int", vk, "Short") & 0x8000) != 0
}

; The program in front when a modifier was found stuck - one more clue to
; who lost the key-up.
ForegroundExe() {
    try return WinGetProcessName("A")
    return "?"
}

StuckLog(source, txt) {
    global g_stuckLog
    try
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") "  [" source "]  " txt "`r`n"
                 , g_stuckLog, "UTF-8")
}

ModStateText() {
    global MODS, g_downSince, g_physSince
    s := ""
    for m in MODS {
        L := GetKeyState(m.name)      ? "DOWN" : "up"
        P := GetKeyState(m.name, "P") ? "DOWN" : "up"
        A := AsyncDown(m.vk)          ? "DOWN" : "up"
        extra := (L != P) ? "  <-- disagrees" : ""
        if (g_downSince.Has(m.name))
            extra .= "  down for " Round((A_TickCount - g_downSince[m.name]) / 1000) " s"
        if (g_physSince.Has(m.name))
            extra .= "  hook-fantom? i " Round((A_TickCount - g_physSince[m.name]) / 1000) " s"
        s .= Format("{1:-7} logisk={2:-4} fysisk(hook)={3:-4} OS-async={4:-4}{5}`n"
                   , m.name, L, P, A, extra)
    }
    return s
}

ReloadApp() {
    TrayTip("Reloading 'Keyboard hacks'")
    Sleep 1000
    Reload
}


