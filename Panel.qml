import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Windscribe in the bar: one icon carrying connection state, and one panel with
// the current connection, the controls that change it, and every location the
// CLI knows about behind a search box.
Panel {
  id: root
  moduleName: "dev.windscribe"
  ipcTarget: "dev.windscribe"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent, urgent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent, urgent)

  readonly property string glyph: "󰦝"

  // `omarchy bar set <id> <key> <value>` writes the value as a string unless
  // it is given `--json`, so a boolean setting arrives as either `true` or
  // `"true"` depending on how it was set. Accept both.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "string") {
      var lower = value.toLowerCase()
      return lower === "true" || lower === "1" || lower === "yes"
    }
    return value === true
  }

  readonly property bool showLabel: boolSetting("showLabel", true)
  readonly property bool hideWhenDisconnected: boolSetting("hideWhenDisconnected", false)
  readonly property bool showPublicIp: boolSetting("showPublicIp", false)

  // ------------------------------------------------------------------- data

  Main {
    id: windscribe
    settings: root.settings
  }

  // Facade over the data item for anything read from inside a Component or an
  // inline component. Those scopes resolve `root` reliably but not sibling ids
  // — a binding onto `windscribe.foo` from in there is reported as depending on
  // non-bindable properties and stops updating.
  readonly property bool connected: windscribe.connected
  readonly property bool transitioning: windscribe.transitioning
  readonly property string currentLocation: windscribe.location
  property real pulseOpacity: 1

  // Drives the uptime readout; only ticks while the panel is on screen.
  property real nowMs: 0
  Timer {
    interval: 1000
    running: root.opened && windscribe.connectedSinceMs > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // ----------------------------------------------------------- list + search

  property string query: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool searchFocused: false

  function matches(entry) {
    var q = root.query.trim().toLowerCase()
    if (q === "") return true
    var terms = q.split(/\s+/)
    for (var i = 0; i < terms.length; i++)
      if (entry.search.indexOf(terms[i]) < 0) return false
    return true
  }

  function filterList(list) {
    var out = []
    for (var i = 0; i < list.length; i++)
      if (root.matches(list[i])) out.push(list[i])
    return out
  }

  // Sections in display order. Favourites and static IPs come first because
  // they are the short, deliberate lists; the ~200 regional entries follow.
  readonly property var sections: {
    var out = []
    var favs = root.filterList(windscribe.favourites)
    if (favs.length > 0) out.push({ title: "FAVOURITES", items: favs })
    var statics = root.filterList(windscribe.staticIps)
    if (statics.length > 0) out.push({ title: "STATIC IPS", items: statics })
    for (var i = 0; i < windscribe.locationGroups.length; i++) {
      var group = windscribe.locationGroups[i]
      var items = root.filterList(group.items)
      if (items.length > 0) out.push({ title: group.region.toUpperCase(), items: items })
    }
    return out
  }

  // The flat view of `sections`, so a single index can address the cursor
  // across section boundaries.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < root.sections.length; i++) {
      var items = root.sections[i].items
      for (var j = 0; j < items.length; j++) out.push(items[j])
    }
    return out
  }

  // Offset of each section's first row within `rows`, so a row delegate can
  // work out its own flat index without the sections being flattened in QML.
  readonly property var sectionOffsets: {
    var out = []
    var running = 0
    for (var i = 0; i < root.sections.length; i++) {
      out.push(running)
      running += root.sections[i].items.length
    }
    return out
  }

  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)) }

  function selectedEntry() {
    if (root.rows.length === 0) return null
    return root.rows[root.clamp(root.selectedIndex, 0, root.rows.length - 1)]
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = root.clamp(root.selectedIndex, 0, root.rows.length - 1)
      root.revealSelected()
      return
    }
    root.selectedIndex = root.clamp(root.selectedIndex + delta, 0, root.rows.length - 1)
    root.revealSelected()
  }

  function jumpCursor(index) {
    if (root.rows.length === 0) return
    root.cursorActive = true
    root.selectedIndex = root.clamp(index, 0, root.rows.length - 1)
    root.revealSelected()
  }

  function activateCursor() {
    var entry = root.selectedEntry()
    if (!entry) return
    windscribe.connectToEntry(entry)
  }

  // Registered by each row delegate so the cursor can scroll itself into view.
  property var rowItems: ({})
  function registerRow(index, item) { root.rowItems[index] = item }
  // Filtering rebuilds every delegate, so the old index-to-item map is stale.
  onSectionsChanged: root.rowItems = ({})

  function revealSelected() {
    if (!panelFlick) return
    var item = root.rowItems[root.selectedIndex]
    if (!item) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    var margin = Style.space(8)
    if (top - margin < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom + margin > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(Math.max(0, panelFlick.contentHeight - panelFlick.height),
                                     bottom + margin - panelFlick.height)
  }

  onQueryChanged: {
    root.selectedIndex = 0
    root.cursorActive = root.query !== "" && root.rows.length > 0
  }

  function focusSearch() {
    root.searchFocused = true
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function leaveSearch() {
    root.searchFocused = false
    keyCatcher.forceActiveFocus()
  }

  // ----------------------------------------------------------------- actions

  function refreshNow() {
    windscribe.refresh()
    windscribe.loadLocations(true)
  }

  onOpenedChanged: if (opened) {
    root.cursorActive = false
    root.selectedIndex = 0
    root.nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    windscribe.refreshOnOpen()
    windscribe.loadLocations(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function connect(): string { windscribe.connectLast(); return "ok" }
    function disconnect(): string { windscribe.disconnect(); return "ok" }
    function status(): string { return windscribe.stateLabel + (windscribe.location !== "" ? " — " + windscribe.location : "") }
  }

  // -------------------------------------------------------------- bar button

  readonly property color barIconColor: {
    if (windscribe.connState === "logged-out" || windscribe.lastError !== "") return root.barForeground
    if (windscribe.connected) return root.accent
    if (windscribe.transitioning) return root.barForeground
    return Qt.darker(root.barForeground, 1.55)
  }

  readonly property string barLabel: root.showLabel && windscribe.connected ? windscribe.shortLocation : ""

  readonly property string barTooltip: {
    if (windscribe.lastError !== "") return "Windscribe — " + windscribe.lastError
    if (windscribe.connState === "logged-out") return "Windscribe — signed out"
    var parts = ["Windscribe — " + windscribe.stateLabel.toLowerCase()]
    if (windscribe.location !== "") parts.push(windscribe.location)
    if (windscribe.connected && windscribe.protocol !== "") parts.push(windscribe.protocol)
    return parts.join("\n")
  }

  // A slot whose item is invisible is collapsed by the bar, which is exactly
  // what `hideWhenDisconnected` wants — but never hide a problem the user
  // needs to see.
  visible: !root.hideWhenDisconnected
           || windscribe.connected
           || windscribe.transitioning
           || windscribe.connState === "logged-out"
           || windscribe.lastError !== ""

  implicitWidth: buttonLoader.item ? buttonLoader.item.implicitWidth : Style.bar.iconSlot
  implicitHeight: buttonLoader.item ? buttonLoader.item.implicitHeight : Style.bar.sizeHorizontal

  function pressBarButton(buttonCode) {
    if (buttonCode === Qt.RightButton) windscribe.toggleConnection()
    else if (buttonCode === Qt.MiddleButton) root.refreshNow()
    else root.toggle()
  }

  // Two button shapes rather than one: BarIconButton optically centres a lone
  // glyph, which a glyph-plus-text label neither needs nor tolerates.
  Loader {
    id: buttonLoader
    anchors.fill: parent
    sourceComponent: root.barLabel !== "" ? labelledButton : iconOnlyButton
  }

  Component {
    id: iconOnlyButton
    BarIconButton {
      bar: root.bar
      text: root.glyph
      foreground: root.barIconColor
      tooltipText: root.barTooltip
      opacity: root.transitioning ? root.pulseOpacity : 1
      onPressed: function(buttonCode) { root.pressBarButton(buttonCode) }
    }
  }

  Component {
    id: labelledButton
    WidgetButton {
      bar: root.bar
      text: root.glyph + "  " + root.barLabel
      fontSize: Style.font.caption
      foreground: root.barIconColor
      tooltipText: root.barTooltip
      opacity: root.transitioning ? root.pulseOpacity : 1
      onPressed: function(buttonCode) { root.pressBarButton(buttonCode) }
    }
  }

  // A slow breath while connecting: the CLI can take ten seconds or more, and
  // a static icon reads as a widget that has stopped working.
  SequentialAnimation {
    running: root.transitioning
    loops: Animation.Infinite
    alwaysRunToEnd: true
    onStopped: root.pulseOpacity = 1
    NumberAnimation { target: root; property: "pulseOpacity"; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseOpacity"; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
  }

  // Unread-style dot for the states that want the eye: a failed action, or a
  // sign-in the user has to complete before anything else works.
  Rectangle {
    visible: windscribe.lastError !== "" || windscribe.connState === "logged-out"
    anchors.right: buttonLoader.right
    anchors.top: buttonLoader.top
    anchors.rightMargin: Style.space(4)
    anchors.topMargin: Style.space(4)
    width: Style.space(5)
    height: width
    radius: width / 2
    color: root.urgent
  }

  // ------------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: buttonLoader
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field owns the keyboard, its own Keys handler routes
      // navigation; letter keys have to reach the field as text.
      blocked: root.searchFocused

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") root.focusSearch()
        else if (t === "r" || t === "R") root.refreshNow()
        else if (t === "d" || t === "D") windscribe.disconnect()
        else if (t === "b" || t === "B") windscribe.connectBest()
        else if (t === "c" || t === "C") windscribe.connectLast()
        else if (t === "f" || t === "F") windscribe.setFirewall(!windscribe.firewall)
        else if (t === "g") root.jumpCursor(0)
        else if (t === "G") root.jumpCursor(root.rows.length - 1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------------- Hero: what the connection is right now ----------

          PanelHero {
            id: hero
            width: parent.width
            // The city alone; the server nickname, protocol, allowance and
            // uptime all share the meta line below it. Data usage is a figure
            // worth a glance, not a sentence, so it rides there in its short
            // form rather than taking a box of its own.
            title: windscribe.connected && windscribe.shortLocation !== "" ? windscribe.shortLocation
                 : (windscribe.connState === "logged-out" ? "Windscribe" : windscribe.stateLabel)
            meta: {
              if (windscribe.connState === "logged-out") return "Signed out"
              if (!windscribe.internet) return "No internet connectivity"
              if (windscribe.connected) {
                var bits = []
                if (windscribe.serverNickname !== "") bits.push(windscribe.serverNickname)
                if (windscribe.protocol !== "") bits.push(windscribe.protocol)
                if (windscribe.dataSummary !== "") bits.push(windscribe.dataSummary)
                if (windscribe.connectedSinceMs > 0)
                  bits.push("up " + windscribe.formatDuration(root.nowMs - windscribe.connectedSinceMs))
                return bits.length > 0 ? bits.join(" · ") : "Connected"
              }
              // Disconnected still has an allowance worth showing.
              return windscribe.dataSummary !== ""
                     ? windscribe.stateLabel + " · " + windscribe.dataSummary
                     : windscribe.stateLabel
            }
            detail: ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: windscribe.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.glyph
                color: root.connected ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------------- Error strip ------------------------------------

          Text {
            visible: windscribe.lastError !== ""
            width: parent.width
            text: windscribe.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------------- Signed out ------------------------------------

          Text {
            visible: windscribe.connState === "logged-out"
            width: parent.width
            text: "Sign in from a terminal with `windscribe-cli login`, then reopen this panel."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // ---------------- Connection facts ------------------------------

          Column {
            visible: windscribe.connected
            width: parent.width
            spacing: Style.space(4)

            FactRow {
              width: parent.width
              label: "Tunnel IP"
              value: windscribe.tunnelIp !== "" ? windscribe.tunnelIp : "—"
            }

            FactRow {
              width: parent.width
              visible: root.showPublicIp
              label: "Public IP"
              value: windscribe.publicIp !== "" ? windscribe.publicIp : "looking up…"
            }

            FactRow {
              width: parent.width
              visible: windscribe.hasRates
              label: "Throughput"
              value: "↓ " + windscribe.formatRate(windscribe.rxRate) + "   ↑ " + windscribe.formatRate(windscribe.txRate)
            }
          }

          // ---------------- Controls --------------------------------------

          Row {
            visible: windscribe.connState !== "logged-out"
            width: parent.width
            spacing: Style.spacing.controlGap

            Button {
              text: windscribe.connected || windscribe.effectiveState === "connecting" ? "Disconnect" : "Connect"
              iconText: windscribe.connected || windscribe.effectiveState === "connecting" ? "󰅖" : "󰐊"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: !windscribe.busy || windscribe.transitioning
              onClicked: windscribe.toggleConnection()
            }

            Button {
              text: "Best"
              iconText: "󰓅"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              tooltipText: "Connect to the fastest location"
              onClicked: windscribe.connectBest()
            }
          }

          Toggle {
            width: parent.width
            visible: windscribe.connState !== "logged-out"
            label: "Firewall"
            description: windscribe.firewall ? "Blocking traffic outside the tunnel"
                                       : "Traffic is allowed outside the tunnel"
            checked: windscribe.firewall
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: windscribe.setFirewall(!windscribe.firewall)
          }

          PanelSeparator {
            visible: windscribe.connState !== "logged-out"
            foreground: root.foreground
          }

          // ---------------- Locations --------------------------------------

          TextField {
            id: searchField
            visible: windscribe.connState !== "logged-out"
            width: parent.width
            foreground: root.foreground
            accent: root.accent
            placeholderText: windscribe.locationsLoaded ? "Search locations" : "Loading locations…"
            onTextChanged: root.query = text
            onActiveFocusChanged: root.searchFocused = activeFocus
            onAccepted: root.activateCursor()

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) {
                root.moveCursor(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveCursor(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                if (root.query !== "") { searchField.text = "" }
                else root.leaveSearch()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                root.leaveSearch()
                event.accepted = true
              }
            }
          }

          Text {
            visible: windscribe.connState !== "logged-out" && windscribe.locationsLoaded && root.rows.length === 0
            width: parent.width
            text: root.query !== "" ? "No location matches “" + root.query + "”."
                                    : "No locations reported by windscribe-cli."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }

          Repeater {
            model: windscribe.connState === "logged-out" ? [] : root.sections

            Column {
              id: section
              required property var modelData
              required property int index

              width: column.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: section.modelData.title
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: section.modelData.items
                LocationRow {
                  required property var modelData
                  required property int index
                  width: column.width
                  entry: modelData
                  flatIndex: root.sectionOffsets[section.index] + index
                }
              }
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------------- components

  component FactRow: Item {
    id: fact
    property string label: ""
    property string value: ""

    implicitHeight: valueText.implicitHeight

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: fact.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: valueText
      anchors.right: parent.right
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: fact.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  component LocationRow: CursorSurface {
    id: locationRow

    property var entry: null
    property int flatIndex: 0

    // Not `hasCursor`: CursorSurface already declares that.
    readonly property bool cursorHere: root.cursorActive && root.selectedIndex === flatIndex
    // The location the CLI currently reports, matched loosely: `status` prints
    // "Copenhagen - LEGO" while the list holds city and nickname separately.
    readonly property bool isCurrent: {
      var entry = locationRow.entry
      if (!entry || !root.connected) return false
      var current = root.currentLocation
      return current === entry.city + " - " + entry.nickname
          || current === entry.city
          || (entry.nickname !== "" && current === entry.nickname)
    }

    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    current: locationRow.cursorHere || locationRow.isCurrent
    opacity: locationRow.entry && locationRow.entry.disabled ? 0.4 : 1
    implicitHeight: rowContent.implicitHeight + Style.spacing.lg

    Component.onCompleted: root.registerRow(locationRow.flatIndex, locationRow)
    onFlatIndexChanged: root.registerRow(locationRow.flatIndex, locationRow)

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        width: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        // Only the connected location is marked; a glyph on all 200 rows is
        // noise, but the column still reserves its width so nothing shifts.
        text: locationRow.isCurrent ? "󰄬" : ""
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        width: parent.width - Style.space(28) - speedText.width - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: locationRow.entry ? locationRow.entry.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: locationRow.isCurrent
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            if (!locationRow.entry) return ""
            var bits = []
            if (locationRow.entry.nickname !== "") bits.push(locationRow.entry.nickname)
            if (locationRow.entry.disabled) bits.push("unavailable")
            return bits.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: speedText
        anchors.verticalCenter: parent.verticalCenter
        text: locationRow.entry ? locationRow.entry.speed : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: !(locationRow.entry && locationRow.entry.disabled)
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.selectedIndex = locationRow.flatIndex
      }
      onClicked: windscribe.connectToEntry(locationRow.entry)
    }
  }
}
