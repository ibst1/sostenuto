#Requires AutoHotkey v2.0

; =============================================================================
;  Functions reachable from the ini as  call:<name>
;
;  The ini expresses "this key sends these keys" well, and "run:<command>"
;  covers a plain launch. What it cannot express is a launch that needs to
;  think: activate a program if it is already open, resolve a version-numbered
;  install folder, fall back from a Start menu name to a path. Those live here
;  as one function each, and the ini names them - so the Keys tab stays the
;  one place that says which key does what, while the logic stays code. The
;  GUI's Insert… menu reads this file, so a function added here shows up there
;  by itself (parameterless ones - call: passes nothing).
;
;  Anything that belongs to one workplace or one machine - its programs,
;  addresses and paths - goes in core\functions.local.ahk instead, which git
;  ignores and Sostenuto includes if it exists. functions.local.ahk.example
;  is the template.
; =============================================================================

; ── Machine-specific values, the only place they are written ─────────────────
class Cfg {
    ; Programs
    static Edge     := "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
    static Teams    := "C:\Program Files (x86)\Microsoft\Teams\current\Teams.exe"

    ; Web addresses
    static Calendar  := "https://calendar.google.com/calendar/u/0/r/week"

    ; Obsidian: the QuickAdd choice a quick note runs, when the vault has one
    static ObsidianNoteChoice   := "Snabbanteckning"
    static ObsidianWindowChoice := "Snabbanteckning i nytt fönster"
}

; ── call: targets ───────────────────────────────────────────────────────────
LaunchCalendar()    => Launch(Cfg.Calendar)

; Store apps change version, so try the Start menu name first and fall back to
; a path where there is one.
LaunchEdge()            => runApp("Microsoft Edge", Cfg.Edge)
LaunchTeams()           => runApp("Teams", Cfg.Teams)
LaunchStore()           => runApp("Microsoft Store")
LaunchCalculator()      => runApp("Kalkylatorn med graffunktion")
LaunchSecureFolderFS()  => runApp("SecureFolderFS")

; ── Obsidian ────────────────────────────────────────────────────────────────
; Vaults are named, not numbered: obsidian://…?vault= takes the folder name
; as well as the id, and the id is per machine (Obsidian makes a new one when
; a vault is opened anywhere else), so the ids once written here pointed at
; nothing. The name is what the ini says:
;     call:LaunchObsidianVault(M)       open vault M
;     call:LaunchObsidianCapture(M)     quick note in vault M
;     call:LaunchObsidianCapture(M, Snabbanteckning i nytt fönster)
;                                       the same, opened in a new window
; Without an argument the two below ask which vault, from the list Obsidian
; keeps itself - a new vault shows up in the menu with nothing to edit here.
LaunchObsidian()     => ObsidianPick("Öppna valv", LaunchObsidianVault)
LaunchObsidianNote() => ObsidianPick("Snabbanteckning i", LaunchObsidianCapture)
LaunchObsidianNoteWindow() => ObsidianPick("Snabbanteckning i nytt fönster i"
    , (v) => LaunchObsidianCapture(v, Cfg.ObsidianWindowChoice))

LaunchObsidianVault(vault) => Launch("obsidian://open?vault=" UriEncode(vault))

; A quick note runs the vault's QuickAdd choice (Cfg.ObsidianNoteChoice, or
; the second argument) - it decides the folder, template and name. A vault
; without QuickAdd or without that choice still gets a note: Obsidian's own
; obsidian://new, named by the time, where the vault puts new notes.
LaunchObsidianCapture(vault, choice := Cfg.ObsidianNoteChoice) {
    if ObsidianHasChoice(vault, choice)
        Launch("obsidian://quickadd?vault=" UriEncode(vault) "&choice=" UriEncode(choice))
    else
        Launch("obsidian://new?vault=" UriEncode(vault) "&name=" UriEncode(FormatTime(, "yyyy-MM-dd HHmm")))
}

