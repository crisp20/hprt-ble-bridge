# HPRT D35BT – Bluetooth printing on macOS: installation

Print to an HPRT D35BT label printer **over Bluetooth** from any macOS app (Firefox, Preview, …) through the normal system print dialog.

```
App ⌘P ─► CUPS queue "HPRT D35BT (Bluetooth)" ─► HPRT driver ─► socket://127.0.0.1:9100
                                                                     │
                                         hprt-ble-bridge (user LaunchAgent) ──BLE──► D35BT
```

Background and design: see [TECHNICAL.md](TECHNICAL.md).

---

## Requirements

| Item                   | Notes                                                                       |
| ---------------------- | --------------------------------------------------------------------------- |
| Mac with Bluetooth LE  | Any recent Mac (Intel or Apple Silicon)                                     |
| Admin rights           | Needed once, for `lpadmin` (creating the print queue)                       |
| HPRT D35BT, powered on | No other bluetooth devices (i.e. mobile phone) connected to it during setup |
| This repo              | `main.swift`, `Info.plist`, `install.sh`                                    |

## Compatibility

The source supports macOS 10.12.6 and avoids Swift syntax newer than Swift 4.0.3. Xcode
9.2 shipped Swift 4.0.3 and the macOS 10.13 SDK. `install.sh` explicitly targets macOS
10.12 when building on Intel, avoiding SDK-default deployment targets older than the BLE
API requires. On Apple Silicon it uses the host's default target because macOS 10.12 has
no Apple Silicon support. Build on the target Mac rather than copying a binary built with
a newer Swift compiler. The bridge uses CoreBluetooth and Darwin sockets; it does not
depend on Apple's newer `Network` framework.

Swift 4.0.3 shipped with Xcode 9.2. 
That version of Xcode is intended for macOS 10.12.6 through 10.13.2, 
so the reliable way to compile and validate this project is on a Mac running one of those systems. 
A macOS 26 machine can try a side-by-side Xcode 9.2 installation, 
but its legacy compiler and SDK are not supported there.

For a side-by-side installation, download Xcode 9.2 from Apple's developer downloads,
unpack it as `/Applications/Xcode_9.2.app`, 
and invoke its compiler without changing the system-wide developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode_9.2.app/Contents/Developer \
/Applications/Xcode_9.2.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
-target x86_64-apple-macosx10.12 --version
```

If that compiler cannot run on the host OS, 
use a Sierra/High Sierra Mac or VM for the legacy build. 
Docker/Linux cannot compile this project as it requires macOS CoreBluetooth.

---

## Step 1 – Install the HPRT macOS driver

1. Download **"Mac Drivers for D35BT"** from <https://download.hprt.com/Downloads.html>.
2. Run the installer.
3. Verify:
   ```sh
   lpinfo -m | grep -i d35bt
   ```
   You should see at least one line (e.g. `… HPRT D35BT, 1.4.10`).

You do **not** need to add a USB printer first. 
The install script creates the Bluetooth queue directly from the installed driver.

## Step 2 – Install the Xcode Command Line Tools

The bridge is compiled locally with `swiftc`.

```sh
xcode-select --install        # skip if `swiftc --version` already works
```

## Step 3 – Find the printer's Bluetooth name

1. Printer on, cover closed (it must **click**), light **blue**.
2. **Hold FEED ~1.5 s** until the light flashes once, then release → a self-test label prints.
3. Read `BT_MAC`, e.g. `ba:ab:14:04:b3:f8`. The Bluetooth name is **`D35BT-` + the last 4 hex digits in uppercase**, so here it's `D35BT-B3F8`.

Pairing in System Settings → Bluetooth is **not required**. BLE connects without pairing.

## Step 4 – Get the files

```sh
mkdir -p ~/src && cd ~/src
git clone <your-repo-url> hprt-ble-bridge     # or copy the folder over
cd hprt-ble-bridge
ls        # docs            Info.plist      install.sh      main.swift
```

Always **build on each Mac**.
Don't copy a compiled binary between Macs: Bluetooth permission is tied to the binary's signature, downloaded binaries get quarantined, and Intel and Apple Silicon needdifferent builds.

## Step 5 – Run the installer

Turn off any devices connected to the printer, then run:

```sh
# sh install.sh <printer id> <port>

