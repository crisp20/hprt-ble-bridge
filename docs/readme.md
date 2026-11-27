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

| Item                               | Notes                                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------------ |
| Hardware supporting Bluetooth LE   | \*                                                                                         |
| macOS compatible with swift 4.0.3+ | This translates to 'macOS 10.12.X+'                                                        |
| Admin rights                       | Needed once for creating the print queue (`lpadmin`)                                       |
| HPRT D35BT printer                 | Powered on and no other bluetooth devices (i.e. mobile phone) connected to it during setup |

\* Run the following command in a terminal:

```sh
system_profiler SPBluetoothDataType | grep -iE 'LMP Version|Low Energy|Chipset|Firmware'
```

If the output shows `Bluetooth Low Energy Supported: No`, then your machine's hardware is unsupported.
Consider installing a **USB Bluetooth 4.0 adapter**.

---

## Installation

### Step 1 – Install the HPRT macOS driver

1. Download **"Mac Drivers for D35BT"** from <https://download.hprt.com/Downloads.html>.
2. Run the installer.
3. Verify installation:
   ```sh
   lpinfo -m | grep -i d35bt
   ```
   You should see at least one line (e.g. `… HPRT D35BT, 1.4.10`).

You do **not** need to add a USB printer first.
The install script creates the Bluetooth queue directly from the installed driver.

### Step 2 – Install the Xcode Command Line Tools

The bridge is compiled locally with `swiftc`. Install the Command Line Tools:

To verify installation:
```sh
swiftc --version 

# expected output
swift-driver version: <...> Apple Swift version: <...>
Target: <...>
```

To install:
```sh
xcode-select --install
```

Already installed but pointing to an incorrect directory - to fix the targetted directory (requires admin):
```sh
osascript -e 'do shell script "/usr/bin/xcode-select --switch /Library/Developer/CommandLineTools" with administrator privileges'
```

### Step 3 – Find the printer's Bluetooth name

1. Printer on, cover closed (it must **click**), light **blue**.
2. **Hold FEED ~1.5 s** until the light flashes once, then release -> a self-test label prints.
3. Read `BT_MAC`. The Bluetooth name is **`D35BT-` + the last 4 hex digits in uppercase**. e.g. `BT_MAC: ba:ab:14:04:b3:f8` -> `D35BT-B3F8`.

Pairing in System Settings -> Bluetooth is **not required** for installation of the bridge.

### Step 4 – Run the install / uninstall script

Run the following script in a terminal:

For the latest stable release:
```sh
curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | \
sh
```

For a specific release:
```sh
curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | \
sh -s -- <release name>
```

Once run, an installation script be executed.

