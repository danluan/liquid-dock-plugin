import QtQuick
import Quickshell
import qs.Commons

// Fallback app library for when the shell does not hand one to this plugin.
// Omarchy only injects shell.appLibrary into plugins whose manifest declares
// the "menu" kind, so a service-only dock gets null and the app grid and the
// launch of non-running pinned apps silently do nothing. This mirrors the
// subset of services/AppLibrary.qml the dock and AppGrid use.
QtObject {
  id: root

  signal appsChanged()

  property int revision: DesktopEntries.applications.values.length
  onRevisionChanged: root.appsChanged()

  function entryName(entry) {
    return entry ? String(entry.name || entry.id || "") : ""
  }

  function entrySubtext(entry) {
    return entry ? String(entry.genericName || entry.comment || "") : ""
  }

  function sortedEntries(query) {
    var q = String(query || "").trim().toLowerCase()
    var values = DesktopEntries.applications.values || []
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e || e.noDisplay) continue
      var name = root.entryName(e)
      var score = 0
      if (q.length > 0) {
        var n = name.toLowerCase()
        var hay = (n + " " + String(e.genericName || "") + " " + String(e.comment || "") + " " + String(e.id || "") + " " + (e.keywords || []).join(" ")).toLowerCase()
        if (n.indexOf(q) === 0) score = 3
        else if (n.indexOf(q) !== -1) score = 2
        else if (hay.indexOf(q) !== -1) score = 1
        else continue
      }
      rows.push({ entry: e, score: score, name: name.toLowerCase() })
    }
    rows.sort(function(a, b) {
      if (a.score !== b.score) return b.score - a.score
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
    })
    return rows
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  function refreshIcons() {}

  function terminalCommand(entry) {
    if (!entry || !entry.runInTerminal) return []
    return (entry.command || []).filter(function(word) { return !/^%[a-zA-Z]$/.test(String(word)) })
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    var command = root.terminalCommand(DesktopEntries.byId(id))
    if (command.length > 0) {
      Util.execDetached("omarchy-launch-tui " + command.map(function(word) { return Util.shellQuote(word) }).join(" "))
      return
    }
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  // Uninstalling from the dock is not supported without the shell library.
  function remove(desktopId, name) {}
}
