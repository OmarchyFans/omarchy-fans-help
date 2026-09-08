import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Offline help for Omarchy: live search over this machine's keybindings, the
// omarchy CLI, and the manual pinned to the installed version.
//
// Two speeds, deliberately:
//   typing  -> `omarchy-local-agent --search-daemon`, a process held open for
//              the life of the panel. Each keystroke is a line in, a line of
//              JSON out, ~1ms. Spawning the CLI per keystroke costs ~100ms of
//              interpreter startup, which reads as lag.
//   Enter   -> the local LLM explains one manual section. Seconds, so it gets
//              its own view with a visible "thinking" state.
//
// Styling borrows the [menu] surface tokens, so any theme that styles the
// Omarchy menu styles this too.
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: "io.github.modpunk.omarchy-help"
  readonly property string agent: Quickshell.env("HOME") + "/.local/bin/omarchy-local-agent"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0

  // answer view
  property bool answering: false
  property string answerTitle: ""
  property string answerText: ""
  property bool answerBusy: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    root.opened = true
    root.clearAnswer()
    root.setFilter("")
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss(); else root.open("{}")
  }

  // ---- search -------------------------------------------------------------

  function setFilter(text) {
    root.filterText = text
    root.selectedIndex = 0
    if (!text) { results.clear(); rebuildEmpty(); return }
    if (searchProc.running) searchProc.write(text + "\n")
  }

  // With no query there is nothing to rank, so show a few things worth knowing
  // rather than an empty box that gives no hint about what this searches.
  function rebuildEmpty() {
    results.clear()
    results.append({ kind: "hint", primary: "Type to search keybindings, commands and the manual",
                     secondary: "", sid: "" })
    results.append({ kind: "hint", primary: "Examples:  nightlight  ·  screenshot  ·  how do I change my theme",
                     secondary: "", sid: "" })
  }

  function applyResults(payload) {
    var data
    try { data = JSON.parse(payload) } catch (e) { return }
    if (!data || data.query !== root.filterText) return   // a later keystroke won

    results.clear()

    // Always offer the free-form question first: it is what someone typing a
    // sentence rather than a word actually wants.
    if (root.filterText.length > 2)
      results.append({ kind: "ask", primary: "Ask the manual: " + root.filterText,
                       secondary: "the local model answers from the manual", sid: "" })

    var i
    for (i = 0; i < (data.binds || []).length; i++)
      results.append({ kind: "bind", primary: data.binds[i].keys,
                       secondary: data.binds[i].description, sid: "" })
    for (i = 0; i < (data.commands || []).length; i++)
      results.append({ kind: "command",
                       primary: (data.commands[i].route + " " + (data.commands[i].args || "")).trim(),
                       secondary: data.commands[i].summary || "", sid: "" })
    for (i = 0; i < (data.sections || []).length; i++) {
      // A chapter with no sub-headings has heading == chapter; printing both
      // just renders the same words twice.
      var head = data.sections[i].heading
      var chap = data.sections[i].chapter
      results.append({ kind: "section", primary: head,
                       secondary: (chap === head ? "" : chap),
                       sid: data.sections[i].sid })
    }

    if (results.count === 0)
      results.append({ kind: "hint", primary: "Nothing matched “" + root.filterText + "”",
                       secondary: "", sid: "" })
    root.selectedIndex = 0
  }

  function selectableAt(i) {
    if (i < 0 || i >= results.count) return null
    var r = results.get(i)
    return r.kind === "hint" ? null : r
  }

  function move(delta) {
    if (results.count === 0) return
    var i = root.selectedIndex
    for (var n = 0; n < results.count; n++) {
      i = (i + delta + results.count) % results.count
      if (selectableAt(i)) { root.selectedIndex = i; resultList.positionViewAtIndex(i, ListView.Contain); return }
    }
  }

  // ---- activation ---------------------------------------------------------

  function activate() {
    var r = selectableAt(root.selectedIndex)
    if (!r) return
    if (r.kind === "section") { askSection(r.sid, r.primary) }
    else if (r.kind === "ask") { askSection("", root.filterText) }
    else { copy(r.primary) }
  }

  function copy(text) {
    Quickshell.execDetached(["wl-copy", "--", text])
    root.answerTitle = "Copied"
    root.answerText = text
    root.answerBusy = false
    root.answering = true
    copyTimer.restart()
  }

  function askSection(sid, title) {
    root.answering = true
    root.answerBusy = true
    root.answerTitle = title
    root.answerText = ""
    explainProc.sid = sid
    explainProc.query = root.filterText
    explainProc.running = false
    explainProc.running = true
  }

  function clearAnswer() {
    root.answering = false
    root.answerBusy = false
    root.answerTitle = ""
    root.answerText = ""
  }

  ListModel { id: results }

  Timer { id: copyTimer; interval: 900; onTriggered: root.clearAnswer() }

  // Held open for the life of the panel: one line in, one JSON line out.
  Process {
    id: searchProc
    command: [root.agent, "--search-daemon"]
    running: root.opened
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { if (line) root.applyResults(line) }
    }
  }

  Process {
    id: explainProc
    property string sid: ""
    property string query: ""
    command: sid
      ? [root.agent, "--explain-section", sid, query]
      : [root.agent, query]
    stdout: StdioCollector {
      onStreamFinished: {
        root.answerBusy = false
        root.answerText = text && text.trim() ? text.trim() : "No answer came back."
      }
    }
    onExited: function(code) {
      root.answerBusy = false
      if (!root.answerText) root.answerText = "The helper exited with code " + code + "."
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-help"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.answering) root.clearAnswer()
            else if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (root.answering) {
            // Any key returns to the list; the answer view is read-only.
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.clearAnswer(); event.accepted = true
            }
          } else if (event.key === Qt.Key_Backspace) {
            root.setFilter(root.filterText.slice(0, -1))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-1); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(); event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ---- search line ----
        Item {
          width: parent.width
          height: root.headerHeight
          Text {
            anchors.left: parent.left; anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.filterText || "Search Omarchy help…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        // ---- body: results, or the answer ----
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          ListView {
            id: resultList
            anchors.fill: parent
            visible: !root.answering
            model: results
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(2)

            delegate: Rectangle {
              width: resultList.width
              height: model.secondary ? Style.space(44) : Style.space(30)
              radius: Style.space(6)
              color: (index === root.selectedIndex && model.kind !== "hint")
                     ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                enabled: model.kind !== "hint"
                onClicked: { root.selectedIndex = index; root.activate() }
                onPositionChanged: root.selectedIndex = index
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  textFormat: Text.PlainText
                  text: model.kind === "bind" ? "⌨"
                      : model.kind === "command" ? "❯"
                      : model.kind === "section" ? "▤"
                      : model.kind === "ask" ? "✦" : " "
                  color: index === root.selectedIndex ? root.selectedText : root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(34)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: model.primary
                    color: index === root.selectedIndex ? root.selectedText : root.foreground
                    opacity: model.kind === "hint" ? 0.55 : 1
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: !!model.secondary
                    textFormat: Text.PlainText
                    text: model.secondary
                    color: index === root.selectedIndex ? root.selectedText : root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }

          // ---- answer view ----
          Flickable {
            anchors.fill: parent
            visible: root.answering
            contentHeight: answerCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: answerCol
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                // The search line above already shows the question; repeating
                // it as the answer heading just prints it twice.
                visible: !!root.answerTitle && root.answerTitle !== root.filterText
                textFormat: Text.PlainText
                text: root.answerTitle
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.answerBusy ? "Thinking… (the local model is answering)" : root.answerText
                color: root.foreground
                opacity: root.answerBusy ? 0.6 : 1
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---- footer hint ----
        Item {
          width: parent.width
          height: root.footerHeight
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.answering
                  ? "esc  back to results"
                  : "↑↓ move   ↵ explain or copy   esc close"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  property int footerHeight: Math.max(Style.space(18), Style.font.caption + Style.space(6))
}
