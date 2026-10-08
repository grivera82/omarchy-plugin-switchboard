import QtQuick
import Quickshell
import qs.Ui

// Only the icon lives in the bar. The menu and worker live in Service.qml.
BarWidget {
  id: root
  moduleName: "grivera.switchboard"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool opened: !!service && service.opened

  function attach(force) {
    if (!service || !bar) return
    // Keep an open menu on its original monitor when another monitor's
    // copy of the icon is reconstructed.
    var newWindow = button.QsWindow.window
    if (!force && service.opened && service.anchorScreenName && newWindow && newWindow.screen
        && service.anchorScreenName !== newWindow.screen.name) return
    service.bar = bar
    service.anchorItem = button
    if (newWindow && newWindow.screen) service.anchorScreenName = newWindow.screen.name
  }
  function open() { attach(true); if (service) service.open() }
  function close() { if (service) service.close() }
  function toggle() { attach(true); if (service) service.toggle() }
  function closeForPopoutSwitch() { if (service) service.closeForPopoutSwitch() }

  onServiceChanged: Qt.callLater(attach)
  onBarChanged: Qt.callLater(attach)
  Component.onCompleted: Qt.callLater(attach)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒓"
    tooltipText: "Switchboard · manage plugins"
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }
}
