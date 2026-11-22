import QtQuick
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
  readonly property int iconSize: 48
  readonly property real maxMag: 1.85               // macOS-like peak size under the pointer
  readonly property int pad: 10
  readonly property int slotGap: 10                 // extra width beside each icon
  readonly property int baseW: iconSize + slotGap
  readonly property int sepW: 18
  readonly property int topPad: 8
  readonly property int dotZone: 14                 // room under the icon for the dot
  readonly property int restH: topPad + iconSize + dotZone
  readonly property int gap: 8                      // between pill and screen edge
  readonly property int radius: 24
  readonly property real falloffRadius: baseW * 2.75 // how far the wave reaches on each side
  readonly property int dragThreshold: 6
  readonly property int removeDistance: 70          // drag this far above the pill to remove

  readonly property int appCount: dock ? dock.itemModel.count : 0
  // An app dragged in from the app grid opens a gap where it would land.
  readonly property int appSlots: appCount + (insertIndex >= 0 && dragFrom < 0 ? 1 : 0)
  // Separator position in slot units; animated so the dock widens smoothly.
  property real sepPos: appSlots
  Behavior on sepPos { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
  readonly property real restW: pad * 2 + (sepPos + 2) * baseW + sepW
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
    var kx = 1 - Math.exp(-dt / 0.045)
    var ka = 1 - Math.exp(-dt / (amountTarget > amount ? 0.07 : 0.11))
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

  function extraBefore(d) {
    var s = 0
    for (var i = 0; i < slots.length; i++) {
      var o = slots[i]
      if (o.disp < d - 0.01) s += o.extra
    }
    return s
  }

  readonly property real totalExtra: {
    var s = 0
    for (var i = 0; i < slots.length; i++) s += slots[i].extra
    return s
  }

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
      if (s.dragGhosted || s.opacity < 0.5) continue
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
  implicitHeight: gap + restH + 64 + Style.spacing.popupRowHeight * 5 + 40

  mask: Region {
    item: window.contentShown ? hitBox : null
    Region { item: window.shown && window.tucked ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
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
    onTriggered: if (!window.pointerIn && !edgeHover.hovered && !window.menuOpen && !window.dragging && window.insertIndex < 0) window.revealed = false
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

    // Glass: translucent theme background, white rim, soft top highlight.
    Rectangle {
      id: glass
      anchors.fill: parent
      radius: window.radius
      color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.40)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.18)

      Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: window.radius - 1
        gradient: Gradient {
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.16) }
          GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.03) }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
        }
      }
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
        width: 1
        height: window.iconSize * 0.7
        color: Qt.rgba(1, 1, 1, 0.22)
        x: window.pad + window.sepPos * window.baseW + window.extraBefore(window.sepPos - 0.5) + (window.sepW - 1) / 2
        y: body.height - window.dotZone - window.iconSize + (window.iconSize - height) / 2
      }

      AppsSlot { targetDisp: window.sepPos }
      TrashSlot { targetDisp: window.sepPos + 1 }
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

    width: window.baseW + extra
    height: body.height
    x: window.pad + disp * window.baseW + window.sepAdj(disp) + window.extraBefore(disp)
    z: hovered ? 2 : 1

    Component.onCompleted: window.registerSlot(slot)
    Component.onDestruction: window.unregisterSlot(slot)

    // Icon box: bottom-aligned above the dot zone and growing upward.
    Item {
      id: iconHolder
      width: window.iconSize * slot.mag
      height: width
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - window.dotZone - height - slot.lift
      opacity: slot.dragGhosted ? 0 : (slot.pressed ? 0.7 : 1)
      Behavior on opacity { NumberAnimation { duration: Style.duration(90) } }
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
      anchors.fill: parent
      primary: window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      iconName: window.dock ? window.dock.iconNameFor(appSlot.modelData) : ""
    }

    // Running indicator.
    Rectangle {
      visible: appSlot.windowCount > 0 && !appSlot.dragGhosted
      width: 4; height: 4; radius: 2
      color: Qt.rgba(Commons.Color.foreground.r, Commons.Color.foreground.g, Commons.Color.foreground.b, 0.85)
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - window.dotZone + 6
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
    opacity: window.hoverSlot && window.contentShown && !window.menuOpen && text.length > 0 ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

    width: tipText.implicitWidth + 20
    height: tipText.implicitHeight + 10
    radius: 9
    color: Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, 0.55)
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.18)

    x: {
      var c = centerX
      return Math.max(8, Math.min(window.width - width - 8, Math.round(c - width / 2)))
    }
    // Sits just above the hovered icon, which grows out of the pill.
    property real iconTop: body.y - 8
    readonly property real liveTop: target ? body.y + target.y + target.iconTop : -1
    onLiveTopChanged: if (liveTop >= 0) iconTop = liveTop
    y: iconTop - height - 8

    Text {
      id: tipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tip.text
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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