; ── Date and time ───────────────────────────────────────────────────────────
; The ini's right-hand column is keys in AutoHotkey's SEND SYNTAX, not code:
; there is no expression to evaluate, so "Send(FormatTime(...))" would be typed
; out literally. Anything computed belongs here and is named with call:.
InsertDate()     => TypeText(FormatTime(, "yyyy-MM-dd"))
InsertDateDots() => TypeText(FormatTime(, "yyMMdd"))
InsertDateTime() => TypeText(FormatTime(, "yyyy-MM-dd HH:mm"))
InsertTime()     => TypeText(FormatTime(, "HH:mm"))
InsertWeek()     => TypeText("v" FormatTime(, "YWeek"))   ; ISO year+week, e.g. v202636

; Paste a Swedish personal identity number without its century digits.
PasteShortPN() {
    found := RegExMatch(A_Clipboard, "(19|20)([0-9]{6}-?.{4})", &SubPtn)
    if found = 1
        A_Clipboard := SubPtn[2]
    Send "{Blind}^v"
}

; Screen brightness. Two wrappers rather than one function with an argument,
; because call: names a function and passes nothing.
BrightnessUp()   => Brightness(+5)
BrightnessDown() => Brightness(-5)

; The moniker is winmgmts:\\.\root\WMI with TWO backslashes - AutoHotkey does
; not escape with backslash, so the string is used verbatim. The port from
; media.ahk lost one, ComObjGet threw, and every call: showed "No such
; function" instead. The current level is read on every call rather than
; cached: the Fn keys change it behind our back, and a stale cache made the
; first press after them jump. Only the built-in panel exposes this class; on
; a docked laptop with the lid closed the query is empty and this throws -
; RemapAction shows the message.
Brightness(offset) {
    static wmi := 0
    if !wmi
        wmi := ComObjGet("winmgmts:\\.\root\WMI")
    cur := wmi.ExecQuery("SELECT * FROM WmiMonitorBrightness").ItemIndex(0).CurrentBrightness
    level := Min(100, Max(1, cur + offset))
    if (level != cur)
        wmi.ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods").ItemIndex(0).WmiSetBrightness(0, level)
}

; ── Shared machinery ────────────────────────────────────────────────────────
; Everything below this heading is plumbing for the functions above, and the
; GUI's Insert… menu stops reading here (FunctionList in Sostenuto.ahk).
; A new call: target therefore belongs ABOVE it.
; Starts target (exe, url, uri, .ahk…) but catches errors, so a broken or
; outdated path gives a discreet tooltip instead of an error box.
Launch(target) {
    if (target = "") {
        Notify("No program to start.`nCheck the path in class Cfg.")
        return
    }
    ; Every launch is logged with the modifier picture of that moment, so a
    ; program that opened "by itself" can be traced to the hotkey and the
    ; stuck key that fired it instead of being guessed at afterwards.
    try StuckLog("launch", A_ThisHotkey " -> " target "  [" ModsBrief() "]")
    try
        Run target
    catch
        Notify("Could not start:`n" target)
}

; Runs an .ahk script with the SAME interpreter as this one (AHK v2). Without
; this the Windows file association decides, and since .ahk has no registered
; default handler the "Open with" dialog appears every time. A_AhkPath is read
; at run time, so it follows along when AutoHotkey is updated.
RunAhk(scriptPath) {
    if !FileExist(scriptPath) {
        Notify("Cannot find the script:`n" scriptPath)
        return
    }
    Launch('"' A_AhkPath '" "' scriptPath '"')
}

; Resolves a program living in a version-numbered folder. Picks the most
; recently installed one, so the path survives updates. Returns "" if nothing
; is found (Launch then shows a tooltip).
NewestApp(baseDir, folderPattern, exeName) {
    best := "", bestTime := ""
    Loop Files, baseDir "\" folderPattern, "D" {
        t := FileGetTime(A_LoopFileFullPath, "M")
        if (bestTime = "" || t > bestTime) {
            bestTime := t
            best := A_LoopFileFullPath
        }
    }
    return (best != "") ? best "\" exeName : ""
}

