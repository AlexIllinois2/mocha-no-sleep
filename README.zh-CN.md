# mocha-no-sleep

[English](README.md) | **简体中文**

小米平板1（`mocha`，NVIDIA Tegra 124 / TN8，2GB RAM，Android 10 / LineageOS 17.1）的 Magisk 模块：阻止设备随机重启并掉进 NVIDIA 保护模式（Force Recovery / RCM）。

包内一切结论都来自设备当场取证（2026-10-12 / 10-13；v4.0 追加 2026-10-31～11-05），不是推断。以后出 bug，**先在恢复不了的那一世跑 `sh /data/adb/modules/mocha_no_sleep/report.sh`**，它会把这些读数汇成一份报告；再按本文末尾"未解与下一步"接着查。

## 一句话概括

- **触发条件**：任何一次真睡。`platform_pm_suspend` 对 `alarmtimer` 返回 `-16`（`EBUSY`），挂起半路中止，框架每秒重试形成风暴，反复重跑 Tegra LP 挂起/唤醒序列，若干轮后内核内存被踩烂；而进睡时武装的 WDT recovery 会把卡死升级成硬件复位 → boot ROM → **Force Recovery**。
- **闸门 1**：持一把专名内核唤醒锁 `mocha_no_sleep`。Android 10 的 `system_suspend` HAL 先读 `wakeup_count`，有人持锁就一直阻塞，内核再也不会被请求挂起。
- **闸门 2（v4.0）**：低功耗档位加固——CPU 上限 1632MHz、禁用 CPU 深空闲 `powered-down`(state1)、EMC 下限 528MHz。
- **代价**：不再有深睡，待机耗电上升。停用本模块即恢复原状。

## 0. 对象身份

| 项 | 值 |
|---|---|
| 机型 | 小米平板1 `lineage_mocha`（Tegra124 TN8 / ARMv7 / 2GB RAM） |
| adb 序列 | `95B357F6`（USB 描述符报 `NVIDIA Corp. SHIELD Tablet`，Tegra 公版平台所致） |
| 系统 | `17.1-20261004-UNOFFICIAL-mocha`，Android 10，userdebug，test-keys，构建主机 `eng.apple` |
| 内核 | `3.10.108_Dargons10_V5.10`（第三方，编于 2026-10-04；内核源码路径串在崩溃日志里：`/media/apple/.../los17.1/kernel/xiaomi/mocha-21.8`） |
| TWRP | recovery 内核是原厂 `3.10.24-g78f6102`（2014-07-15）＝与系统内核不同一枚 |
| eMMC | 三星 `016GE2`，manfid 0x000011，date 03/2014，14.6 GiB，HS200 200MHz，tuning best tap 66 |
| 分区 | by-name：APP(system) CAC(cache) UDA(data) LNX/LN1(kernel) …；p26=APP p27=CAC p28=UDA；p27 start=7813120 p28 start=8790016 |

**症状**：不论刷哪套系统，频繁自动重启，然后落进 "NVIDIA 保护模式"（Tegra Force Recovery / RCM），必须长按电源强制断电才能再开机。

## 1. 根因链（四环，每环都有日志签名）

1. **alarmtimer 交不出 RTC** — 每次真睡，`platform_pm_suspend` 对 alarmtimer 返回 `-16`：
   ```
   dpm_run_callback(): platform_pm_suspend+0x0/0x5c returns -16
   PM: Device alarmtimer failed to suspend: error -16
   PM: Some devices failed to suspend
   ```
   `-16=EBUSY`＝内核有待处理 alarmtimer 但拿不到 RTC 设备去托管闹钟 ⇒ 挂起在**半路中止**。
2. **中止风暴** — 框架每秒重试，7 秒内 `suspend entry/exit` 反复 5–6 次；每一轮都重跑 Tegra 的 LP 挂起/唤醒序列（`tegra_soctherm: resumed` / `tegra_dvfs: resumed` / `Tegra cpufreq resume: restoring frequency to 51000 kHz`）。
3. **内核内存被踩烂** — 崩溃点全部落在"醒来后 1.4–24 秒"，形态是随机内核态损坏（7 份崩溃日志，分布在 CPU0/1/3，非单核故障）：
   ```
   Internal error: Oops - undefined instruction: 0  PC is at sys_fork+0x24      ← 内核代码段读出非法指令
   Unable to handle kernel paging request at 69207471  binder_get_thread+0x30   ← 指针位置是 ASCII 文本字节
   swap_dup: Bad swap file entry 30000000 / BUG: Bad page map pte:400000300000002
   Unable to handle kernel NULL pointer dereference  account_entity_enqueue+0x5c / process_vm_rw+0x6a4
   Watchdog detected hard LOCKUP on cpu 1 / cpu 2   (kernel/watchdog.c:270)
   ```
