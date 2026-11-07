#!/system/bin/sh
# Mi Pad 1 稳定档位（v4.0）：尽早落盘，别等 late_start，否则开机早期 CPU 还会进
# powered-down 深空闲（11-03 实测：开机 12.64s 在 tegra_set_cpu_in_pd 空指针 panic）。
#
# 1) CPU 上限 1632MHz —— 本机 2218.5MHz 是标称上限，限频减小内存子系统压力
# 2) 禁用 cpu 深空闲 powered-down(state1) —— 该路径有 NULL deref（见 README §9）
# 3) EMC 下限 528MHz —— 空闲态原本会掉到 12.75/20.4MHz（DVFS 表外档），
#    同时把 vdd_core 压到 800mV；抬到 528MHz 后 vdd_core 最低 880mV
#
# 三个写入都是幂等的；service.sh 在 late_start 会再调用本脚本一次兜底。

MAXFREQ=1632000
EMCFLOOR=528000000

for i in 0 1 2 3; do
  [ -f "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_max_freq" ] && echo $MAXFREQ > "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_max_freq"
  [ -f "/sys/devices/system/cpu/cpu$i/cpuidle/state1/disabled" ] && echo 1 > "/sys/devices/system/cpu/cpu$i/cpuidle/state1/disabled"
done

[ -f /sys/kernel/tegra_emc/emc_floor_rate ] && echo $EMCFLOOR > /sys/kernel/tegra_emc/emc_floor_rate
[ -f /sys/kernel/tegra_emc/emc_floor_state ] && echo 1 > /sys/kernel/tegra_emc/emc_floor_state
