# HPRT D35BT – Bluetooth printing on macOS: technical notes

Why the setup looks the way it does, how the data reaches the printer, and why it's slower than USB.
Installation: see [readme.md](./readme.md).

---

## 1. The problem

The D35BT prints fine over wired USB with HPRT's macOS driver.
The goal is the same experience wirelessly over bluetooth.

No built-in path exists:

| Option | Why it fails |
|---|---|
| macOS Add Printer | macOS only discovers network (Bonjour/IPP) and USB printers. A paired Bluetooth label printer never appears |
| HPRT driver's own queue | It's `usb://…`, so it shows "Offline" without the cable |
| HPRT HereLabel (Mac App Store) | Not available in the Hong Kong store |
| HereLabel web / Web Bluetooth | Web version is USB-only, and Firefox doesn't implement Web Bluetooth |
| Classic Bluetooth serial (`/dev/cu.D35BT-XXXX`) | macOS creates the port, but `open()` **hangs forever**. The printer advertises a serial profile it doesn't actually serve |
| HPRT iOS SDK | `PrinterSDK.xcframework` is built for iOS only (arm64 / x86_64 simulator), so it can't be linked on macOS |

The SDK did confirm that **HPRT's own apps talk BLE** (CoreBluetooth `CBPeripheral`), and it contained
the BLE service and characteristic UUIDs and the CPCL/TSPL manuals.

## 2. The solution

Keep everything that already works (the driver), and replace only the last hop.

```
┌──────────────────────── unchanged from USB ─────────────────────────┐
│ App ⌘P → CUPS → HPRT PPD → filter "raster-cpcl" → CPCL job (~20 KB) │
└──────────────────────────────────────┬──────────────────────────────┘
                                       │ CUPS built-in backend
                                       ▼
                       socket://127.0.0.1:9100   (loopback only)
                                       │
                       hprt-ble-bridge serve     (Swift, LaunchAgent, user session)
                                       │ CoreBluetooth
                                       ▼
                       D35BT  BLE service FF00 → write FF02, status FF03
```

### Why a separate helper, and not a CUPS backend?

A CUPS backend is the usual place to implement a new transport, but:

| | CUPS backend | User-session LaunchAgent |
|---|---|---|
| Runs as | root, or `_lp` | the logged-in user |
| Runs in | the CUPS sandbox, outside any login session | the user's GUI session |
| CoreBluetooth | ✗ needs a user session and TCC Bluetooth permission | ✅ |

So the BLE code lives in a small user process, and CUPS reaches it with the stock
**`socket://` (AppSocket/JetDirect)** backend. No custom files go into `/usr/libexec/cups`, and the
sandbox doesn't need relaxing.

### Why Swift?

CoreBluetooth is Apple's native BLE API, so a single compiled Swift file with no dependencies is the
shortest path. Python (`bleak`) or Node (`noble`) would work, but they bring runtimes and
packages, and still need the same TCC permission. The `Info.plist` is embedded into the binary
(`-sectcreate __TEXT __info_plist`) because macOS terminates any process that touches Bluetooth
without an `NSBluetoothAlwaysUsageDescription`.

## 3. What the bridge does per job

```
CUPS connects to :9100 ─► receive whole job ─► sanity check (refuse %!PS / %PDF / empty)
      │                                        save copy to /tmp/hprt-last-job.bin
      ▼
scan for exact name "D35BT-XXXX" ─► connect ─► discover services
      ▼
subscribe FF01 / FF03 (status) ─► printer announces max packet + initial credits
      ▼
write job to FF02 in ≤100 B packets, one packet per credit
      ▼
wait 1.5 s (printer drains) ─► disconnect ─► close TCP ─► CUPS marks job done
```

Design choices:

| Choice | Reason |
|---|---|
| Connect per job, then disconnect | The printer allows **one** BLE central. Phones and other Macs can use it between jobs |
| Exact, case-sensitive name match | Never print to someone else's D35BT nearby |
| Loopback-only listener | Nothing on the LAN can send jobs to the printer |
| Refuse PostScript/PDF | Raw PostScript sent to the printer wastes labels |
| One job at a time | The printer has one BLE link, so jobs are serialised |

## 4. Printer BLE protocol (as observed)

| Item | Value |
|---|---|
| Advertised name | `D35BT-` + last 4 hex of `BT_MAC` |
| Services | `FF00` (HPRT) and `49535343-FE7D-4AE5-8FA9-9FAFD205E455` (Microchip/ISSC "transparent UART") |
| Write characteristic | `FF02`, props `0x0C` (write + write-without-response) |
| Status characteristics | `FF01`, `FF03` (notify) |
| `FF03` = `02 64 00` | **Max packet length = 0x0064 = 100 bytes** |
| `FF03` = `01 nn` | **Credit grant**: the host may send `nn` more packets |

This is credit-based flow control. The printer tells the host exactly how much its receive buffer can
take. It was confirmed empirically: every job showed *writes = credits granted* (198/198) and never
overflowed.

### Job format (HPRT `raster-cpcl` filter, 60×40 mm)

```
512 × 0x00                 padding / buffer flush
! 0 203 203 320 1          CPCL header: 203 dpi, label height 320 dots (40 mm), 1 copy
PW 480                     print width 480 dots (60 mm)
CG 60 320 0 0 <19200 B>    uncompressed 1-bit bitmap: 60 bytes × 320 rows
FORM                       feed to the next gap
PRINT
```

A 60×40 mm label is therefore **~19.7 KB regardless of content**, because the driver sends the whole
bitmap, white space included.

## 5. Why it's slower than USB

### Timeline of one Bluetooth job (from the bridge log)

