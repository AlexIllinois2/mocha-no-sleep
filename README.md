# mocha-no-sleep

**English** | [简体中文](README.zh-CN.md)

A Magisk module for the Xiaomi Mi Pad 1 (`mocha`, NVIDIA Tegra 124 / TN8, 2 GB RAM, Android 10 / LineageOS 17.1) that stops the tablet from randomly rebooting and falling into NVIDIA Force Recovery (RCM / "protection mode").

Every conclusion below comes from on-device forensics (2026-10-12 / 10-13, extended 2026-10-31 → 11-05), not from speculation.

## TL;DR

- **Trigger**: any real suspend. `platform_pm_suspend` fails on `alarmtimer` with `-16` (`EBUSY`), so suspend aborts half-way and the framework retries in a storm, re-running Tegra LP suspend/resume over and over. The kernel heap gets corrupted and the watchdog armed at suspend entry turns a hang into a hardware reset → boot ROM → **Force Recovery**.
- **Fix (gate 1)**: hold a kernel wake lock named `mocha_no_sleep`. Android 10's `system_suspend` HAL blocks on `wakeup_count` while a lock is held, so the kernel is never asked to suspend.
- **Fix (gate 2, v4.0)**: harden idle low-power states — CPU max 1632 MHz, disable CPU deep idle `powered-down` (state1), EMC floor 528 MHz.
- **Cost**: no more deep sleep, higher standby drain. Disable the module to restore stock behavior.

## Symptom

Regardless of which ROM is flashed: frequent spontaneous reboots, after which the device sits in NVIDIA Force Recovery (Tegra RCM) and only a long power-button press brings it back.

Device under test:

| Item | Value |
|---|---|
| Model | Xiaomi Mi Pad 1 `lineage_mocha` (Tegra124 TN8 / ARMv7 / 2 GB RAM) |
| adb serial | `95B357F6` (USB descriptor reports `NVIDIA Corp. SHIELD Tablet` — Tegra reference platform) |
| System | `17.1-20261004-UNOFFICIAL-mocha`, Android 10, userdebug, test-keys, build host `eng.apple` |
| Kernel | `3.10.108_Dargons10_V5.10` (third-party, built 2026-10-04) |
| TWRP kernel | stock `3.10.24-g78f6102` (2014-07-15) — a different kernel from the ROM's |
| eMMC | Samsung `016GE2`, manfid 0x000011, date 03/2014, 14.6 GiB, HS200 200 MHz, tuning best tap 66 |

## Root cause chain

Four links, each with its own log signature.

1. **`alarmtimer` cannot hand over the RTC.** Every real suspend returns `-16`:
   ```
   dpm_run_callback(): platform_pm_suspend+0x0/0x5c returns -16
   PM: Device alarmtimer failed to suspend: error -16
   PM: Some devices failed to suspend
   ```
   `-16 = EBUSY` means a pending alarmtimer exists but no RTC device can host the alarm, so suspend aborts mid-flight.

2. **Abort storm.** The framework retries every second — 5–6 `suspend entry/exit` cycles inside 7 seconds — each re-running Tegra's LP suspend/resume sequence (`tegra_soctherm: resumed`, `tegra_dvfs: resumed`, restoring CPU frequency).

3. **Kernel memory gets trashed.** All crash points land 1.4–24 s *after wake*, as random kernel-mode corruption across CPU0/1/3 (7 crash logs):
   ```
   Internal error: Oops - undefined instruction: 0  PC is at sys_fork+0x24
   Unable to handle kernel paging request at 69207471  binder_get_thread+0x30
   swap_dup: Bad swap file entry 30000000 / BUG: Bad page map pte:400000300000002
   Watchdog detected hard LOCKUP on cpu 1 / cpu 2   (kernel/watchdog.c:270)
   ```

