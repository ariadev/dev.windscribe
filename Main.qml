import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Data side of the Windscribe bar widget.
//
// Everything comes from `windscribe-cli`, which is fast (~50 ms) but has two
// traps worth stating once here rather than at every call site:
//
//   1. It exits 0 unconditionally — even for an unknown subcommand. Exit codes
//      carry no information, so success is judged by re-reading `status`, and
//      failures are recognised from the text the CLI prints.
//   2. `status` prints a variable number of labelled lines (`Update available:`
//      only shows up when there is one), so fields are looked up by label and
//      never by line index.
//
// One poll spawns one shell that runs `status` and reads the tunnel interface's
// byte counters in the same pass, so throughput costs no extra process.
Item {
  id: root
  visible: false

  property var settings: ({})

  // ------------------------------------------------------------------ state

  // Named `connState` rather than `state`: Item already has a `state` property
  // and shadowing it breaks QML's state machine in confusing ways.
  //
  // "connected" | "connecting" | "disconnected" | "disconnecting"
  // | "logged-out" | "unknown"
  property string connState: "unknown"

  property string location: ""      // as the CLI reports it, e.g. "Copenhagen - LEGO"
  property string protocol: ""      // e.g. "TCP:80"
  property bool firewall: false
  property string dataUsed: ""
  property string dataLimit: ""
  property bool loggedIn: false
  property bool internet: true
  property string updateAvailable: ""

  // Verbatim CLI complaint from the last action that failed, surfaced in the
  // panel. Cleared when a new action starts or a later status looks healthy.
  property string lastError: ""

  property bool everPolled: false

  // ------------------------------------------------------------- throughput

  property string iface: ""
  property string tunnelIp: ""
  property string publicIp: ""
  property real rxBytes: -1
  property real txBytes: -1
  property real rxRate: 0           // bytes/sec
  property real txRate: 0
  property real lastSampleMs: 0
  readonly property bool hasRates: iface !== "" && connected && rxBytes >= 0

  // Client-side, because the CLI does not report it: only known for a
  // connection this widget watched come up. Zero means "don't claim to know".
  property real connectedSinceMs: 0

  // -------------------------------------------------------------- locations

  property var locationGroups: []   // [{ region, items: [entry] }]
  property var favourites: []       // [entry]
  property var staticIps: []        // [entry]
  property var bestEntry: null
  property bool locationsLoaded: false
  property real locationsFetchedMs: 0
  readonly property bool locationsLoading: locationsProc.running

  // ----------------------------------------------------------- optimistic UI

  // A connect takes ten seconds or more. Rather than leave the bar looking
  // inert until the next poll agrees, an action states its intent here and the
  // UI reads `effectiveState`; the intent is dropped as soon as the CLI
  // confirms it, or abandoned by `desireTimeout` if it never does.
  property string desired: ""       // "" | "connected" | "disconnected"

  readonly property bool busy: statusProc.running || actionProc.running

  readonly property string effectiveState: {
    if (root.desired === "connected" && root.connState !== "connected") return "connecting"
    if (root.desired === "disconnected" && root.connState !== "disconnected") return "disconnecting"
    return root.connState
  }
  readonly property bool connected: effectiveState === "connected"
  readonly property bool transitioning: effectiveState === "connecting" || effectiveState === "disconnecting"

  // ----------------------------------------------------------------- config

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int pollIntervalSec: {
    var n = Number(setting("pollIntervalSec", 10))
    if (!isFinite(n) || n <= 0) n = 10
    return Math.max(2, Math.min(120, Math.round(n)))
  }
  // `omarchy bar set` writes strings unless given `--json`, so a boolean
  // setting arrives as either `true` or `"true"`. Accept both.
  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "string") {
      var lower = value.toLowerCase()
      return lower === "true" || lower === "1" || lower === "yes"
    }
    return value === true
  }

  readonly property bool showPublicIp: boolSetting("showPublicIp", false)

  // ------------------------------------------------------------------ polls

  // One shell, two jobs: the CLI status and the tunnel interface's counters.
  // The interface globs are deliberately narrow — a bare `wg*` would pick up
  // an unrelated WireGuard interface, and `tun*` alone would still miss the
  // AmneziaWG naming — so only Windscribe's own devices match.
  readonly property string statusScript: [
    'windscribe-cli status',
    'for d in /sys/class/net/tun[0-9]* /sys/class/net/*windscribe*; do',
    '  [ -d "$d" ] || continue',
    '  n=${d##*/}',
    '  echo "X-Iface: $n"',
    '  echo "X-Rx: $(cat "$d/statistics/rx_bytes" 2>/dev/null)"',
    '  echo "X-Tx: $(cat "$d/statistics/tx_bytes" 2>/dev/null)"',
    '  ip -4 -o addr show dev "$n" 2>/dev/null | awk \'NR==1 { split($4, a, "/"); print "X-Ip: " a[1] }\'',
    '  break',
    'done'
  ].join('\n')

  // `windscribe-cli` refuses to run twice at once ("Windscribe CLI is already
  // running") — the second invocation prints that instead of doing its job. So
  // every call goes through one gate: status, locations and actions never
  // overlap, and whatever was asked for meanwhile runs as soon as the line is
  // free.
  readonly property bool cliBusy: statusProc.running || locationsProc.running || actionProc.running

  property bool statusPending: false
  property bool locationsPending: false
  property bool locationsPendingForce: false

  // A CLI process that has exited has not necessarily released Windscribe's
  // single-instance lock yet, so back-to-back invocations still collide.
  // Everything queued waits out a short gap rather than starting immediately.
  onCliBusyChanged: if (!cliBusy) drainTimer.restart()

  Timer {
    id: drainTimer
    interval: 400
    onTriggered: root.drainPending()
  }

  function drainPending() {
    if (root.cliBusy) return
    if (root.statusPending) { root.statusPending = false; root.refresh(); return }
    if (root.locationsPending) {
      var force = root.locationsPendingForce
      root.locationsPending = false
      root.locationsPendingForce = false
      root.loadLocations(force)
    }
  }

  function refresh() {
    if (root.cliBusy) { root.statusPending = true; return }
    root.statusPending = false
    statusProc.running = true
  }

  function refreshOnOpen() { root.refresh() }

  Process {
    id: statusProc
    command: ["bash", "-c", root.statusScript]
    running: false

    onRunningChanged: {
      if (running) { stallTimer.restart(); return }
      stallTimer.stop()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }
  }

  // `windscribe-cli` talks to a local socket; if that socket wedges, the
  // process can hang forever and the widget would freeze with it.
  Timer {
    id: stallTimer
    interval: 8000
    onTriggered: {
      statusProc.running = false
      root.lastError = "windscribe-cli status timed out."
    }
  }

  Timer {
    id: pollTimer
    interval: (root.transitioning ? 2 : root.pollIntervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // An intent the CLI never honours must not pin the bar to "connecting"
  // forever — a failed connect is silent apart from the text it printed.
  Timer {
    id: desireTimeout
    interval: 45000
    onTriggered: {
      root.desired = ""
      if (root.lastError === "") root.lastError = "Windscribe did not reach the requested state."
    }
  }

  onDesiredChanged: root.desired === "" ? desireTimeout.stop() : desireTimeout.restart()

  // ------------------------------------------------------------ status parse

  function parseStatus(raw) {
    var text = String(raw || "")
    var lines = text.split("\n")
    var fields = ({})
    var extra = ({})

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var at = line.indexOf(": ")
      if (at < 0) continue
      var key = line.substring(0, at).trim()
      var value = line.substring(at + 2).trim()
      if (key.indexOf("X-") === 0) extra[key.substring(2)] = value
      else fields[key] = value
    }

    // No labelled line at all means the CLI printed something unexpected
    // (an error, or nothing because it is not installed). Say so rather than
    // silently reporting "disconnected".
    if (fields["Connect state"] === undefined && fields["Login state"] === undefined) {
      // Losing a race for the single-instance lock says nothing about the VPN.
      // Keep the last known state and try again shortly.
      if (text.toLowerCase().indexOf("already running") >= 0) {
        statusRetry.restart()
        return
      }
      root.connState = "unknown"
      // Only the CLI's own words — the interface readings this script appends
      // are not part of the complaint.
      var complaint = lines.filter(function(l) { return l.trim() !== "" && l.indexOf("X-") !== 0 })
                           .join("\n").trim()
      root.lastError = complaint !== "" ? complaint : "windscribe-cli returned no status."
      root.everPolled = true
      return
    }

    root.loggedIn = String(fields["Login state"] || "").toLowerCase().indexOf("logged in") === 0
    root.internet = String(fields["Internet connectivity"] || "available").toLowerCase() !== "unavailable"
    root.firewall = String(fields["Firewall state"] || "").toLowerCase() === "on"
    root.protocol = String(fields["Protocol"] || "")
    root.updateAvailable = String(fields["Update available"] || "")

    var usage = String(fields["Data usage"] || "")
    var slash = usage.indexOf(" / ")
    if (slash >= 0) {
      root.dataUsed = usage.substring(0, slash).trim()
      root.dataLimit = usage.substring(slash + 3).trim()
    } else {
      root.dataUsed = usage
      root.dataLimit = ""
    }

    var previous = root.connState
    var connect = String(fields["Connect state"] || "")

    if (!root.loggedIn) {
      root.connState = "logged-out"
      root.location = ""
    } else if (connect.indexOf("Connected:") === 0) {
      root.connState = "connected"
      root.location = connect.substring("Connected:".length).trim()
    } else if (connect.indexOf("Connecting:") === 0) {
      root.connState = "connecting"
      root.location = connect.substring("Connecting:".length).trim()
    } else if (connect.indexOf("Disconnecting") === 0) {
      root.connState = "disconnecting"
    } else if (connect.indexOf("Disconnected") === 0 || connect.indexOf("Not connected") === 0) {
      root.connState = "disconnected"
      root.location = ""
    } else {
      root.connState = "unknown"
    }

    // The intent has been honoured (or overtaken by the user doing something
    // else in the Windscribe GUI); either way stop overriding reality.
    if (root.desired !== "" && root.connState === root.desired) root.desired = ""
    if (root.connState === "logged-out") root.desired = ""

    if (root.connState === "connected" && previous !== "connected") {
      root.connectedSinceMs = Date.now()
      root.publicIp = ""
      if (root.showPublicIp) publicIpProc.running = true
    } else if (root.connState !== "connected" && previous === "connected") {
      root.connectedSinceMs = 0
      root.publicIp = ""
      root.rxRate = 0
      root.txRate = 0
    }

    // A status that parsed cleanly means whatever went wrong before is stale.
    if (root.connState !== "unknown") root.lastError = ""

    root.sampleThroughput(extra)
    root.everPolled = true
  }

  function sampleThroughput(extra) {
    var name = String(extra["Iface"] || "")
    if (name === "") {
      root.iface = ""
      root.tunnelIp = ""
      root.rxBytes = -1
      root.txBytes = -1
      root.rxRate = 0
      root.txRate = 0
      return
    }

    var rx = Number(extra["Rx"])
    var tx = Number(extra["Tx"])
    var now = Date.now()
    var sameIface = root.iface === name

    root.iface = name
    root.tunnelIp = String(extra["Ip"] || "")

    if (!isFinite(rx) || !isFinite(tx)) return

    var dt = (now - root.lastSampleMs) / 1000
    // Counters reset when the tunnel is torn down and rebuilt, so a negative
    // delta is a new tunnel rather than negative traffic.
    if (sameIface && dt > 0 && root.rxBytes >= 0 && rx >= root.rxBytes && tx >= root.txBytes) {
      root.rxRate = (rx - root.rxBytes) / dt
      root.txRate = (tx - root.txBytes) / dt
    } else {
      root.rxRate = 0
      root.txRate = 0
    }

    root.rxBytes = rx
    root.txBytes = tx
    root.lastSampleMs = now
  }

  Process {
    id: publicIpProc
    command: ["bash", "-c", "curl -sf --max-time 5 https://api.ipify.org"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ip = String(text || "").trim()
        // Only accept something that actually looks like an address; the
        // endpoint returning an HTML error page must not land in the panel.
        root.publicIp = /^[0-9a-fA-F:.]{7,45}$/.test(ip) ? ip : ""
      }
    }
  }

  // ---------------------------------------------------------------- actions

  // The CLI's exit code is always 0, so failure has to be read out of the text
  // it printed. These are the phrases it uses for conditions the user can act
  // on; anything else is treated as chatter and ignored.
  readonly property var failureMarkers: [
    "internet connectivity is not available",
    "not logged in",
    "you must be logged in",
    "failed",
    "unable to",
    "error",
    "invalid",
    "no such location",
    "key limit"
  ]

  function looksLikeFailure(text) {
    var lower = String(text || "").toLowerCase()
    if (lower === "") return false
    for (var i = 0; i < root.failureMarkers.length; i++)
      if (lower.indexOf(root.failureMarkers[i]) >= 0) return true
    return false
  }

  Process {
    id: actionProc
    running: false

    property string outText: ""
    property string errText: ""

    onRunningChanged: if (running) { outText = ""; errText = "" }

    stdout: StdioCollector { waitForEnd: true; onStreamFinished: actionProc.outText = text.trim() }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: actionProc.errText = text.trim() }

    onExited: {
      // The collectors may still be draining when this fires.
      Qt.callLater(function() {
        var combined = [actionProc.outText, actionProc.errText].filter(function(s) { return s !== "" }).join("\n")
        if (root.looksLikeFailure(combined)) {
          root.lastError = combined
          root.desired = ""
        }
        root.refresh()
      })
    }
  }

  function runAction(command, intent) {
    if (actionProc.running) return
    root.lastError = ""
    if (intent !== undefined && intent !== "") root.desired = intent
    actionProc.command = command
    actionProc.running = true
  }

  // `-n` returns immediately instead of blocking for the whole handshake, so a
  // disconnect issued mid-connect is not queued behind it.
  function connectTo(target) {
    var command = ["windscribe-cli", "connect", "-n"]
    if (target !== undefined && target !== null && String(target) !== "") command.push(String(target))
    root.runAction(command, "connected")
  }

  function connectBest() { root.connectTo("best") }
  function connectLast() { root.connectTo("") }
  function disconnect() { root.runAction(["windscribe-cli", "disconnect", "-n"], "disconnected") }
  function setFirewall(on) { root.runAction(["windscribe-cli", "firewall", on ? "on" : "off"], "") }

  function toggleConnection() {
    if (root.connected || root.effectiveState === "connecting") root.disconnect()
    else root.connectLast()
  }

  // -------------------------------------------------------------- locations

  Process {
    id: locationsProc
    command: ["bash", "-c",
      "windscribe-cli locations; sleep 0.4; " +
      "echo '---FAV---'; windscribe-cli locations fav; sleep 0.4; " +
      "echo '---STATIC---'; windscribe-cli locations static"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseLocations(text)
    }
  }

  function loadLocations(force) {
    if (!force && root.locationsLoaded && Date.now() - root.locationsFetchedMs < 600000) return
    if (root.cliBusy) {
      root.locationsPending = true
      if (force) root.locationsPendingForce = true
      return
    }
    root.locationsFetchedMs = Date.now()
    locationsProc.running = true
  }

  // Lines read `Region - City - Nickname (Speed)`, with a literal `(Disabled)`
  // wedged in before the speed when the location is unavailable, and the
  // nickname absent on some entries. The trailing parenthesised group is
  // always the speed, so it is peeled off the end first.
  function parseLocationLine(line) {
    var text = String(line || "").trim()
    if (text === "") return null

    // Every real entry ends in a parenthesised speed. Requiring it is what
    // keeps the CLI's own chatter — "Windscribe CLI is already running",
    // "No locations." — from being parsed as places you could connect to.
    var match = text.match(/^(.*\S)\s\(([^()]*)\)\s*$/)
    if (!match) return null
    var head = match[1]
    var speed = match[2]

    // Disabled entries usually read `... (Disabled) (10 Gbps)`, but when the
    // location has no speed at all the marker is the only parenthesised group
    // and lands in `speed` instead.
    var disabled = false
    if (speed === "Disabled") {
      disabled = true
      speed = ""
    }
    if (/\(Disabled\)\s*$/.test(head)) {
      disabled = true
      head = head.replace(/\s*\(Disabled\)\s*$/, "")
    }

    if (head === "") return null

    var parts = head.split(" - ")
    if (parts.length === 0) return null

    var region = parts[0].trim()
    var city = parts.length > 1 ? parts[1].trim() : ""
    var nickname = parts.length > 2 ? parts.slice(2).join(" - ").trim() : ""

    // Nicknames are the CLI's own unique handles, so they are the safest
    // connect target; the city name is the fallback when there is no nickname.
    var target = nickname !== "" ? nickname : (city !== "" ? city : region)

    return {
      region: region,
      city: city,
      nickname: nickname,
      speed: speed,
      disabled: disabled,
      target: target,
      label: city !== "" ? city : region,
      search: (region + " " + city + " " + nickname).toLowerCase()
    }
  }

  function parseLocationSection(block) {
    var lines = String(block || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var entry = root.parseLocationLine(lines[i])
      if (entry) out.push(entry)
    }
    return out
  }

  function parseLocations(raw) {
    var text = String(raw || "")
    var favAt = text.indexOf("---FAV---")
    var staticAt = text.indexOf("---STATIC---")

    var allBlock = favAt >= 0 ? text.substring(0, favAt) : text
    var favBlock = favAt >= 0 ? text.substring(favAt + 9, staticAt >= 0 ? staticAt : text.length) : ""
    var staticBlock = staticAt >= 0 ? text.substring(staticAt + 12) : ""

    var all = root.parseLocationSection(allBlock)

    // The internal gate keeps this widget from colliding with itself, but the
    // Windscribe GUI can hold the CLI too, and that reads as an empty list.
    // Retry rather than replacing a good list with nothing.
    if (all.length === 0 && text.toLowerCase().indexOf("already running") >= 0) {
      locationsRetry.restart()
      return
    }

    var best = null
    var groups = []
    var index = ({})

    for (var i = 0; i < all.length; i++) {
      var entry = all[i]
      if (entry.region === "Best Location") {
        entry.label = "Best Location"
        entry.target = "best"
        best = entry
        continue
      }
      if (index[entry.region] === undefined) {
        index[entry.region] = groups.length
        groups.push({ region: entry.region, items: [] })
      }
      groups[index[entry.region]].items.push(entry)
    }

    root.bestEntry = best
    root.locationGroups = groups
    root.favourites = root.parseLocationSection(favBlock)

    // Static entries connect through a different subcommand shape, so they
    // carry their own target form rather than the plain nickname.
    var statics = root.parseLocationSection(staticBlock)
    for (var s = 0; s < statics.length; s++) statics[s].isStatic = true
    root.staticIps = statics

    root.locationsLoaded = true
  }

  Timer {
    id: locationsRetry
    interval: 3000
    onTriggered: root.loadLocations(true)
  }

  Timer {
    id: statusRetry
    interval: 1500
    onTriggered: root.refresh()
  }

  function connectToEntry(entry) {
    if (!entry || entry.disabled) return
    if (entry.isStatic === true) {
      var name = entry.city !== "" ? entry.city : entry.target
      root.runAction(["windscribe-cli", "connect", "-n", "static", name], "connected")
      return
    }
    root.connectTo(entry.target)
  }

  // ----------------------------------------------------------- presentation

  function formatRate(bytesPerSecond) {
    var n = Number(bytesPerSecond)
    if (!isFinite(n) || n < 0) n = 0
    if (n < 1024) return Math.round(n) + " B/s"
    if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB/s"
    return (n / (1024 * 1024)).toFixed(1) + " MB/s"
  }

  function formatDuration(ms) {
    var total = Math.floor(Number(ms) / 1000)
    if (!isFinite(total) || total < 0) return ""
    var hours = Math.floor(total / 3600)
    var minutes = Math.floor((total % 3600) / 60)
    if (hours > 0) return hours + "h " + minutes + "m"
    if (minutes > 0) return minutes + "m " + (total % 60) + "s"
    return total + "s"
  }

  // The city on its own is what belongs in a bar, not "Copenhagen - LEGO".
  readonly property string shortLocation: {
    var full = String(root.location || "")
    if (full === "") return ""
    var dash = full.indexOf(" - ")
    return dash > 0 ? full.substring(0, dash) : full
  }

  // Data usage compressed to fit on the meta line: "2.70 GB" / "Unlimited"
  // becomes "2.7GB/∞". parseFloat drops the trailing zeros the CLI pads its
  // figures with, and an unmetered plan is a symbol rather than a word — the
  // line it sits on is already carrying four facts.
  readonly property string dataSummary: {
    if (root.dataUsed === "") return ""
    var match = root.dataUsed.match(/^([\d.]+)\s*(\S+)$/)
    var used = match ? String(parseFloat(match[1])) + match[2] : root.dataUsed.replace(/\s+/g, "")
    var limit = root.dataLimit.replace(/\s+/g, "")
    if (limit.toLowerCase() === "unlimited") limit = "∞"
    return limit !== "" ? used + "/" + limit : used
  }

  // The other half of "Copenhagen - LEGO": the server's nickname.
  readonly property string serverNickname: {
    var full = String(root.location || "")
    var dash = full.indexOf(" - ")
    return dash > 0 ? full.substring(dash + 3) : ""
  }

  readonly property string stateLabel: {
    switch (root.effectiveState) {
      case "connected": return "Connected"
      case "connecting": return "Connecting"
      case "disconnecting": return "Disconnecting"
      case "disconnected": return "Disconnected"
      case "logged-out": return "Signed out"
      default: return root.everPolled ? "Unavailable" : "Checking"
    }
  }
}
