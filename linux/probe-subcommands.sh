#!/usr/bin/env bash
# Sweep the vendor subcommand space of an AIC8800D80 clone while it sits in ZeroCD mode.
#
#   sudo ./probe-subcommands.sh [SUB_FROM] [SUB_TO]
#   sudo ./probe-subcommands.sh 0xF0 0xFF      # the documented family + control
#   sudo ./probe-subcommands.sh 0x00 0xEF      # the rest
#
# The target is resolved by USB identity (`1111:1111`, override with USB_VID/USB_PID), never by
# assuming a `/dev/sdX` letter. With another storage device plugged in, assuming the letter means
# probing the wrong hardware: a generic fake-disk stub answers vendor opcodes with plain `Good` and
# you end up with a plausible but meaningless "map".
#
# Writes a raw-image copy of the fake disk and a log holding the full `sg_raw -v` output plus the USB
# ID state before/after every probe. Stops on the first probe that leaves the device unresponsive and
# prints the subcommand to resume from (a replug is needed: the bulk-only state machine desyncs).
#
# Everything is issued read-only (`sg_raw -R`): this never writes to the device.
set -u

SUB_FROM="${1:-0xF0}"
SUB_TO="${2:-0xFF}"
USB_VID="${USB_VID:-1111}"
USB_PID="${USB_PID:-1111}"
# Defaults live next to the script, not in $PWD: run with sudo from a home directory, a
# $PWD-relative default would create ~/evidence and a root-owned ~/artifacts in the caller home.
SELFDIR="$(cd -- "$(dirname -- "$(readlink -f "$0")")" && pwd)"
OUT="${OUT:-$SELFDIR/evidence}"
ART="${ART:-$SELFDIR/artifacts}"
mkdir -p "$OUT" "$ART"
LOG="$OUT/probe-subcommands-$(date +%Y%m%d-%H%M%S).log"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

log "=== AIC8800D80 ZeroCD sweep: subcommands $SUB_FROM..$SUB_TO (opcode 0xFD) ==="
log "date: $(date -Is)"
log "target USB ID: $(printf '%04x:%04x' "0x$USB_VID" "0x$USB_PID")"

# --- 1) resolve the device by USB identity, never by drive letter -----------------
find_usb() {
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor")" = "$USB_VID" ] && [ "$(cat "$d/idProduct")" = "$USB_PID" ]; then
      printf '%s\n' "${d%/}"; return 0
    fi
  done
  return 1
}

USBDEV="$(find_usb)" || {
  log "!! no USB device $(printf '%04x:%04x' "0x$USB_VID" "0x$USB_PID") connected -> nothing to probe."
  log "!! check 'lsusb': if the dongle is not listed it is unplugged, or it is already switched"
  log "!! and enumerating as a69c:8d80/8d81 (a replug brings it back to ZeroCD mode)."
  exit 1
}
log "USB device: ${USBDEV##*/}  product='$(cat "$USBDEV/product" 2>/dev/null)' manufacturer='$(cat "$USBDEV/manufacturer" 2>/dev/null)' bcdDevice=$(cat "$USBDEV/bcdDevice" 2>/dev/null)"

BLK=""; SG=""
for b in /sys/block/sd*; do
  real="$(readlink -f "$b/device" 2>/dev/null || true)"
  case "$real" in
    "$(readlink -f "$USBDEV")"*)
      BLK="$b"; SG="$(ls "$b/device/scsi_generic/" 2>/dev/null | head -1)"; break ;;
  esac
done

if [ -z "$SG" ]; then
  log "!! ${USBDEV##*/} is present but exposes no generic (sg) node on a block device."
  log "!! Is it already switched (a69c:8d80/8d81) or bound to another driver? Check 'lsusb'."
  exit 1
fi

DEV="/dev/$SG"
BLOCKDEV="/dev/$(basename "$BLK")"
log "block device: $BLOCKDEV   sg device: $DEV"
log "SCSI identity: vendor='$(cat "$BLK/device/vendor" 2>/dev/null)' model='$(cat "$BLK/device/model" 2>/dev/null)' rev='$(cat "$BLK/device/rev" 2>/dev/null)'"
log "capacity: $(cat "$BLK/size" 2>/dev/null) sectors"

