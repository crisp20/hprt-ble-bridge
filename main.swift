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
let verbose    = env["HPRT_VERBOSE"] == "1"
let statusUUID = CBUUID(string: "FF03")
let serviceUUIDs = ["FF00", "49535343-FE7D-4AE5-8FA9-9FAFD205E455", "FFE0", "18F0"].map(CBUUID.init(string:))
let writeUUIDs = (env["HPRT_CHAR"].map { [$0] } ??
                  ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "FFE1", "2AF1"]).map(CBUUID.init(string:))
let listenPort = UInt16(env["HPRT_PORT"] ?? "") ?? 9100
let poweredOn = 5                                          // same raw value in CBCentralManagerState and CBManagerState

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
      self.completion = completion; self.payload = Data(data); self.offset = 0
      self.writeChar = nil; self.credits = 0; self.granted = 0; self.writes = 0
      self.maxLen = nil; self.draining = false; self.pumpScheduled = false; self.lastNotify = ""
      if self.central.state.rawValue == poweredOn { self.findPeripheral() } else { self.pendingStart = true }
      self.q.asyncAfter(deadline: .now() + 20) {
        if self.job == myJob && self.writeChar == nil {
          self.finish(BridgeError(description: "timeout: \(targetName) not found / no writable characteristic"))
        }
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
    log("bluetooth state: \(c.state.rawValue)  (5 = poweredOn, 3 = unauthorized)")
    if c.state.rawValue == poweredOn && pendingStart { pendingStart = false; findPeripheral() }
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
    if completion != nil {
      log("  disconnected after \(offset)/\(payload.count) B")
      finish(error ?? BridgeError(description: "disconnected mid-job"))
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
    if flow == "credit" {
      let myJob = job
      q.asyncAfter(deadline: .now() + 3) {
        if self.job == myJob && self.completion != nil && self.granted == 0 {
          self.finish(BridgeError(description: "no FF03 credits within 3 s – use HPRT_FLOW=delay or paced"))
        }
      }
    }
    pump()
  }

  // ---- sending ----
  private func chunkSize(_ p: CBPeripheral, _ t: CBCharacteristicWriteType) -> Int {
    return max(20, min(chunkCap, maxLen ?? chunkCap, p.maximumWriteValueLength(for: t)))
  }
  private func nextChunk(_ size: Int) -> Data {
    let end = min(offset + size, payload.count)
    let d = payload.subdata(in: offset..<end); offset = end; writes += 1
    return d
  }
  private func pump() {
    guard let p = peripheral, let ch = writeChar, completion != nil, !draining else { return }
    if offset >= payload.count { return drain() }
    switch flow {
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
  @available(OSX 10.13, *)
  func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { if flow == "credit" { pump() } }

  private func drain() {
    guard !draining else { return }
    draining = true
    let secs = Date().timeIntervalSince(started)
    log(String(format: "sent %d B in %.1f s (%d writes, %d credits granted)", payload.count, secs, writes, granted))
    let myJob = job
    q.asyncAfter(deadline: .now() + 1.5) { if self.job == myJob { self.finish(nil) } }  // let printer drain
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
      if flow == "credit" { pump() }
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
    completion = nil; writeChar = nil; central.stopScan()
    if let p = peripheral { central.cancelPeripheralConnection(p) }
    done(err)
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
  log("listening on 127.0.0.1:\(listenPort) for \(targetName) (flow \(flow), chunk \(chunkCap), delay \(delayMs) ms)")
  DispatchQueue(label: "accept").async {                       // one job at a time
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { if errno == EINTR { continue }; fatal("accept(): \(errnoText())") }
      var tv = timeval(tv_sec: 60, tv_usec: 0)                 // don't hang forever on a stalled sender
      _ = setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      guard let data = readAll(c) else { close(c); continue }
      log("job received: \(data.count) bytes")
      try? data.write(to: URL(fileURLWithPath: "/tmp/hprt-last-job-\(listenPort).bin"))
      let sem = DispatchSemaphore(value: 0)
      printer.send(data) { err in log(err.map { "job ERROR: \($0)" } ?? "job done"); sem.signal() }
      sem.wait(); close(c)                                     // close → CUPS marks job complete
    }
  }
  dispatchMain()
} else {
  print("usage: hprt-ble-bridge send <file> | serve   (env: HPRT_NAME, HPRT_PORT, HPRT_FLOW=delay|paced|credit, HPRT_CHUNK, HPRT_DELAY_MS, HPRT_GAP_MS, HPRT_VERBOSE=1)")
}