4. **A hang escalates into RCM.** The kernel arms watchdog recovery on suspend entry:
   ```
   PM: suspend entry
   tegra_wdt_reset_enable: WDT Recovery Enabled
   ```
   Plus `/vendor/etc/init/hw/init.tegra.rc` runs `watchdogd 10 20`. So a hang → hardware watchdog reset → boot ROM → **Force Recovery**.

## What the module does

| Gate | Path | Value |
|---|---|---|
| No-suspend wake lock | `/sys/power/wake_lock` | `mocha_no_sleep` |
| CPU max frequency | `cpu*/cpufreq/scaling_max_freq` | `1632000` |
| CPU deep idle | `cpu*/cpuidle/state1/disabled` | `1` (powered-down disabled) |
| EMC floor | `/sys/kernel/tegra_emc/emc_floor_rate` + `emc_floor_state` | `528000000` + `1` |

`post-fs-data.sh` applies the idle hardening before Zygote starts (on 11-03 the device panicked only 12.64 s after boot, inside `tegra_set_cpu_in_pd`, before `service.sh` could run); `service.sh` applies everything again at `late_start` as a fallback and starts `crashwatch.sh`.

Why the wake lock is the right gate: on Android 10 the only suspend requester is the `system_suspend` HAL, which reads `wakeup_count` first and blocks while any wake lock is held — it never writes `mem` to `/sys/power/state`. The framework uses the same mechanism (`PowerManager.SuspendLockout`, `PowerManagerService.Display`), so this is a native gate, not a hack.

## Install

1. Flash `mocha_no_sleep-v4.0.zip` in Magisk (or via TWRP — see caveats below).
2. Reboot.
3. Note: if an old standalone `freq_cap` module exists, the installer removes `/data/adb/modules/freq_cap` to avoid two modules writing the same sysfs nodes.

### Verify after flashing

```
rm -f /data/adb/service.d/01-crashwatch-boot.sh    # remove old temporary hook
adb reboot
adb shell cat /data/local/tmp/crashwatch/boot.csv  # last line: lock_held must be 1
```

`lock_held` is a 0/1 produced by grepping the unique name `mocha_no_sleep`, so only this module can set it — it is positional evidence that the module ran at boot. If it is 0, check `ls -laZ /data/adb/modules/mocha_no_sleep` and `magisk -d`.

v4.0 state check:

```
adb shell su -c 'for i in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$i/cpuidle/state1/disabled; done'
adb shell su -c 'cat /sys/kernel/tegra_emc/emc_floor_state /sys/kernel/tegra_emc/emc_floor_rate /sys/kernel/tegra_emc/emc_rate'
adb shell su -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq'
adb shell su -c 'cat /sys/power/wake_lock'
```

Expected: `1 1 1 1` / `1 528000000 528000000` / `1632000` / `mocha_no_sleep`.

After a few hours of real standby: `dmesg | grep -c "suspend entry"` must not increase and `grep -c "failed to suspend"` must be 0.

## Uninstall

Disable/remove the module in Magisk, or `rm -rf /data/adb/modules/mocha_no_sleep` and reboot. Deep sleep returns, along with the original bug.

## Crash / forensics when something goes wrong

Run this in the session that still boots:

```
sh /data/adb/modules/mocha_no_sleep/report.sh
```

Data locations:

| Path | Contents |
|---|---|
| `/data/local/tmp/crashwatch/prev_kmsg-<boot_id>.log` | Previous session's kernel log.* `/proc/last_kmsg` is not guaranteed to exist (confirmed 2026-10-13); a missing witness does not mean no crash — cross-check with the count and mtime of `dropbox/SYSTEM_LAST_KMSG*` |
| `.../evidence.log` | Per-session `last_kmsg=<bytes|absent>`, `dropbox_LAST_KMSG=<count>`, late `bootreason` backfill |
| `.../boot.csv` | `epoch,uptime_s,boot_id,kernel,bootreason,lock_held,cpu_max_khz`; `bootreason` commas are rewritten to `;` since v3.1 so columns stay aligned |
| `.../heartbeat.csv` | Every 20 s: frequencies, CPU/MEM temps, battery µV/µA, MemFree, cumulative `mmc_io_err_total` |
| `.../dmesg-err-<epoch>.log` | Full dmesg captured when eMMC I/O errors increase |
| `.../report.txt` | `report.sh` output (also attempted at `/sdcard/mocha_no_sleep-report.txt`) |
| `/data/system/dropbox/` | `SYSTEM_LAST_KMSG@*.txt.gz` (originals of the 7 crashes on 2026-10-10), `SYSTEM_RESTART`, `system_server_native_crash*` |

