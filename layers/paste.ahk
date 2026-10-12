#Requires AutoHotkey v2.0

; Klistrar in urklipp men normaliserar genomiska koordinater, t.ex.
;   "chr1:144,503,392-248,930,485"  ->  "144503392:248930485"
#+v::paste_special()

paste_special() {
    text := A_Clipboard
    ; chr<n> : <start> - <slut>, med valfria komma/punkt/mellanslag i koordinaterna
    monster := "i)(?<kromosom>chr\w+)\s*:\s*(?<start>[\d,.]+)\s*-\s*(?<slut>[\d,.]+)"
    if RegExMatch(text, monster, &match) {
        startRen := StrReplace(StrReplace(match.start, ","), ".")
        slutRen  := StrReplace(StrReplace(match.slut, ","), ".")
        SendInput startRen ":" slutRen
    } else {
        ToolTip "Ingen matchning hittades i urklipp!"
        SetTimer () => ToolTip(), -2000
    }
}
