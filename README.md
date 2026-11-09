# AERA Recovery build for Nubia Z60 Ultra (NX721J / cerro)

A reproducible build script that turns the upstream [AERA Recovery
Project](https://github.com/AERA-Recovery) `aera-16.0` manifest plus
[delvoryx's cerro recovery tree](https://github.com/delvoryx/android_device_nubia_cerro-recovery)
into a working recovery for the Nubia Z60 Ultra — a device AERA does not
officially support.

Everything here is the glue: the manifest, the recovery and the device tree
belong to their authors (see [Credits](#credits)). What this repository adds is
the set of device-specific fixes needed to make that combination boot and work,
each one documented inline with the reason it exists.

## Usage

```sh
bash build-aera-cerro.sh              # full sync (~90 GB) + build
NO_SYNC=1   bash build-aera-cerro.sh  # rebuild only
SYNC_ONLY=1 bash build-aera-cerro.sh  # sources only
UPDATE_DT=1 bash build-aera-cerro.sh  # refresh the device tree
AERA_PIN=0  bash build-aera-cerro.sh  # track AERA HEAD instead of pinned revisions
```

The script runs the build inside a `distrobox` container named `rom` and holds a
`systemd-inhibit` lock so the machine stays awake. Output lands in
`out/target/product/cerro/` as `AERA-R1.0-Beta-Unofficial-cerro.img` and a
flashable `.zip`.

## Why a build script and not a device tree fork

Nothing here patches AERA or the device tree in git. The script clones both
upstream, applies its fixes on top, and documents each one, so updating means
re-running it rather than rebasing a fork. AERA moves fast — over 100 commits
landed in `bootable/recovery` in three weeks — so the script also pins the two
AERA repositories to known revisions by default.

## The fixes, and why each is needed

All of these were diagnosed on the device itself (kernel ring buffer pulled over
EDL, logs over ADB), not guessed:

| # | Fix | Symptom without it |
|---|-----|--------------------|
| 1 | Release `ap2a` → `bp2a` | tree targets Android 14 |
| 2 | Unquote `TARGET_RECOVERY_PIXEL_FORMAT` | quoted value leaks into `soong.*.extra.variables`, `merge_json` fails at ~90% |
| 3 | Drop the A14 prebuilt `libc++.so` | it shadows the A16 one and lacks `std::basic_stringstream`/`std::__fs::filesystem` symbols `init` needs → `CANNOT LINK EXECUTABLE "/system/bin/init"` → `Kernel panic: Attempted to kill init` → ZTE memory dump mode |
| 4 | Drop the A14 vendor `libbinder`/`libbinder_ndk` | A16 HAL NDK libs need an API-36 symbol the A14 pair lacks → keymint, gatekeeper, boot and health HALs die → recovery hangs waiting for keystore2 |
| 5 | `AERA_BUILD_TYPE := Beta` | `Stable` enables `OF_ADVANCED_SECURITY`, which disables ADB and MTP by design |
| 6 | `AERA_UI_ADAPTIVE_RESOLUTION` + `AERA_SCREEN_H := 2400` | UI metrics are hardcoded for a 1440x3168 panel; on 1116x2480 the layout is skewed and swipes crash the UI |
| 7 | Default `sys.usb.config=adb` | nothing sets it in normal recovery, so adbd never starts and the phone is invisible on USB (ADB works only in sideload) |
| 8 | Wi-Fi bring-up script | `rfkill` lives in `system_dlkm` where AERA's loader does not look; the driver needs `WCNSS_qcom_cfg.ini` from the vendor partition; `modules.dep` uses absolute paths so the dlkm partitions must be mounted canonically |
| 9 | `AERA_USE_BUSYBOX_BINARY=1` | the plugin catalog is fetched with `busybox wget`, and the build otherwise deletes busybox from the ramdisk |
| 10 | cgroup2 at `/dev/cg2_bpf` + `msm_kgsl` | the browser jail creates its cgroups there and bind-mounts `/dev/kgsl-3d0`; without them: `Browsing unavailable` |

Space is tight: the recovery partition is exactly 100 MB, and the WPE WebKit
engine is 41 MB. To fit it the script disables the offline root providers and
enables UPX compression of `/sbin` and `/system/bin`, leaving ~2.4 MB of
headroom.

## What works

Boot, `/data` decryption, mounting, reboot from the menu, ADB, a UI matched to
the panel, 33 languages (Russian default, Chinese with MiSans), Wi-Fi scanning
and connecting, the plugin catalog, and the browser.

## What does not

Mobile data over SIM. Generic AERA ships only the client side
(`/dev/socket/aera-cellular`); the provider daemon comes from the device tree
and the existing implementation targets OnePlus hardware (`oplusreserve1`,
`/dev/mdmfeature`, `/proc/oplusVersion`). A nubia port is a separate project.

## Helper scripts

- `scripts/aera-wifi-diag.sh` — one-shot Wi-Fi diagnostics over ADB
- `scripts/catch-aera-crash.sh` — streams logs before reproducing a UI crash,
  because the crash takes adbd down with it
- `docs/edl-recovery.ru.txt` — EDL rescue notes (dump mode is not EDL)

## Credits

- Device tree — [delvoryx](https://github.com/delvoryx/android_device_nubia_cerro-recovery)
- Recovery — [AERA Recovery Project](https://github.com/AERA-Recovery), a fork of
  OrangeFox, itself based on TWRP
- Platform — AOSP, LineageOS

This repository contains no binaries, blobs or firmware: only the script and
documentation.