4. **卡死被升级成 RCM** — 这是"保护模式"的直接来源。内核在**进睡时武装看门狗恢复**：
   ```
   PM: suspend entry
   tegra_wdt_reset_enable: WDT Recovery Enabled      ← 一进睡就武装
   ```
   另有一路：`/vendor/etc/init/hw/init.tegra.rc:12` 的 `service watchdogd /system/bin/watchdogd 10 20`（第 42 行 `start watchdogd`）。于是卡死＝硬件看门狗复位＝boot ROM 判定启动异常＝**Force Recovery(RCM)**，软件无法自恢复，只能长按断电。

## 2. 已排除（都是当场实测，不是推断）

- **DRAM 清白**：256MB 随机图案常驻 tmpfs（纯内存），四核满载、MEM 温度 50.5→61.0°C，25 轮校验（≈6.4GB 校验流量）**0 次失配**。
- **eMMC 清白**：整片 14.6GB 顺序读完 1878 个 8MB 块 **0 失败**。开机时那 10 处 `end_request: I/O error, dev mmcblk0, sector 7818240…9265144`（跨 CAC 与 UDA 之间及数据区分段）**不复现** ⇒ 瞬时总线/超时事件，不是绑定地址的坏块。EXT_CSD 264=0x32 且 265/266=0x00（寿命估算 0%）、269=0x19。
- **电池/供电不像嫌疑**：`bq27x00 soc 100 v 4.246V`，`health=Good`，`fcc 5077/5510`，`cycle_count=1`，`temp 27.0°C`。
- **不是单一坏核**：崩溃上下文覆盖 CPU0/1/3。
- **不是频率顶格**：CPU 全程 `2218500 kHz` 属 Tegra124 标称上限，非超频；`gpu_cap/floor 852MHz`，`core_cap_level=1150`，`tegra_volt_cap/cpu_volt=0`（未外部降压）。EMC 那一项当时读的是 `emc_floor_rate=924MHz`，但 `emc_floor_state=0`（并**未生效**），空闲实际掉到 12.75/20.4MHz —— v4.0 已改正，见 §9.3。

## 3. 本包的闸门为什么是这一条

Android 10 上内核挂起只有一个请求方：`system_suspend` HAL（`/system/bin/hw/android.system.suspend@1.0-service`）。它**先读 `wakeup_count`**（内核语义：有人持 wakelock 就一直阻塞），拿不到值就不会往 `/sys/power/state` 写 `mem`。

⇒ 本模块 `service.sh` 开机把专名 `mocha_no_sleep` 写进 `/sys/power/wake_lock`，HAL 阻塞在 `wakeup_count`，内核再也不被请求挂起，坏支路一次都不走。框架自己也用同一接口挡挂起（锁表里能看到 `PowerManager.SuspendLockout`、`PowerManagerService.Display`），所以这是本机原生闸门，不是外挂 hack。

**代价**：不再有深睡，待机耗电上升。要恢复：Magisk 里禁用/删除本模块，或 `rm -rf /data/adb/modules/mocha_no_sleep` 后重启。

## 4. 两条地雷（都付过学费，别再踩）

1. **绝不可 `stop system_suspend`**。LOS 17.1 熄屏路径会调 `disableAutoSuspend()`，HAL 不在即拿到 HIDL `DEAD_OBJECT`，`return_status::assertOk()` 直接 abort：
   ```
   Abort message: 'Attempted to retrieve value from failed HIDL call: Status(EX_TRANSACTION_FAILED): 'DEAD_OBJECT''
   #04 android::disableAutoSuspend() (libandroid_servers.so)  线程 PhotonicModulat
   → system_server SIGABRT；systemui/launcher 连带 DeadSystemException
   ```
   （现场记录：`/data/system/dropbox/system_server_native_crash@1791812951508.txt.gz`）
