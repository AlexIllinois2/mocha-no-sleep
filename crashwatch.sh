#!/system/bin/sh
# 崩溃取证守护 v3
# 两处证人互证：/proc/last_kmsg（不保证在场——干净重启会丢 ramconsole）与
# dropbox 的 SYSTEM_LAST_KMSG*（框架自己按世归档）。证人缺席要显式记 absent，不许被当"没崩"。
D=/data/local/tmp/crashwatch
mkdir -p "$D" 2>/dev/null
BOOT="$D/boot.csv"
HB="$D/heartbeat.csv"
EV="$D/evidence.log"
[ -f "$BOOT" ] || echo "epoch,uptime_s,boot_id,kernel,bootreason,lock_held,cpu_max_khz" > "$BOOT"
[ -f "$HB" ] || echo "epoch,uptime_s,cpu0_khz,cpu_therm_mC,mem_therm_mC,batt_uV,batt_uA,free_kb,mmc_io_err_total" > "$HB"

BID=$(cut -d- -f1-3 /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BID" ] || BID=unknown

# --- 证人一：/proc/last_kmsg（属上一世）---
# 幂等闸：同一世只开一次账，守护被手工重启不许重复记行（"世"的分母要能信）
if [ ! -e "$D/.bootdone-$BID" ]; then
KM=absent
if [ -s /proc/last_kmsg ]; then
  KM=$(wc -c < /proc/last_kmsg 2>/dev/null)
  cp /proc/last_kmsg "$D/prev_kmsg-$BID.log" 2>/dev/null
  touch "$D/.kmsg_done-$BID" 2>/dev/null
fi
# --- 证人二：dropbox 按世归档的内核崩溃记录 ---
DB=$(ls /data/system/dropbox/SYSTEM_LAST_KMSG* 2>/dev/null | wc -l)
DB=$(echo "$DB" | tr -d ' ')
[ -n "$DB" ] || DB=0
{
  if grep -q "boot_id=$BID" "$EV" 2>/dev/null; then
    printf '%s  开机记账(同世重记，非新世) boot_id=%s\n' "$(date)" "$BID"
  else
    printf '%s  开机记账 boot_id=%s\n' "$(date)" "$BID"
  fi
  printf '  last_kmsg=%s 字节(缺席记 absent)  dropbox_LAST_KMSG=%s 份\n' "$KM" "$DB"
  printf '  锁=[%s]\n' "$(cat /sys/power/wake_lock 2>/dev/null)"
} >> "$EV" 2>/dev/null

# --- 本世开账（bootreason 可能还没被 bootstat 写入，稍后在循环里补一次）---
# bootreason 的值本身带逗号(如 "reboot,adb")，直接写进 CSV 会冲歪列 ⇒ 逗号一律换成 ";"
BR=$(getprop ro.boot.bootreason 2>/dev/null | tr "," ";")
LOCK=$(grep -c mocha_no_sleep /sys/power/wake_lock 2>/dev/null)
echo "$(date +%s),$(cut -d. -f1 /proc/uptime),$BID,$(uname -r),$BR,${LOCK:-0},$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)" >> "$BOOT"
touch "$D/.bootdone-$BID" 2>/dev/null
sync
fi

REASON_DONE=0
[ -n "$(getprop ro.boot.bootreason)" ] && REASON_DONE=1
PREV_ERR=0
N=0
while true; do
  # bootreason 迟到补录（不许让空值留在账上被误读成"原因未知"）
  R=$(getprop ro.boot.bootreason 2>/dev/null | tr "," ";")
  if [ "$REASON_DONE" = 0 ] && [ -n "$R" ]; then
    printf '%s  补录 bootreason=%s (boot_id=%s)\n' "$(date)" "$R" "$BID" >> "$EV" 2>/dev/null
    REASON_DONE=1
  fi
  # last_kmsg 迟到补档
  if [ ! -e "$D/.kmsg_done-$BID" ] && [ -s /proc/last_kmsg ]; then
    cp /proc/last_kmsg "$D/prev_kmsg-$BID.log" 2>/dev/null
    touch "$D/.kmsg_done-$BID" 2>/dev/null
    printf '%s  迟到补档 prev_kmsg-%s.log\n' "$(date)" "$BID" >> "$EV" 2>/dev/null
  fi

  UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
  CT=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  MT=$(cat /sys/class/thermal/thermal_zone2/temp 2>/dev/null)
  BV=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  BI=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  FR=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null)
  ERR=$(dmesg 2>/dev/null | grep -c "I/O error")
  echo "$(date +%s),$UP,$F0,$CT,$MT,$BV,$BI,$FR,$ERR" >> "$HB"
  if [ "$ERR" -gt "$PREV_ERR" ] 2>/dev/null; then
    dmesg > "$D/dmesg-err-$BID-$N.log" 2>/dev/null
    PREV_ERR=$ERR
  fi
  N=$((N + 1))
  if [ $((N % 5)) -eq 0 ]; then
    sync
  fi
  if [ "$(wc -c < "$HB" 2>/dev/null)" -gt 2000000 ] 2>/dev/null; then
    tail -4000 "$HB" > "$HB.rot" 2>/dev/null
    mv "$HB.rot" "$HB" 2>/dev/null
  fi
  sleep 20
done