Example:
```
curl -fsSL https://raw.githubusercontent.com/crisp20/hprt-ble-bridge/main/get.sh | sh -s

# ======================================================================================
# downloads the source code
# ======================================================================================

== downloading crisp20/hprt-ble-bridge v0.1.1
   26 KB

# ========================================================================================
# lists existing bridges from previous installations
# option to perform a full uninstall at this point for a fresh installation
# ========================================================================================

== bridges already installed:
   B3F8
Uninstall all of them first (fresh start)? [y/N] y                                        # answer 'y' / 'n', default 'n'
                                                                                          # if will install bridges for multiple printer, answer 'n'
removed bridge local.hprt-ble-bridge.B3F8 (port 9100)
removed binary, logs and Bluetooth permission for justin
Kept shared queue(s) (other accounts may use them): HPRT_D35BT_B3F8
Re-run with --queue to delete them.
Done.

# ========================================================================================
# supply mandatory info about the installation
# ========================================================================================

Printer name is on the printer's label / self-test page, e.g. D35BT-ABCD → ABCD
Printer (last 4 characters): B3F8                                                         # provide the last 4 characters of the printer name
Port [9100]:                                                                              # specify which network port this bridge should run on
                                                                                          # default: 9100, if occupied by another bridge / application then next avaliable one (9101, 9102, ...)
Printer: D35BT-B3F8   port: 9100   queue: HPRT_D35BT_B3F8   user: <accoutn username>

# ========================================================================================
# installation begins
# ========================================================================================

== 1/4 build bridge                                                                        # the bridge source code being compiled

== 2/4 Bluetooth check (one blank label feeds)                                             # binary compiled, attempting a connection with the printer
(macOS 10.15+: allow Bluetooth if asked)                                                   # program will ask for bluetooth permission - allow
2026-11-27 17:11:36.339 +08:00 bluetooth state: 5 (5 = poweredOn)                          # expected state: 5, if otherwise, check the [Troubleshooting] section 
2026-11-27 17:11:36.340 +08:00 scanning for D35BT-B3F8…
2026-11-27 17:11:36.676 +08:00 connecting to D35BT-B3F8
2026-11-27 17:11:37.494 +08:00 writing 31 B to FF02: flow delay, chunk ≤100 B, delay 20 ms
2026-11-27 17:11:37.917 +08:00   printer max packet: 100 B
2026-11-27 17:11:37.973 +08:00 sent 31 B in 0.5 s (1 writes, 4 credits granted)
2026-11-27 17:11:37.973 +08:00 drain 250 ms
2026-11-27 17:11:38.234 +08:00 OK: sent 31 bytes

# ========================================================================================
# configure bridge settings
# ========================================================================================

== 3/4 LaunchAgent local.hprt-ble-bridge.B3F8                                              # It is highly recommended you leave the settings on the recommended values
Bridge settings:                                                                           # unless you know what they do - reference [Bridge settings] section
  HPRT_FLOW          credit  [recommend to leave as default]
  HPRT_CHUNK         100     [recommend to leave as default]
  HPRT_DELAY_MS      20      [recommend to leave as default]
  HPRT_GAP_MS        8       [recommend to leave as default]
  HPRT_DRAIN_MS      250     [recommend to leave as default]
  HPRT_CHAR          (auto)  [recommend to leave as default]
  HPRT_MERGE         1       [can customize as desired]
  HPRT_KEEPALIVE_MS  30000   [can customize as desired]
  HPRT_VERBOSE       0       [can customize as desired]
  HPRT_LOG_MAX_KB    1024    [can customize as desired]

# ========================================================================================
# create print queue
# ========================================================================================

== 4/4 CUPS queue HPRT_D35BT_B3F8 (shared by all accounts)
Asking for an administrator to create the shared print queue…                              # program will ask for admin credentials to create the print queue
queue created

2026-11-27 17:11:38.284 +08:00 listening on 127.0.0.1:9100 for D35BT-B3F8 (flow credit, chunk 100, delay 20 ms), drain 250 ms
2026-11-27 17:11:38.312 +08:00 bluetooth state: 5 (5 = poweredOn)
Done. Print to 'HPRT D35BT B3F8 (Bluetooth)'.
Create the 60 x 40 mm paper size (margins 0) and save print settings for this printer.     # reminding user to create the printer settings - see the next step
Install another printer on this Mac? [y/N] n                                               # if more bridges need to be installed, answer 'y'
== done. Logs: ~/Library/Logs/hprt-ble-bridge-*.log                                        # logs for print bridges can be seen in these log files
```

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
# displays all available logs for hprt bridges
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
# displays all available logs for hprt bridges
less +F ~/Library/Logs/hprt-ble-bridge-*.log
```

## Uninstall

Each printer has its own bridge and queue:

| Printer      | Queue             | LaunchAgent                  | Port          | Log                                       |
| ------------ | ----------------- | ---------------------------- | ------------- | ----------------------------------------- |
| `D35BT-XXXX` | `HPRT_D35BT_XXXX` | `local.hprt-ble-bridge.XXXX` | 9100, 9101, … | `~/Library/Logs/hprt-ble-bridge-XXXX.log` |

The binary `~/bin/hprt-ble-bridge` is shared by all printers.
The HPRT driver and any **USB queue** are left untouched.

```sh 
# Uninstall a specific printer
sh ./uninstall.sh XXXX # The suffix of the printer

# Uninstall all printers
sh ./uninstall.sh --all

# ...as well as the print queues
sh ./uninstall.sh XXXX|--all --queue
```

<details>
<summary>note</summary>

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
</details>

---

## Bridge settings 

plist `EnvironmentVariables`

| Variable            | Default                              | Meaning                                                                                                                         |
| ------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `HPRT_NAME`         | /                                    | Exact BLE name, case-sensitive                                                                                                  |
| `HPRT_PORT`         | `9100`                               | TCP port on 127.0.0.1 that CUPS connects to; must match the queue URI                                                           |
| `HPRT_FLOW`         | `delay` (`install.sh` sets `credit`) | `credit` = printer-driven flow control (~5 s), `delay` = acknowledge + pause (~30 s), `paced` = fixed pause, no acknowledgement |
| `HPRT_CHUNK`        | `100`                                | Max bytes per BLE write. The printer itself caps this at 100                                                                    |
| `HPRT_DELAY_MS`     | `20`                                 | Pause per write in `delay`/`paced` modes                                                                                        |
| `HPRT_GAP_MS`       | `8`                                  | Interval (ms) between packets in credit mode (relevant for macOS 10.12 only)                                                    |
| `HPRT_DRAIN_MS`     | `250`                                | Drain time (ms) between jobs. Ensures end of job is not lost.                                                                   |
| `HPRT_CHAR`         | `<empty string>`                     | Write characteristic UUID.                                                                                                      |
| `HPRT_MERGE`        | `<on>`                               | Merges byte-identical consecutive labels into one CPCL label with quantity N. 0 = off                                           |
| `HPRT_KEEPALIVE_MS` | `30000`                              | Keep alive (ms) for the printer connection.                                                                                     |
| `HPRT_VERBOSE`      | `<off>`                              | `1` logs every characteristic and credit                                                                                        |
| `HPRT_LOG_MAX_KB`   | `1024`                               | Max size of log file before being rotated                                                                                       |

## References

- HPRT downloads: <https://download.hprt.com/Downloads.html>
- HPRT D35 user manual (EN): <https://shop.ribbon.ua/uploads/instructions/2438/ribbonua_hprt_sl32_series_label_printer_user_manual_en.pdf>
- CUPS `lpadmin`: <https://www.cups.org/doc/man-lpadmin.html> · `lpinfo`: <https://www.cups.org/doc/man-lpinfo.html>
- launchd.plist: <https://keith.github.io/xcode-man-pages/launchd.plist.5.html>