# --- 2) raw image of the fake disk (provenance) ------------------------------------
SECT="$(cat "$BLK/size" 2>/dev/null || echo 0)"
if [ "${SECT:-0}" -gt 0 ]; then
  # Timestamped name: overwriting one file loses the previous boot's image, which is exactly what
  # you need to compare when the raw hash changes between power cycles (it does: the payload stays
  # byte-identical while the filesystem metadata region does not).
  IMG="$ART/fake-cd-raw-$(date +%Y%m%d-%H%M%S).img"
  log "--- fake disk raw image: $BLOCKDEV ($SECT sectors) -> $IMG ---"
  dd if="$BLOCKDEV" of="$IMG" bs=512 count="$SECT" conv=noerror,sync status=none
  sha256sum "$IMG" | tee -a "$LOG"
  # The payload is the stable identifier; hash the regular files too, not just the raw image.
  if [ -d /run/media/$USER/*/ ]; then :; fi
fi

# --- 3) liveness and identity ------------------------------------------------------
# Liveness: TEST UNIT READY (no data phase). Do NOT use INQUIRY without -r here: this stub answers
# "Illegal Request / Invalid field in cdb" while it is perfectly healthy.
vive() { sg_raw -R -t 10 "$DEV" 00 00 00 00 00 00 >/dev/null 2>&1; }
# Identity the device reports itself (subcommand F3 = GetHippo)
ident() { sg_raw -R -t 10 -r 64 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f3 2>/dev/null; }

if vive; then log "TEST UNIT READY: OK -> device is alive"
else log "!! TUR failed: the device is already desynced (replug)"; fi
log "GetHippo (F3 -r 64): $(ident | tr -s '[:space:]' ' ' | tr -d '\n')"

estado() { lsusb 2>/dev/null | grep -oE 'ID (1111:1111|a69c:[0-9a-f]{4})' | sort -u | tr '\n' ' '; }

# --- 4) one subcommand: with and without a data phase ------------------------------
probe() {   # $1 = subcommand in hex (e.g. F3)
  local sub="$1" antes despues
  antes="$(estado)"
  log ""
  log "### subcommand 0x$sub  (USB ID state before: ${antes:-none})"
  log "--- no data phase ---"
  sg_raw -v -R -t 10 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "$sub" >>"$LOG" 2>&1
  log "exit=$?"
  log "--- data-IN up to 64 bytes ---"
  sg_raw -v -R -t 10 -r 64 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "$sub" >>"$LOG" 2>&1
  log "exit=$?"
  despues="$(estado)"
  log "USB ID state after: ${despues:-none}"
  if [ "$antes" != "$despues" ]; then
    log "*** USB ID CHANGE with 0x$sub: '$antes' -> '$despues' ***"
    log "*** an identity change invalidates the rest of the sweep: the device is no longer the"
    log "*** personality being mapped (seen in the field: 1111:1111 'AIC 88M80' falling back to"
    log "*** 214b:2030 'Generic Flash Disk 2.0' with a blank fake disk)."
    log "*** Power-cycle the dongle and resume with:  $0 0x<next sub> $SUB_TO"
    exit 3
  fi
  if ! vive; then
    log "*** device stopped answering after 0x$sub ***"
    log "*** replug, then resume with:  $0 0x<next sub> $SUB_TO"
    exit 2
  fi
}

# --- 5) sweep ----------------------------------------------------------------------
FROM=$((16#${SUB_FROM#0x})); TO=$((16#${SUB_TO#0x}))
for ((i=FROM; i<=TO; i++)); do
  printf -v sub '%02X' "$i"
  [ "$sub" = "F2" ] && continue          # F2 is the known switch: kept out of the sweep
  probe "$sub"
done

# --- 6) optional control: F2 via usb_modeswitch (it also performs the required USB reset) ----------
if [ "${CONTROL_F2:-0}" = "1" ]; then
  log ""
  log "### CONTROL: F2 through usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111"
  [ -f /etc/usb_modeswitch.d/1111:1111 ] && usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111 >>"$LOG" 2>&1 \
    || log "!! /etc/usb_modeswitch.d/1111:1111 not present"
  sleep 3
  log "final USB ID state: $(estado)"
else
  log ""
  log "(F2 control skipped: the device stays in ZeroCD mode. Run it with: CONTROL_F2=1 $0 $SUB_FROM $SUB_TO)"
fi
log "=== sweep finished ==="
echo "LOG: $LOG"
