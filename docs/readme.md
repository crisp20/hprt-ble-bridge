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

---

## Installation

### Step 1 – Install the HPRT macOS driver

1. Download **"Mac Drivers for D35BT"** from <https://download.hprt.com/Downloads.html>.
2. Run the installer.
3. Verify:
   ```sh
   lpinfo -m | grep -i d35bt
   ```
   You should see at least one line (e.g. `… HPRT D35BT, 1.4.10`).

You do **not** need to add a USB printer first. 
The install script creates the Bluetooth queue directly from the installed driver.

### Step 2 – Install the Xcode Command Line Tools

The bridge is compiled locally with `swiftc`. Install the Command Line Tools:

```sh
# swiftc --version to check if already installed
# otherwise, run:
xcode-select --install
```

```sh
# ...or already installed but pointing to an incorrect directory, in which case:
osascript -e 'do shell script "/usr/bin/xcode-select --switch /Library/Developer/CommandLineTools" with administrator privileges'
```

### Step 3 – Find the printer's Bluetooth name

1. Printer on, cover closed (it must **click**), light **blue**.
2. **Hold FEED ~1.5 s** until the light flashes once, then release -> a self-test label prints.
3. Read `BT_MAC`, e.g. `ba:ab:14:04:b3:f8`. The Bluetooth name is **`D35BT-` + the last 4 hex digits in uppercase**, so here it's `D35BT-B3F8`.

Pairing in System Settings -> Bluetooth is **not required**. BLE connects without pairing.

### Step 4 – Run the install / uninstall script

Run the following script in a terminal:

```sh
# Production version
curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | sh

# Specific version
curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | sh -s -- <release name>
```

The script will ask:
 1. Whether you want to uninstall existing bridges,
 2. Whether you want to install new bridges,
 3. (if continuing) the name of the printer being set up,
 4. admin accounts & permission grants where necessary.

### Step 5 – Paper size and print preset (one-time)

Associate the desired print size and setting to this printer.

In any print dialog:
1. Choose:
   - Paper Size: **Manage Custom Sizes… -> +**
   - Set width **60 mm**, height **40 mm**, all margins **0**
   - Name it e.g. **Small Label**
2. Choose:
   - Printer: **HPRT D35BT XXXX (Bluetooth)**
   - Paper Size: **Small Label**
   - Orientation: **Portrait**
   - Check ✅: **Ignore Scaling and Shrink To Fit Page Width**
   - Page Headers / Footers: all six **--blank--**
3. **Presets -> Save Current Settings as Preset…:**.
   - Preset Name: **"D35BT label"**
   - Available For: **HPRT D34BT XXXX**
   - Type: **Print Job Preset**

### Step 6 – Test

```sh
tail -f ~/Library/Logs/hprt-ble-bridge-*.log
# or
less +F ~/Library/Logs/hprt-ble-bridge-*.log
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
- **Before printing:** the printer is on, the light is blue, and no other devices are connected.
- A label takes **~7 s** from clicking Print to paper out. See [technical.md](./technical.md) for why.

## Troubleshooting

| Symptom                                   | Fix                                                                                                                                                                                                 |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Log: `scanning…` -> `timeout … not found` | Printer off, asleep, stuck, or connected to a phone. **Power-cycle the printer**, close phone apps, and print again                                                                                 |
| Log: `bluetooth state: 3`                 | Grant Bluetooth permission (Step 6). This is needed again after rebuilding the binary                                                                                                               |
| Blank label                               | Run `LC_ALL=C tr -d '\000' < ~/Library/Logs/hprt-last-job-9100.bin \| wc -c` (use your port). A value around 57 means the page image was empty: check "Shrink To Fit Page Width" and the paper size |
| Log: `refusing … not printer data`        | The queue isn't using the HPRT driver. Re-run `install.sh`                                                                                                                                          |
| Log: `no FF03 credits within 3 s`         | Different firmware. Set `HPRT_FLOW` to `delay` in the plist (slower, ~30 s), then `bootout` + `bootstrap`                                                                                           |
| Nothing in the log at all                 | Bridge not running: `launchctl print gui/$(id -u)/local.hprt-ble-bridge.XXXX \| grep state`                                                                                                         |
| Job shows "completed" but nothing printed | Known limitation: CUPS doesn't see Bluetooth failures. Check the log and reprint                                                                                                                    |

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
# device for HPRT_D35BT_5676: socket://127.0.0.1:9101/?snmp=false
# device for HPRT_D35BT_B3F8: socket://127.0.0.1:9100/?snmp=false
```