## Landmines

1. **Never `stop system_suspend`.** LOS 17.1's screen-off path calls `disableAutoSuspend()`; with the HAL gone it gets HIDL `DEAD_OBJECT` and `return_status::assertOk()` aborts `system_server` (`Abort message: 'Attempted to retrieve value from failed HIDL call: Status(EX_TRANSACTION_FAILED): 'DEAD_OBJECT''`).
2. **Do not use a manual suspend as a probe.** `echo mem > /sys/power/state` bypasses kernel wake locks (it still prints `suspend entry` even while a lock is held). Test lock effectiveness only via `wakeup_count` and `boot.csv`'s `lock_held`.
3. **`input keyevent 26` does not turn the screen off on this device** (`mWakefulness` stays `Awake`); only natural `screen_off_timeout` gives real standby readings.
4. **`update-binary`'s shebang must be `#!/sbin/sh`.** This device's TWRP (omni 5.1.1 ramdisk) has `/sbin/sh` but no `/system/bin/sh`; the wrong shebang yields `Updater process ended with ERROR: 255` with zero `ui_print` output. Verify with `execv` of the script path, not `sh script` (which hides the shebang problem). Switch back to `/system/bin/sh` only for official LOS recovery.
5. **This old TWRP parses but ignores `/cache/recovery/command`.** The log shows `Startup Commands: '--install_zip=...'` and then returns to the GUI; there is no unattended flashing.
6. **`update-binary` args are not positional by guesswork.** This TWRP passes `argv = <script> 1 2 <zip path>` — the zip is `$3`, not `$4`. Since v3.5 the script detects arguments **by shape** (existing `*.zip` ⇒ package; FIFO path or pure number ⇒ output channel) and logs raw argv.

## Evidence summary

- **DRAM is clean**: 256 MB random-pattern resident tmpfs, four cores loaded, MEM 50.5→61.0 °C, 25 verification rounds (~6.4 GB checked), 0 mismatches. memtester 4.6.0 (static ARMv7, 3 parallel × 300 MB, full pass): `FAILURE=0`; >1.1 GB cumulative, no mismatch.
- **eMMC is clean**: full 14.6 GB sequential read of 1878 × 8 MB blocks, 0 failures. The 10 boot-time `end_request: I/O error, dev mmcblk0` entries do not reproduce ⇒ transient bus/timeout events, not address-bound bad blocks. EXT_CSD 264=0x32, 265/266=0x00 (0 % wear), 269=0x19.
- **Battery/power not a suspect**: `bq27x00 soc 100 v 4.246V`, `health=Good`, `fcc 5077/5510`, `cycle_count=1`, `temp 27.0 °C`.
- **Not a single bad core**: crash contexts cover CPU0/1/3.
- **Not a frequency ceiling problem**: CPU at `2218500 kHz` is the Tegra124 rated max, not an overclock.
- **Idle-only trigger**: crashes almost exclusively during screen-off idle; 20-second heartbeats before crashes are normal (CPU 1632 MHz, CPU 26 °C, MEM 23 °C, battery 3.969 V, MemFree 133 MB).
- **Crash inside `powered-down` idle**: 11-03 kernel log shows a NULL dereference in `tegra_set_cpu_in_pd`, 12.64 s after boot, in `cpuidle state1`.
- **EMC drops below the DVFS table when idle**: with `emc_floor_state=0`, `emc_rate` oscillates at 12.75/20.4 MHz (table minimum is 204 MHz) and `vdd_core` sinks to 800 mV. After `floor=528 MHz` + `state=1`, EMC stays at 528 MHz and `vdd_core` bottoms at 880 mV.

