Credit mode cut the transfer time from about **29 s to 4.8 s** for the same 19.7 KB label. It worked in all three runs, and for every packet sent the printer had granted permission first (198 writes, 198 credits). So the FF03 status messages really are permission-to-send counts. Set `HPRT_FLOW=credit` permanently in the plist (step 3 from before).

I've also moved the whole setup into its own memory file, so future sessions can pick it up without redoing the investigation.

# Bluetooth printing for the HPRT D35BT on macOS

## 1. Summary

**Goal:** print 60×40 mm labels from Firefox through the macOS print dialog to an HPRT D35BT over Bluetooth. USB already worked.

**Problem:** macOS has no built-in way to print to a Bluetooth Low Energy (BLE) device, and the printer's classic Bluetooth serial port doesn't work on a Mac.

**Solution:** keep HPRT's own macOS driver to produce the print data, and replace only the delivery step. CUPS (the macOS print system) sends each job to a small local program, the bridge, which forwards it to the printer over BLE.

```
                 ┌──────────────────────────── unchanged from USB ───────────────────────────┐
Firefox ⌘P ──►  CUPS queue "HPRT D35BT (Bluetooth)" ──► HPRT driver (raster-cpcl) ──► CPCL job
                                                                                         │
                 ┌──────────────────────────────── new ───────────────────────────────────┘
                 ▼
     socket://127.0.0.1:9100   (built-in CUPS backend, loopback only)
                 │
                 ▼
     hprt-ble-bridge serve     (Swift, LaunchAgent, runs as the logged-in user)
                 │  scan "D35BT-xxxx" → connect → subscribe FF03 → write FF02 using credits → disconnect
                 ▼
     D35BT over BLE            (~5 s per 60×40 label)
```

## 2. How we got here

| # | Attempt | Result | What we learned |
|---|---|---|---|
| 1 | HereLabel app from the Mac App Store | Not offered in the Hong Kong store | No vendor Mac app is available |
| 2 | Web printing in Firefox | Firefox doesn't support Web Bluetooth | A browser can't talk to the printer directly |
| 3 | Add Printer in Printers & Scanners | The paired printer doesn't appear | macOS doesn't offer Bluetooth printers there |
| 4 | Existing CUPS queue | It was `usb://`, so it shows "Offline" without the cable | A separate Bluetooth queue is needed |
| 5 | Classic Bluetooth serial (`/dev/cu.D35BT-B3F8`) | Opening the port hangs forever, even after reconnecting | The printer lists a serial port that never actually connects. **Dead end.** |
| 6 | Checked the HPRT iOS SDK | iOS-only library, but it contains the BLE IDs and the CPCL manual | HPRT's own apps use **BLE**, through channels FF00, FF02 and FF03 |
| 7 | First BLE write (58 B) | A blank label fed out | The BLE link works |
| 8 | Ran HPRT's driver through `cupsfilter` | Output was **PostScript**, not printer commands | `cupsfilter` stops before HPRT's filter on macOS, so test through a real queue instead |
| 9 | Real CUPS job (20 KB) sent in 180 B pieces | Disconnected within about 1 s, and the printer then stopped advertising | The printer accepts at most **100 B** per packet and needs flow control |
| 10 | 100 B pieces with a 20 ms pause after each acknowledgement | Printed, but blank | Transfer worked. The test PDF was simply empty (Letter-size page, nothing in the label area). |
| 11 | Firefox with Fit to page width | ✅ Printed correctly, ~30 s | The whole chain works |
| 12 | Credit flow control | ✅ ~5 s | The printer's status messages tell the sender exactly how much to send |

## 3. Why the bridge is built this way

```
Why not a CUPS backend talking BLE directly?
  CUPS backend ─ runs as root, outside the login session, inside the CUPS sandbox
        ✗ Bluetooth access (CoreBluetooth) needs a user session and the user's Bluetooth permission

So:    CUPS ──TCP──► user-session process that HAS Bluetooth permission
```

