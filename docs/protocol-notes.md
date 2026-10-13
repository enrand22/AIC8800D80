# AIC8800D80 clone (`1111:1111`, "Pandora 88M80"): verified protocol notes

Evidence-backed notes from probing a device we own, kept in this fork because the upstream
pull request and issue comments from this work have not been answered yet
(see `fix/resetusb-after-modeswitch`, PR #6: open and mergeable, no review).

No vendor binary is redistributed here — only behaviour we observed, hashes, and our own tooling.
Device: `1111:1111`, SCSI inquiry `LGX WIFI6 2.30`, `bcdDevice 10.01`. Host: Arch Linux, kernel 7.2.x.

## 1. What was verified on a second build of `Usb_Driver.dll`

The published analysis is for one build; ours is another one (109 568 bytes, 2026-03-29,
sha256 `034fa698512ed5139630d1fd689b620ab52247cbb79c1fd19625833b8d7ba247`, 611 procedures) and
confirms it. Export RVAs differ (`GetHippo 0x2cd0`, `SendCMD 0x2d10`, `Set_CS1_0 0x2c90`,
`UKeySCListDevs 0x28d0`, `UniSCConnectDev 0x28a0`), but the **spacing between exports is identical**
(`0x30, 0x3C0, 0x40, 0x40`) — same source, relinked.

```c
bool Set_CS1_0(HANDLE h) {                       // 0x10002c90, 62 bytes
  local_20 = 0xfd; uStack_14 = 0xf2000000;       // CDB = FD 00 .. 00 F2
  return SendCMD(h, &local_20, 0, NULL, 0, NULL, 0x14) != 0;   // no data phase, timeout 20 s
}

bool GetHippo(HANDLE h, uint *out) {             // 0x10002cd0
  local_20 = 0xfd; uStack_14 = 0xf3000000;       // CDB = FD 00 .. 00 F3
  return SendCMD(h, &local_20, 5, out, 1, NULL, 0x14) != 0;     // data-IN, length 5
}
```

Inner SCSI wrapper (`0x10001ca0`) matches the documented `SCSI_PASS_THROUGH` layout field by field:
buffer zeroed for `0x250` bytes, `Length 0x2C`, `CdbLength 0x10`, `SenseInfoLength 0x18`,
`DataBufferOffset 0x50`, `SenseInfoOffset 0x30`, `DeviceIoControl(h, 0x4D004, …)`, and success requires
`DeviceIoControl != 0 && ScsiStatus == 0`. The CDB is copied as four dwords.

`xrefs SendCMD` returns exactly **two code call sites** (`Set_CS1_0`, `GetHippo`) plus one reference from
the export address table, which is not a call.

### Two refinements to the published write-up

1. **`SendCMD` makes three attempts in total, not three retries.** The loop counter starts at 0 and runs
   while `< 3`, sleeping `0x96` = **150 ms** between attempts, and it returns immediately (no retry) when
   `GetLastError()` is `6` (INVALID_HANDLE), `55` (DEV_NOT_EXIST), `121` (SEM_TIMEOUT) or
   `1167` (DEVICE_NOT_CONNECTED).
2. **"Reads 5 bytes back" is the caller's buffer, not the device's answer.** `GetHippo` asks for exactly
   5 bytes; the device's real payload is longer (next section). Documenting the truncated view as the
   protocol sends the next reader down the wrong path.

## 2. Subcommand map for the vendor SCSI opcode `0xFD`

The device answers SCSI while it is still in ZeroCD mode. It enumerates as a **disk** (`/dev/sda`, model
`WIFI6`, ~1.9 MB read-only vfat, label `WiFi-driver`), so its generic node is the one listed in
`/sys/block/sda/device/scsi_generic/`. Sweep the last CDB byte with `sg_raw` in read-only mode:

```bash
sg_raw -R -t 10 -r 64 /dev/sg0 fd 00 00 00 00 00 00 00 00 00 00 00 00 00 00 <SUB>
```

| sub | behaviour | answer |
|---|---|---|
| `F2` | the mode switch (trigger) | CSW OK; needs the USB reset afterwards on this revision |
| `F3` (`GetHippo`) | **real data-IN command** | 17 bytes: `88M800 DISK\0` (`38 38 4d 38 30 30 20 44 49 53 4b 20 20 20 20 20 00`) |
| `FB` | data-IN candidate | without a data phase: `Illegal Request / Invalid field in cdb`; with data-IN: `Good` and **0 bytes** |
| `F0 F1 F4-FA FC-FF` | no effect | `SCSI Status: Good` and *no data received* — the stub acknowledges blindly whatever it does not implement |

Notes that save time if you repeat this:
- The device honours the allocation length: `-r 5` returns only `88M80`. It reports its own
  identity/mode in that string, ending in `DISK` while in ZeroCD mode.
- **Do not use INQUIRY without a data phase as a liveness check on this stub** — it answers
  `Illegal Request / Invalid field in cdb` while perfectly healthy. Use `TEST UNIT READY`
  (`sg_raw -R <dev> 00 00 00 00 00 00`), and always pass `-r N` for data-IN commands.
- No subcommand other than `F2` changed the device state: no re-enumeration, no lost response, no replug
  needed across the sweep. Everything was issued with `-R` (read-only), so nothing was written.
- Commands that have no meaning are not rejected — that is why a "it answered OK" test proves nothing
  about whether a command exists.

Tooling: `linux/probe-subcommands.sh` (this fork) runs the sweep, writes a log with the raw
`sg_raw -v` output and the USB ID state before/after every probe, stops on the first unresponsive probe
and prints the subcommand to resume from after a replug.

## 3. Vendor firmware vs the Linux firmware in use

The Windows package ships **no loose firmware files**; `aicloadfw.Sys` embeds the Bluetooth pieces
(the WiFi `fmacfw` is nowhere in plaintext, and there is no large high-entropy blob hiding in either
driver). Inside `driversfiles/win10_x64/aicloadfw.Sys`:

| piece | vendor copy | Linux copy (`/lib/firmware/aic8800D80/`) |
|---|---|---|
| `fw_adid_8800d80_u02.bin` | **byte-identical**, 1708 B at file offset `0xa5a20` | 1708 B, sha256 `a526cbd02fcdc495…` |
| `fw_patch_table_8800d80_u02.bin` | `AICBT_PT_TAG`+`AICBT_PINF_T` header, **revision counter 3**, patch addresses `0x0020d2d0…` | **revision counter 6**, addresses `0x001e7e9c…` |

So the Bluetooth patch table in use on Linux is **newer** than the one embedded in the vendor's Windows
driver (revision 6 vs 3). That rules out "the Linux side is running an old firmware" as an explanation
for chip-level defects on this revision. The INF files carry unexplained `OtaKey` values
(`da681918c11078801e432552b70bd4a95fad9b6d` for the WiFi driver, `d3ce088cfa29e92ee5b88a4ae0123c72069fc840`
for the loader) — plausible key material for encrypted OTA blobs, not investigated further.

## 4. Which clones need which treatment

The driver source's own `install.sh` drops a udev rule (package-unowned,
`/usr/lib/udev/rules.d/aic.rules`) that switches `1111:1111` by running
`usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111` — the **same switch as the rule this project
installs**. Two rules, one switch: disabling only your own rule leaves the dongle switching on every
plug, with no window to read the fake disk or probe the protocol. Rename both to `.off` and
`udevadm control --reload-rules` when you need the device to stay in storage mode.

