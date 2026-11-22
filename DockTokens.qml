import QtQuick

// Design tokens for the dock and its window previews.
// Every color, radius, shadow, spacing, font and duration the dock uses lives here.
// material "liquid": translucent glass over Hyprland's blur; "solid": opaque.
QtObject {
  id: t

  // Set by the dock from its settings file (~/.config/omarchy/danluan-dock.json).
  property string material: "liquid"
  property bool reduceTransparency: false
  property bool indicators: true
  function a(alpha) { return reduceTransparency ? 1.0 : alpha }

  // ── Material
  readonly property bool liquid: material === "liquid" && !reduceTransparency

  // ── Surfaces (dock and popup share one material)
  // liquid: a faint light tint over the blur plus a thread of dark for contrast
  readonly property color surfaceBase:   liquid ? Qt.rgba(1, 1, 1, 0.06)
                                                : Qt.rgba(0x16 / 255, 0x16 / 255, 0x1A / 255, a(0.90))
  readonly property color surfaceTint:   liquid ? Qt.rgba(0, 0, 0, 0.06) : "transparent"
  // popup: denser than the dock so it reads over busy dark windows
  readonly property color surfaceRaised: liquid ? Qt.rgba(0.08, 0.08, 0.10, 0.70)
                                                : Qt.rgba(0x1E / 255, 0x1E / 255, 0x24 / 255, a(0.94))
  readonly property color surfaceHover:  Qt.rgba(1, 1, 1, 0.06)
  readonly property color surfaceActive: Qt.rgba(1, 1, 1, 0.10)

  // ── Borders and highlights
  readonly property color borderSubtle:   Qt.rgba(1, 1, 1, 0.08)
  // specular rim (1px ring, vertical gradient)
  readonly property color rimTop:    liquid ? Qt.rgba(1, 1, 1, 0.60) : borderSubtle
  readonly property color rimMid:    liquid ? Qt.rgba(1, 1, 1, 0.12) : borderSubtle
  readonly property color rimBottom: liquid ? Qt.rgba(1, 1, 1, 0.26) : borderSubtle
  readonly property real sheen:      liquid ? 0.11 : 0.06   // inner top glow
  readonly property color highlightTop:   Qt.rgba(1, 1, 1, 0.06)   // inner light line at the top
  readonly property color borderInnerDark: Qt.rgba(0, 0, 0, 0.25)  // thickness at the bottom

  // ── Shadows
  // Hyprland blurs every layer pixel above ignore_alpha (0.1 in the theme's layer_rule):
  // liquid glass is ~0.12 (blurred); liquid shadows stay below it or they turn into a blurred slab.
  readonly property var shadowDock:  liquid ? [{ y: 4, blur: 16, alpha: 0.04 }]
                                            : [{ y: 8, blur: 24, alpha: 0.35 }, { y: 2, blur: 6, alpha: 0.25 }]
  readonly property var shadowPopup: liquid ? [{ y: 6, blur: 20, alpha: 0.04 }]
                                            : [{ y: 12, blur: 32, alpha: 0.45 }, { y: 2, blur: 8, alpha: 0.30 }]

  // ── Text
  readonly property color textPrimary:   Qt.rgba(1, 1, 1, 0.92)
  readonly property color textSecondary: Qt.rgba(1, 1, 1, 0.60)
  readonly property string fontUi: "SF Pro Text"
  readonly property int fontSizeLabel: 12
  readonly property int fontWeightLabel: Font.Medium

  // ── Accent: a single color, for state indicators
  readonly property color accent: Qt.rgba(1, 1, 1, 0.9)
  function accentA(alpha) { return Qt.rgba(1, 1, 1, alpha) }

  // ── Radii (concentric: inner = outer − padding)
  readonly property int radiusDock:  22
  readonly property int radiusPopup: 14
  readonly property int radiusThumb: radiusPopup - popupPadding   // 6
  readonly property int radiusSlot:  14

  // ── Spacing (4px scale)
  readonly property int dockPadding: 8
  readonly property int dockGap: 8
  readonly property int popupPadding: 8
  readonly property int popupGap: 6
  readonly property int popupOffset: 12

  // ── Sizes
  readonly property int iconSize: 48
  readonly property int slotSize: 56
  readonly property real roundIconScale: 0.95     // round icons (Chrome) look bigger
  readonly property var roundIcons: ["google-chrome", "chromium", "firefox"]
  readonly property real hoverScale: 1.2
  readonly property real neighborScale: 1.06
  readonly property real pressScale: 0.94
  readonly property int thumbWidth: 240
  readonly property int thumbMinH: 110
  readonly property int thumbMaxH: 170



  // ── Motion
  readonly property int durationFast: 120
  readonly property int durationBase: 180
  readonly property int popupOpenDelay: 250
  readonly property int popupCloseGrace: 120
}
