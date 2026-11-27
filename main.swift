import Foundation
import CoreBluetooth
// Builds with Swift 4.0.3 (Xcode/CLT 9.2, macOS 10.12.6) up to current Swift. No Network.framework.

struct BridgeError: Error, CustomStringConvertible { let description: String }
let logFmt: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")   // fixed format, ignores user locale settings
  f.timeZone = TimeZone.current                  // Mac's time zone (Asia/Hong_Kong)
  f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"   // e.g. 2026-11-24 16:19:29.123 +08:00
  return f
}()
func log(_ s: String) {
  FileHandle.standardError.write("\(logFmt.string(from: Date())) \(s)\n".data(using: .utf8)!)
}
func errnoText() -> String { return String(cString: strerror(errno)) }
func fatal(_ s: String) -> Never { log("FATAL: \(s)"); exit(1) }

let env = ProcessInfo.processInfo.environment
let targetName = env["HPRT_NAME"] ?? "D35BT-B3F8"
let flow       = env["HPRT_FLOW"] ?? "delay"               // delay | paced | credit
let chunkCap   = Int(env["HPRT_CHUNK"] ?? "") ?? 100
let delayMs    = Int(env["HPRT_DELAY_MS"] ?? "") ?? 20
let legacyGapMs = Int(env["HPRT_GAP_MS"] ?? "") ?? 8       // credit mode on macOS < 10.13 only
let drainMs    = max(0, Int(env["HPRT_DRAIN_MS"] ?? "") ?? 250)      // drain wait to preserve end of job
let verbose    = env["HPRT_VERBOSE"] == "1"
let statusUUID = CBUUID(string: "FF03")
let serviceUUIDs = ["FF00", "49535343-FE7D-4AE5-8FA9-9FAFD205E455", "FFE0", "18F0"].map(CBUUID.init(string:))
let writeUUIDs = (env["HPRT_CHAR"].map { [$0] } ??
                  ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "FFE1", "2AF1"]).map(CBUUID.init(string:))
let listenPort = UInt16(env["HPRT_PORT"] ?? "") ?? 9100
let poweredOn = 5                                          // same raw value in CBCentralManagerState and CBManagerState
let mergeCopies = env["HPRT_MERGE"] != "0"     // merge byte-identical consecutive labels into one CPCL quantity
let keepAliveMs = max(0, Int(env["HPRT_KEEPALIVE_MS"] ?? "") ?? 0)   // 0 = disconnect after every job (today)

