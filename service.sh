#!/system/bin/sh
# Mi Pad 1 (mocha / Tegra124) 稳定性修复（v4.0）
#
# 闸门 1：持一把内核部分唤醒锁，内核不再被请求挂起（根因链见 README）。
# 为什么有效：Android 10 的 system_suspend HAL 先读 /sys/power/wake_lock 语义下的
# wakeup_count（有人持锁就一直阻塞），拿不到值就不会往 /sys/power/state 写 "mem"。
#
# 禁忌：绝不可 stop system_suspend。LOS 17.1 熄屏路径的 disableAutoSuspend() 拿到
# HIDL DEAD_OBJECT 会直接 abort 掉 system_server（2026-10-12 现场验证）。
# 另注：手工 echo mem > /sys/power/state 会绕过本锁，不能用它来检验锁是否生效。

echo mocha_no_sleep > /sys/power/wake_lock 2>/dev/null

MODDIR=${MODDIR:-/data/adb/modules/mocha_no_sleep}

# 闸门 2：低功耗档位加固。post-fs-data.sh 在开机早期已落过一次，这里再兜一次
# （两处都幂等；11-03 那次开机 12.6s 内的崩溃说明只靠 late_start 太晚）。
if [ -f "$MODDIR/post-fs-data.sh" ]; then
  sh "$MODDIR/post-fs-data.sh"
fi

# 顺带拉起取证守护（同一模块内携带；缺文件就什么都不做）
if [ -f "$MODDIR/crashwatch.sh" ]; then
  nohup sh "$MODDIR/crashwatch.sh" >/dev/null 2>&1 &
fi