| Decision | Reason | Alternatives rejected |
|---|---|---|
| Reuse HPRT's PPD and `raster-cpcl` filter | It already renders labels correctly over USB | Writing our own renderer (pointless) |
| Built-in `socket://` backend | No custom files in `/usr/libexec/cups`, no sandbox problems | A custom backend script (the serial route was dead anyway) |
| User-session LaunchAgent | Bluetooth permission belongs to the logged-in user | A root LaunchDaemon (no Bluetooth permission) |
| Connect per job, then disconnect | The printer accepts only **one** BLE connection, so a phone can use it between jobs | A permanent connection |
| Listen on loopback only | Nothing on the network can send jobs to the printer | Listening on all interfaces |
| Refuse PostScript and PDF | Sending raw PostScript to the printer wastes labels | — |
| Credit flow control | ~6× faster than waiting for each acknowledgement, and it can't overflow the printer | Fixed delays (guesswork, slower) |

### Printer protocol, as observed

| Item | Value |
|---|---|
| BLE services | `FF00` (HPRT) and `49535343-FE7D-…` (generic serial-over-BLE) |
| Write channel | `FF02`, which accepts writes with or without acknowledgement |
| Status channel | `FF03` (notify). `02 64 00` means max packet 100 B. `01 nn` means you may send `nn` more packets. |
| Job format | 512 × `00` padding, then `! 0 203 203 320 1`, `PW 480`, `CG 60 320 0 0` + uncompressed bitmap, `FORM`, `PRINT` |

### Known limitations

- **CUPS shows a job as "completed" as soon as the bridge has received it**, even if sending over Bluetooth fails later. Check `/tmp/hprt-ble-bridge.log`.
- After a dropped connection, the printer **stops advertising until it's power-cycled**. With credit mode, drops shouldn't happen any more.
- Each bridge serves **one printer on port 9100**.
- Any phone app connected to the printer blocks the Mac.

## 4. Setting it up on another Mac

### Requirements