final class BLEPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let q = DispatchQueue(label: "ble")
  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private var payload = Data()
  private var offset = 0
  private var credits = 0, granted = 0, writes = 0
  private var maxLen: Int?
  private var draining = false
  private var pumpScheduled = false
  private var started = Date()
  private var lastNotify = ""
  private var completion: ((Error?) -> Void)?
  private var pendingStart = false
  private var job = 0
  private var mode = flow
  private var idleTimer: DispatchWorkItem?
  private var closing = false           // we called cancelPeripheralConnection on a connected link
  private var startAfterClose = false   // a job arrived while closing
  private var quietDisconnect = false   // we called cancel ourselves; don't log the callback as a dro

  override init() { super.init(); central = CBCentralManager(delegate: self, queue: q) }

  // ---- public entry point ----
  func send(_ data: Data, completion: @escaping (Error?) -> Void) {
    let head = String(decoding: data.prefix(5), as: UTF8.self)
    if data.isEmpty || head.hasPrefix("%!") || head.hasPrefix("%PDF") {
      return completion(BridgeError(description:
        "refusing \(data.count) B: not printer data (starts with \(head.debugDescription))"))
    }
    q.async {
      self.job += 1; let myJob = self.job
      self.idleTimer?.cancel(); self.idleTimer = nil
      self.completion = completion; self.payload = Data(data); self.offset = 0
      self.granted = 0; self.writes = 0                         // per-job stats only
      self.draining = false; self.pumpScheduled = false; self.lastNotify = ""; self.mode = flow
      if self.closing, self.peripheral?.state == .disconnected { self.closing = false }   // safety
      if let p = self.peripheral, p.state == .connected, self.writeChar != nil, !self.closing {
        self.reuseLink()
      } else {
        self.writeChar = nil; self.credits = 0; self.maxLen = nil
        if self.closing { self.startAfterClose = true; log("link closing, reconnecting after disconnect") }
        else if self.central.state.rawValue == poweredOn { self.findPeripheral() }
        else { self.pendingStart = true }
      }
      self.q.asyncAfter(deadline: .now() + 20) {
        if self.job == myJob && self.writeChar == nil {
          self.finish(BridgeError(description: "timeout: \(targetName) not found / no writable characteristic"))
        }
      }
    }
  }

  private func reuseLink() {
    guard let p = peripheral, let ch = writeChar else { return }
    started = Date()
    log("reusing open link: writing \(payload.count) B to \(ch.uuid), \(credits) credits carried over")
    if mode == "credit" {
      if credits == 0,
         let st = (p.services ?? []).flatMap({ $0.characteristics ?? [] }).first(where: { $0.uuid == statusUUID }) {
        log("  no credits left, re-subscribing to \(st.uuid)")      // untested: re-trigger the credit handshake
        p.setNotifyValue(false, for: st); p.setNotifyValue(true, for: st)
      }
      armCreditFallback()
    }
    pump()
  }

  private func armCreditFallback() {
    let myJob = job
    q.asyncAfter(deadline: .now() + 3) {
      if self.job == myJob && self.completion != nil && self.granted == 0 && self.offset < self.payload.count {
        log("  no FF03 credits within 3 s - falling back to delay mode for this job")
        self.mode = "delay"; self.pump()
      }
    }
  }

  // ---- discovery / connection ----
  private func findPeripheral() {
    let already = central.retrieveConnectedPeripherals(withServices: serviceUUIDs)
    if let p = already.first(where: { $0.name == targetName }) ?? peripheral { connect(p) }
    else { log("scanning for \(targetName)…"); central.scanForPeripherals(withServices: nil, options: nil) }
  }
  private func connect(_ p: CBPeripheral) {
    peripheral = p; p.delegate = self
    log("connecting to \(p.name ?? "?")"); central.connect(p, options: nil)
  }
  func centralManagerDidUpdateState(_ c: CBCentralManager) {
      let s = c.state.rawValue
      switch s {
        case 2:    log("bluetooth state: 2 (unsupported) - FATAL: this Mac has no Bluetooth LE. Needs a Bluetooth 4.0+ Mac or a USB BLE adapter (BCM20702).")
        case 3:    log("bluetooth state: 3 (unauthorized) - allow Bluetooth for hprt-ble-bridge in Privacy settings")
        case 4:    log("bluetooth state: 4 (powered off) - turn Bluetooth on; the bridge resumes by itself")
        case 0, 1: log("bluetooth state: \(s) (\(s == 0 ? "unknown" : "resetting"), waiting)")
        default:   log("bluetooth state: \(s) (5 = poweredOn)")
      }
      if s == poweredOn && pendingStart { pendingStart = false; findPeripheral() }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                      advertisementData ad: [String: Any], rssi: NSNumber) {
    guard ((ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name) == targetName else { return }
    c.stopScan(); connect(p)
  }
  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices(nil) }
  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    finish(error ?? BridgeError(description: "connect failed"))
  }
  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    let ours = closing || quietDisconnect
    closing = false; quietDisconnect = false; writeChar = nil; credits = 0; maxLen = nil
    idleTimer?.cancel(); idleTimer = nil
    if startAfterClose {                                    // a job was waiting for our own disconnect
      startAfterClose = false
      if central.state.rawValue == poweredOn { findPeripheral() } else { pendingStart = true }
      return
    }
    if completion != nil {
      log("  disconnected after \(offset)/\(payload.count) B")
      finish(error ?? BridgeError(description: "disconnected mid-job"))
    } else if !ours {
      log("link dropped while idle\(error.map { ": \($0.localizedDescription)" } ?? ""); next job reconnects")
    }
  }

  // ---- services / characteristics ----
  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error { return finish(error) }
    for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
  }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    if verbose { for ch in s.characteristics ?? [] { log("  char \(ch.uuid) props=0x\(String(ch.properties.rawValue, radix: 16))") } }
    for ch in s.characteristics ?? [] where ch.properties.contains(.notify) {
      p.setNotifyValue(true, for: ch)                       // printer status (FF01/FF03)
    }
    guard writeChar == nil, completion != nil,
          let ch = s.characteristics?.first(where: {
            writeUUIDs.contains($0.uuid) &&
            ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) })
    else { return }
    writeChar = ch; started = Date()
    log("writing \(payload.count) B to \(ch.uuid): flow \(flow), chunk ≤\(chunkCap) B, delay \(delayMs) ms")
    if mode == "credit" { armCreditFallback() }
    pump()
  }

  // ---- sending ----
  private func chunkSize(_ p: CBPeripheral, _ t: CBCharacteristicWriteType) -> Int {
    var osMax = 20                                           // BLE minimum (default MTU 23 − 3)
    if #available(OSX 10.12, *) { osMax = p.maximumWriteValueLength(for: t) }
    return max(20, min(chunkCap, maxLen ?? chunkCap, osMax))
  }
  private func nextChunk(_ size: Int) -> Data {
    let end = min(offset + size, payload.count)
    let d = payload.subdata(in: offset..<end); offset = end; writes += 1
    return d
  }
  private func pump() {
    guard let p = peripheral, let ch = writeChar, completion != nil, !draining else { return }
    if offset >= payload.count { return drain() }
    switch mode {
    case "credit":                                           // send as many as the printer allows
      let size = chunkSize(p, .withoutResponse)
      if #available(OSX 10.13, *) {
        while credits > 0 && offset < payload.count && p.canSendWriteWithoutResponse {
          p.writeValue(nextChunk(size), for: ch, type: .withoutResponse); credits -= 1
        }
        if offset >= payload.count { drain() }
      } else if credits > 0 && !pumpScheduled {              // 10.12: no send-queue signal → 1 packet per gap
        p.writeValue(nextChunk(size), for: ch, type: .withoutResponse); credits -= 1
        if offset >= payload.count { return drain() }
        pumpScheduled = true
        q.asyncAfter(deadline: .now() + .milliseconds(legacyGapMs)) { self.pumpScheduled = false; self.pump() }
      }
    case "paced":                                            // no ack, fixed gap
      if #available(OSX 10.13, *) {
        if p.canSendWriteWithoutResponse {
          p.writeValue(nextChunk(chunkSize(p, .withoutResponse)), for: ch, type: .withoutResponse)
        }
      } else {
        p.writeValue(nextChunk(chunkSize(p, .withoutResponse)), for: ch, type: .withoutResponse)
      }
      q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() }
    default:                                                 // "delay": ack + gap (proven)
      p.writeValue(nextChunk(chunkSize(p, .withResponse)), for: ch, type: .withResponse)
    }
  }
  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    if let error = error { return finish(error) }
    q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() }
  }
  // Called only by macOS 10.13+; on 10.12 CoreBluetooth never calls it (pump() has its own #available checks)
  func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { if mode == "credit" { pump() } }

  private func drain() {
    guard !draining else { return }
    draining = true
    let secs = Date().timeIntervalSince(started)
    log(String(format: "sent %d B in %.1f s (%d writes, %d credits granted)", payload.count, secs, writes, granted))
    log("drain \(drainMs) ms")
    let myJob = job
    q.asyncAfter(deadline: .now() + .milliseconds(drainMs)) { if self.job == myJob { self.finish(nil) } }  // let printer drain
  }

  // ---- printer status ----
  func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
    if let error = error { log("  subscribe \(ch.uuid) failed: \(error)") }
  }
  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let v = ch.value.map({ [UInt8]($0) }), !v.isEmpty else { return }
    if ch.uuid == statusUUID && v[0] == 0x01 && v.count >= 2 {       // 01 nn = +nn credits
      credits += Int(v[1]); granted += Int(v[1])
      if verbose { log("  +\(v[1]) credits (now \(credits))") }
      if mode == "credit" { pump() }
      return
    }
    if ch.uuid == statusUUID && v[0] == 0x02 && v.count >= 3 {       // 02 lo hi = max packet
      let m = Int(v[1]) | (Int(v[2]) << 8)
      maxLen = m
      log("  printer max packet: \(m) B")
      return
    }
    let hex = v.map { String(format: "%02x", $0) }.joined()
    if hex != lastNotify { log("  notify \(ch.uuid): \(hex)"); lastNotify = hex }
  }

  // ---- cleanup ----
  private func finish(_ err: Error?) {
    guard let done = completion else { return }
    completion = nil; central.stopScan()
    if err == nil, keepAliveMs > 0, let p = peripheral, p.state == .connected, writeChar != nil {
      let w = DispatchWorkItem { [weak self] in self?.closeLink("idle \(keepAliveMs) ms") }
      idleTimer = w
      q.asyncAfter(deadline: .now() + .milliseconds(keepAliveMs), execute: w)
    } else {
      closeLink(nil)
    }
    done(err)
  }

  private func closeLink(_ why: String?) {
    idleTimer?.cancel(); idleTimer = nil
    writeChar = nil
    guard let p = peripheral, p.state != .disconnected else { return }
    if let why = why { log("\(why), disconnecting") }
    if p.state == .connected { closing = true }   // only then is didDisconnect guaranteed
    quietDisconnect = true
    central.cancelPeripheralConnection(p)
  }
}

