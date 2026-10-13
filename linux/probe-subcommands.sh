#!/usr/bin/env bash
# Sweep the vendor subcommand space of an AIC8800D80 clone while it sits in ZeroCD mode.
#
#   sudo ./probe-subcommands.sh [SUB_FROM] [SUB_TO]
#   sudo ./probe-subcommands.sh 0xF0 0xFF      # the documented family + control
#   sudo ./probe-subcommands.sh 0x00 0xEF      # the rest
#
# Writes a raw-image copy of the fake disk and a log holding the full `sg_raw -v` output plus the USB
# ID state before/after every probe. Stops on the first probe that leaves the device unresponsive and
# prints the subcommand to resume from (a replug is needed: the bulk-only state machine desyncs).
#
# Everything is issued read-only (`sg_raw -R`): this never writes to the device.
set -u

SUB_FROM="${1:-0xF0}"
SUB_TO="${2:-0xFF}"
OUT="${OUT:-$PWD/evidence}"
ART="${ART:-$PWD/artifacts}"
mkdir -p "$OUT" "$ART"
LOG="$OUT/probe-subcommands-$(date +%Y%m%d-%H%M%S).log"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

log "=== AIC8800D80 ZeroCD sweep: subcommands $SUB_FROM..$SUB_TO (opcode 0xFD) ==="
log "date: $(date -Is)"

# --- 1) raw image of the fake disk (provenance) --------------------------------
MODEL="$(cat /sys/block/sda/device/model 2>/dev/null)"
case "$MODEL" in
  WIFI6*) SECT=$(cat /sys/block/sda/size)
          log "--- fake disk raw image: /dev/sda ($SECT sectors) ---"
          dd if=/dev/sda of="$ART/fake-cd-raw.img" bs=512 count="$SECT" conv=noerror,sync status=none
          sha256sum "$ART/fake-cd-raw.img" | tee -a "$LOG" ;;
  *)      log "!! /dev/sda is not the fake disk (model='$MODEL'): skipping the dd, continuing" ;;
esac

# --- 2) find the device's generic (sg) node ------------------------------------
SG=$(ls /sys/block/sda/device/scsi_generic/ 2>/dev/null | head -1)
if [ -z "$SG" ]; then log "!! no /dev/sg* for sda -> aborting"; exit 1; fi
DEV="/dev/$SG"
log "sg device: $DEV  (model='$(cat /sys/class/scsi_generic/$SG/device/model 2>/dev/null)')"

# Liveness: TEST UNIT READY (no data phase). Do NOT use INQUIRY without -r here: this stub answers
# "Illegal Request / Invalid field in cdb" while it is perfectly healthy.
vive() { sg_raw -R -t 10 "$DEV" 00 00 00 00 00 00 >/dev/null 2>&1; }
# Identity the device reports itself (subcommand F3 = GetHippo)
ident() { sg_raw -R -t 10 -r 64 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f3 2>/dev/null; }

if vive; then log "TEST UNIT READY: OK -> device is alive"
else log "!! TUR failed: the device is already desynced (replug)"; fi
log "GetHippo (F3 -r 64): $(ident | tr -s '[:space:]' ' ')"

estado() { lsusb 2>/dev/null | grep -oE 'ID (1111:1111|a69c:[0-9a-f]{4})' | sort -u | tr '\n' ' '; }

# --- 3) one subcommand: with and without a data phase ---------------------------
probe() {   # $1 = subcommand in hex (e.g. F3)
  local sub="$1" antes despues
  antes="$(estado)"
  log ""
  log "### subcommand 0x$sub  (state before: ${antes:-none})"
  log "--- no data phase ---"
  sg_raw -v -R -t 10 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "$sub" >>"$LOG" 2>&1
  log "exit=$?"
  log "--- data-IN up to 64 bytes ---"
  sg_raw -v -R -t 10 -r 64 "$DEV" fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "$sub" >>"$LOG" 2>&1
  log "exit=$?"
  despues="$(estado)"
  log "state after: ${despues:-none}"
  if [ "$antes" != "$despues" ]; then
    log "*** STATE CHANGE with 0x$sub: '$antes' -> '$despues' ***"
  fi
  if ! vive; then
    log "*** device stopped answering after 0x$sub ***"
    log "*** replug, then resume with:  $0 0x<next sub> $SUB_TO"
    exit 2
  fi
}

# --- 4) sweep -------------------------------------------------------------------
FROM=$((16#${SUB_FROM#0x})); TO=$((16#${SUB_TO#0x}))
for ((i=FROM; i<=TO; i++)); do
  printf -v sub '%02X' "$i"
  [ "$sub" = "F2" ] && continue          # F2 is the known switch: kept out of the sweep
  probe "$sub"
done

# --- 5) optional control: F2 via usb_modeswitch (it also performs the required USB reset) ----------
if [ "${CONTROL_F2:-0}" = "1" ]; then
  log ""
  log "### CONTROL: F2 through usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111"
  [ -f /etc/usb_modeswitch.d/1111:1111 ] && usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111 >>"$LOG" 2>&1 \
    || log "!! /etc/usb_modeswitch.d/1111:1111 not present"
  sleep 3
  log "final state: $(estado)"
else
  log ""
  log "(F2 control skipped: the device stays in ZeroCD mode. Run it with: CONTROL_F2=1 $0 $SUB_FROM $SUB_TO)"
fi
log "=== sweep finished ==="
echo "LOG: $LOG"
