#!/bin/bash

# 1. Stop every bridge agent and remove its plist
for p in ~/Library/LaunchAgents/local*hprt-ble-bridge*.plist; do
  [ -e "$p" ] || continue
  launchctl bootout gui/$(id -u) "$p" 2>/dev/null
  rm -f "$p"
done

# 2. Remove every Bluetooth queue, i.e. any queue pointing at the local bridge (USB queues are kept)
lpstat -v | awk '/socket:\/\/127\.0\.0\.1:/ { sub(":", "", $3); print $3 }' |
while read -r q; do
  echo "removing queue $q"; sudo lpadmin -x "$q"
done

# 3. Remove the binary, logs and job captures
rm -f ~/bin/hprt-ble-bridge /tmp/hprt-ble-bridge*.log /tmp/hprt-last-job*.bin /tmp/hprt-probe.cpcl

# 4. Check: no bridge listening, no Bluetooth queues left
lsof -nP -iTCP:9100-9199 -sTCP:LISTEN || echo "ports free"
lpstat -v | grep D35BT                        # only the USB queue (if any) should remain

# 5. Optional: remove the Bluetooth permission entry
tccutil reset BluetoothAlways local.hprt-ble-bridge 2>/dev/null || true