```
t = 0.0 s   job received from CUPS
t ≈ 0.5 s   BLE connected, services discovered, subscribed
t ≈ 5.5 s   last packet written      (19,769 B in ~4.8 s ≈ 4 KB/s)
t ≈ 7.0 s   drain wait done, disconnect, CUPS marks job complete
            + printing/feeding itself (same as USB)
```

### Comparison

| Factor | USB | BLE (this setup) |
|---|---|---|
| Link setup | Already enumerated | **~0.5–1 s** connect + service discovery per job |
| Raw link speed | USB 2.0 full-speed: 12 Mbit/s | BLE 1M PHY: 1 Mbit/s air rate, far less in practice |
| Packet size | 64 B USB bulk packets, back-to-back | **≤100 B**, the printer's own cap |
| Flow control | Hardware handshake, effectively no stalls | Printer grants **~2 packets per credit message** |
| Effective throughput | Hundreds of KB/s, so 20 KB is instantaneous | **~4 KB/s**, so 20 KB takes ~5 s |
| End-of-job | Immediate | 1.5 s safety wait before disconnecting |

**The bottleneck is the printer's BLE firmware, not the Mac.** macOS would accept 180+ byte writes
(`maximumWriteValueLength`), but the printer caps packets at 100 B and paces credits to its buffer.
Ignoring that overflows it: the link drops (`CBErrorDomain 6`), and the printer stops advertising until
it's power-cycled.

### How we got from ~90 s to ~5 s

| Mode | Strategy | Time per label | Result |
|---|---|---|---|
| 180 B, acknowledged, no pause | Fill as fast as macOS allows | – | ✗ Disconnect after ~1 s (`FF03 01 04` then drop) |
| `delay` 20 B / 30 ms | HPRT-style conservative pacing | ~90 s | ✅ |
| `delay` 100 B / 20 ms | Acknowledge each write + pause | ~30 s | ✅ |
| **`credit`** | Send only what the printer grants, no acknowledgements | **~5 s** | ✅ default |

### Further speed-ups (not implemented)

| Idea | Expected gain | Notes |
|---|---|---|
| Crop blank bitmap rows | 3–5× less data for sparse labels | Rewrite one `CG` into several `CG` strips covering only rows with ink. Standard CPCL, low risk |
| CPCL `CGLZO` compression | Large | Used by HPRT's apps (LZO1X), but undocumented |
| Keep the connection open between jobs | Saves ~1 s per job | Blocks phones and other Macs from the printer |
| Shorter drain wait | Up to ~1 s | Needs a reliable "done" signal from `FF03` |

## 6. Limitations and hazards

| Issue | Effect | Mitigation |
|---|---|---|
| CUPS completes the job once the bridge has received it | Bluetooth failures don't show in the print queue | Check `/tmp/hprt-ble-bridge.log`. Possible improvement: retry plus a macOS notification |
| Printer error states (red light: cover open, no paper) | Printer doesn't advertise or print; the job is lost | Fix the printer, then reprint |
| A mid-job disconnect | Printer stops advertising | Power-cycle the printer |
| Single BLE connection | A connected phone app blocks the Mac | Close phone apps |
| Bridge runs per user, on port 9100 | Only one logged-in user's bridge can bind the port | Fine for a single-user Mac |
| Rebuilt binary has a new signature | TCC may ask for Bluetooth permission again | Re-allow under Privacy & Security → Bluetooth |
| Logs in `/tmp` | Cleared at boot | Harmless |

## 7. Files

| Path | Purpose |
|---|---|
| `~/src/hprt-ble-bridge/main.swift` | Bridge source (`send <file>` for tests, `serve` for CUPS) |
| `~/src/hprt-ble-bridge/Info.plist` | Bluetooth usage text, embedded in the binary |
| `~/bin/hprt-ble-bridge` | Compiled bridge |
| `~/Library/LaunchAgents/local.<user>.hprt-ble-bridge.plist` | Autostart at login, `KeepAlive`, settings |
| `/tmp/hprt-ble-bridge.log` | Log |
| `/tmp/hprt-last-job.bin` | Copy of the last job received from CUPS |
| CUPS queue `HPRT_D35BT_BT` | HPRT PPD + `socket://127.0.0.1:9100` |

## 8. References

- CUPS: [backends](https://www.cups.org/doc/man-backend.html) ·
  [`socket://`](https://www.cups.org/doc/network.html#SOCKET) ·
  [PPD `cupsFilter`](https://www.cups.org/doc/spec-ppd.html) ·
  [page sizes](https://www.cups.org/doc/options.html#PAGESIZE)
- Apple: [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) ·
  [`maximumWriteValueLength(for:)`](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:)) ·
  [`canSendWriteWithoutResponse`](https://developer.apple.com/documentation/corebluetooth/cbperipheral/cansendwritewithoutresponse) ·
  [`NSBluetoothAlwaysUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription) ·
  [`NWListener`](https://developer.apple.com/documentation/network/nwlistener) ·
  [launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- HPRT: [downloads](https://download.hprt.com/Downloads.html) ·
  [D35 user manual (EN)](https://shop.ribbon.ua/uploads/instructions/2438/ribbonua_hprt_sl32_series_label_printer_user_manual_en.pdf) ·
  CPCL manual `Document/CPCL/PTCommandCPCL_en.pdf` in iOS SDK V3.2.24
- Prior art: [phomemo-macos](https://github.com/jacquesg/phomemo-macos) (BLE label printer + CUPS on macOS) ·
  [d35bt-cglzo-protocol-lab](https://github.com/camellia-yip/d35bt-cglzo-protocol-lab) (D35BT BLE/CPCL notes)
