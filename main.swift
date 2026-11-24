import Foundation
import CoreBluetooth
import Network

struct BridgeError: Error, CustomStringConvertible { let description: String }
let logFmt: DateFormatter = {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")   // fixed format, ignores user locale settings
  f.timeZone = .current                          // Mac's time zone (Asia/Hong_Kong)
  f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"   // e.g. 2026-11-24 16:19:29.123 +08:00
  return f
}()
func log(_ s: String) {
  FileHandle.standardError.write("\(logFmt.string(from: Date())) \(s)\n".data(using: .utf8)!)
}


let env = ProcessInfo.processInfo.environment
let targetName = env["HPRT_NAME"] ?? "D35BT-B3F8"
let flow       = env["HPRT_FLOW"] ?? "delay"               // delay | paced | credit
let chunkCap   = Int(env["HPRT_CHUNK"] ?? "") ?? 100
let delayMs    = Int(env["HPRT_DELAY_MS"] ?? "") ?? 20
let verbose    = env["HPRT_VERBOSE"] == "1"
let statusUUID = CBUUID(string: "FF03")
let serviceUUIDs = ["FF00", "49535343-FE7D-4AE5-8FA9-9FAFD205E455", "FFE0", "18F0"].map(CBUUID.init(string:))
let writeUUIDs = (env["HPRT_CHAR"].map { [$0] } ??
                  ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "FFE1", "2AF1"]).map(CBUUID.init(string:))

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
      self.maxLen = nil; self.draining = false; self.lastNotify = ""
      if self.central.state == .poweredOn { self.findPeripheral() } else { self.pendingStart = true }
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
    else { log("scanning for \(targetName)…"); central.scanForPeripherals(withServices: nil) }
  }
  private func connect(_ p: CBPeripheral) {
    peripheral = p; p.delegate = self
    log("connecting to \(p.name ?? "?")"); central.connect(p)
  }
  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    log("bluetooth state: \(c.state.rawValue)  (5 = poweredOn, 3 = unauthorized)")
    if c.state == .poweredOn && pendingStart { pendingStart = false; findPeripheral() }
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
    if let error { return finish(error) }
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
    max(20, min(chunkCap, maxLen ?? chunkCap, p.maximumWriteValueLength(for: t)))
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
      while credits > 0 && offset < payload.count && p.canSendWriteWithoutResponse {
        p.writeValue(nextChunk(size), for: ch, type: .withoutResponse); credits -= 1
      }
      if offset >= payload.count { drain() }
    case "paced":                                            // no ack, fixed gap
      if p.canSendWriteWithoutResponse {
        p.writeValue(nextChunk(chunkSize(p, .withoutResponse)), for: ch, type: .withoutResponse)
      }
      q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() }
    default:                                                 // "delay": ack + gap (proven)
      p.writeValue(nextChunk(chunkSize(p, .withResponse)), for: ch, type: .withResponse)
    }
  }
  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    if let error { return finish(error) }
    q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() }
  }
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
    if let error { log("  subscribe \(ch.uuid) failed: \(error)") }
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
      maxLen = Int(v[1]) | Int(v[2]) << 8
      log("  printer max packet: \(maxLen!) B")
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

let printer = BLEPrinter()
let args = CommandLine.arguments

if args.count >= 3 && args[1] == "send" {                      // one-shot test
  let data = try! Data(contentsOf: URL(fileURLWithPath: args[2]))
  printer.send(data) { err in
    if let err { log("ERROR: \(err)"); exit(1) }
    log("OK: sent \(data.count) bytes"); exit(0)
  }
  dispatchMain()
} else if args.count >= 2 && args[1] == "serve" {              // CUPS bridge
  let params = NWParameters.tcp
  params.requiredInterfaceType = .loopback                     // 127.0.0.1 only
  let listener = try! NWListener(using: params, on: 9100)
  let jobs = DispatchQueue(label: "jobs")                      // one job at a time
  func receiveAll(_ c: NWConnection, _ acc: Data, _ done: @escaping (Data) -> Void) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, complete, err in
      var acc = acc; if let d { acc.append(d) }
      if complete || err != nil { done(acc) } else { receiveAll(c, acc, done) }
    }
  }
  listener.newConnectionHandler = { c in
    c.start(queue: .global())
    receiveAll(c, Data()) { data in
      jobs.async {
        log("job received: \(data.count) bytes")
        try? data.write(to: URL(fileURLWithPath: "/tmp/hprt-last-job.bin"))
        let sem = DispatchSemaphore(value: 0)
        printer.send(data) { err in log(err.map { "job ERROR: \($0)" } ?? "job done"); sem.signal() }
        sem.wait(); c.cancel()                                 // close → CUPS marks job complete
      }
    }
  }
  listener.start(queue: .main)
  log("listening on 127.0.0.1:9100 for \(targetName) (flow \(flow), chunk \(chunkCap), delay \(delayMs) ms)")
  dispatchMain()
} else {
  print("usage: hprt-ble-bridge send <file> | serve   (env: HPRT_NAME, HPRT_FLOW=delay|paced|credit, HPRT_CHUNK, HPRT_DELAY_MS, HPRT_VERBOSE=1)")
}