; Starts an app by its Start menu display name, falling back to a path if the
; name is not found - robust when Store apps change version.
runApp(appName, fallback := "") {
    for app in ComObject("Shell.Application").NameSpace("shell:AppsFolder").Items {
        if (app.Name = appName) {
            Launch("explorer shell:AppsFolder\" app.Path)
            return
        }
    }
    if (fallback != "")
        Launch(fallback)
    else
        Notify("Could not find the app: " appName)
}

; Obsidian's own list of vaults, name -> folder. The name is the folder's
; last part, which is what obsidian://…?vault= matches on. Read on every
; call: it is a small file and Obsidian changes it behind our back.
ObsidianVaults() {
    vaults := Map()
    vaults.CaseSense := false
    file := EnvGet("APPDATA") "\obsidian\obsidian.json"
    try data := JSON.Load(FileRead(file, "UTF-8"))
    catch {
        Notify("Hittar inga Obsidian-valv:`n" file)
        return vaults
    }
    for id, v in data["vaults"] {
        SplitPath(v["path"], &name)
        vaults[name] := v["path"]
    }
    return vaults
}

; A menu of the vaults at the mouse, the first letter of each name its
; accelerator: Copilot, o, m opens vault M. The chosen name goes to action.
ObsidianPick(title, action) {
    vaults := ObsidianVaults()
    if !vaults.Count
        return
    m := Menu()
    m.Add(title, (*) => 0), m.Disable(title)
    for name, path in vaults
        m.Add("&" StrReplace(name, "&", "&&") "`t" path, ((n, *) => action(n)).Bind(name))
    m.Show()
}

; Whether the vault's QuickAdd has a choice by that name, at any depth (a
; choice inside a Multi is found by the URI too). Read from QuickAdd's own
; settings file, so a choice added in Obsidian counts at once.
ObsidianHasChoice(vault, choice) {
    vaults := ObsidianVaults()
    if !vaults.Has(vault)
        return false
    try data := JSON.Load(FileRead(vaults[vault] "\.obsidian\plugins\quickadd\data.json", "UTF-8"))
    catch
        return false
    has(list) {
        for c in list
            if (c["name"] = choice || (c.Has("choices") && has(c["choices"])))
                return true
        return false
    }
    return data.Has("choices") && has(data["choices"])
}

; Percent-encodes s as UTF-8 for a URI query value; letters, digits and
; -_.~ stay as they are.
UriEncode(s) {
    buf := Buffer(StrPut(s, "UTF-8")), StrPut(s, buf, "UTF-8"), out := ""
    Loop buf.Size - 1 {
        b := NumGet(buf, A_Index - 1, "UChar")
        out .= (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || InStr("-_.~", Chr(b))
            ? Chr(b) : Format("%{:02X}", b)
    }
    return out
}

Notify(msg, ms := 3000) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -ms)
}

; Types text from a call: function. The layer modifier is still held while the
; function runs - CapsLock IS right Ctrl - so it is lifted first, or the
; characters arrive as Ctrl chords and nothing is typed. KeepDown presses it
; back within 25 ms if the layer key is still down, so nothing is lost.
TypeText(s) {
    lift := ""
    for k in ["LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"]
        if GetKeyState(k)
            lift .= "{" k " up}"
    if (lift != "")
        Send "{Blind}" lift
    SendText(s)
}

; One line of modifier state, only the keys that are down: L = logically down
; (what hotkeys match on), P = physically down according to the hook.
ModsBrief() {
    s := ""
    for k in ["LCtrl", "RCtrl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin", "CapsLock", "F23"] {
        L := GetKeyState(k), P := GetKeyState(k, "P")
        if (L || P)
            s .= (s = "" ? "" : " ") k ":" (L ? "L" : "-") (P ? "P" : "-")
    }
    return (s = "" ? "no modifiers" : s) " copilot=" (g_copilotDown ? 1 : 0)
}