### logging

```sh

less +F ~/Library/Logs/hprt-ble-bridge-*.log

# displays all available logs for hprt bridges
```

### Rebuild binary

```sh
LABEL="local.hprt-ble-bridge.XXXX"            # XXXX = printer id

# After editing main.swift: rebuild + restart (plist unchanged)
swiftc -O main.swift -o ~/bin/hprt-ble-bridge \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
launchctl kickstart -k gui/$(id -u)/$LABEL

# After editing the plist: reload
launchctl bootout gui/$(id -u)/$LABEL
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LABEL.plist
```

## Uninstall

Each printer has its own bridge and queue:

| Printer      | Queue             | LaunchAgent                  | Port          | Log                                       |
| ------------ | ----------------- | ---------------------------- | ------------- | ----------------------------------------- |
| `D35BT-XXXX` | `HPRT_D35BT_XXXX` | `local.hprt-ble-bridge.XXXX` | 9100, 9101, … | `~/Library/Logs/hprt-ble-bridge-XXXX.log` |

The binary `~/bin/hprt-ble-bridge` is shared by all printers.
The HPRT driver and any **USB queue** are left untouched.

### Remove a specific printer

```sh
SUFFIX=5676                                   # last 4 hex of the printer to remove
PORT=9101                                     # its port
LABEL="local.hprt-ble-bridge.$SUFFIX"

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null
rm -f ~/Library/LaunchAgents/$LABEL.plist \
      ~/Library/Logs/hprt-ble-bridge-$SUFFIX.log \
      ~/Library/Logs/hprt-last-job-$PORT.bin
sudo lpadmin -x "HPRT_D35BT_$SUFFIX"          # admin account; a standard account can't use sudo

lpstat -v | grep D35BT                        # queue gone, others unchanged
```

The other printers keep working. Their ports don't change.

### Remove all printers

Remove all printers and print queues.

```sh
sh ./uninstall.sh XXXX|--all [--queue]
```

---

## Bridge settings (plist `EnvironmentVariables`)

| Variable        | Default                              | Meaning                                                                                                                         |
| --------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `HPRT_NAME`     | `D35BT-B3F8`                         | Exact BLE name, case-sensitive                                                                                                  |
| `HPRT_PORT`     | `9100`                               | TCP port on 127.0.0.1 that CUPS connects to; must match the queue URI                                                           |
| `HPRT_FLOW`     | `delay` (`install.sh` sets `credit`) | `credit` = printer-driven flow control (~5 s), `delay` = acknowledge + pause (~30 s), `paced` = fixed pause, no acknowledgement |
| `HPRT_CHUNK`    | `100`                                | Max bytes per BLE write. The printer itself caps this at 100                                                                    |
| `HPRT_DELAY_MS` | `20`                                 | Pause per write in `delay`/`paced` modes                                                                                        |
| `HPRT_VERBOSE`  | off                                  | `1` logs every characteristic and credit                                                                                        |
| `HPRT_DRAIN_MS` | `250`                                | Drain time (ms) between jobs. Ensures end of job is not lost.                                                                   |
| `HPRT_MERGE`    | on                                   | Merges byte-identical consecutive labels into one CPCL label with quantity N. 0 = off                                           |

## References

- HPRT downloads: <https://download.hprt.com/Downloads.html>
- HPRT D35 user manual (EN): <https://shop.ribbon.ua/uploads/instructions/2438/ribbonua_hprt_sl32_series_label_printer_user_manual_en.pdf>
- CUPS `lpadmin`: <https://www.cups.org/doc/man-lpadmin.html> · `lpinfo`: <https://www.cups.org/doc/man-lpinfo.html>
- launchd.plist: <https://keith.github.io/xcode-man-pages/launchd.plist.5.html>