The same file shows that **other ZeroCD IDs from this chip family switch with a plain SCSI `eject`**,
no vendor CDB at all: `a69c:5721`, `5722` (`aicudisk`), `5723`, `5726`, `5727`, `572a` (`tendaudisk`),
`5724` (`ugreenax900`), `572c` (`cudydiskv2`), `572f`. Worth stating explicitly when documenting which
device needs which treatment — "it is an AIC8800 ZeroCD clone" does not imply it needs the `F2` CDB.

## 5. Method / limitations (what was *not* touched)

- All probes ran in read-only mode (`sg_raw -R`); nothing was written to the device.
- No subcommand was probed with a data-OUT phase (writes) on purpose.
- The sweep covers opcode `0xFD`; other vendor opcodes were not swept, consistent with the published
  static analysis finding only `0xFD` in the DLL.
- Subcommands `0x00`-`0xEF` of `0xFD` are still pending (the `0xF0`-`0xFF` family is complete).
- The firmware comparison covers the Bluetooth half; the WiFi blob is not comparable against this
  installer because the vendor does not ship it in plaintext.
- Reproducing the static part needs `7z x <installer>.exe` (the closed binaries live inside the NSIS
  self-extractor) and any decompiler — nothing here depends on a specific tool.

## 6. Provenance

| item | value |
|---|---|
| Installer on the fake disk | `Wifi6_install_bt.exe`, 1 919 072 B, sha256 `fea38706153861865b67dae00d9f13227deb923172299d2ae93bf082349d725c` |
| Raw image of the fake disk | 2 031 616 B (3968 × 512), sha256 `f9da38295ada7763b3e9f9c084558213ded4e39f77bd3108e38b103f78a2724b` |
| `Usb_Driver.dll` analysed here | 109 568 B, sha256 `034fa698512ed5139630d1fd689b620ab52247cbb79c1fd19625833b8d7ba247` |
| Post-switch IDs observed | `a69c:8d80` (boot ROM) → `a69c:8d81` (WiFi + BT, 3 interfaces) |
