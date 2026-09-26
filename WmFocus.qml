pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// Keyboard focus on open for the OmaqBT window. See the Task 7 report for
// the investigation. In order, until the backing QQuickWindow reports
// `active`:
//  1. forceActiveFocus() on the key item (Qt-side focus inside the window);
//  2. QWindow.requestActivate() on the backing window, which Qt Wayland
//     turns into an xdg-activation token + activate request; Omarchy sets
//     misc.focus_on_activate = true, so Hyprland honors it;
//  3. wlr-foreign-toplevel `activate` on our own toplevel (Hyprland treats
//     that as a forced activation, the path window switchers use);
//  4. a Hyprland focus dispatch by address.
// After ~1.5 s it stops and logs which side refused, for the live check.
QtObject {
  id: wmFocus

  // The window to activate and the item that takes the keys inside it.
  required property FloatingWindow targetWindow
  required property Item keyItem

  // ---- diagnostics ---------------------------------------------------------
  property int focusAttempts: 0
  property bool focusActivateAsked: false

  function requestWmFocus() {
    keyItem.forceActiveFocus()
    focusAttempts = 0
    focusActivateAsked = false
    focusRetry.restart()
  }

  function ownHyprlandToplevel() {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || t.title !== targetWindow.title) continue
      var w = t.wayland
      if (w && w.appId && w.appId !== "org.quickshell") continue
      return t
    }
    return null
  }

  function ownWaylandToplevel() {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (t && t.title === targetWindow.title && t.appId === "org.quickshell") return t
    }
    return null
  }

  function focusStep() {
    if (!targetWindow.visible) {
      focusRetry.stop()
      return
    }
    // _backingWindow is Quickshell's QQuickWindow behind the proxy; qmllint
    // can't see it on FloatingWindow's declared type, hence the index form.
    var backing = targetWindow["_backingWindow"]
    if (backing && backing.active) {
      focusRetry.stop()
      keyItem.forceActiveFocus()
      console.info("OmaqBT window: keyboard focus after " + focusAttempts + " attempt(s)")
      return
    }
    focusAttempts = focusAttempts + 1
    try {
      // The backing window can connect a moment after the item exists, so
      // the xdg-activation request goes out on the first step that has one.
      if (!focusActivateAsked && backing) {
        focusActivateAsked = true
        backing.requestActivate()
      }
      if (focusAttempts === 1) {
        Hyprland.refreshToplevels()
      } else if (focusAttempts === 3) {
        var wl = ownWaylandToplevel()
        if (wl) wl.activate()
      } else if (focusAttempts === 6) {
        var hy = ownHyprlandToplevel()
        if (hy && hy.address) {
          var addr = String(hy.address)
          if (addr.indexOf("0x") !== 0) addr = "0x" + addr
          if (Hyprland.usingLua) Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })")
          else Hyprland.dispatch("focuswindow address:" + addr)
        }
      } else if (focusAttempts >= 15) {
        focusRetry.stop()
        var own = ownHyprlandToplevel()
        var active = Hyprland.activeToplevel
        console.warn("OmaqBT window: no keyboard focus after open."
          + " qt.active=" + (backing ? backing.active : "no-backing-window")
          + " hypr.activated=" + (own ? own.activated : "no-toplevel")
          + " hypr.address=" + (own ? own.address : "")
          + " hypr.activeTitle=" + (active ? active.title : "")
          + " foreignToplevel=" + (ownWaylandToplevel() !== null))
      }
    } catch (e) {
      console.warn("OmaqBT window: focus attempt " + focusAttempts + " threw: " + e)
    }
  }

  property Timer retry: Timer {
    id: focusRetry
    interval: 100
    repeat: true
    onTriggered: wmFocus.focusStep()
  }
}
