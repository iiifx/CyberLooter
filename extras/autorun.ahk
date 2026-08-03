; Autorun for Cyberpunk 2077 - double-tap forward to keep running.
;
; This is NOT part of the CyberLooter mod and does not touch the game at all.
; It is a plain AutoHotkey script that holds the forward key down for you.
;
; Why it lives outside the mod: the game's movement axes are read-only from
; scripts. Locomotion reads them through GetActionValue(n"MoveY") and nothing in
; the scripting API can write them back, so no Cyber Engine Tweaks mod can make
; the character move on its own. Mods that do it either ship a native C++ DLL or
; drive the key from outside, which is what this does.
;
; Requires AutoHotkey v2: https://www.autohotkey.com/
; Usage: double-click the file to run it, right-click the tray icon to quit.

#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------------------------------------------------------------- settings ---

GameWindow    := "ahk_exe Cyberpunk2077.exe"  ; only active while the game has focus
ForwardKey    := "w"                          ; must match the game's forward binding
DoubleTapMs   := 300                          ; max gap between the two taps
CancelKeys    := ["a", "s", "d"]              ; any of these stops autorun
ShowTooltip   := true                         ; brief on-screen confirmation

; ------------------------------------------------------------------- state ---

autorun := false
lastTap := 0

; ------------------------------------------------------------------- logic ---

StartAutorun() {
    global autorun
    if (autorun)
        return

    autorun := true
    Send "{" ForwardKey " down}"
    Notify("Autorun ON")
}

StopAutorun() {
    global autorun
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

; ------------------------------------------------------------------ hotkeys --
; The ~ prefix means the key still reaches the game normally - the script only
; watches it. Nothing is swallowed, so movement always behaves as usual.

#HotIf WinActive(GameWindow)

Hotkey "~*" ForwardKey, OnForwardDown
Hotkey "~*" ForwardKey " up", OnForwardUp

for key in CancelKeys
    Hotkey "~*" key, (*) => StopAutorun()

; Opening a menu should not leave the character jogging into a wall.
~*Escape:: StopAutorun()

#HotIf

OnForwardDown(*) {
    global lastTap, DoubleTapMs

    ; While running, a single tap is the natural way to stop.
    if (autorun) {
        StopAutorun()
        lastTap := 0
        return
    }

    if (A_TickCount - lastTap <= DoubleTapMs) {
        StartAutorun()
        lastTap := 0
        return
    }

    lastTap := A_TickCount
}

OnForwardUp(*) {
    ; The second tap of the pair is still physically held when autorun starts,
    ; so its release would cancel what we just began. Press the key again right
    ; after the physical release to keep the game seeing a continuous hold.
    if (autorun)
        Send "{" ForwardKey " down}"
}

; Alt-tabbing out with the key held would leave it stuck down in Windows.
SetTimer CheckFocus, 250

CheckFocus() {
    if (autorun && !WinActive(GameWindow))
        StopAutorun()
}

; Same on exit: never leave a key pressed behind.
OnExit((*) => autorun ? Send("{" ForwardKey " up}") : "")
