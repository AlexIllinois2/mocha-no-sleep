#!/system/bin/sh
# 一键取证报告：把"接着修所需"的读数汇成一份文本
# 用法（root shell）：sh /data/adb/modules/mocha_no_sleep/report.sh
# 只读，不改任何设置。dumpsys/getprop 一律带 timeout，框架死了也不会卡住。

MOD=/data/adb/modules/mocha_no_sleep
D=/data/local/tmp/crashwatch
OUT=${1:-$D/report.txt}
mkdir -p "$D" 2>/dev/null

p() { printf '%s\n' "$1"; }

{
  p "===== mocha_no_sleep 取证报告  $(date) ====="
  p "身份=$(id 2>/dev/null)"
  id -u 2>/dev/null | grep -qx 0 || p "  !! 非 root：下面 dmesg / prev_kmsg / dropbox 相关计数会是假 0，别当读数用"
  p "uptime=$(cut -d. -f1 /proc/uptime)s  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

  p ""
  p "----- 1. 身份 -----"
  p "model=$(getprop ro.product.model)  display=$(getprop ro.build.display.id)"
  p "kernel=$(uname -a 2>/dev/null)"
  p "bootreason=$(getprop ro.boot.bootreason)  bootmode=$(getprop ro.boot.bootmode)"

  p ""
  p "----- 2. 闸门是否生效（最关键）-----"
  p "wake_lock 表=[$(timeout 5 cat /sys/power/wake_lock 2>/dev/null || echo 需root)]"
  if timeout 5 cat /sys/power/wake_lock 2>/dev/null | grep -q mocha_no_sleep; then
    p "  lock_held=1  本模块这把锁在"
  else
    p "  lock_held=0  锁不在表里：模块没跑(见第 8 节)或这世尚未到 late_start"
  fi
  p "module 目录状态: $(ls $MOD 2>&1 | tr '\n' ' ')"
  [ -f "$MOD/disable" ] && p "  !! 模块被禁用(disable 标记存在)"
  [ -f "$MOD/remove" ] && p "  !! 模块待删除(remove 标记存在)"
  p "autosleep=$(timeout 5 cat /sys/power/autosleep 2>/dev/null)"
  p "system_suspend=$(getprop init.svc.system_suspend)   ← 应为 running；被停掉会崩 system_server"

  p ""
  p "----- 3. 挂起活动计数（风暴的量化读数）-----"
  p "suspend_entry=$(timeout 20 dmesg | grep -c 'suspend entry')"
  p "suspend_exit =$(timeout 20 dmesg | grep -c 'suspend exit')"
  p "中止(EBUSY)  =$(timeout 20 dmesg | grep -c 'failed to suspend')"
  p "Some devices =$(timeout 20 dmesg | grep -c 'Some devices failed to suspend')"
  p "WDT Recovery 武装次数=$(timeout 20 dmesg | grep -c 'WDT Recovery Enabled')"
  p "本世有无内核损坏征象:"
  timeout 20 dmesg | grep -E "Unable to handle|Internal error|BUG: Bad page|hard LOCKUP|Kernel panic|undefined instruction" | tail -8 | sed 's/^/  /'

  p ""
  p "----- 4. eMMC 与健康 -----"
  p "累计 I/O error=$(timeout 20 dmesg | grep -c 'I/O error')"
  timeout 20 dmesg | grep "I/O error" | tail -5 | sed 's/^/  /'
  p "mmc0 身份: $(timeout 5 cat /sys/block/mmcblk0/device/name 2>/dev/null) date=$(timeout 5 cat /sys/block/mmcblk0/device/date 2>/dev/null)"
  p "最近两世开账(boot.csv 末两行):"
  tail -2 "$D/boot.csv" 2>/dev/null | sed 's/^/  /'

  p ""
  p "----- 5. 每世开账(全表) -----"
  cat "$D/boot.csv" 2>/dev/null || echo "  boot.csv 不存在(守护没跑过)"

  p ""
  p "----- 6. 上一世是不是崩溃世（两处证人互证）-----"
  p "  注意：/proc/last_kmsg 不保证在场（干净 reboot 会丢 ramconsole）。"
  p "  证人缺席 ≠ 没崩溃，必须与 dropbox 的 SYSTEM_LAST_KMSG 份数与 mtime 对看。"
  cat "$D/evidence.log" 2>/dev/null | tail -8 | sed 's/^/  /'
  for f in "$D"/prev_kmsg-*.log; do
    [ -f "$f" ] || continue
    printf '  %s: entry=%s 中止=%s panic=%s 损坏=%s 末行: %s\n' \
      "${f##*/}" \
      "$(grep -c 'suspend entry' "$f" 2>/dev/null)" \
      "$(grep -c 'failed to suspend' "$f" 2>/dev/null)" \
      "$(grep -c 'Kernel panic' "$f" 2>/dev/null)" \
      "$(grep -cE 'Unable to handle|Internal error|BUG: Bad page|hard LOCKUP' "$f" 2>/dev/null)" \
      "$(tail -1 "$f" 2>/dev/null | cut -c1-90)"
  done
  p "  /proc/last_kmsg 现在: $(ls -la /proc/last_kmsg 2>/dev/null || echo 不存在)"

  p ""
  p "----- 7. 崩溃史清单(只列真崩溃记录，避开 strictmode 刷屏) -----"
  timeout 25 ls -la /data/system/dropbox/ 2>/dev/null | grep -E "SYSTEM_LAST_KMSG|SYSTEM_RESTART|_crash|TOMBSTONE|SYSTEM_BOOT" | tail -12 | sed 's/^/  /'
  p "  LAST_KMSG 份数=$(timeout 25 sh -c 'ls /data/system/dropbox/SYSTEM_LAST_KMSG* 2>/dev/null | wc -l' | tr -d ' ')  最新一份: $(timeout 25 sh -c 'ls -t /data/system/dropbox/SYSTEM_LAST_KMSG* 2>/dev/null | head -1' | xargs -r ls -la 2>/dev/null)"

  p ""
  p "----- 8. 若 lock_held=0 才需要看这几条 -----"
  p "magisk 版本=$(timeout 10 magisk -v 2>/dev/null | head -1)"
  p "late_start 是否已过: sys.boot_completed=$(getprop sys.boot_completed)  dev.bootcomplete=$(getprop dev.bootcomplete)"
  p "SELinux=$(timeout 5 getenforce 2>/dev/null)"
  timeout 25 dmesg | grep -iE "avc:.*denied.*(wake_lock|mocha|magisk)" | tail -5 | sed 's/^/  /'
  p "service.d 旧钩子是否还在(应删): $(ls /data/adb/service.d/ 2>/dev/null | tr '\n' ' ')"

  p ""
  p "----- 9. 温度/电压/频率快照 -----"
  p "CPU 顶频=$(timeout 5 cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null) 当前=$(timeout 5 cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)"
  p "EMC 地板=$(timeout 5 cat /sys/kernel/tegra_emc/emc_floor_rate 2>/dev/null)"
  p "volt_cap cpu_volt=$(timeout 5 cat /sys/kernel/tegra_volt_cap/cpu_volt 2>/dev/null)"
  for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/temp" ] && printf '  %s=%s\n' "$(timeout 5 cat $z/type 2>/dev/null)" "$(timeout 5 cat $z/temp 2>/dev/null)"
  done
  p "电池: $(timeout 5 cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)uV $(timeout 5 cat /sys/class/power_supply/battery/current_now 2>/dev/null)uA soc=$(timeout 5 cat /sys/class/power_supply/battery/capacity 2>/dev/null)% 状态=$(timeout 5 cat /sys/class/power_supply/battery/status 2>/dev/null)"
  p "心跳末 3 行:"
  tail -3 "$D/heartbeat.csv" 2>/dev/null | sed 's/^/  /'

  p ""
  p "===== 判读顺序 ====="
  p "1) 第 2 节 lock_held 与 system_suspend；2) 第 3 节 中止/EBUSY 是否为 0；"
  p "3) 第 6 节 上一世是不是崩溃世及其签名；4) 第 5 节 跨世对照 bootreason。"
  p "详细说明与地雷清单见 $MOD/README.md"
} | tee "$OUT" 2>/dev/null

# 尽力另存一份到 /sdcard 方便 adb pull；失败不影响报告本身，也不许带走退出码
if cp "$OUT" /sdcard/mocha_no_sleep-report.txt 2>/dev/null; then
  printf '已另存: /sdcard/mocha_no_sleep-report.txt\n'
else
  printf '/sdcard 写不进去(正常)，报告只在这两处: %s 与标准输出\n' "$OUT"
fi
exit 0
