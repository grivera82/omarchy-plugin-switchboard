import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "grivera.switchboard"
  ipcTarget: "grivera.switchboard"
  // This instance belongs to the service host, so bar layout rebuilds cannot
  // destroy the menu, process, or its search/filter/scroll state.
  property var shell: null
  property var manifest: null
  property Item anchorItem: null
  property string anchorScreenName: ""

  property var plugins: []
  property string scope: "custom"
  property string stateFilter: "all"
  property string message: ""
  property bool failed: false
  readonly property bool busy: worker.running
  readonly property int enabledCount: plugins.filter(function(p) { return !p.firstParty && p.enabled }).length
  readonly property var filtered: plugins.filter(function(p) {
    var query = search.text.trim().toLowerCase()
    return (scope === "all" || !p.firstParty)
      && (stateFilter === "all" || (stateFilter === "enabled" ? p.enabled : !p.enabled))
      && (!query || (p.name + " " + p.id + " " + p.kinds.join(" ")).toLowerCase().indexOf(query) !== -1)
  })

  function request(args) {
    if (busy) return
    failed = false
    message = ""
    worker.command = ["python3", Qt.resolvedUrl("manager.py").toString().replace(/^file:\/\//, "")].concat(args)
    worker.running = true
  }
  function refresh() { request(["list"]) }
  function applyPlugins(next) {
    var scroll = list.contentY
    var index = list.currentIndex
    var selected = index >= 0 && index < filtered.length ? filtered[index].id : ""
    plugins = next
    Qt.callLater(function() {
      var found = root.filtered.findIndex(function(p) { return p.id === selected })
      list.currentIndex = found >= 0 ? found : Math.min(index, list.count - 1)
      list.contentY = Math.max(0, Math.min(scroll, list.contentHeight - list.height))
    })
  }
  function kindLabel(p) {
    if (p.kinds.indexOf("bar") !== -1) return "Replacement bar"
    if (p.kinds.indexOf("bar-widget") !== -1) return "Bar widget"
    if (p.kinds.indexOf("service") !== -1) return "Background service"
    if (p.kinds.indexOf("menu") !== -1) return "Menu"
    return "Popup"
  }
  function togglePlugin(p) {
    if (p.id === moduleName || (p.enabled && !p.canDisable)) return
    request(["toggle", p.id, p.enabled ? "false" : "true"])
  }
  onOpenedChanged: if (opened) refresh()

  Process {
    id: worker
    property string output: ""
    property string errorOutput: ""
    stdout: StdioCollector { onStreamFinished: worker.output = text }
    stderr: StdioCollector { onStreamFinished: worker.errorOutput = text }
    onStarted: { output = ""; errorOutput = "" }
    onExited: function(exitCode, exitStatus) {
      try {
        var result = JSON.parse(output)
        root.failed = !result.ok
        if (result.plugins) root.applyPlugins(result.plugins)
        root.message = result.ok ? result.message : result.error
      } catch (e) {
        root.failed = true
        root.message = errorOutput.trim() || "Could not read plugins. Check that the Omarchy shell is running."
      }
    }
  }

  Timer { interval: 6000; repeat: true; running: root.opened; onTriggered: if (!root.busy && !root.failed) root.refresh() }

  IpcHandler {
    target: "grivera.switchboard-control"
    function status(): string {
      return JSON.stringify({opened: root.opened, visible: popup.visible,
        busy: root.busy, query: search.text, scope: root.scope,
        stateFilter: root.stateFilter, scroll: list.contentY, message: root.message,
        failed: root.failed})
    }
    function togglePlugin(id: string): void {
      var plugin = root.plugins.find(function(p) { return p.id === id })
      if (plugin) root.togglePlugin(plugin)
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: search
    contentWidth: fittedContentWidth(Style.space(480))
    contentHeight: cappedContentHeight(Style.space(600))

    FocusScope {
      anchors.fill: parent
      Keys.onEscapePressed: root.close()

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(8)
          Column {
            width: parent.width - refreshButton.width - closeButton.width - parent.spacing * 2
            Text { text: "Switchboard"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
            Text { text: root.enabledCount + " custom plugins enabled"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
          }
          Button { id: refreshButton; text: "↻"; tooltipText: "Refresh plugins"; focusable: true; enabled: !root.busy; opacity: enabled ? 1 : 0.4; onClicked: root.refresh() }
          Button { id: closeButton; text: "×"; tooltipText: "Close (Esc)"; focusable: true; onClicked: root.close() }
        }

        TextField {
          id: search
          width: parent.width
          placeholderText: "Search name, ID, or kind…"
          Keys.onEscapePressed: root.close()
          Keys.onDownPressed: { list.forceActiveFocus(); list.currentIndex = Math.max(0, list.currentIndex) }
          onTextChanged: list.currentIndex = 0
        }

        Row {
          width: parent.width
          ButtonGroup {
            options: [{value: "custom", label: "Custom"}, {value: "all", label: "All plugins"}]
            value: root.scope
            onChanged: function(v) { root.scope = v; list.currentIndex = 0 }
          }
        }

        ButtonGroup {
          options: [{value: "all", label: "Any state"}, {value: "enabled", label: "Enabled"}, {value: "disabled", label: "Disabled"}]
          value: root.stateFilter
          onChanged: function(v) { root.stateFilter = v; list.currentIndex = 0 }
        }

        Item {
          id: listContainer
          width: parent.width
          height: Math.max(60, content.height - y - footer.height - content.spacing)

          ListView {
            id: list
            anchors.fill: parent
            clip: true
            spacing: Style.space(6)
            model: root.filtered
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar {}
            keyNavigationEnabled: true
            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: if (currentIndex >= 0 && currentIndex < root.filtered.length && !root.busy) root.togglePlugin(root.filtered[currentIndex])
            Keys.onSpacePressed: if (currentIndex >= 0 && currentIndex < root.filtered.length && !root.busy) root.togglePlugin(root.filtered[currentIndex])

            delegate: Toggle {
              required property var modelData
              required property int index
              width: list.width - Style.space(12)
              label: modelData.name
              description: modelData.id + "\n" + (modelData.id === root.moduleName ? "Manager stays enabled" : root.kindLabel(modelData))
              checked: modelData.enabled
              hasCursor: list.activeFocus && list.currentIndex === index
              enabled: !root.busy && modelData.id !== root.moduleName && (!modelData.enabled || modelData.canDisable)
              opacity: enabled ? 1 : 0.45
              onClicked: { list.currentIndex = index; root.togglePlugin(modelData) }
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: list.count === 0
            text: root.busy ? "Loading plugins…" : "No matching plugins"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Text {
          id: footer
          width: parent.width
          textFormat: Text.PlainText
          text: root.busy ? "Applying…" : root.message || "Changes apply immediately · Esc closes"
          color: root.failed ? Color.urgent : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