2. **别用手工挂起当探针**：`echo mem > /sys/power/state` **会绕过**内核 wakelock（实测持锁状态下照样打出 `suspend entry`，且 34ms 就退出）。判"锁有没有生效"只能看 `wakeup_count` 那条路和 `boot.csv` 的 `lock_held`。
3. 附：**`input keyevent 26` 在这台机上不会熄屏**（`mWakefulness` 仍 `Awake`），所以任何"关屏静置"读数若靠它注入都作废；靠 `screen_off_timeout` 自然熄屏才算真待机。
4. **`update-binary` 的 shebang 必须写 `#!/sbin/sh`**。本机 TWRP 是 omni 5.1.1 ramdisk，`PATH=/sbin:/system/bin` 但**没有 `/system/bin/sh`**（只有 `/sbin/sh`）。写成 `/system/bin/sh` 时 TWRP 表现为 `Updater process ended with ERROR: 255`、0 秒退出、一条 `ui_print` 都不落日志——因为内核解不了 shebang。
   检验方法要忠实于 TWRP 的调用：**直接 `execv` 脚本路径**（`/tmp/mz/META-INF/.../update-binary 1 1 <fifo> <zip>`），**不能**用 `sh 脚本` 跑——那样绕过 shebang，会把好结果误读成"包没问题"（我就这样误判过一次）。同法负控：`rc=127 /sbin/sh: ...not found`。
   若换官方 LOS recovery（那边只有 `/system/bin/sh`），把这行换回去即可。Magisk App 装机走 `customize.sh`（在系统里由 Magisk 自带安装器执行），不受本行影响。
5. 附：这枚老 TWRP **认但不做** `/cache/recovery/command`——日志会出现 `Startup Commands: '--install_zip=...'` 然后直接回 `main2` 图形页，不会无人值守刷包。别把"命令文件被吃掉"当成"已执行"。
6. **`update-binary` 的参数不能按位置取**。本机 TWRP 传的是 `argv = <脚本> 1 2 <包路径>`，即**包在 `$3`**；而常见写法（含我 v3.2/v3.3/v3.4）取 `$4` 当包、`$3` 当输出通道，于是包取到空、脚本自己 `exit 1`，TWRP 表现为：
   ```
   错误: 没拿到安装包路径
   /tmp/updater: line 35: can't create /proc/self/fd//sdcard/Download/mocha_no_sleep-v3.4.zip: nonexistent directory
   Updater process ended with ERROR: 1
   ```
   那行 `/proc/self/fd//sdcard/...` 就是铁证：`$3` 才是包路径。v3.5 起**按形状识别**（存在的 `*.zip` ⇒ 包；FIFO 路径或纯数字 ⇒ 输出通道），并把 argv 原样打进日志，形状再变也一眼可判。
   教训：自造调用形状验通 ≠ 按被测方的真实调用验通。

## 5. 验证口径（刷完必做一次）

```
rm -f /data/adb/service.d/01-crashwatch-boot.sh    # 旧临时钩子要删，否则两个守护抢同一批日志
adb reboot
adb shell cat /data/local/tmp/crashwatch/boot.csv  # 最后一行 lock_held 必须是 1
```

`lock_held` 是 grep 专名 `mocha_no_sleep` 得出的 0/1，只有本模块会写它 ⇒ 这是"开机时模块真生效"的位置证据。若为 0：模块没被 Magisk 跑到，查 `ls -laZ /data/adb/modules/mocha_no_sleep` 与 `magisk -d`。
真待机几小时后应满足：`dmesg | grep -c "suspend entry"` 不涨、`grep -c "failed to suspend"` 为 0。

v4.0 档位自检：

```
adb shell su -c 'for i in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$i/cpuidle/state1/disabled; done'
adb shell su -c 'cat /sys/kernel/tegra_emc/emc_floor_state /sys/kernel/tegra_emc/emc_floor_rate /sys/kernel/tegra_emc/emc_rate'
adb shell su -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq'
adb shell su -c 'cat /sys/power/wake_lock'
```

期望：`1 1 1 1` / `1 528000000 528000000` / `1632000` / `mocha_no_sleep`。
注意：开机后 `state1/usage` 可能已非 0（`post-fs-data.sh` 之前进去的那几次），只要 `disabled=1` 就不会再进。