# e.g.
sh install.sh B3F8 9100
sh install.sh 5676 9101
```

What it does:

| Stage | Action                                                                                                                                                                      |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1/4   | Compiles `~/bin/hprt-ble-bridge`, with the Bluetooth usage text embedded                                                                                                    |
| 2/4   | Stops any running bridge, then sends a tiny test job over BLE. The printer **feeds one blank label**, and macOS asks **Terminal** for Bluetooth permission: click **Allow** |
| 3/4   | Installs and starts the LaunchAgent `~/Library/LaunchAgents/local.<user>.hprt-ble-bridge.plist`                                                                             |
| 4/4   | Creates the CUPS queue `HPRT_D35BT_BT` → `socket://127.0.0.1:9100` (asks for your password)                                                                                 |

Re-running the script is safe. It rebuilds the binary and replaces the agent and the queue.

On port collision (installing multiple bridges on the same port), the installation simply fails.
[Uninstall the existing bridge](#uninstall), then run the installation again.

## Step 6 – Grant Bluetooth permission to the bridge (if asked)

The background bridge may need its own permission the first time it prints. 
If a print does nothing and the log shows `bluetooth state: 3`, 
open **System Settings → Privacy & Security → Bluetooth** and enable `hprt-ble-bridge`.

## Step 7 – Paper size and print preset (one-time)

1. In any print dialog:
   **Paper Size → Manage Custom Sizes… → +**, then set width **60 mm**, height **40 mm**, all margins **0**. 
   Name it e.g. **Small Label**. (The HPRT driver has no 60×40 preset.)
2. In the print dialog, choose:
   - Printer: **HPRT D35BT (Bluetooth)**
   - Paper Size: **Small Label**
   - Check ✅: **Ignore Scaling and Shrink To Fit Page Width**
   - Page Headers / Footers: all six **--blank--**
3. **Presets → Save Current Settings as Preset… → "D35BT label"**.

## Step 8 – Test

```sh
tail -f /tmp/hprt-ble-bridge.log
```

Print a page with large black text, for example [sample.html](/sample.html).
Expected log:

```
… job received: 19769 bytes
… connecting to D35BT-B3F8
… writing 19769 B to FF02: flow credit, chunk ≤100 B, …
… sent 19769 B in 4.8 s (198 writes, 198 credits granted)
… job done
```

---

## Daily use

- **After a reboot:** nothing to do. Log in and the bridge starts automatically.
- **Before printing:** the printer is on, the light is blue, and no phone app is connected.
- A label takes **~7 s** from clicking Print to paper out. See [technical.md](./technical.md) for why.

## Troubleshooting

| Symptom                                   | Fix                                                                                                                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Log: `scanning…` → `timeout … not found`  | Printer off, asleep, stuck, or connected to a phone. **Power-cycle the printer**, close phone apps, and print again                                                      |
| Log: `bluetooth state: 3`                 | Grant Bluetooth permission (Step 6). This is needed again after rebuilding the binary                                                                                    |
| Blank label                               | Run `LC_ALL=C tr -d '\000' < /tmp/hprt-last-job.bin \| wc -c`. A value around **57** means the page image was empty: check "Shrink To Fit Page Width" and the paper size |
| Log: `refusing … not printer data`        | The queue isn't using the HPRT driver. Re-run `install.sh`                                                                                                               |
| Log: `no FF03 credits within 3 s`         | Different firmware. Set `HPRT_FLOW` to `delay` in the plist (slower, ~30 s), then `bootout` + `bootstrap`                                                                |
| Nothing in the log at all                 | Bridge not running: `launchctl print gui/$(id -u)/local.$(id -un).hprt-ble-bridge \| grep state`                                                                         |
| Job shows "completed" but nothing printed | Known limitation: CUPS doesn't see Bluetooth failures. Check the log and reprint                                                                                         |

### Printer indicator (from the HPRT D35 manual §3.4.2)

| Light              | Meaning                          | Fix                                                      |
| ------------------ | -------------------------------- | -------------------------------------------------------- |
| Blue, steady       | Ready                            | –                                                        |
| Red, steady        | Cover not closed                 | Press the cover down until it clicks                     |
| Red, slow blink    | Out of paper / no label          | Reload the roll and set the guides                       |
| Red, fast blink    | Label calibration failed         | Hold FEED ~3 s (2 flashes) to recalibrate for gap labels |
| Orange, slow blink | Jam / label came off the backing | Clear the paper path                                     |
| Purple             | Print head too hot               | Let it cool                                              |

Jobs sent while the light is red are **lost**, so reprint them.

## Maintenance

### show all running bridges

```sh
lpstat -v | grep D35BT

# e.g.
# device for HPRT_D35BT_5676: socket://127.0.0.1:9101
# device for HPRT_D35BT_B3F8: socket://127.0.0.1:9100
```

### Rebuild binary

```sh
LABEL="local.$(id -un).hprt-ble-bridge"

# After editing main.swift: rebuild + restart (plist unchanged)
swiftc -O -target x86_64-apple-macosx10.12 main.swift -o ~/bin/hprt-ble-bridge \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
launchctl kickstart -k gui/$(id -u)/$LABEL

# After editing the plist: reload
launchctl bootout gui/$(id -u)/$LABEL
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LABEL.plist
```

## Uninstall

Each printer has its own bridge and queue:

| Printer      | Queue             | LaunchAgent                  | Port          | Log                             |
| ------------ | ----------------- | ---------------------------- | ------------- | ------------------------------- |
| `D35BT-XXXX` | `HPRT_D35BT_XXXX` | `local.hprt-ble-bridge.XXXX` | 9100, 9101, … | `/tmp/hprt-ble-bridge-XXXX.log` |

The binary `~/bin/hprt-ble-bridge` is shared by all printers.
The HPRT driver and any **USB queue** are left untouched.

### Remove one printer

```sh
SUFFIX=5676                                   # last 4 hex of the printer to remove
LABEL="local.hprt-ble-bridge.$SUFFIX"

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null
rm -f ~/Library/LaunchAgents/$LABEL.plist /tmp/hprt-ble-bridge-$SUFFIX.log
sudo lpadmin -x "HPRT_D35BT_$SUFFIX"

lpstat -v | grep D35BT                        # queue gone, others unchanged
```

The other printers keep working. Their ports don't change.

### Remove everything

Remove all printers and print queues.

```sh
sh ./uninstall.sh
```

---

## Bridge settings (plist `EnvironmentVariables`)

| Variable        | Default                              | Meaning                                                                                                                         |
| --------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `HPRT_NAME`     | `D35BT-B3F8`                         | Exact BLE name, case-sensitive                                                                                                  |
| `HPRT_FLOW`     | `delay` (`install.sh` sets `credit`) | `credit` = printer-driven flow control (~5 s), `delay` = acknowledge + pause (~30 s), `paced` = fixed pause, no acknowledgement |
| `HPRT_CHUNK`    | `100`                                | Max bytes per BLE write. The printer itself caps this at 100                                                                    |
| `HPRT_DELAY_MS` | `20`                                 | Pause per write in `delay`/`paced` modes                                                                                        |
| `HPRT_VERBOSE`  | off                                  | `1` logs every characteristic and credit                                                                                        |

## References

- HPRT downloads: <https://download.hprt.com/Downloads.html>
- HPRT D35 user manual (EN): <https://shop.ribbon.ua/uploads/instructions/2438/ribbonua_hprt_sl32_series_label_printer_user_manual_en.pdf>
- CUPS `lpadmin`: <https://www.cups.org/doc/man-lpadmin.html> · `lpinfo`: <https://www.cups.org/doc/man-lpinfo.html>
- launchd.plist: <https://keith.github.io/xcode-man-pages/launchd.plist.5.html>