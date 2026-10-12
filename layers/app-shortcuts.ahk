#Requires AutoHotkey v2.0

; InstallKeybdHook() is in Sostenuto.ahk - the umbrella installs the hook
; once, for every layer.

; =====================================================================
;  Win-chord launchers:  Alt+Win (!#), Ctrl+Win (^#), Shift+Win (+#)
;
;  What is left in this file. The Copilot layer that used to sit below has
;  moved into the ini's [Copilot] section, where the Keys tab can edit it -
;  the launches that need code are call: targets in core\functions.ahk now,
;  and everything machine-specific lives in class Cfg there. These chords
;  cannot move the same way: the ini has a CapsLock layer and a Copilot
;  layer, and no place to say "Alt+Win". Chords for one workplace's programs
;  go in layers\local.ahk (git-ignored, template local.ahk.example), which
;  is included after this file and can use WinHeld() below.
;
;  Every chord requires a PHYSICAL Win key. Without that guard a Win key
;  stuck logically down (the watchdog log shows LWin sticking many times a
;  day - injected by something in the hook chain, never physical) turns
;  Shift+CapsLock+L or Alt+CapsLock+L into Shift+Win+L / Alt+Win+L for the
;  few milliseconds RemapAction has the layer modifier lifted around its
;  Send - and AutoHotkey gives an exact-modifier hotkey precedence over the
;  wildcard *l of the CapsLock layer (hook.cpp sorts wildcard hotkeys first
;  so the exact ones overwrite their slot). That was "CapsLock+L opens a
;  program". A layer modifier that IS a Win key still counts, since that is
;  the whole point of configuring one.
; =====================================================================
WinHeld(*) => GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
    || (InStr(g_capsMod, "Win") && CapsHeld())
    || (InStr(g_copilotMod, "Win") && g_copilotDown)

#HotIf WinHeld()
; Programs
!#s::Launch("Spotify")
!#f::LaunchSecureFolderFS()
!#c::LaunchCalculator()
!#e::LaunchEdge()
!#y::LaunchStore()
!#t::LaunchTeams()
!#x::Launch("Notepad")
!#k::LaunchCalendar()

; Obsidian
!#o::LaunchObsidian()
!#n::LaunchObsidianNote()
+!#n::LaunchObsidianNoteWindow()
#HotIf

; =====================================================================
;  Miscellaneous
; =====================================================================
Shift & WheelDown::Click "WheelRight"
Shift & WheelUp::Click "WheelLeft"