## 6. 读数位置

| 位置 | 内容 |
|---|---|
| `/data/local/tmp/crashwatch/prev_kmsg-<boot_id>.log` | 每次开机归档的**上一世**内核日志。**两处证人互证**：`/proc/last_kmsg` 不保证在场（2026-10-13 实测：`adb reboot` 后的新一世里它压根不存在，而 10-12 从 recovery 回去的那世有 76192 字节）⇒ **证人缺席不等于没崩**，要与 `dropbox/SYSTEM_LAST_KMSG*` 的份数和 mtime 对看；`evidence.log` 已把"当世证人是否在场"记进账里 |
| `/data/local/tmp/crashwatch/evidence.log` | 每世记录 `last_kmsg=<字节数\|absent>` 与 `dropbox_LAST_KMSG=<份数>`，以及迟到的 `bootreason` 补录 |
| `/data/local/tmp/crashwatch/boot.csv` | v3 起为 `epoch,uptime_s,boot_id,kernel,bootreason,lock_held,cpu_max_khz`；`lock_held`＝专名 grep 的 0/1；**`bootreason` 原值带逗号（`reboot,adb`），直接入 CSV 会冲歪列，v3.1 起一律存成 `;`**；`cpu_max_khz` 是 t≈12s 的现读值，可能被温控压低（10-13 读到 2078250），别当配置改动 |
| `/data/local/tmp/crashwatch/heartbeat.csv` | 20 秒一行：频率、CPU/MEM 温度、电池 uV/uA、MemFree、`mmc_io_err_total` 累计 |
| `/data/local/tmp/crashwatch/prev_kmsg-<epoch>.log` | 每次开机归档的**上一世**内核日志（崩溃现场就在这里；`/proc/last_kmsg` 只有一个槽，不归档就会被覆盖） |
| `/data/local/tmp/crashwatch/dmesg-err-<epoch>.log` | eMMC I/O 错误一增长就抓的整份 dmesg |
| `/data/local/tmp/crashwatch/report.txt` | `report.sh` 输出（同时尝试写 `/sdcard/mocha_no_sleep-report.txt`） |
| `/data/system/dropbox/` | `SYSTEM_LAST_KMSG@*.txt.gz`（2026-10-10 那 7 次崩溃的原件在此）、`SYSTEM_RESTART`、`system_server_native_crash*` |

## 7. 未解与下一步线索

- **根治（不留"永不深睡"代价）＝换掉这枚内核/这套包**。社区包多自带同一枚 Dargons 内核，这就是"刷什么系统都一样"的解释。可判定实验：刷**不含该内核**的包（原厂 5.1 或 LOS 14.1 一类成熟包），看 `suspend entry` 是否不再中止。
- **`alarmtimer` 没有运行时开关**：`/sys/module/alarmtimer/parameters/` 不存在（内建，`alarmtimer.rtc=` 只在启动命令行生效），所以不能靠 `echo` 把 RTC 名字补上去。若要试，就得改 boot 镜像的 cmdline/DT 后重刷 `LNX`。
- **为何 `alarmtimer_get_rtcdev()` 为空**值得再查：palmas-rtc 明明注册了 `rtc core: registered rtc.10 as rtc0`，且 `vdd-rtc: 950 mV` 正常。两种可能：内核 `alarmtimer` 找的不是 `rtc0` 这个名字；或 palmas-rtc 未提供 alarm/IRQ_PIE 能力。判定办法：改好的内核里给 `alarmtimer_suspend` 加一行打印，或看 DT 是否有 `nvidia,tegra124-rtc`/`alarm` 节点。
- **eMMC 那 10 处瞬时 I/O error 未归因**：与 HS200 200MHz/tap 66 的信号裕度、或与崩溃前的电源扰动都还分不开。若要判，用同一把尺在"持锁不睡"与"真待机"两档下各数一次 `mmc_io_err_total` 增速（`heartbeat.csv` 已带这列）。
- **档位实验代码已写好未跑**：`hwdiag/crashwatch.sh` 里 A0-asis / A1-emc408 / A2-cpu1836 / A3-both 每次开机自动轮转，每世生效值都现读回写进 `boot.csv`。原用来判"是不是频率/电压裕度"，现在知道触发条件是休眠，所以**先别开**；若将来出现"不睡也崩"，再启用它做单因子对照。
- 若装了本模块后仍崩：**先确认 `lock_held=1`**。若 1 且崩溃日志里再无 `failed to suspend`，则根因链第 1–2 环已被排除，剩下要查的是别的请求方（`logcat | grep -E "SystemSuspend|PowerManager"`）或另一类缺陷（`GPU/gk20a`、`dhd/sdio_reset_comm`、`dyn_fsync` 通知链），别急着怀疑硬件。

