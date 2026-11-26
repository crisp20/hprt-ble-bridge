# HPRT D35BT – Bluetooth printing on macOS: technical notes

Why the setup looks the way it does, how the data reaches the printer, and why it's slower than USB.
Installation: see [readme.md](./readme.md).

---

## 1. The problem

The D35BT prints fine over wired USB with HPRT's macOS driver.
The goal is the same experience wirelessly over bluetooth.

No built-in path exists:

| Option                                          | Why it fails                                                                                                              |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| macOS Add Printer                               | macOS only discovers network (Bonjour/IPP) and USB printers. A paired Bluetooth label printer never appears               |
| HPRT driver's own queue                         | It's `usb://…`, so it shows "Offline" without the cable                                                                   |
| HPRT HereLabel (Mac App Store)                  | Not available in the Hong Kong store                                                                                      |
| HereLabel web / Web Bluetooth                   | Web version is USB-only, and Firefox doesn't implement Web Bluetooth                                                      |
| Classic Bluetooth serial (`/dev/cu.D35BT-XXXX`) | macOS creates the port, but `open()` **hangs forever**. The printer advertises a serial profile it doesn't actually serve |
| HPRT iOS SDK                                    | `PrinterSDK.xcframework` is built for iOS only (arm64 / x86_64 simulator), so it can't be linked on macOS                 |

The SDK did confirm that **HPRT's own apps talk BLE** (CoreBluetooth `CBPeripheral`), 
and it contained the BLE service and characteristic UUIDs and the CPCL/TSPL manuals.

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

|               | CUPS backend                                        | User-session LaunchAgent |
| ------------- | --------------------------------------------------- | ------------------------ |
| Runs as       | root, or `_lp`                                      | the logged-in user       |
| Runs in       | the CUPS sandbox, outside any login session         | the user's GUI session   |
| CoreBluetooth | ✗ needs a user session and TCC Bluetooth permission | ✅                        |

So the BLE code lives in a small user process, 
and CUPS reaches it with the stock **`socket://` (AppSocket/JetDirect)** backend.
No custom files go into `/usr/libexec/cups`, and the sandbox doesn't need relaxing.

### Why Swift?

CoreBluetooth is Apple's native BLE API, 
so a single compiled Swift file with no dependencies is the shortest path. 
Python (`bleak`) or Node (`noble`) would work, 
but they bring runtimes and packages, 
and still need the same TCC permission. 
The `Info.plist` is embedded into the binary (`-sectcreate __TEXT __info_plist`) because macOS terminates any process that touches Bluetooth without an `NSBluetoothAlwaysUsageDescription`.

## 3. What the bridge does per job

```
CUPS connects to :PORT ─► receive whole job ─► sanity check (refuse %!PS / %PDF / empty)
      │                                        save copy to ~/Library/Logs/hprt-last-job-PORT.bin
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

| Choice                           | Reason                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------- |
| Connect per job, then disconnect | The printer allows **one** BLE central. Phones and other Macs can use it between jobs |
| Exact, case-sensitive name match | Never print to someone else's D35BT nearby                                            |
| Loopback-only listener           | Nothing on the LAN can send jobs to the printer                                       |
| Refuse PostScript/PDF            | Raw PostScript sent to the printer wastes labels                                      |
| One job at a time                | The printer has one BLE link, so jobs are serialised                                  |

## 4. Printer BLE protocol (as observed)

| Item                   | Value                                                                                        |
| ---------------------- | -------------------------------------------------------------------------------------------- |
| Advertised name        | `D35BT-` + last 4 hex of `BT_MAC`                                                            |
| Services               | `FF00` (HPRT) and `49535343-FE7D-4AE5-8FA9-9FAFD205E455` (Microchip/ISSC "transparent UART") |
| Write characteristic   | `FF02`, props `0x0C` (write + write-without-response)                                        |
| Status characteristics | `FF01`, `FF03` (notify)                                                                      |
| `FF03` = `02 64 00`    | **Max packet length = 0x0064 = 100 bytes**                                                   |
| `FF03` = `01 nn`       | **Credit grant**: the host may send `nn` more packets                                        |

This is credit-based flow control.
The printer tells the host exactly how much its receive buffer can take.
It was confirmed empirically: every job showed *writes = credits granted* (198/198) and never overflowed.

### Job format (HPRT `raster-cpcl` filter, 60×40 mm)

```
512 × 0x00                 padding / buffer flush
! 0 203 203 320 1          CPCL header: 203 dpi, label height 320 dots (40 mm), 1 copy
PW 480                     print width 480 dots (60 mm)
CG 60 320 0 0 <19200 B>    uncompressed 1-bit bitmap: 60 bytes × 320 rows
FORM                       feed to the next gap
PRINT
```

A 60×40 mm label is therefore **~19.7 KB regardless of content**,
because the driver sends the whole bitmap, white space included.

## 5. Print time, and why it's slower than USB

### Where the time goes

```
click Print (system print dialog)
  │ 1) Firefox renders the page → PDF → CUPS              ~1 s
  ▼
  │ 2) CUPS filters: cgpdftoraster → raster-cpcl          <1 s
  │    socket backend connects to 127.0.0.1:PORT          ~0 s (was ~4 s, see "snmp=false" below)
  ▼
