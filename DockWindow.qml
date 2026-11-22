import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel

// One screen's macOS-style glass dock: bottom center, magnification, intellihide.
// The surface is full width and tall enough for magnified icons, tooltips and
// menus; its input mask is limited to what is actually visible.
PanelWindow {
  id: window

  property var dock: null

  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1

  // ------------------------------------------------------------ geometry
  // Geometry comes from the design tokens (DockTokens.qml).
  readonly property DockTokens tk: DockTokens {
    material: window.dock ? window.dock.material : "liquid"
    reduceTransparency: window.dock ? window.dock.reduceTransparency : false
    indicators: window.dock ? window.dock.showIndicators : true
  }
  readonly property int iconSize: tk.iconSize                         // 40
  readonly property real maxMag: tk.hoverScale                        // magnification is a transform only
  readonly property int baseW: tk.slotSize + tk.dockGap - 2           // slot + gap
  readonly property int slotGap: baseW - iconSize
  readonly property int pad: tk.dockPadding - (baseW - tk.slotSize) / 2  // pill edge -> slot = dockPadding
  // trailing slots (app grid, trash) are optional
  readonly property int trailing: (dock && dock.showApps ? 1 : 0) + (dock && dock.showTrash ? 1 : 0)
  readonly property int sepW: trailing > 0 ? 18 : 0
  readonly property int topPad: tk.dockPadding + (tk.slotSize - tk.iconSize) / 2   // 12
  readonly property int dotZone: tk.dockPadding + (tk.slotSize - tk.iconSize) / 2  // 12
  readonly property int restH: topPad + iconSize + dotZone            // fixed height: hover never resizes the dock
  readonly property int gap: 8                      // between pill and screen edge
  readonly property int radius: tk.radiusDock
  // immediate neighbours grow only slightly
  readonly property real falloffRadius: baseW * 1.6
  readonly property int dragThreshold: 6
  readonly property int removeDistance: 70          // drag this far above the pill to remove

  readonly property int appCount: dock ? dock.itemModel.count : 0
  // An app dragged in from the app grid opens a gap where it would land.
  readonly property int appSlots: appCount + (insertIndex >= 0 && dragFrom < 0 ? 1 : 0)
  // Separator position in slot units; animated so the dock widens smoothly.
  property real sepPos: appSlots
  Behavior on sepPos { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
  readonly property real restW: pad * 2 + (sepPos + trailing) * baseW + sepW
  readonly property real restLeft: (width - restW) / 2

  // ------------------------------------------------------------ state
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      if (!t.workspace || t.workspace.id !== workspaceId) continue
      var ipc = t.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && fullscreenMode < 2
  property bool revealed: false
  property bool gridOpen: false
  property var menuItem: null
  property Item menuSlot: null
  property bool settingsMenu: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu

  // A window overlaps the resting dock rectangle (layout coordinates).
  property int revision: 0
  readonly property bool overlapped: {
    revision
    if (!monitor || !screen) return false
    var mi = monitor.lastIpcObject
    var mx = mi && mi.x !== undefined ? mi.x : monitor.x
    var my = mi && mi.y !== undefined ? mi.y : monitor.y
    var left = mx + (screen.width - restW) / 2 - 8
    var right = left + restW + 16
    var top = my + screen.height - gap - restH - 8
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var t = toplevels[i]
      var ipc = t.lastIpcObject
      if (!ipc || !t.workspace || t.workspace.id !== workspaceId) continue
      if (ipc.mapped === false || ipc.hidden === true) continue
      var at = ipc.at, size = ipc.size
      if (!at || !size) continue
      if (at[0] < right && at[0] + size[0] > left && at[1] + size[1] > top && at[1] < my + screen.height) return true
    }
    return false
  }

  readonly property bool tucked: dock && dock.intellihide && overlapped && !(revealed || menuOpen || gridOpen || dragging)
  readonly property bool contentShown: shown && !tucked

  // ------------------------------------------------------------ pointer
  property bool pointerIn: false
  property real pointerX: 0
  property real pointerY: 0
  property Item hoverSlot: null

  // ------------------------------------------------------------ window previews
  // Hover an app with 1+ windows: live thumbnails of each, click to focus, × to close.
  readonly property int previewMin: 1
  property Item previewSlot: null
  readonly property var previewItem: previewSlot && previewSlot.modelData ? previewSlot.modelData : null
  readonly property bool previewOpen: previewItem !== null && previewItem.windows.length >= previewMin
  property Item previewCandidate: null
  // last slot with a preview: the popup stays there (with its content) while it fades out
  property Item anchorSlot: null
  onPreviewSlotChanged: if (previewSlot) anchorSlot = previewSlot
  function slotWindows(slot) { return slot && slot.modelData ? slot.modelData.windows.length : 0 }
  onHoverSlotChanged: {
    if (hoverSlot && !dragging && !menuOpen && slotWindows(hoverSlot) >= previewMin) {
      previewHideTimer.stop()
      if (previewSlot) previewSlot = hoverSlot          // already open: switch right away
      else { previewCandidate = hoverSlot; previewShowTimer.restart() }
    } else {
      previewShowTimer.stop()
      if (previewSlot) previewHideTimer.restart()
    }
  }
  onMenuOpenChanged: if (menuOpen) previewSlot = null
  onDraggingChanged: if (dragging) previewSlot = null
  Timer {
    id: previewShowTimer
    interval: window.tk.popupOpenDelay
    onTriggered: if (window.hoverSlot === window.previewCandidate) window.previewSlot = window.previewCandidate
  }
  Timer {
    id: previewHideTimer
    interval: window.tk.popupCloseGrace
    onTriggered: {
      if (previewHover.hovered) return
      if (window.hoverSlot && window.slotWindows(window.hoverSlot) >= window.previewMin) return
      window.previewSlot = null
      if (!window.pointerIn) hideTimer.restart()
    }
  }
  property Item pressSlot: null
  property int pressButton: 0
  property point pressPos: Qt.point(0, 0)

  // Internal reorder: the app at dragFrom is carried by the pointer and the
  // others make room at dragTo.
  property int dragFrom: -1
  property int dragTo: -1
  property string dragKey: ""
  property point grabOffset: Qt.point(0, 0)   // pointer minus the grabbed icon's center
  readonly property bool dragging: dragFrom >= 0
  readonly property bool removing: dragging && pointerY < body.y - removeDistance
                                   && !!dock && dock.isPinned(dragKey)
  // External drag from the app grid: the slot index the app would land at.
  property int insertIndex: -1

  // The rendered pointer and magnification amount chase their targets every
  // frame, so the wave follows the pointer smoothly instead of stepping with
  // each motion event, and grows/shrinks in and out of the dock.
  readonly property real amountTarget: ((pointerIn && !menuOpen && !removing) || insertIndex >= 0) ? 1 : 0
  property real smoothX: 0
  property real amount: 0

  readonly property bool animating: Math.abs(smoothX - pointerX) > 0.05 || Math.abs(amount - amountTarget) > 0.0005

  FrameAnimation {
    running: window.animating && window.visible
    onTriggered: window.step(frameTime)
  }

  function step(dt) {
    if (Style.reduceMotion || dt <= 0 || dt > 0.25) {
      smoothX = pointerX
      amount = amountTarget
      return
    }
    // Critically damped-ish exponential follow, frame-rate independent.
    var kx = 1 - Math.exp(-dt / 0.022)
    var ka = 1 - Math.exp(-dt / (amountTarget > amount ? 0.035 : 0.08))
    smoothX += (pointerX - smoothX) * kx
    amount += (amountTarget - amount) * ka
    if (Math.abs(smoothX - pointerX) <= 0.05) smoothX = pointerX
    if (Math.abs(amount - amountTarget) <= 0.0005) amount = amountTarget
  }

  // ------------------------------------------------------------ layout math
  // Slots register themselves so the layout can sum their widths.
  property var slots: []
  function registerSlot(s) { slots = slots.concat([s]) }
  function unregisterSlot(s) { slots = slots.filter(function(o) { return o !== s }) }

  // Separator offset for a (possibly fractional, mid-animation) slot position.
  function sepAdj(d) { return Math.max(0, Math.min(1, d - (sepPos - 1))) * sepW }

  function restCenter(d) { return restLeft + pad + d * baseW + baseW / 2 + sepAdj(d) }

  function magFor(d) {
    var dist = Math.abs(smoothX - restCenter(d))
    if (amount <= 0 || dist >= falloffRadius) return 1
    var f = (Math.cos(Math.PI * dist / falloffRadius) + 1) / 2
    return 1 + (maxMag - 1) * amount * f
  }

  // Magnification is a transform only: the dock never changes size.
  function extraBefore(d) { return 0 }
  readonly property real totalExtra: 0

  function displayIndexOf(i) {
    if (dragFrom >= 0 && dragTo >= 0) {
      if (i === dragFrom) return dragTo
      if (dragFrom < dragTo && i > dragFrom && i <= dragTo) return i - 1
      if (dragTo < dragFrom && i >= dragTo && i < dragFrom) return i + 1
      return i
    }
    if (insertIndex >= 0 && i >= insertIndex) return i + 1
    return i
  }

  // Rest-layout slot index nearest to a window x, for drop targets.
  function restIndexAt(x, count) {
    var i = Math.round((x - restLeft - pad - baseW / 2) / baseW)
    return Math.max(0, Math.min(count, i))
  }

  function slotAt(x) {
    for (var i = 0; i < slots.length; i++) {
      var s = slots[i]
      if (!s.visible || s.dragGhosted || s.opacity < 0.5) continue
      var l = body.x + s.x
      if (x >= l && x < l + s.width) return s
    }
    return null
  }

  // ------------------------------------------------------------ pointer handling
  function pointerMoved(x, y) {
    if (!pointerIn || amount < 0.02) smoothX = x   // grow from where the pointer is, not where it left
    pointerX = x
    pointerY = y
    if (pressSlot && !dragging && pressButton === Qt.LeftButton && pressSlot.appKey !== ""
        && Math.hypot(x - pressPos.x, y - pressPos.y) > dragThreshold) {
      dragKey = pressSlot.appKey
      grabOffset = Qt.point(pressPos.x - (body.x + pressSlot.x + pressSlot.width / 2),
                            pressPos.y - (body.y + pressSlot.iconTop + window.iconSize * pressSlot.mag / 2))
      dragTo = pressSlot.modelIndex
      dragFrom = pressSlot.modelIndex
      closeMenu()
    }
    if (dragging) dragTo = restIndexAt(x, appCount - 1)
    hoverSlot = dragging ? null : slotAt(x)
  }

  function pressAt(x, y, button) {
    pointerMoved(x, y)
    pressSlot = slotAt(x)
    pressButton = button
    pressPos = Qt.point(x, y)
  }

  function releaseAt(x, y, button) {
    if (dragging) {
      finishDrag()
    } else if (pressSlot && button === pressButton && slotAt(x) === pressSlot) {
      pressSlot.triggered(button)
    }
    pressSlot = null
    pressButton = 0
  }

  function finishDrag() {
    var from = dragFrom, to = dragTo, key = dragKey, remove = removing
    if (remove) {
      dragFrom = -1; dragTo = -1; dragKey = ""
      dock.setPinned(key, false)
    } else {
      if (dock) dock.moveItem(from, to)     // the model moves first, so slots don't jump
      dragFrom = -1; dragTo = -1; dragKey = ""
    }
    hoverSlot = slotAt(pointerX)
    if (!pointerIn) hideTimer.restart()
  }

  function cancelDrag() {
    dragFrom = -1; dragTo = -1; dragKey = ""
    pressSlot = null
  }

  // ------------------------------------------------------------ external drag (app grid)
  // Coordinates are the grid panel's, which covers the screen.
  function moveExternalDrag(x, y) {
    if (!window.shown) return
    var wy = y - (screen.height - window.height)
    var near = wy >= body.y - 70 && x >= body.x - 50 && x <= body.x + body.width + 50
    if (!near) { insertIndex = -1; return }
    revealed = true
    if (insertIndex < 0) smoothX = x
    pointerX = x
    insertIndex = restIndexAt(x, appCount)
  }
  function dropExternalDrag(x, y, key) {
    if (insertIndex >= 0 && key && window.dock) window.dock.pinAt(key, insertIndex)
  }
  function endExternalDrag() {
    insertIndex = -1
    if (!pointerIn) hideTimer.restart()
  }

  function openMenu(item, slot) {
    window.settingsMenu = false
    window.menuItem = item
    window.menuSlot = slot
  }
  function openSettingsMenu(slot) {
    window.menuItem = null
    window.settingsMenu = true
    window.menuSlot = slot
  }
  function closeMenu() {
    window.menuItem = null
    window.settingsMenu = false
    window.menuSlot = null
    hideTimer.restart()
  }

  onShownChanged: if (!shown) { closeMenu(); cancelDrag(); revealed = false }

  // ------------------------------------------------------------ surface
  visible: !remapGuard.remapping
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: 0

  anchors { bottom: true; left: true; right: true }
  implicitWidth: 0
  implicitHeight: Math.max(gap + restH + 64 + Style.spacing.popupRowHeight * 5 + 40, gap + restH + 260)

  mask: Region {
    item: window.contentShown ? hitBox : null
    Region { item: window.shown && window.tucked ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
    Region { item: preview.visible ? preview : null }
  }

  ScreenMoveRemap { id: remapGuard; window: window }

  HyprlandFocusGrab {
    active: window.menuOpen
    windows: [window]
    onCleared: window.closeMenu()
  }

  // Refresh Hyprland's window geometry when windows move, and poll slowly for
  // floating drags, which emit no events of their own.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (["openwindow", "closewindow", "movewindow", "movewindowv2", "workspace", "workspacev2",
           "changefloatingmode", "fullscreen", "focusedmon", "activewindowv2", "windowtitlev2", "movetoworkspace"].indexOf(name) >= 0)
        refreshTimer.restart()
    }
  }
  Timer {
    id: refreshTimer
    interval: 40
    onTriggered: Hyprland.refreshToplevels()
  }
  Timer {
    interval: 800
    repeat: true
    running: !!window.dock && window.dock.intellihide && window.shown
    onTriggered: Hyprland.refreshToplevels()
  }
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { window.revision++ }
  }
  Connections {
    target: window.monitor
    ignoreUnknownSignals: true
    function onLastIpcObjectChanged() { window.revision++ }
  }
  onWorkspaceIdChanged: revision++

  Timer {
    id: hideTimer
    interval: 350
    onTriggered: if (!window.pointerIn && !edgeHover.hovered && !window.menuOpen && !window.previewOpen && !window.dragging && window.insertIndex < 0) window.revealed = false
  }

  // Bottom-edge hot zone that brings a tucked dock back.
  Item {
    id: edgeTrigger
    height: 4
    width: window.restW + 240
    x: Math.round((window.width - width) / 2)
    y: window.height - height
    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }
  }

  // Fixed footprint of the pill at full magnification: input mask and the one
  // place all pointer input is handled (hover, click, drag).
  Item {
    id: hitBox
    readonly property real extraW: (window.maxMag - 1) * window.iconSize * 2.2
    width: window.restW + extraW
    height: window.restH + (window.maxMag - 1) * window.iconSize + 6
    x: Math.round((window.width - width) / 2)
    y: window.height - window.gap - height

    MouseArea {
      id: pointerArea
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      cursorShape: window.dragging ? Qt.ClosedHandCursor : (window.hoverSlot ? Qt.PointingHandCursor : Qt.ArrowCursor)

      readonly property bool engaged: containsMouse || pressed
      onEngagedChanged: {
        window.pointerIn = engaged
        if (engaged) window.revealed = true
        else {
          window.hoverSlot = null
          hideTimer.restart()
        }
      }
      onPositionChanged: function(mouse) { window.pointerMoved(hitBox.x + mouse.x, hitBox.y + mouse.y) }
      onPressed: function(mouse) { window.pressAt(hitBox.x + mouse.x, hitBox.y + mouse.y, mouse.button) }
      onReleased: function(mouse) { window.releaseAt(hitBox.x + mouse.x, hitBox.y + mouse.y, mouse.button) }
      onCanceled: window.cancelDrag()
    }
  }

  // ------------------------------------------------------------ pill
  Item {
    id: body
    width: window.restW + window.totalExtra
    height: window.restH
    x: (window.width - width) / 2
    property real tuck: window.tucked ? height + window.gap + 20 : 0
    y: window.height - window.gap - height + tuck
    opacity: window.shown ? 1 : 0

    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 160 : 220)
        easing.type: Easing.OutCubic
      }
    }

    // Dock surface (see DockTokens).
    SolidSurface {
      id: glass
      anchors.fill: parent
      radius: window.radius
      fill: window.tk.surfaceBase
      shadows: window.tk.shadowDock
    }

    // Slots are laid out in body coordinates from their (animated) display
    // position plus the room magnification gives the slots before them.
    // Icons grow upward out of the pill, like macOS.
    Item {
      id: slotLayer
      anchors.fill: parent

      Repeater {
        id: appRepeater
        model: window.dock ? window.dock.itemModel : null
        delegate: AppSlot {}
      }

      Rectangle {
        id: separator
        visible: window.trailing > 0
        width: 1
        height: window.iconSize * 0.7
        color: Qt.rgba(1, 1, 1, 0.22)
        x: window.pad + window.sepPos * window.baseW + window.extraBefore(window.sepPos - 0.5) + (window.sepW - 1) / 2
        y: body.height - window.dotZone - window.iconSize + (window.iconSize - height) / 2
      }

      AppsSlot { visible: !!window.dock && window.dock.showApps; targetDisp: window.sepPos }
      TrashSlot { visible: !!window.dock && window.dock.showTrash; targetDisp: window.sepPos + (window.dock && window.dock.showApps ? 1 : 0) }

    }
  }

  // ------------------------------------------------------------ slots
  component Slot: Item {
    id: slot

    property string label: ""
    property string appKey: ""      // set for app slots: those can be dragged
    property int modelIndex: -1
    property real targetDisp: 0
    property real disp: targetDisp
    property bool animateDisp: true
    Behavior on disp {
      enabled: slot.animateDisp
      NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
    }
    property bool dragGhosted: false
    property real lift: 0           // launch bounce, px
    readonly property real mag: window.magFor(disp)
    readonly property real extra: (mag - 1) * window.iconSize
    readonly property bool pressed: window.pressSlot === slot && !window.dragging
    readonly property bool hovered: window.hoverSlot === slot
    readonly property real iconTop: iconHolder.y
    default property alias content: iconHolder.data
    signal triggered(int button)

    width: window.baseW
    height: body.height
    x: window.pad + disp * window.baseW + window.sepAdj(disp) + window.extraBefore(disp)
    z: hovered ? 2 : 1

    Component.onCompleted: window.registerSlot(slot)
    Component.onDestruction: window.unregisterSlot(slot)

    // Slot background on hover/press (concentric with the dock radius).
    Rectangle {
      width: window.tk.slotSize
      height: width
      radius: window.tk.radiusSlot
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - window.dotZone - window.iconSize - (window.tk.slotSize - window.iconSize) / 2
      color: slot.pressed ? window.tk.surfaceActive : (slot.hovered ? window.tk.surfaceHover : "transparent")
      Behavior on color { ColorAnimation { duration: window.tk.durationFast } }
    }

    // Icon: fixed size; magnification and press are a scale from the bottom.
    Item {
      id: iconHolder
      width: window.iconSize
      height: width
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - window.dotZone - height - slot.lift
      transformOrigin: Item.Bottom
      // magnification is already smoothed per frame (step()); only the press animates here
      property real pressK: slot.pressed ? window.tk.pressScale : 1
      Behavior on pressK { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
      scale: slot.mag * pressK
      opacity: slot.dragGhosted ? 0 : 1
    }
  }

  // Image that walks a list of candidate sources when one fails to load, so
  // apps resolve even before the configured icon theme (WhiteSur) has them.
  component FallbackImage: Image {
    id: fi
    property string primary: ""
    property string iconName: ""
    property int attempt: 0
    property bool active: true
    readonly property var candidates: {
      var out = []
      if (primary) out.push(primary)
      var n = iconName
      if (n && n.charAt(0) !== "/" && n.indexOf("://") < 0) {
        var base = "file:///usr/share/icons/"
        out.push(base + "hicolor/scalable/apps/" + n + ".svg")
        var sizes = ["512x512", "256x256", "128x128", "64x64", "48x48"]
        for (var i = 0; i < sizes.length; i++) out.push(base + "hicolor/" + sizes[i] + "/apps/" + n + ".png")
        out.push(base + "Adwaita/scalable/places/" + n + ".svg")
        out.push("file:///usr/share/pixmaps/" + n + ".png")
        out.push("file:///usr/share/pixmaps/" + n + ".svg")
      }
      out.push(base2 + "hicolor/scalable/apps/application-x-executable.svg")
      return out
    }
    readonly property string base2: "file:///usr/share/icons/"
    onCandidatesChanged: attempt = 0
    source: active ? candidates[Math.min(attempt, candidates.length - 1)] : ""
    onStatusChanged: if (status === Image.Error && attempt < candidates.length - 1) attempt++
    sourceSize: Qt.size(128, 128)
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    mipmap: true
  }

  component AppSlot: Slot {
    id: appSlot

    required property int index
    required property string key
    readonly property var modelData: window.dock ? window.dock.itemFor(key) : null
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property var entry: window.dock ? window.dock.entryFor(modelData) : null
    appKey: key
    modelIndex: index
    targetDisp: window.displayIndexOf(index)
    dragGhosted: window.dragFrom === index
    label: entry ? String(entry.name || key) : key

    // A new app fades in where it lands rather than popping.
    opacity: 0
    Component.onCompleted: opacity = 1
    Behavior on opacity { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }

    onTriggered: function(button) {
      if (button === Qt.RightButton) { window.openMenu(appSlot.modelData, appSlot); return }
      window.closeMenu()
      if (button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
      else window.dock.activate(appSlot.modelData)
    }

    FallbackImage {
      readonly property real optical: window.tk.roundIcons.indexOf(appSlot.key) >= 0 ? window.tk.roundIconScale : 1
      anchors.centerIn: parent
      width: parent.width * optical
      height: width
      primary: window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      iconName: window.dock ? window.dock.iconNameFor(appSlot.modelData) : ""
    }

    // State: dot = running · bar = focused · 2–3 dots = several windows.
    readonly property bool focusedApp: {
      var ws = appSlot.modelData ? appSlot.modelData.windows : []
      for (var i = 0; i < ws.length; i++) if (ws[i].toplevel && ws[i].toplevel.activated) return true
      return false
    }
    Row {
      visible: window.tk.indicators && appSlot.windowCount > 0 && !appSlot.dragGhosted
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height + 3            // parent is iconHolder: 3px under the icon
      spacing: 3
      Repeater {
        model: appSlot.focusedApp ? 1 : Math.min(3, appSlot.windowCount)
        delegate: Rectangle {
          height: 3
          width: appSlot.focusedApp ? 12 : 4
          radius: 1.5
          color: window.tk.accentA(appSlot.focusedApp ? 0.95 : 0.6)
          Behavior on width { NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: window.tk.durationBase } }
        }
      }
    }

    // Launch feedback: a small, steady hop. Ease-out only, no overshoot.
    SequentialAnimation {
      running: appSlot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.lift = 0
      NumberAnimation { target: appSlot; property: "lift"; from: 0; to: 10; duration: 260; easing.type: Easing.OutCubic }
      NumberAnimation { target: appSlot; property: "lift"; from: 10; to: 0; duration: 260; easing.type: Easing.OutQuad }
      PauseAnimation { duration: 180 }
    }
  }

  // Launchpad: gradient rounded square with a 3x3 grid of dots.
  component AppsSlot: Slot {
    id: appsSlot
    label: Commons.I18n.t("dock.searchApps")
    animateDisp: false              // follows sepPos, which is already animated

    onTriggered: function(button) {
      if (button === Qt.RightButton) { window.openSettingsMenu(appsSlot); return }
      window.closeMenu()
      if (window.dock) window.dock.openApps()
    }

    Rectangle {
      anchors.fill: parent
      radius: width * 0.225
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.25)
      gradient: Gradient {
        GradientStop { position: 0.0; color: "#8e9aaf" }
        GradientStop { position: 1.0; color: "#4a5568" }
      }

      Grid {
        anchors.centerIn: parent
        columns: 3
        spacing: parent.width * 0.07
        readonly property real sq: parent.width * 0.18
        Repeater {
          model: ["#ff5f57", "#febc2e", "#28c840", "#5ac8fa", "#af52de", "#ff9f0a", "#ff375f", "#64d2ff", "#30d158"]
          delegate: Rectangle {
            required property string modelData
            width: parent.sq; height: parent.sq
            radius: width * 0.3
            color: modelData
          }
        }
      }
    }
  }

  component TrashSlot: Slot {
    id: trashSlot
    label: "Trash"
    animateDisp: false

    onTriggered: function(button) {
      if (button !== Qt.LeftButton) return
      window.closeMenu()
      Util.execDetached("xdg-open trash:///")
    }

    FallbackImage {
      anchors.fill: parent
      primary: window.dock ? window.dock.iconByName("user-trash") : ""
      iconName: "user-trash"
    }
  }

  // ------------------------------------------------------------ drag ghost
  // The app being reordered, under the pointer. Dragged well above the dock
  // it fades: letting go there takes it out of the dock.
  Item {
    id: ghost
    readonly property var item: window.dock && window.dragKey ? window.dock.itemFor(window.dragKey) : null
    property real size: window.iconSize * (window.removing ? 1.1 : window.maxMag * 0.95)
    visible: window.dragging && !!item
    width: size
    height: size
    x: window.pointerX - window.grabOffset.x - width / 2
    y: window.pointerY - window.grabOffset.y - height / 2
    z: 10
    opacity: window.removing ? 0.5 : 1
    Behavior on opacity { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on size { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }

    FallbackImage {
      anchors.fill: parent
      active: ghost.visible
      primary: window.dock && ghost.item ? window.dock.iconFor(ghost.item) : ""
      iconName: window.dock && ghost.item ? window.dock.iconNameFor(ghost.item) : ""
    }
  }

  // ------------------------------------------------------------ tooltip
  Rectangle {
    id: tip
    readonly property Item target: window.hoverSlot
    property string text: ""
    property real centerX: 0
    readonly property real liveCenter: target ? body.x + target.x + target.width / 2 : -1
    onLiveCenterChanged: if (liveCenter >= 0) centerX = liveCenter
    onTargetChanged: {
      if (!target) return
      text = target.label

    }
    visible: opacity > 0.01
    opacity: window.hoverSlot && window.contentShown && !window.menuOpen && !window.previewOpen && text.length > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

    width: tipText.implicitWidth + 2 * window.tk.popupPadding + 4
    height: tipText.implicitHeight + window.tk.popupPadding
    radius: 8
    color: window.tk.surfaceRaised
    border.width: 1
    border.color: window.tk.borderSubtle

    x: {
      var c = centerX
      return Math.max(8, Math.min(window.width - width - 8, Math.round(c - width / 2)))
    }
    // Sits just above the hovered icon, which grows out of the pill.
    property real iconTop: body.y - 8
    readonly property real liveTop: target ? body.y + target.y + target.iconTop : -1
    onLiveTopChanged: if (liveTop >= 0) iconTop = liveTop
    y: body.y - window.tk.popupOffset - height

    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tip.text
      color: window.tk.textPrimary
      font.family: window.tk.fontUi
      font.pixelSize: window.tk.fontSizeLabel
      font.weight: window.tk.fontWeightLabel
    }
  }

  // ------------------------------------------------------------ window previews
  // Same material as the dock, tight padding, thumbnail filling the card,
  // sans 12/500 title. Enters with fade + 4px + 0.98 scale; between icons it
  // slides and swaps content without closing.
  Item {
    id: preview
    // Stable list: the dock rebuilds its app objects on every Hyprland event
    // (and every 800ms); recreating thumbnails on that made the preview flicker.
    // Delegates only change when the SET of windows changes (by address).
    readonly property var liveWins: window.anchorSlot && window.anchorSlot.modelData ? window.anchorSlot.modelData.windows : []
    readonly property string winAddrs: liveWins.map(function(w) { return String(w.address) }).join(",")
    property var addrs: []
    onWinAddrsChanged: addrs = winAddrs === "" ? [] : winAddrs.split(",")
    function winFor(addr) {
      for (var i = 0; i < liveWins.length; i++) if (String(liveWins[i].address) === addr) return liveWins[i]
      return null
    }
    readonly property bool on: window.previewOpen && window.contentShown
    visible: opacity > 0.01
    opacity: on ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: preview.on ? window.tk.durationBase : window.tk.durationFast; easing.type: Easing.OutCubic } }
    scale: on ? 1 : 0.98
    Behavior on scale { NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic } }
    transformOrigin: Item.Bottom
    transform: Translate {
      y: preview.on ? 0 : 4
      Behavior on y { NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic } }
    }

    width: Math.min(window.width - 2 * window.gap, cards.implicitWidth + 2 * window.tk.popupPadding)
    height: cards.implicitHeight + 2 * window.tk.popupPadding
    Behavior on width { enabled: preview.on && preview.opacity > 0.99; NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: preview.on && preview.opacity > 0.99; NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic } }
    x: window.anchorSlot ? window.popupX(window.anchorSlot, preview) : 0
    Behavior on x {
      enabled: preview.on && preview.opacity > 0.99     // slide between apps only; when closing, just fade
      NumberAnimation { duration: window.tk.durationBase; easing.type: Easing.OutCubic }
    }
    y: body.y - window.tk.popupOffset - height

    // only react when the APP changes (by key, not by object)
    property string shownKey: ""
    readonly property string curKey: window.previewItem ? String(window.previewItem.key) : ""
    onCurKeyChanged: {
      if (curKey !== "" && shownKey !== "" && curKey !== shownKey && opacity > 0.99) swapFade.restart()
      if (curKey !== "") shownKey = curKey
    }
    // app switch: no dimming; new thumbnails fade in on their own
    SequentialAnimation { id: swapFade }

    // aspect ratio per window (address), remembered across switches
    property var aspects: ({})
    function aspectOf(addr, win, src) {
      if (src && src.width > 0 && src.height > 0) return src.height / src.width
      if (aspects[addr] !== undefined) return aspects[addr]
      if (win && win.size && win.size[0] > 0) return win.size[1] / win.size[0]
      return 0.625
    }

    HoverHandler {
      id: previewHover
      onHoveredChanged: if (!hovered) previewHideTimer.restart(); else previewHideTimer.stop()
    }

    SolidSurface {
      anchors.fill: parent
      radius: window.tk.radiusPopup
      fill: window.tk.surfaceRaised
      shadows: window.tk.shadowPopup
    }

    Row {
      id: cards
      x: window.tk.popupPadding; y: window.tk.popupPadding
      spacing: 8
      Repeater {
        model: preview.addrs
        delegate: Item {
          id: card
          required property var modelData            // window address
          readonly property var win: preview.winFor(modelData)
          readonly property var tl: win ? win.toplevel : null
          readonly property bool focusedWin: !!tl && tl.activated
          // real window aspect ratio, height clamped
          readonly property real aspect: preview.aspectOf(modelData, win, shot.sourceSize)
          readonly property int thumbH: Math.round(Math.max(window.tk.thumbMinH, Math.min(window.tk.thumbMaxH, window.tk.thumbWidth * aspect)))
          readonly property int thumbW: Math.round(Math.max(120, Math.min(window.tk.thumbWidth, thumbH / aspect)))
          width: thumbW
          height: thumbH + window.tk.popupGap + title.implicitHeight

          HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
          TapHandler {
            onTapped: {
              if (window.dock && card.win) window.dock.bringForward(card.win)
              window.previewSlot = null
            }
          }

          // thumbnail with concentric corners (radiusThumb = radiusPopup − padding)
          Item {
            id: thumb
            width: parent.width
            height: card.thumbH
            layer.enabled: true
            layer.effect: MultiEffect {
              maskEnabled: true
              maskSource: thumbMask
              maskThresholdMin: 0.5
              maskSpreadAtMin: 1.0
            }
            Rectangle { anchors.fill: parent; color: window.tk.surfaceHover }
            ScreencopyView {
              id: shot
              anchors.centerIn: parent
              captureSource: preview.visible ? card.tl : null
              live: preview.visible
              constraintSize: Qt.size(thumb.width, thumb.height)
              width: implicitWidth
              height: implicitHeight
              opacity: hasContent ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: window.tk.durationFast; easing.type: Easing.OutCubic } }
              onSourceSizeChanged: if (sourceSize.width > 0) preview.aspects[card.modelData] = sourceSize.height / sourceSize.width
            }
            // no frame after 350ms (minimized): big centered app icon
            Timer { id: noShot; interval: 350; running: !shot.hasContent }
            FallbackImage {
              anchors.centerIn: parent
              width: 56; height: 56
              visible: !shot.hasContent && !noShot.running
              active: visible
              primary: window.dock && window.previewItem ? window.dock.iconFor(window.previewItem) : ""
            }
          }
          Item {
            id: thumbMask
            width: thumb.width; height: thumb.height
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; radius: window.tk.radiusThumb; color: "black" }
          }
          // 1px inner border (accent 0.5 on the focused window)
          Rectangle {
            width: thumb.width; height: thumb.height
            radius: window.tk.radiusThumb
            color: "transparent"
            border.width: 1
            border.color: card.focusedWin ? window.tk.accentA(0.5)
              : (cardHover.hovered ? Qt.rgba(1, 1, 1, 0.18) : window.tk.borderSubtle)
            Behavior on border.color { ColorAnimation { duration: window.tk.durationFast } }
          }

          Text {
            id: title
            y: card.thumbH + window.tk.popupGap
            width: parent.width
            text: card.tl ? String(card.tl.title || "") : ""
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignLeft
            color: window.tk.textPrimary
            font.family: window.tk.fontUi
            font.pixelSize: window.tk.fontSizeLabel
            font.weight: window.tk.fontWeightLabel
            textFormat: Text.PlainText
          }

          // close this window
          Rectangle {
            width: 20; height: 20; radius: 10
            x: thumb.width - width - 6; y: 6
            visible: cardHover.hovered
            color: closeHover.hovered ? "#FF5F57" : window.tk.surfaceRaised
            border.width: 1
            border.color: window.tk.borderSubtle
            Text {
              anchors.centerIn: parent
              text: "×"
              color: window.tk.textPrimary
              font.family: window.tk.fontUi
              font.pixelSize: 14
            }
            HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: if (card.tl) card.tl.close() }
          }
        }
      }
    }
  }

  // Surface shared by the dock, popup and tooltip:
  // fill + specular rim + inner top glow + shadows.
  component SolidSurface: Item {
    id: ss
    property real radius: 14
    property color fill: "black"
    property var shadows: []
    Repeater {
      model: ss.shadows
      delegate: RectangularShadow {
        required property var modelData
        anchors.fill: ss
        radius: ss.radius
        offset.y: modelData.y
        blur: modelData.blur
        color: Qt.rgba(0, 0, 0, modelData.alpha)
      }
    }
    // glass body: tint + a thread of dark for contrast
    Rectangle {
      anchors.fill: parent
      radius: ss.radius
      color: ss.fill
      Behavior on color { ColorAnimation { duration: window.tk.durationBase } }
      Rectangle { anchors.fill: parent; radius: parent.radius; color: window.tk.surfaceTint }
    }
    // inner light from the top (and a faint reflection at the bottom)
    Rectangle {
      anchors.fill: parent
      anchors.margins: 1
      radius: ss.radius - 1
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, window.tk.sheen) }
        GradientStop { position: 0.42; color: "transparent" }
        GradientStop { position: 0.85; color: "transparent" }
        GradientStop { position: 1.0; color: window.tk.liquid ? Qt.rgba(1, 1, 1, 0.05) : window.tk.borderInnerDark }
      }
    }
    // specular rim: 1px ring with a vertical gradient
    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeWidth: -1
        fillRule: ShapePath.OddEvenFill
        fillGradient: LinearGradient {
          x1: 0; y1: 0; x2: 0; y2: ss.height
          GradientStop { position: 0.0; color: window.tk.rimTop }
          GradientStop { position: 0.5; color: window.tk.rimMid }
          GradientStop { position: 1.0; color: window.tk.rimBottom }
        }
        PathRectangle { x: 0; y: 0; width: ss.width; height: ss.height; radius: ss.radius }
        PathRectangle { x: 1; y: 1; width: ss.width - 2; height: ss.height - 2; radius: Math.max(0, ss.radius - 1) }
      }
    }
  }

  // ------------------------------------------------------------ menu
  function popupX(slot, popup) {
    if (!slot) return 0
    var center = body.x + slot.x + slot.width / 2
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }
  function popupY(slot, popup) { return body.y - window.gap - popup.height }

  BorderSurface {
    id: menu

    readonly property var item: window.menuItem
    readonly property bool hasEntry: !!item && !!window.dock && !!window.dock.entryFor(item)
    readonly property bool running: !!item && item.windows.length > 0

    visible: window.contentShown && (!!item || window.settingsMenu)
    width: Math.max(Style.space(160), menuColumn.implicitWidth) + padding * 2
    height: menuColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: Style.cornerRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    Column {
      id: menuColumn
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset

      MenuRow {
        visible: window.settingsMenu
        text: Commons.I18n.t("dock.autoHide")
        checked: !!window.dock && window.dock.intellihide
        onTriggered: window.dock.setMode(window.dock.intellihide ? "always" : "intellihide")
      }
      MenuRow {
        visible: menu.hasEntry && !menu.running
        text: Commons.I18n.t("dock.open")
        onTriggered: window.dock.launch(menu.item)
      }
      MenuRow {
        visible: menu.hasEntry && menu.running
        text: Commons.I18n.t("dock.newWindow")
        onTriggered: window.dock.launch(menu.item)
      }
      MenuRow {
        visible: menu.hasEntry
        text: menu.item && menu.item.pinned ? Commons.I18n.t("dock.removeFromDock") : Commons.I18n.t("dock.keepInDock")
        onTriggered: window.dock.setPinned(menu.item.key, !menu.item.pinned)
      }
      MenuRow {
        visible: menu.running
        text: Commons.I18n.t("dock.quit")
        onTriggered: window.dock.quit(menu.item)
      }
    }
  }

  component MenuRow: Rectangle {
    id: row
    property string text: ""
    property bool checked: false
    signal triggered()

    width: parent ? parent.width : 0
    height: visible ? Style.spacing.popupRowHeight : 0
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: row.text
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Text {
      visible: row.checked
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: "✓"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { row.triggered(); window.closeMenu() }
    }
  }
}