## 8. 实机验证记录（2026-10-13，序列 `95B357F6`）

- 基线（10-10）：1.5 小时内 7 次内核崩溃，全部紧跟 `PM: suspend exit` + `failed to suspend` 风暴。
- 手工加锁后：**24h 不断**（`uptime=85562s` 同一世）、0 次新 `SYSTEM_LAST_KMSG`、`I/O error` 停在 10 没涨。
- **模块开机自生效已证**：删掉手工钩子、释放手工锁、`adb reboot` → 新世 `boot.csv` 第一行 `lock_held=1`，锁表里只剩专名 `mocha_no_sleep`。
- **闸门已证**：把熄屏超时压到 15s 让框架自己走睡——`mWakefulness=Dozing` 连续 150 秒，内核 `suspend entry` **增量 0**、`failed to suspend` 0。即"框架想睡，但请求到不了内核"。
- 安装器代码路径实机跑通：设备端建真 FIFO、按 recovery 的四参数调用 → `rc=0`，管道流里 `ui_print`/`progress` 语法正确，6 个文件落位且模式位对（`/dev/tmp` 在已启动系统上也可建，故模拟与恢复环境同路）。
- **TWRP 那一格已闭合（v3.3）**：第一次手点刷入报 `Updater process ended with ERROR: 255`。在 recovery 里用 `execv` 忠实复现：旧 shebang `rc=127`（`/sbin/sh: ...not found`），新 shebang `#!/sbin/sh` `rc=0` 且装成 6 个文件；回系统后新世 `lock_held=1`、`suspend entry` 0。剩下只是可选的一步——在 TWRP 图形界面里再手点一次，验 TWRP 自身的 fork/exec 管线（失败机制已在同域同法验过）。
- 附带发现：**`/proc/last_kmsg` 不保证在场**（这一世 `adb reboot` 后它不存在），所以判"上一世是否崩"要 `last_kmsg` 与 dropbox `SYSTEM_LAST_KMSG*` 两处互证，v3 起 `evidence.log` 会记下证人是否缺席。

## 9. v4.0：稳定档位加固（2026-10-31 ～ 11-05 现场）

### 9.1 触发条件收窄到"空闲"

用户侧观察：**基本只在息屏闲置时崩，正常使用时几乎不崩**。取证侧与之吻合：崩溃前 20 秒心跳（`heartbeat.csv`）正常（CPU 1632MHz、CPU 温 26°C、MEM 温 23°C、电池 3.969V、MemFree 133MB），没有任何温度/电压前兆；崩溃进程各异（surfaceflinger / statsd.writer / app_process / logd / sh …），不是单一 app。

### 9.2 决定性证据：崩在 powered-down 空闲路径里

11-03 那一世的内核日志（`prev_kmsg-6329c451-bef1-4fa8.log`，开机 **12.64s** 就 panic）：

```
Unable to handle kernel NULL pointer dereference at virtual address 00000000
Internal error: Oops: 205 [#1] PREEMPT SMP ARM
CPU: 2 PID: 0 Comm: swapper/2  Tainted: G  W  3.10.108_Dargons10_V5.10
PC is at tegra_set_cpu_in_pd+0x38/0xb8
 tegra11x_idle_power_down+0x38/0x520 → tegra_idle_enter_pd+0xe4/0x314
 → cpuidle_enter_state+0x48/0xec → cpuidle_idle_call → arch_cpu_idle
 → cpu_startup_entry
```