Measured results:

- Baseline (10-10): 7 kernel crashes within 1.5 hours, each right after `PM: suspend exit` + `failed to suspend` storms.
- With the manual lock: 24 h uptime in a single session (`uptime=85562s`), 0 new `SYSTEM_LAST_KMSG`, I/O error count flat at 10.
- Module auto-applied at boot confirmed: `boot.csv` first line `lock_held=1`, only `mocha_no_sleep` in the lock table.
- Gate confirmed: screen timeout lowered to 15 s, framework reached `mWakefulness=Dozing` for 150 s while kernel `suspend entry` delta stayed 0.
- 10-31 12:25 → 11-03 20:10: single session of **3 d 8 h** (still crashed at the end, see the `powered-down` NULL deref).
- 11-03 20:11 → 11-05 19:50: **1 d 23 h 38 m** without reboot, no new `SYSTEM_LAST_KMSG`.

## Open questions / next steps

- **Root fix** = replace this kernel/ROM combination. Community ROMs ship the same Dargons kernel, which explains "any ROM behaves the same". Decisive experiment: flash a ROM without this kernel (stock 5.1 or a mature LOS 14.1) and check whether `suspend entry` no longer aborts.
- **`alarmtimer` has no runtime switch**: `/sys/module/alarmtimer/parameters/` does not exist (built-in; `alarmtimer.rtc=` is boot-cmdline only). Fixing it requires editing the boot image cmdline/DT and reflashing `LNX`.
- **Why `alarmtimer_get_rtcdev()` is empty**: palmas-rtc registers `rtc core: registered rtc.10 as rtc0` and `vdd-rtc: 950 mV` is normal. Either alarmtimer looks for a name other than `rtc0`, or palmas-rtc lacks alarm/IRQ_PIE capability. Add a print in `alarmtimer_suspend` in a patched kernel, or inspect the DT for `nvidia,tegra124-rtc`/`alarm` nodes.
- **The 10 transient eMMC I/O errors are unattributed**: still inseparable from HS200 200 MHz/tap 66 margin or pre-crash power disturbance. Measure `mmc_io_err_total` growth rate in both "locked, no sleep" and "real standby" modes (`heartbeat.csv` already records it).
- **A/B idle-profile experiment code exists but is disabled**: `hwdiag/crashwatch.sh` rotates A0-asis / A1-emc408 / A2-cpu1836 / A3-both per boot and records effective values into `boot.csv`. Knowing the trigger is suspend, leave it off; enable it only if "crashes even without sleep" appears.
- If it still crashes with the module installed: **confirm `lock_held=1` first**. If 1 and no `failed to suspend` in the crash log, links 1–2 are ruled out — look for another suspend requester (`logcat | grep -E "SystemSuspend|PowerManager"`) or another class of defect (`GPU/gk20a`, `dhd/sdio_reset_comm`, `dyn_fsync`), not hardware.

## Repository layout

```
mocha-no-sleep/
├── module.prop          # module metadata (v4.0)
├── customize.sh         # Magisk installer entry
├── post-fs-data.sh      # early idle hardening (before Zygote)
├── service.sh           # wake lock + hardening fallback + crashwatch
├── crashwatch.sh        # boot/session forensics daemon
├── report.sh            # one-shot report for troubleshooting
├── README.md            # English (this file)
├── README.zh-CN.md      # 简体中文
└── META-INF/com/google/android/{update-binary,updater-script}
```

## Disclaimer

This module intentionally prevents the CPU/memory subsystem from entering deep sleep. Standby power consumption will be higher. It is a workaround, not a root fix. Flashing is at your own risk; this device can always be recovered with a Tegra 9008 flash package.