// ---- TCP listener (BSD sockets, 127.0.0.1 only) ----
func listenLoopback(_ port: UInt16) -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  if fd < 0 { fatal("socket(): \(errnoText())") }
  var yes: Int32 = 1                                          // allow quick restart (TIME_WAIT)
  _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  if rc != 0 { fatal("cannot listen on 127.0.0.1:\(port): \(errnoText())") }
  if listen(fd, 8) != 0 { fatal("listen(): \(errnoText())") }
  return fd
}
func readAll(_ c: Int32) -> Data? {
  var buf = [UInt8](repeating: 0, count: 1 << 16)
  var data = Data()
  while true {
    let n = read(c, &buf, buf.count)
    if n > 0 { data.append(buf, count: n) }
    else if n == 0 { return data }                            // CUPS finished sending
    else if errno == EINTR { continue }
    else { log("job ERROR: receive failed after \(data.count) B: \(errnoText())"); return nil }
  }
}

/// Splits a raster-cpcl job into labels ("! 0 …" up to "PRINT") and merges runs of
/// byte-identical consecutive labels into one label with CPCL quantity N.
/// data == nil: send the original job; summary says why.
func mergeIdenticalLabels(_ job: Data) -> (data: Data?, summary: String) {
    let b = [UInt8](job), n = b.count
    let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D
    let header = Array("! 0 ".utf8), cg = Array("CG ".utf8), eg = Array("EG ".utf8)

    func matches(_ p: [UInt8], at k: Int) -> Bool {
        return k + p.count <= n && b[k..<k + p.count].elementsEqual(p)
    }
    func lineEnd(from k: Int) -> Int? {
        var i = k
        while i < n { if b[i] == LF { return i }; i += 1 }
        return nil
    }
    func text(_ from: Int, _ lf: Int) -> String {            // line without CR/LF
        var e = lf
        while e > from && b[e - 1] == CR { e -= 1 }
        return String(bytes: b[from..<e], encoding: .ascii) ?? ""
    }
    func skip(_ why: String) -> (data: Data?, summary: String) { return (nil, "not merged: " + why) }

    // prefix (512 x 0x00 + CRLF) = everything before the first header
    var first = 0
    while first < n && !matches(header, at: first) { first += 1 }
    if first >= n { return skip("no CPCL header found") }

    var labels: [(start: Int, qtyEnd: Int, end: Int)] = []   // qtyEnd: index just after the quantity "1"
    var i = first
    while true {
        while i < n && (b[i] == CR || b[i] == LF) { i += 1 }
        if i >= n { break }
        let no = labels.count + 1
        guard matches(header, at: i), let hLF = lineEnd(from: i) else { return skip("label \(no): no header at byte \(i)") }
        let hText = text(i, hLF), h = hText.split(separator: " ")
        guard h.count == 6, h[5] == "1" else { return skip("label \(no): header '\(hText)' is not quantity 1") }
        var qtyEnd = hLF
        while qtyEnd > i && b[qtyEnd - 1] == CR { qtyEnd -= 1 }

        var j = hLF + 1, done = false
        while j < n && !done {
            guard let le = lineEnd(from: j) else { return skip("label \(no): line at byte \(j) has no line end") }
            if matches(cg, at: j) || matches(eg, at: j) {
                // measured layout: "CG w h x y" CRLF, then exactly w*h bitmap bytes, then the next command
                let f = text(j, le).split(separator: " ").dropFirst().map { Int(String($0)) }
                guard f.count == 4, let w = f[0], let ht = f[1], w > 0, ht > 0 else {
                    return skip("label \(no): unexpected graphics line '\(text(j, le))'")
                }
                j = le + 1 + w * ht                            // skip the bitmap: it may contain any byte
                guard j <= n else { return skip("label \(no): bitmap runs past the end of the job") }
                continue
            }
            if text(j, le) == "PRINT" { done = true }
            j = le + 1
        }
        guard done else { return skip("label \(no): no PRINT") }
        labels.append((i, qtyEnd, j))
        i = j
    }

    var out = Array(b[0..<first]), runs: [Int] = [], g = 0
    while g < labels.count {
        let L = labels[g], body = b[L.start..<L.end]
        var run = 1
        while g + run < labels.count && run < 1024 {           // CPCL quantity max 1024
            let M = labels[g + run]
            guard M.end - M.start == body.count, b[M.start..<M.end].elementsEqual(body) else { break }
            run += 1
        }
        if run == 1 {
            out += body
        } else {
            out += b[L.start..<(L.qtyEnd - 1)]                 // header without its "1"
            out += Array(String(run).utf8)
            out += b[L.qtyEnd..<L.end]
        }
        runs.append(run); g += run
    }
    if runs.count == labels.count {
        return skip(labels.count == 1 ? "only 1 label" : "\(labels.count) labels, no two consecutive ones identical")
    }
    out += b[labels[labels.count - 1].end..<n]
    let qty = runs.map { String($0) }.joined(separator: "+")
    return (out.withUnsafeBufferPointer { Data(buffer: $0) }, "merged \(labels.count) labels into \(runs.count) (qty \(qty))")
}