- 这是 **cpuidle state1（powered-down，电源门控）** 的路径，空指针解引用 ⇒ 这条路径本身有缺陷，不需要"睡下去又醒来"也能踩到。
- 那一晚是连环：上一世（10-31 12:25 起、跑了 3 天 8 小时）崩溃 → 重启 → 新一世 12.6 秒再崩 → 再重启。上一世的 `last_kmsg` 因此没来得及归档就被覆盖，只剩 `evidence.log` 里 `last_kmsg=183446` 这一笔。
- 12.6 秒这个时间点很关键：Magisk 的 `service.sh` 在 late_start 才跑，**来不及**在 CPU 第一次进 powered-down 之前把 `disabled` 写进去。v4.0 因此新增 `post-fs-data.sh`，在 Zygote 之前先把档位落盘。

### 9.3 空闲时另一个被忽略的低点：EMC 掉到 DVFS 表外

息屏无负载实测：

```
emc_floor_state=0 时：emc_rate = 12.75MHz / 20.4MHz 之间跳（DVFS 表最低只到 204MHz）
                     此时 vdd_core = 800mV
写入 floor=528000000 + state=1 后：emc_rate 稳定 528MHz，vdd_core 最低 880mV
```

（另：`vdd_cpu` 表 204～714MHz 全是 800mV，所以"CPU 低电压"这一档靠限频改不动；`tegra_volt_cap/cpu_volt=0` 也没有外部降压入口。）

### 9.4 内存不是嫌疑（追加证据）

memtester 4.6.0 用 Android NDK 编译成静态 ARMv7 二进制，3 个并发各 300MB、跑满全套 1 轮：三个实例都是 `Done`、`FAILURE=0`；连同前面 200MB 单实例，累计覆盖 >1.1GB 无失配。⇒ 有负载时 DRAM 路径是干净的，问题集中在空闲档位。

### 9.5 v4.0 的档位（`post-fs-data.sh` 落盘，`service.sh` 兜底）

| 项 | 路径 | 值 |
|---|---|---|
| 持锁不挂起 | `/sys/power/wake_lock` | `mocha_no_sleep` |
| CPU 上限 | `cpu*/cpufreq/scaling_max_freq` | `1632000` |
| CPU 深空闲 | `cpu*/cpuidle/state1/disabled` | `1`（powered-down 禁用） |
| EMC 下限 | `/sys/kernel/tegra_emc/emc_floor_rate` + `emc_floor_state` | `528000000` + `1` |

### 9.6 结果

- 10-31 12:25 → 11-03 20:10 单世 **3 天 8 小时**（收尾仍崩，见 9.2）。
- 11-03 20:11 起至 11-05 19:50 **连续 1 天 23 小时 38 分**无重启、无新增 `SYSTEM_LAST_KMSG`、`/proc/last_kmsg` 一直是当世内容。

### 9.7 刷完自检

```
adb shell su -c 'for i in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$i/cpuidle/state1/disabled; done'
adb shell su -c 'cat /sys/kernel/tegra_emc/emc_floor_state /sys/kernel/tegra_emc/emc_floor_rate /sys/kernel/tegra_emc/emc_rate'
adb shell su -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq'
adb shell su -c 'cat /sys/power/wake_lock'
```

期望：`1 1 1 1` / `1 528000000 528000000` / `1632000` / `mocha_no_sleep`。
注意：开机后 `state1/usage` 可能已非 0（`post-fs-data.sh` 之前进去的那几次），只要 `disabled=1` 就不会再进。

### 9.8 旧 `freq_cap` 模块

v4.0 已包含独立 `freq_cap` 模块的全部设置；安装器（`update-binary` / `customize.sh`）会删除 `/data/adb/modules/freq_cap`（若存在），避免两个模块写同一批 sysfs，出现"关了主模块却还在限频"的误判。

## 10. 仓库结构

```
mocha-no-sleep/
├── module.prop          # 模块元数据（v4.0）
├── customize.sh         # Magisk 安装入口
├── post-fs-data.sh      # 早期低功耗档位加固（Zygote 之前）
├── service.sh           # 唤醒锁 + 档位兜底 + 拉起 crashwatch
├── crashwatch.sh        # 开机/每世取证守护
├── report.sh            # 一键出报告的排查脚本
├── README.md            # English
├── README.zh-CN.md      # 简体中文（本文件）
└── META-INF/com/google/android/{update-binary,updater-script}
```

## 免责声明

本模块有意阻止 CPU/内存子系统进入深睡，因此待机功耗会上升；它是权宜修复而非根治。刷机风险自负——本机随时可用 Tegra 9008 刷机包救回。
