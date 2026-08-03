; Autorun for Cyberpunk 2077 - double-tap forward to keep running.
;
; This is NOT part of the CyberLooter mod and does not touch the game at all.
; It is a plain AutoHotkey script that holds the forward key down for you.
;
; Why it lives outside the mod: the game's movement axes are read-only from
; scripts. Locomotion reads them through GetActionValue(n"MoveY") and nothing in
; the scripting API can write them back, so no Cyber Engine Tweaks mod can make
; the character move on its own. Mods that manage it ship a native C++ DLL.
;
; Requires AutoHotkey v2: https://www.autohotkey.com/
; Usage: double-click the file to run it, right-click the tray icon to quit.

#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode "Input"

; ---------------------------------------------------------------- settings ---

GameWindow    := "ahk_exe Cyberpunk2077.exe"  ; only active while the game has focus
ForwardKey    := "w"                          ; must match the game's forward binding
DoubleTapMs   := 300                          ; max gap between the two taps
DodgeGuardMs  := 250                          ; see the note about dodge below
CancelKeys    := ["a", "s", "d"]              ; any of these stops autorun
ShowTooltip   := true                         ; brief on-screen confirmation

; The dodge guard exists because vanilla Cyberpunk already uses double-tap
; forward for a dodge roll:
;     <multitap action="DodgeForward" count="2" uptime="0.2" downtime="0.2" />
; The script therefore swallows the second tap entirely and only presses the key
; again after this delay, so the game never sees two taps close enough together
; to count as a dodge. 250 ms clears the game's 200 ms window with margin.

; ------------------------------------------------------------------- state ---

autorun  := false
lastTap  := 0
keyHeld  := false

; ------------------------------------------------------------------- logic ---

StartAutorun() {
    global autorun, ForwardKey, DodgeGuardMs

    autorun := true
    Notify("Autorun ON")

    ; Wait out the dodge window before taking over the key.
    SetTimer(EngageKey, -DodgeGuardMs)
}

EngageKey() {
    global autorun, ForwardKey

    if (autorun)
        Send "{" ForwardKey " down}"
}

StopAutorun() {
    global autorun, ForwardKey

    if (!autorun)
        return

    autorun := false
    Send "{" ForwardKey " up}"
    Notify("Autorun OFF")
}

Notify(text) {
    global ShowTooltip
    if (!ShowTooltip)
        return

    ToolTip text
    SetTimer () => ToolTip(), -900
}

; ----------------------------------------------------------------- hotkeys ---

#HotIf WinActive(GameWindow)

; Forward is intercepted rather than merely observed: the second tap has to be
; swallowed, otherwise the game reads it as a dodge.
Hotkey "$*" ForwardKey, OnForwardDown
Hotkey "$*" ForwardKey " up", OnForwardUp

; Cancel keys are only watched - the ~ prefix leaves them fully functional.
for key in CancelKeys
    Hotkey "~*" key, (*) => StopAutorun()

; Opening a menu should not leave the character jogging into a wall.
~*Escape:: StopAutorun()

#HotIf

OnForwardDown(*) {
    global autorun, lastTap, keyHeld, DoubleTapMs, ForwardKey

    if (keyHeld)        ; keyboard auto-repeat, not a new press
        return
    keyHeld := true

    ; While running, a single tap is the natural way to stop.
    if (autorun) {
        StopAutorun()
        lastTap := 0
        return
    }

    ; Second tap of the pair: swallowed, autorun takes over instead.
    if (A_TickCount - lastTap <= DoubleTapMs) {
        lastTap := 0
        StartAutorun()
        return
    }

    ; Ordinary press - pass it straight through to the game.
    lastTap := A_TickCount
    Send "{" ForwardKey " down}"
}

OnForwardUp(*) {
    global autorun, keyHeld, ForwardKey

    keyHeld := false

    ; While autorun holds the key, the physical release must not reach the game.
    if (autorun)
        return

    Send "{" ForwardKey " up}"
}

; Alt-tabbing out with the key held would leave it stuck down in Windows.
SetTimer CheckFocus, 250

CheckFocus() {
    global autorun, GameWindow
    if (autorun && !WinActive(GameWindow))
        StopAutorun()
}

; Same on exit: never leave a key pressed behind.
OnExit((*) => autorun ? Send("{" ForwardKey " up}") : "")