let printer = BLEPrinter()
let args = CommandLine.arguments

if args.count >= 3 && args[1] == "send" {                      // one-shot test
  let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
  printer.send(data) { err in
    if let err = err { log("ERROR: \(err)"); exit(1) }
    log("OK: sent \(data.count) bytes"); exit(0)
  }
  dispatchMain()
} else if args.count >= 2 && args[1] == "serve" {              // CUPS bridge
  signal(SIGPIPE, SIG_IGN)
  let fd = listenLoopback(listenPort)                          // exits with FATAL if the port is taken
  log("listening on 127.0.0.1:\(listenPort) for \(targetName) (flow \(flow), chunk \(chunkCap), delay \(delayMs) ms), drain \(drainMs) ms")
  DispatchQueue(label: "accept").async {                       // one job at a time
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { if errno == EINTR { continue }; fatal("accept(): \(errnoText())") }
      log("connection accepted")
      var tv = timeval(tv_sec: 60, tv_usec: 0)                 // don't hang forever on a stalled sender
      _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      guard let data = readAll(c) else { close(c); continue }
      log("job received: \(data.count) bytes")
      try? data.write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/hprt-last-job-\(listenPort).bin"))
      var outJob = data
      if mergeCopies {
        let m = mergeIdenticalLabels(data)
        if let d = m.data { outJob = d }
        log("\(m.summary): \(data.count) → \(outJob.count) B")
      }

      let sem = DispatchSemaphore(value: 0)
      printer.send(outJob) { err in log(err.map { "job ERROR: \($0)" } ?? "job done"); sem.signal() }
      sem.wait(); close(c)                                     // close → CUPS marks job complete
    }
  }
  dispatchMain()
} else {
  print("usage: hprt-ble-bridge send <file> | serve   (env: HPRT_NAME, HPRT_PORT, HPRT_FLOW=delay|paced|credit, HPRT_CHUNK, HPRT_DELAY_MS, HPRT_GAP_MS, HPRT_VERBOSE=1)")
}
