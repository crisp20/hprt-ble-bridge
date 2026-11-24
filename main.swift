import Foundation
import CoreBluetooth
import Network

struct BridgeError: Error, CustomStringConvertible { let description: String }
func log(_ s: String) { FileHandle.standardError.write("\(Date()) \(s)\n".data(using: .utf8)!) }

let env = ProcessInfo.processInfo.environment
let targetName = env["HPRT_NAME"] ?? "D35BT-B3F8"
let chunkCap   = Int(env["HPRT_CHUNK"] ?? "") ?? 180
let fast       = env["HPRT_FAST"] == "1"                  // use write-without-response
let delayMs    = Int(env["HPRT_DELAY_MS"] ?? "") ?? 0     // pause between chunks
let serviceUUIDs = ["FF00", "49535343-FE7D-4AE5-8FA9-9FAFD205E455", "FFE0", "18F0"].map(CBUUID.init(string:))
let writeUUIDs = (env["HPRT_CHAR"].map { [$0] } ??
                  ["FF02", "49535343-8841-43F4-A8D4-ECBE34729BB3", "FFE1", "2AF1"]).map(CBUUID.init(string:))

final class BLEPrinter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let q = DispatchQueue(label: "ble")
  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private var writeType: CBCharacteristicWriteType = .withResponse
  private var payload = Data()
  private var chunks: [Data] = []
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
      self.completion = completion; self.payload = data; self.writeChar = nil; self.chunks = []
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
    log("connecting to \(p.name ?? "?") \(p.identifier)"); central.connect(p)
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
      log("  disconnected with \(chunks.count) chunks still unsent")
      finish(error ?? BridgeError(description: "disconnected mid-job"))
    }
  }

  // ---- services / characteristics ----
  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    if let error { return finish(error) }
    for s in p.services ?? [] { log("service \(s.uuid)"); p.discoverCharacteristics(nil, for: s) }
  }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    for ch in s.characteristics ?? [] { log("  char \(ch.uuid) props=0x\(String(ch.properties.rawValue, radix: 16))") }
    for ch in s.characteristics ?? [] where ch.properties.contains(.notify) {
      p.setNotifyValue(true, for: ch)                     // subscribe to printer status (FF01/FF03)
    }
    guard writeChar == nil, completion != nil,
          let ch = s.characteristics?.first(where: {
            writeUUIDs.contains($0.uuid) &&
            ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) })
    else { return }
    writeChar = ch
    writeType = (ch.properties.contains(.write) && !fast) ? .withResponse : .withoutResponse
    let size = max(20, min(chunkCap, p.maximumWriteValueLength(for: writeType)))
    chunks = stride(from: 0, to: payload.count, by: size).map {
      payload.subdata(in: $0..<min($0 + size, payload.count)) }
    log("writing \(payload.count) B to \(ch.uuid): \(chunks.count)×\(size) B, " +
        "\(writeType == .withResponse ? "with" : "without") response, delay \(delayMs) ms")
    pump()
  }

  // ---- sending ----
  private func pump() {
    guard let p = peripheral, let ch = writeChar, completion != nil else { return }
    if chunks.isEmpty {
      let myJob = job
      q.asyncAfter(deadline: .now() + 1.5) { if self.job == myJob { self.finish(nil) } }  // let printer drain
      return
    }
    if writeType == .withResponse {
      p.writeValue(chunks.removeFirst(), for: ch, type: .withResponse)   // next one sent from didWriteValueFor
    } else if delayMs > 0 {
      if p.canSendWriteWithoutResponse { p.writeValue(chunks.removeFirst(), for: ch, type: .withoutResponse) }
      q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() }
    } else {
      while !chunks.isEmpty && p.canSendWriteWithoutResponse {
        p.writeValue(chunks.removeFirst(), for: ch, type: .withoutResponse)
      }
      if chunks.isEmpty { pump() }
    }
  }
  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    if let error { return finish(error) }
    if chunks.count % 200 == 0 { log("  \(chunks.count) chunks left") }
    if delayMs > 0 { q.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.pump() } }
    else { pump() }
  }
  func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { if delayMs == 0 { pump() } }

  // ---- printer status ----
  func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
    log("  subscribed \(ch.uuid): \(error.map { "\($0)" } ?? "ok")")
  }
  private var lastNotify = ""
  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    let v = ch.value?.map { String(format: "%02x", $0) }.joined() ?? "-"
    if v != lastNotify { log("  notify \(ch.uuid): \(v)"); lastNotify = v }
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
  log("listening on 127.0.0.1:9100 for \(targetName) (chunk \(chunkCap), delay \(delayMs) ms)")
  dispatchMain()
} else {
  print("usage: hprt-ble-bridge send <file> | serve   (env: HPRT_NAME, HPRT_CHAR, HPRT_CHUNK, HPRT_DELAY_MS, HPRT_FAST=1)")
}