bridge: "job received"                                <--------------------------------------------\
  │ 3)  BLE connect + service discovery + subscribe       ~0.6 s                                   |
  ▼                                                                                                |
bridge: "writing N B"                                                                              |
  │ 4)  BLE transfer, printer-paced (~4.3 KB/s)           ~4.6 s per label in job (19.5 KB)        |
  ▼                                                                                                |
bridge: "sent N B in X s"     ← printer is already printing/feeding (same as USB)                  |
  │ 5)  static drain wait, disconnect                     1.5s delay for next job in queue         |
  ▼                                                                                                |
bridge: "job done" → CUPS marks the job complete      --- subsequent queued jobs ------------------/
```

### Print time: BLE vs USB (60 × 40 mm labels)

| Stage / factor                                 | BLE, 1 label (19.5 KB)                                | BLE, 2 labels (39 KB, one job) | USB, 1 label (estimated)      |
| ---------------------------------------------- | ----------------------------------------------------- | ------------------------------ | ----------------------------- |
| Firefox + print dialog                         | ~1 s                                                  | ~1 s                           | ~1 s                          |
| CUPS filters (`cgpdftoraster` → `raster-cpcl`) | <1 s                                                  | <1 s                           | <1 s                          |
| CUPS backend                                   | ~0 s (`socket`, `?snmp=false`; was ~4 s)              | ~0 s                           | ~0 s (`usb`)                  |
| Link setup                                     | ~0.6 s connect + discovery                            | ~0.6 s (once per job)          | none (already enumerated)     |
| Transfer                                       | ~4.6 s                                                | ~9 s                           | ≪0.1 s                        |
| **Click → last byte sent**                     | **~7 s**                                              | **~11.5 s**                    | **~1.5–2 s**                  |
| After last byte                                | 1.5 s drain wait, disconnect (label already printing) | same                           | none                          |
| Packet size                                    | ≤100 B (printer cap, FF03 `02 64 00`)                 | ≤100 B                         | 64 B bulk, back-to-back       |
| Flow control                                   | 1 packet per credit (FF03 `01 nn`)                    | 391 writes / 392 credits       | hardware handshake, no stalls |
| Throughput                                     | ~4.3 KB/s                                             | ~4.3 KB/s                      | hundreds of KB/s              |
| Source                                         | bridge + CUPS logs (Mac mini)                         | bridge + CUPS logs (Mac mini)  | not measured                  |

**The bottleneck is the printer's BLE firmware.**
Every Mac reaches about the same speed:
the bridge sends each 100 B packet the moment a credit arrives.
Bigger packets or unpaced writes overflow the printer (`CBErrorDomain 6`),
and the printer then stops advertising until it's power-cycled.

### How we got from ~90 s to ~4.5 s per label

Bluetooth transfer (per label):

| Mode                          | Strategy                                               | Transfer per label | Result                                           |
| ----------------------------- | ------------------------------------------------------ | ------------------ | ------------------------------------------------ |
| 180 B, acknowledged, no pause | Fill as fast as macOS allows                           | –                  | ✗ Disconnect after ~1 s (`FF03 01 04` then drop) |
| `delay` 20 B / 30 ms          | HPRT-style conservative pacing                         | ~90 s              | ✅                                                |
| `delay` 100 B / 20 ms         | Acknowledge each write + pause                         | ~30 s              | ✅                                                |
| **`credit`**                  | Send only what the printer grants, no acknowledgements | **~4.6 s**         | ✅ default                                        |

End to end (2 labels, click → last byte sent):

| Step | Change                                          | Saved  | Total       |
| ---- | ----------------------------------------------- | ------ | ----------- |
| 0    | First working bridge, `delay` 100 B / 20 ms     | –      | ~66 s*      |
| 1    | `credit` flow control                           | ~51 s  | ~16 s       |
| 2    | Queue URI `socket://127.0.0.1:PORT/?snmp=false` | ~3–4 s | **~11.5 s** |

\* Estimated from ~30 s per label in `delay` mode. Steps 1–2 are measured.

