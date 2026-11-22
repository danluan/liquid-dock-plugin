import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "DockModel.js" as DockModel

// An app dock that shows on floating workspaces. A floating workspace has no
// tiles to hand the apps out, so the dock gives back a place to find them:
// pinned apps, running apps, and a grid of every app.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // The shell only injects appLibrary into "menu"-kind plugins; fall back to
  // a local one so the app grid and launching pinned apps work.
  readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : localAppLibrary
  property LocalAppLibrary localAppLibrary: LocalAppLibrary { }

  // Plugin settings live outside the plugin directory (saving there reloads
  // the plugin): ~/.config/omarchy/danluan-dock.json
  //   mode:       "intellihide" (default) | "always"
  //   pinned:     desktop ids, in dock order
  //   material:   "liquid" (default, translucent glass) | "solid" (opaque)
  //   showApps:   app-grid button (default true)
  //   showTrash:  trash button (default true)
  //   indicators: running/focused dots under icons (default true)
  //   reduceTransparency: fully opaque surfaces (default false)
  //   titleRules: [{ match: "<regex>", app: "<desktop id>" }] — a window whose
  //               title matches goes to that app (e.g. a CLI running inside a
  //               terminal that marks its title); first match wins
  readonly property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/danluan-dock.json"
  readonly property var defaultPins: ["brave-browser", "org.gnome.Nautilus", "foot", "com.microsoft.VSCode", "spotify", "obsidian"]
  property var settings: ({})
  readonly property string mode: settings.mode === "always" ? "always" : "intellihide"
  readonly property bool intellihide: mode === "intellihide"
  readonly property string material: settings.material === "solid" ? "solid" : "liquid"
  readonly property bool showApps: settings.showApps !== false
  readonly property bool showTrash: settings.showTrash !== false
  readonly property bool showIndicators: settings.indicators !== false
  readonly property bool reduceTransparency: settings.reduceTransparency === true
  readonly property var dockConfig: ({ pinned: Array.isArray(settings.pinned) ? settings.pinned : null })
  readonly property var defaultDockConfig: ({ pinned: defaultPins })
  readonly property string position: "bottom"
  readonly property bool vertical: false

  function saveSettings(patch) {
    var next = Object.assign({}, root.settings, patch)
    root.settings = next
    settingsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function setMode(value) { root.saveSettings({ mode: value === "always" ? "always" : "intellihide" }) }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) root.settings = parsed
      } catch (e) {
        console.warn("danluan.dock: invalid settings file: " + e)
      }
    }
  }

  // The dock's order for the session, as desktop ids, set when the user moves
  // an app: a drag moves it, and keeping it in the dock puts it at the end. An
  // app the order does not know yet goes at the end. Pins are saved in this
  // order.
  property var order: []

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onSettingsChanged: pendingPins = null

  // Entries that can claim a terminal app's window: those run in a terminal,
  // and those that hand the terminal an app id of their own.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  // Title rules: compiled once per settings change.
  readonly property var titleRules: {
    var list = Array.isArray(settings.titleRules) ? settings.titleRules : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var rule = list[i]
      if (!rule || !rule.match || !rule.app) continue
      try { out.push({ re: new RegExp(String(rule.match)), app: String(rule.app) }) }
      catch (e) { console.warn("danluan.dock: invalid titleRules regex: " + rule.match) }
    }
    return out
  }

  function entryForTitle(title) {
    if (root.titleRules.length === 0 || !title) return null
    for (var i = 0; i < root.titleRules.length; i++) {
      if (root.titleRules[i].re.test(title)) {
        var entry = DesktopEntries.byId(root.titleRules[i].app)
        if (entry) return entry
      }
    }
    return null
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  readonly property var items: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })

    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForTitle(String(toplevel.title || "")) || root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        address: toplevels[i].address,
        // Size Hyprland already knows: lets the preview use the right aspect from frame one
        size: toplevels[i].lastIpcObject && toplevels[i].lastIpcObject.size ? toplevels[i].lastIpcObject.size : null,
        toplevel: toplevel
      })
    }

    return DockModel.orderItems(DockModel.buildItems(pinned, windows), root.order)
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.items.length; i++) byKey[root.items[i].key] = root.items[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  // The dock's slots follow this model rather than the items list itself, so
  // a slot survives a window opening or closing instead of being rebuilt
  // under the pointer, and a reorder moves slots rather than replacing them.
  property alias itemModel: itemModel

  ListModel { id: itemModel }

  onItemsChanged: syncItemModel()

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  function syncItemModel() {
    var keys = root.items.map(function(item) { return item.key })
    for (var i = 0; i < keys.length; i++) {
      if (i < itemModel.count && itemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < itemModel.count; j++) {
        if (itemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) itemModel.move(found, i, 1)
      else itemModel.insert(i, { key: keys[i] })
    }
    if (itemModel.count > keys.length) itemModel.remove(keys.length, itemModel.count - keys.length)
    root.settleLaunches()
  }

  // An app launched from the dock pulses its dot until a new window of it
  // shows up, or for ten seconds if none does.
  property var launches: ({})
  readonly property int launchTimeout: 10000

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var windows = item ? item.windows.length : 0
      if (windows > launch.windows || now - launch.at > root.launchTimeout) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  function iconFor(item) {
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    var src = root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
    // Themed fallback through Qt's icon provider (follows the GTK/Qt icon theme, then hicolor).
    return src && src.length > 0 ? src : ""
  }

  function iconNameFor(item) {
    var entry = entryFor(item)
    return entry && entry.icon ? String(entry.icon) : (item ? item.key : "")
  }

  function iconByName(name) {
    var src = root.appLibrary ? root.appLibrary.iconSource(name) : Quickshell.iconPath(name, true)
    return src && src.length > 0 ? src : ""
  }

  function launch(item) {
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    root.launchEntry(entry)
  }

  function launchEntry(entry) {
    if (entry && root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
  }

  function activate(item) {
    if (!item) return
    if (item.windows.length === 0) {
      root.launch(item)
      return
    }
    var monitor = Hyprland.focusedMonitor
    var workspaceId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var index = DockModel.pickWindow(item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: window.toplevel.activated }
    }), workspaceId)
    root.bringForward(item.windows[index])
  }

  // A window the dock brings forward lands on top of the others, focused; a
  // minimized one first comes back to the workspace in front of the user.
  function bringForward(window) {
    var address = String(window.address || "")
    if (!address) {
      window.toplevel.activate()
      return
    }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var steps = []
    var after = []
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (!(workspace >= 1)) return
      // A restored window is simply there again, without animating in.
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    var command = steps.map(dispatch).join(" && ")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    Util.execDetached(command)
  }

  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  function openApps() {
    appGrid.open()
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves an app to a slot in the dock's order, pinning it there; the pins are
  // saved in the new order. The index counts the slots once the app has left
  // its own.
  function placeAt(key, index) {
    if (!key) return
    root.order = DockModel.orderWithKeyAt(root.shownKeys(), key, index)
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    pinned[key] = true
    root.savePins(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  // A reorder shows at once; the saved config catches up after.
  function savePins(pins) {
    root.pendingPins = pins
    root.saveSettings({ pinned: pins })
  }

  function moveItem(fromIndex, toIndex) {
    if (fromIndex !== toIndex) root.placeAt(root.shownKeys()[fromIndex], toIndex)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index) {
    var from = root.shownKeys().indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index)
  }

  // Keeping an app in the dock puts it at the end; taking one out leaves it in
  // its slot while it still runs.
  function setPinned(key, pinned) {
    if (!key) return
    if (pinned) {
      root.placeAt(key, root.shownKeys().length)
    } else {
      root.pendingPins = root.pinnedKeys.filter(function(other) { return other !== key })
      root.saveSettings({ pinned: root.pendingPins })
    }
  }

  Component.onCompleted: syncItemModel()

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      }
    }
  }

  ShellIpc {
    target: "omarchy.dock"

    function refresh(): void {}
    function apps(): void { appGrid.toggle() }
  }

  // An app dragged out of the app grid: the grid holds the pointer and
  // reports where it is, and the dock on that screen shows where it would land.
  function dockOn(screen) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) return windows[i]
    }
    return null
  }

  function moveExternalDrag(screen, x, y) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) windows[i].moveExternalDrag(x, y)
      else windows[i].endExternalDrag()
    }
  }

  function dropExternalDrag(screen, x, y, key) {
    var target = root.dockOn(screen)
    if (target) target.dropExternalDrag(x, y, key)
    root.endExternalDrag()
  }

  function endExternalDrag() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].endExternalDrag()
  }

  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData

        screen: modelData
        dock: root
      }
    }
  }

  AppGrid {
    id: appGrid
    appLibrary: root.appLibrary
    dock: root
  }
}
