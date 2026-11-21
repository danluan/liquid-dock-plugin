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
  readonly property real maxMag: 1.5
  readonly property int pad: 10
  readonly property int slotGap: 10                 // extra width beside each icon
  readonly property int baseW: iconSize + slotGap
  readonly property int sepW: 18
  readonly property int topPad: 8
  readonly property int dotZone: 14                 // room under the icon for the dot
  readonly property int restH: topPad + iconSize + dotZone
  readonly property int gap: 8                      // between pill and screen edge
  readonly property int radius: 24
  readonly property real falloffRadius: 150

  readonly property int appCount: dock ? dock.itemModel.count : 0
  readonly property int slotCount: appCount + 2     // apps, launchpad, trash
  readonly property real restW: pad * 2 + slotCount * baseW + sepW

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

  readonly property bool tucked: dock && dock.intellihide && overlapped && !(revealed || menuOpen || gridOpen)
  readonly property bool contentShown: shown && !tucked
  property bool pointerIn: false
  property real pointerX: 0
  // 0..1: magnification fades in and out as the pointer enters and leaves.
  property real amount: pointerIn && !menuOpen ? 1 : 0
  Behavior on amount {
    NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
  }

  property Item hoverSlot: null

  // ------------------------------------------------------------ magnification math
  function modelCenter(i) {
    var c = (window.width - restW) / 2 + pad + i * baseW + baseW / 2
    if (i >= appCount) c += sepW
    return c
  }

  function magAt(i) {
    var d = Math.abs(pointerX - modelCenter(i))
    var f = d < falloffRadius ? (Math.cos(Math.PI * d / falloffRadius) + 1) / 2 : 0
    return 1 + (maxMag - 1) * amount * f
  }

  function extraBefore(i) {
    var s = 0
    for (var j = 0; j < i; j++) s += (magAt(j) - 1) * iconSize
    return s
  }

  readonly property real totalExtra: {
    pointerX; amount; slotCount; width
    return extraBefore(slotCount)
  }
  readonly property real maxExtraH: {
    pointerX; amount; slotCount; width
    var m = 1
    for (var i = 0; i < slotCount; i++) m = Math.max(m, magAt(i))
    return (m - 1) * iconSize
  }

  // ------------------------------------------------------------ external drag (app grid)
  property int insertIndex: -1
  function moveExternalDrag(x, y) {
    if (window.shown && !window.tucked) window.revealed = window.revealed
  }
  function dropExternalDrag(x, y, key) {
    var top = screen.height - window.height
    var inside = x >= body.x - 30 && x <= body.x + body.width + 30 && y - top >= body.y - 30
    if (inside && key && window.dock) window.dock.pinAt(key, window.dock.itemModel.count)
  }
  function endExternalDrag() { insertIndex = -1 }

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

  onShownChanged: if (!shown) { closeMenu(); revealed = false }

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
    interval: 250
    onTriggered: if (!window.pointerIn && !edgeHover.hovered && !window.menuOpen) window.revealed = false
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

  // Fixed footprint of the pill at full magnification: input mask and pointer tracking.
  Item {
    id: hitBox
    readonly property real extraW: (window.maxMag - 1) * window.iconSize * 2.6
    width: window.restW + extraW
    height: window.restH + (window.maxMag - 1) * window.iconSize
    x: Math.round((window.width - width) / 2)
    y: window.height - window.gap - height

    HoverHandler {
      id: pointerHover
      onHoveredChanged: {
        window.pointerIn = hovered
        if (hovered) window.revealed = true
        else {
          window.hoverSlot = null
          hideTimer.restart()
        }
      }
      onPointChanged: window.pointerX = hitBox.x + point.position.x
    }
  }

  // ------------------------------------------------------------ pill
  Item {
    id: body
    width: window.restW + window.totalExtra
    height: window.restH + window.maxExtraH
    x: Math.round((window.width - width) / 2)
    property real tuck: window.tucked ? height + window.gap + 20 : 0
    y: window.height - window.gap - height + tuck
    opacity: window.shown ? 1 : 0

    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 120 : 180)
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

    // Slots are laid out in body coordinates; each is placed from the model
    // layout plus the shift magnification gives it.
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
        x: window.pad + window.appCount * window.baseW + window.extraBefore(window.appCount) + (window.sepW - 1) / 2
        y: body.height - window.dotZone - window.iconSize + (window.iconSize - height) / 2
      }

      AppsSlot { slotIndex: window.appCount }
      TrashSlot { slotIndex: window.appCount + 1 }
    }
  }

  // ------------------------------------------------------------ slots
  component Slot: Item {
    id: slot

    property int slotIndex: 0
    property string label: ""
    property real mag: window.magAt(slotIndex)
    property bool hovered: mouse.containsMouse
    property alias mouse: mouse
    property real lift: 0           // launch bounce, px
    default property alias content: iconHolder.data

    readonly property real extra: (mag - 1) * window.iconSize
    width: window.baseW + extra
    height: body.height
    x: window.pad + slotIndex * window.baseW + (slotIndex >= window.appCount ? window.sepW : 0)
       + window.extraBefore(slotIndex)
    z: hovered ? 2 : 1

    // Icon box: bottom-aligned above the dot zone and growing upward.
    Item {
      id: iconHolder
      width: window.iconSize * slot.mag
      height: width
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - window.dotZone - height - slot.lift
    }

    MouseArea {
      id: mouse
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      y: iconHolder.y
      height: parent.height - iconHolder.y
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      onContainsMouseChanged: {
        if (containsMouse) window.hoverSlot = slot
        else if (window.hoverSlot === slot) window.hoverSlot = null
      }
    }
  }

  // Image that walks a list of candidate sources when one fails to load, so
  // apps resolve even before the configured icon theme (WhiteSur) has them.
  component FallbackImage: Image {
    id: fi
    property string primary: ""
    property string iconName: ""
    property int attempt: 0
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
    source: candidates[Math.min(attempt, candidates.length - 1)]
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
    slotIndex: index
    label: entry ? String(entry.name || key) : key

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) { window.openMenu(appSlot.modelData, appSlot); return }
      window.closeMenu()
      if (event.button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
      else window.dock.activate(appSlot.modelData)
    }

    FallbackImage {
      anchors.fill: parent
      primary: window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      iconName: window.dock ? window.dock.iconNameFor(appSlot.modelData) : ""
      opacity: appSlot.pressedFade
    }

    property real pressedFade: mouse.pressed ? 0.75 : 1

    // Running indicator.
    Rectangle {
      visible: appSlot.windowCount > 0
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

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) { window.openSettingsMenu(appsSlot); return }
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
      opacity: mouse.pressed ? 0.8 : 1

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

    mouse.onClicked: function(event) {
      if (event.button !== Qt.LeftButton) return
      window.closeMenu()
      Util.execDetached("xdg-open trash:///")
    }

    FallbackImage {
      anchors.fill: parent
      primary: window.dock ? window.dock.iconByName("user-trash") : ""
      iconName: "user-trash"
      opacity: mouse.pressed ? 0.75 : 1
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
    y: body.y - height - 8

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
