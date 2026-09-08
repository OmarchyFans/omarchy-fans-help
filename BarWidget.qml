import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar button for Omarchy Help. Click toggles the help panel; the same panel
// opens on SUPER + CTRL + SHIFT + L.
BarWidget {
  id: root
  moduleName: "io.github.modpunk.omarchy-help"

  readonly property string pluginId: "io.github.modpunk.omarchy-help"

  // The shell owns the panel's open state; this widget only asks it to toggle.
  readonly property bool opened: false
  function open() { togglePanel() }
  function close() {}

  function togglePanel() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function")
      root.bar.shell.toggle(pluginId, "{}")
    else if (root.bar && typeof root.bar.run === "function")
      root.bar.run("omarchy-shell shell toggle " + pluginId + " '{}'")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋖"                     // nf-md-help_circle_outline
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Omarchy Help — search keybindings, commands and the manual (SUPER + CTRL + SHIFT + L)"
    onPressed: root.togglePanel()
  }
}