| Item | Note |
|---|---|
| macOS with Bluetooth LE | Any recent Mac |
| HPRT Mac driver for the D35BT | [download.hprt.com](https://download.hprt.com/Downloads.html), "Mac Drivers for D35BT" |
| Xcode Command Line Tools | `xcode-select --install`, to get `swiftc` |
| The printer's BLE name | `D35BT-` plus the last 4 hex digits of the BT MAC on its self-test label |

### Copy the source files

Copy `~/src/hprt-ble-bridge/main.swift` and `Info.plist` to the new Mac. A git repo is the easiest way. **Compile on each Mac** rather than copying the binary:

- Bluetooth permission is tied to the binary's signature.
- Downloaded binaries get quarantined.
- Intel and Apple Silicon Macs need different builds.

### Install script

Save as `install.sh` next to `main.swift` and `Info.plist`:

```sh
#!/bin/bash
# Usage: ./install.sh D35BT-XXXX
set -euo pipefail

NAME="${1:?usage: $0 D35BT-XXXX   (last 4 hex of BT_MAC on self-test label)}"
QUEUE="HPRT_D35BT_BT"
LABEL="local.$(id -un).hprt-ble-bridge"
BIN="$HOME/bin/hprt-ble-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/4 build bridge"
mkdir -p "$HOME/bin" "$HOME/Library/LaunchAgents"
swiftc -O "$SRC/main.swift" -o "$BIN" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SRC/Info.plist"

echo "== 2/4 one-off Bluetooth permission check (allow the prompt for Terminal)"
printf '! 0 200 200 80 1\r\nFORM\r\nPRINT\r\n' > /tmp/hprt-probe.cpcl
HPRT_NAME="$NAME" HPRT_FLOW=delay "$BIN" send /tmp/hprt-probe.cpcl || {
  echo "Probe failed: power-cycle the printer, close phone apps, re-run."; exit 1; }

echo "== 3/4 LaunchAgent"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HPRT_NAME</key><string>$NAME</string>
    <key>HPRT_FLOW</key><string>credit</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/hprt-ble-bridge.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "== 4/4 CUPS queue"
MODEL="$(lpinfo -m | grep -i 'd35bt' | head -1 | cut -d' ' -f1)"
[ -n "$MODEL" ] || { echo "HPRT D35BT driver not found: install it from download.hprt.com"; exit 1; }
sudo lpadmin -p "$QUEUE" -D "HPRT D35BT (Bluetooth)" \
  -v socket://127.0.0.1:9100 -m "$MODEL" -o PageSize=Custom.60x40mm -E
sudo cupsenable "$QUEUE"; sudo cupsaccept "$QUEUE"

sleep 2; tail -2 /tmp/hprt-ble-bridge.log
echo "Done. Print from any app to 'HPRT D35BT (Bluetooth)'."
```

Notes on the script:

- `lpinfo -m` finds the HPRT driver by its installed model name, so you don't need an existing USB queue to copy a PPD from. If it lists several D35BT entries, check which one it picked.
- The probe in step 2 triggers the Bluetooth permission prompt in Terminal. The background LaunchAgent may ask again the first time it prints. If a print silently does nothing, check System Settings → Privacy & Security → Bluetooth.
- Only one Mac can be connected to the printer at a time, but several Macs can share it, because the bridge disconnects after each job.

### First print on the new Mac

1. Create the custom paper size: in the print dialog, open Paper Size → Manage Custom Sizes… and add 60×40 mm with zero margins.
2. In Firefox's print dialog, set:
   - **Scale:** Fit to page width (the "Ignore Scaling and Shrink To Fit Page Width" option)
   - **Headers and footers:** all six set to `--blank--`
3. Save these settings as a preset, for example "D35BT label".
4. Watch the bridge with `tail -f /tmp/hprt-ble-bridge.log`. You should see `job received`, then `sent 19709 B in ~5 s`, then `job done`.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `scanning…` then a timeout | Power-cycle the printer, close any phone app, then run `cupsenable HPRT_D35BT_BT` |
| `bluetooth state: 3` | Allow Bluetooth for the bridge under Privacy & Security → Bluetooth |
| Blank label | Run `LC_ALL=C tr -d '\000' < /tmp/hprt-last-job.bin \| wc -c`. A count near 57 means the page was empty, so check the Fit-to-width setting. |
| `no FF03 credits within 3 s` | Possibly a different firmware. Set `HPRT_FLOW=delay` in the plist (slower, but proven). |
| Plist edits have no effect | Plist changes need `bootout` then `bootstrap`. After a rebuild, `kickstart -k` is enough. |

## Docs

- CUPS: [backends](https://www.cups.org/doc/man-backend.html), [`socket://`](https://www.cups.org/doc/network.html#SOCKET), [`lpadmin`](https://www.cups.org/doc/man-lpadmin.html), [`lpinfo`](https://www.cups.org/doc/man-lpinfo.html), [custom page sizes](https://www.cups.org/doc/options.html#PAGESIZE)
- Apple: [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth), [`NSBluetoothAlwaysUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription), [`NWListener`](https://developer.apple.com/documentation/network/nwlistener), [launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- CPCL commands: `Document/CPCL/PTCommandCPCL_en.pdf` in the HPRT SDK

## Next steps

- [ ] On this Mac, set `HPRT_FLOW=credit` in the plist (remove `HPRT_CHUNK` and `HPRT_DELAY_MS`), then run `bootout` and `bootstrap`.
- [ ] Blank Firefox's headers and footers and save the "D35BT label" preset.
- [ ] Put `main.swift`, `Info.plist` and `install.sh` in a git repo.
- [ ] On each new Mac: install the HPRT driver, then run `./install.sh D35BT-XXXX`, using the name from the printer's self-test label.
- [ ] Optional: if 5 s is still too slow, or the queue should show Bluetooth failures, I can add blank-row cropping and error reporting back to CUPS.