**`snmp=false`:** before connecting, 
the CUPS socket backend sends an SNMP supply-level query to the device address and waits on it (`backendWaitLoop(snmp_fd=…)`, ~4 s).
Nothing answers SNMP on `127.0.0.1`, so every job waited for nothing.
The URI option needs the `/` before the `?`: `socket://127.0.0.1:9100?snmp=false` is rejected as `Bad device-uri`.
See [apple/cups #5256](https://github.com/apple/cups/issues/5256) and [CUPS AppSocket](https://www.cups.org/doc/network.html#SOCKET).

### Considered and rejected

| Idea                                 | Would save                  | Why not                                                                    |
| ------------------------------------ | --------------------------- | -------------------------------------------------------------------------- |
| Bigger packets (180 B)               | –                           | Printer disconnects (`CBErrorDomain 6`)                                    |
| Lower `HPRT_GAP_MS` / unpaced writes | –                           | The printer's credits set the rate; unpaced writes overflow it             |
| Crop or compress the bitmap          | ~1.5–3× less data           | Changes the job the driver produced; not reliable enough                   |
| Keep the BLE link open after a job   | ~0.6 s per back-to-back job | Too little gain; blocks phones, the app's Chrome button and other accounts |
| Shorter drain / close TCP early      | 0.5 s per back-to-back job  | Risk losing end of job. Figure of 0.5s is a chosen safety margine.         |

### Re-measuring

```sh
# bridge stages (connect, transfer)
tail -f ~/Library/Logs/hprt-ble-bridge-XXXX.log

# CUPS stages (filters, backend); admin needed
sudo cupsctl --debug-logging
lp -d HPRT_D35BT_XXXX label.pdf; sleep 8
grep '\[Job NN\]' /var/log/cups/error_log | grep -iE 'Started|exited|snmp|Connecting'
sudo cupsctl --no-debug-logging
```

## 6. Limitations and hazards

| Issue                                                  | Effect                                                                                                | Mitigation                                                                                             |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| CUPS completes the job once the bridge has received it | Bluetooth failures don't show in the print queue                                                      | Check `~/Library/Logs/hprt-ble-bridge-XXXX.log`. Possible improvement: retry plus a macOS notification |
| Printer error states (red light: cover open, no paper) | Printer doesn't advertise or print; the job is lost                                                   | Fix the printer, then reprint                                                                          |
| A mid-job disconnect                                   | Printer stops advertising                                                                             | Power-cycle the printer                                                                                |
| Single BLE connection                                  | A connected phone app blocks the Mac                                                                  | Close phone apps                                                                                       |
| Bridges run per user; one port per printer             | On a shared Mac only one logged-in user's bridge can bind a given port (others log `FATAL` and retry) | Fine for sequential logins; concurrent fast user switching is untested                                 |
| Rebuilt binary has a new signature                     | TCC may ask for Bluetooth permission again                                                            | Re-allow under Privacy & Security → Bluetooth                                                          |

## 7. Files

| Path                                                      | Purpose                                                        |
| --------------------------------------------------------- | -------------------------------------------------------------- |
| `~/src/hprt-ble-bridge/main.swift`                        | Bridge source (`send <file>` for tests, `serve` for CUPS)      |
| `~/src/hprt-ble-bridge/Info.plist`                        | Bluetooth usage text, embedded in the binary                   |
| `~/bin/hprt-ble-bridge`                                   | Compiled bridge, shared by all printers                        |
| `~/Library/LaunchAgents/local.hprt-ble-bridge.XXXX.plist` | One per printer: autostart at login, `KeepAlive`, settings     |
| `~/Library/Logs/hprt-ble-bridge-XXXX.log`                 | Log, one per printer (also visible in Console.app)             |
| `~/Library/Logs/hprt-last-job-PORT.bin`                   | Copy of the last job received from CUPS, one per port          |
| CUPS queue `HPRT_D35BT_XXXX`                              | HPRT PPD + `socket://127.0.0.1:PORT/?snmp=false` (system-wide) |

## 8. References

- CUPS: [backends](https://www.cups.org/doc/man-backend.html) ·
  [`socket://`](https://www.cups.org/doc/network.html#SOCKET) ·
  [PPD `cupsFilter`](https://www.cups.org/doc/spec-ppd.html) ·
  [page sizes](https://www.cups.org/doc/options.html#PAGESIZE)
- Apple: [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth) ·
  [`maximumWriteValueLength(for:)`](https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:)) ·
  [`canSendWriteWithoutResponse`](https://developer.apple.com/documentation/corebluetooth/cbperipheral/cansendwritewithoutresponse) ·
  [`NSBluetoothAlwaysUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription) ·
  [launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- HPRT: [downloads](https://download.hprt.com/Downloads.html) ·
  [D35 user manual (EN)](https://shop.ribbon.ua/uploads/instructions/2438/ribbonua_hprt_sl32_series_label_printer_user_manual_en.pdf) ·
  CPCL manual `Document/CPCL/PTCommandCPCL_en.pdf` in iOS SDK V3.2.24
- Prior art: [phomemo-macos](https://github.com/jacquesg/phomemo-macos) (BLE label printer + CUPS on macOS) ·
  [d35bt-cglzo-protocol-lab](https://github.com/camellia-yip/d35bt-cglzo-protocol-lab) (D35BT BLE/CPCL notes)
