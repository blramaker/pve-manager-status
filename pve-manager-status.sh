#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2026-09-16 (SATA fix + 硬件监控日志采集/界面日志查看)

echo -e "\n🛠️ \033[1;33;41mPVE-Manager-Status v0.6.3-satafix-log by MiKing233\033[0m"

echo -e "为你的 ProxmoxVE 节点概要页面添加扩展的硬件监控信息"
echo -e "OpenSource on GitHub (https://github.com/MiKing233/PVE-Manager-Status)\n"

# 先决条件执行判断
# 执行用户判断, 必须为 root 用户执行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "⛔ 请以 root 身份运行此脚本!"
    echo && exit 1
fi

# 执行环境判断, 必须为 Debian 发行版且存在 ProxmoxVE 环境
if ! command -v pveversion &> /dev/null; then
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "⛔ 检测到当前系统非 Debian 发行版, 终止执行!"
            echo && exit 1
        fi
    fi
    echo -e "⛔ 未检测到 ProxmoxVE 环境, 终止执行!"
    echo && exit 1
fi

# 脚本执行前确认
read -p "确认执行吗? [y/N]:" para
[[ "$para" =~ ^[Yy]$ ]] || { [[ "$para" =~ ^[Nn]$ ]] && echo -e "\n🚫 操作取消, 未执行任何操作!\n" && exit 0; echo -e "\n⚠️ 无效输入, 未执行任何操作!\n"; exit 1; }

nodes="/usr/share/perl5/PVE/API2/Nodes.pm"
pvemanagerlib="/usr/share/pve-manager/js/pvemanagerlib.js"
pvever=$(pveversion | awk -F"/" '{print $2}')

echo -e "\n⚙️ 当前 Proxmox VE 版本: $pvever"

####################   配置文件备份步骤   ####################

echo -e "\n💾 正在备份原文件:"

delete_old_backups() {
    local pattern="$1"
    local description="$2"

    shopt -s nullglob
    local files=($pattern)
    shopt -u nullglob

    if [ ${#files[@]} -gt 0 ]; then
        for file in "${files[@]}"; do
            echo "旧备份清理: $file ♻️"
        done
        rm -f "${files[@]}"
    else
        echo "没有发现任何旧备份文件! ♻️"
    fi
}
echo -e "清理旧的备份文件..."
delete_old_backups "${nodes}.*.bak" "nodes"
delete_old_backups "${pvemanagerlib}.*.bak" "pvemanagerlib"

echo -e "备份当前将要被修改的文件..."
cp "$nodes" "${nodes}.${pvever}.bak"
echo "新备份生成: ${nodes}.${pvever}.bak ✅"
cp "$pvemanagerlib" "${pvemanagerlib}.${pvever}.bak"
echo "新备份生成: ${pvemanagerlib}.${pvever}.bak ✅"

echo && sleep 0.5

####################   修改前重装软件包避免重复修改   ####################

spinner() {
    local pid=$1
    local text="$2"
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r%s %s" "$text" "${spinstr:$i:1}"
            sleep $delay
        done
    done

    printf "\r%s " "$text"
}

echo -e "♻️ 正在重装相关软件包:"

reinstall_packages=(pve-manager pve-i18n)
reinstall_failed=()

for pkg in "${reinstall_packages[@]}"; do
    text="正在重装 $pkg:"

    apt-get install --reinstall -y "$pkg" >/dev/null 2>&1 &
    pid=$!

    spinner "$pid" "$text"

    wait $pid
    if [ $? -eq 0 ]; then
        echo "已重装 ✅"
    else
        echo "重装失败 ⛔"
        reinstall_failed+=("$pkg")
    fi
done

# 最终结果判断
if [ ${#reinstall_failed[@]} -ne 0 ]; then
    echo -e "\n⛔ 软件包重装失败! 请检查你的 apt 源配置或网络连接"
    echo && exit 1
else
    echo -e "相关软件包已重装完成!"
fi

echo && sleep 0.5

####################   软件包依赖检查   ####################

# 软件包依赖
echo -e "🗃️ 正在检查依赖软件包:"
dep_packages=(sudo sysstat lm-sensors smartmontools linux-cpupower)
dep_missing=()

# 检查依赖状态
installed_list=$(apt list --installed 2>/dev/null)
for pkg in "${dep_packages[@]}"; do
    if echo "$installed_list" | grep -q "^$pkg/"; then
        echo "$pkg: 已安装 ✅"
    else
        echo "$pkg: 未安装 ⛔"
        dep_missing+=("$pkg")
    fi
done

# 安装缺失的包
if [ ${#dep_missing[@]} -ne 0 ]; then
    echo -e "\n📦 检查到软件包缺失: ${dep_missing[*]} 开始安装..."
    if ! (apt-get update && apt-get install -y "${dep_missing[@]}"); then
        echo -e "\n⛔ 依赖软件包安装失败! 请检查你的 apt 源配置或网络连接"
        echo && exit 1
    fi
    echo -e "✅ 依赖软件包已成功安装!"
else
    echo -e "所有依赖软件包均已安装!"
fi

echo && sleep 0.5

####################   配置设备传感器模块   ####################

echo -e "🧰 正在配置设备传感器模块:"
sensors-detect --auto > /tmp/sensors

drivers=$(sed -n '/Chip drivers/,/\#----cut here/p' /tmp/sensors | sed '/Chip /d;/cut/d')

if [ -n "$drivers" ]; then
    echo "发现传感器模块, 正在配置开机自动加载"
    for drv in $drivers; do
        modprobe "$drv"
        if grep -qx "$drv" /etc/modules; then
            echo "模块 $drv 已存在于 /etc/modules ➡️"
        else
            echo "$drv" >> /etc/modules
            echo "模块 $drv 已添加至 /etc/modules ✅"
        fi
    done
    if [[ -e /etc/init.d/kmod ]]; then
        echo "正在应用模块配置使其立即生效..."
        /etc/init.d/kmod start &>/dev/null
        echo "模块配置已生效 ✅"
    else
        echo "未找到 /etc/init.d/kmod 跳过此步骤 ➡️"
    fi
    echo "设备传感器模块已配置完成!"
elif grep -q "No modules to load, skipping modules configuration" /tmp/sensors; then
    echo "未找到需要手动加载的模块, 跳过配置步骤 (可能已由内核自动加载) ➡️"
elif grep -q "Sorry, no sensors were detected" /tmp/sensors; then
    echo "未检测到任何传感器, 跳过配置步骤 (当前环境可能为虚拟机) ⚠️"
else
    echo "发生预期外的错误, 跳过配置步骤! 你的设备可能不支持或内核未包含相关模块 ⛔"
fi

rm -f /tmp/sensors

# 确保 msr 模块被加载并设为开机自启, 为 turbostat 提供支持
modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf

echo && sleep 0.5

####################   配置 sudo 执行权限   ####################

echo -e "🔩 正在配置必要的执行权限:"
echo -e "允许 www-data 用户以 sudo 权限执行特定监控命令"
SUDOERS_FILE="/etc/sudoers.d/pve-manager-status"
# 首先移除可能被添加的 SUID 权限设置, 以防曾经被其它监控脚本添加
binaries=(/usr/sbin/nvme /usr/bin/iostat /usr/bin/sensors /usr/bin/cpupower /usr/sbin/smartctl /usr/sbin/turbostat)
for bin in "${binaries[@]}"; do
    if [[ -e $bin && -u $bin ]]; then
        chmod -s "$bin" && echo "检测到不安全的 SUID 权限已移除: $bin ⚠️"
    fi
done

# 定义需要 sudo 权限执行命令的绝对路径
SENSORS_PATH=$(command -v sensors)
TURBOSTAT_PATH=$(command -v turbostat)
SMARTCTL_PATH=$(command -v smartctl)
IOSTAT_PATH=$(command -v iostat)

# 配置 sudoers 规则内容
echo -e "正在配置 sudoers 规则内容并进行语法检查..."
read -r -d '' SUDOERS_CONTENT << EOM
# Allow www-data user (PVE Web GUI) to run specific hardware monitoring commands
# This file is managed by pve-manager-status.sh (https://github.com/MiKing233/PVE-Manager-Status)

Cmnd_Alias PVE_MANAGER_STATUS = ${SENSORS_PATH}, ${TURBOSTAT_PATH}, ${SMARTCTL_PATH}, ${IOSTAT_PATH}
Defaults!PVE_MANAGER_STATUS !log_allowed
Defaults!PVE_MANAGER_STATUS !pam_session

www-data ALL=(root) NOPASSWD: ${SENSORS_PATH}
www-data ALL=(root) NOPASSWD: ${TURBOSTAT_PATH} -S -q -s PkgWatt -i 0.1 -n 1 -c package
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -a /dev/*
www-data ALL=(root) NOPASSWD: ${SMARTCTL_PATH} -n standby -a /dev/*
www-data ALL=(root) NOPASSWD: ${IOSTAT_PATH} -d -x -k 1 1

EOM

# 使用 visudo 在最终添加前对 sudoers 规则执行语法检查
TMP_SUDOERS=$(mktemp)
echo "${SUDOERS_CONTENT}" > "${TMP_SUDOERS}"

if visudo -c -f "${TMP_SUDOERS}" &> /dev/null; then
    echo "sudoers 规则语法检查通过 ✅"
    mv "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    chmod 0440 "${SUDOERS_FILE}"
    echo "已成功配置 sudo 规则于: ${SUDOERS_FILE} 🔐"
else
    echo "⛔ sudoers 规则语法错误, 操作终止!"
    echo -e "\n--- DEBUG INFO START ---"
    echo "生成的 sudoers 规则内容如下:"
    echo "--------------------------------------------------"
    cat "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo
    echo "visudo 语法检查的详细错误信息:"
    echo "--------------------------------------------------"
    visudo -c -f "${TMP_SUDOERS}"
    echo "--------------------------------------------------"
    echo -e "\n--- DEBUG INFO END ---"
    rm -f "${TMP_SUDOERS}"
    echo && exit 1
fi

echo && sleep 0.5

####################   硬件监控信息日志采集   ####################

echo -e "📝 正在部署硬件监控信息日志功能:"

HWLOG_SCRIPT="/usr/local/bin/pve-hardware-log.sh"
HWLOG_DIR="/var/log/pve-hardware"

# 采集脚本: 由 cron 每5分钟以 root 调用, 仅记录硬件指标 (不含序列号等敏感信息)
cat > "$HWLOG_SCRIPT" << 'LOGEOF'
#!/bin/bash
# pve-hardware-log.sh - 硬件监控信息定时采集 (由 pve-manager-status.sh 安装维护)
# 调用方: /etc/cron.d/pve-hardware-log (每5分钟)
# 输出:   /var/log/pve-hardware/hardware.log (logrotate 每日轮转, 保留30天)

LOGDIR="/var/log/pve-hardware"
LOGFILE="$LOGDIR/hardware.log"
mkdir -p "$LOGDIR"

# 取 ATA SMART 属性行的 RAW_VALUE (破折号后第一个整数)
ata_raw() {
    grep -E "^[[:space:]]*$1[[:space:]]" 2>/dev/null \
        | grep -oE -- '-[[:space:]]+[0-9]+' | head -1 \
        | grep -oE '[0-9]+' | head -1
}

ts="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "===== $ts ====="

    gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
    load="$(awk '{print $1","$2","$3}' /proc/loadavg 2>/dev/null)"
    echo "CPU: governor=${gov:-unknown} loadavg=${load:-unknown}"

    if command -v sensors >/dev/null 2>&1; then
        sens_line="$(sensors 2>/dev/null \
            | grep -Ei '^(Package id|Tctl|Tdie|edge|junction|Composite|temp[0-9]+|fan[0-9]+)' \
            | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//' \
            | paste -sd'|' -)"
        [ -n "$sens_line" ] && echo "SENSORS: $sens_line"
    fi

    # SATA / SAS 硬盘
    for d in /dev/sd[a-z]; do
        [ -b "$d" ] || continue
        info="$(smartctl -n standby -a "$d" 2>/dev/null)"
        if printf '%s' "$info" | grep -qi 'STANDBY'; then
            echo "$d: STANDBY (休眠中, 跳过SMART读取)"
            continue
        fi
        model="$(printf '%s' "$info" | grep -E '^(Device Model|Model Number):' | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//')"
        if [ -z "$model" ]; then
            model="$(printf '%s' "$info" | grep -E '^(Vendor|Product):' | cut -d: -f2- | sed 's/^[[:space:]]*//' | paste -sd' ' -)"
        fi
        temp="$(printf '%s' "$info" | ata_raw 194)"
        [ -z "$temp" ] && temp="$(printf '%s' "$info" | ata_raw 190)"
        [ -z "$temp" ] && temp="$(printf '%s' "$info" | grep -i 'Current Drive Temperature:' | grep -oE '[0-9]+' | head -1)"
        hours="$(printf '%s' "$info" | ata_raw 9)"
        [ -z "$hours" ] && hours="$(printf '%s' "$info" | grep -i 'hours:minutes' | grep -oE '[0-9]+:' | head -1 | tr -d ':')"
        health="$(printf '%s' "$info" | grep -Ei 'SMART (overall-health self-assessment test result|Health Status):' | grep -oE 'PASSED|FAILED|OK' | head -1)"
        warns=""
        for spec in "5 Reallocated_Sector_Ct:重映射扇区" "197 Current_Pending_Sector:待映射扇区" "198 Offline_Uncorrectable:不可纠正扇区" "187 Reported_Uncorrect:报告性错误" "199 UDMA_CRC_Error_Count:CRC接口错误"; do
            id="${spec%% *}"
            name="${spec#*:}"
            v="$(printf '%s' "$info" | ata_raw "$id")"
            if [ -n "$v" ] && [ "$v" -ne 0 ] 2>/dev/null; then
                warns="${warns}${name}=${v};"
            fi
        done
        echo "$d ${model:-未知型号}: ${temp:-N/A}°C 通电=${hours:-N/A}h SMART=${health:-N/A}${warns:+ 预警[$warns]}"
    done

    # NVMe 硬盘
    for d in /dev/nvme[0-9]n1; do
        [ -b "$d" ] || continue
        info="$(smartctl -n standby -a "$d" 2>/dev/null)"
        model="$(printf '%s' "$info" | grep '^Model Number:' | cut -d: -f2- | sed 's/^[[:space:]]*//')"
        temp="$(printf '%s' "$info" | grep -E '^Temperature:' | grep -oE '[0-9]+' | head -1)"
        hours="$(printf '%s' "$info" | grep '^Power On Hours:' | grep -oE '[0-9,]+' | head -1 | tr -d ',')"
        used="$(printf '%s' "$info" | grep '^Percentage Used:' | grep -oE '[0-9]+' | head -1)"
        health="$(printf '%s' "$info" | grep -Ei 'SMART (overall-health self-assessment test result|Health Status):' | grep -oE 'PASSED|FAILED|OK' | head -1)"
        if [ -n "$used" ]; then life="$((100-used))%"; else life="N/A"; fi
        echo "$d ${model:-未知型号}: ${temp:-N/A}°C 通电=${hours:-N/A}h 剩余寿命=${life} SMART=${health:-N/A}"
    done

    echo ""
} >> "$LOGFILE" 2>&1
LOGEOF
chmod 0755 "$HWLOG_SCRIPT"

# cron 定时任务: 每5分钟采集一次
cat > /etc/cron.d/pve-hardware-log << 'CRONEOF'
# pve-hardware-log - 硬件监控信息定时采集 (由 pve-manager-status.sh 维护)
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/pve-hardware-log.sh
CRONEOF
chmod 0644 /etc/cron.d/pve-hardware-log

# 日志轮转: 每日一次, 压缩保留30天
cat > /etc/logrotate.d/pve-hardware-log << 'ROTEOF'
# pve-hardware-log logrotate config (由 pve-manager-status.sh 维护)
/var/log/pve-hardware/hardware.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
ROTEOF
chmod 0644 /etc/logrotate.d/pve-hardware-log

# 立即执行一次, 保证部署完成后页面即可看到日志
if "$HWLOG_SCRIPT" && [ -s "$HWLOG_DIR/hardware.log" ]; then
    echo -e "  硬件日志首次采集完成 -> $HWLOG_DIR/hardware.log ✅"
else
    echo -e "  ⚠️ 硬件日志首次采集无输出 (可能无 sensors/smartctl, cron 仍会按周期重试)"
fi

echo && sleep 0.5

####################   概要页面监控功能实现   ####################

echo -e "📋 正在添加概要页面监控功能:"

# 修改 node.pm 文件前置步骤
tmpf1=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf1" << 'EOF'

        my $cpumodes = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;
        my $cpupowers = `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package | grep -v PkgWatt`;
        $res->{cpupower} = $cpumodes . $cpupowers;

        my $cpufreqs = `lscpu | grep MHz`;
        my $threadfreqs = `cat /proc/cpuinfo | grep -i "cpu MHz"`;
        $res->{cpufreq} = $cpufreqs . $threadfreqs;

        $res->{sensors} = `sudo sensors`;
EOF

for x in {0..9}; do
    for dev in "/dev/nvme${x}" "/dev/nvme${x}n1"; do
        if [ -b "$dev" ]; then
            cat >> "$tmpf1" << EOF

        my \$nvme${x}_info = \`sudo smartctl -a $dev | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors"\`;
        my \$nvme${x}_io = \`sudo iostat -d -x -k 1 1 | grep -E "^${dev##*/}"\`;
        \$res->{nvme${x}_status} = \$nvme${x}_info . \$nvme${x}_io;
EOF
            break
        fi
    done
done

cat >> "$tmpf1" << 'EOF'

        $res->{sata_status} = `for d in /dev/sd[a-z]; do [ -b "\$d" ] || continue; echo "===\$d==="; sudo smartctl -n standby -a "\$d" 2>/dev/null || true; done | grep -Ei '^===|model|vendor|product:|user capacity|power_on_hours|power_cycle_count|power on|powered up|drive temperature|temperature|smart overall|smart health|rotation rate|solid state|standby|reallocated|pending|uncorrect|udma_crc'`;

        $res->{hardware_log_tail} = `tail -n 100 /var/log/pve-hardware/hardware.log 2>/dev/null`;
EOF

# 在实际修改前检查锚点文本是否存在, 若不存在则报错退出停止修改
if ! grep -q 'PVE::pvecfg::version_text' "$nodes"; then
    echo "⛔ 在 $nodes 中未找到锚点, 操作终止!"
    rm -f "$tmpf1"
    echo -e "⚠️ 锚点'PVE::pvecfg::version_text', 文件可能已更新或与当前版本不兼容"
    echo && exit 1
fi

# 应用更改
sed -i '/PVE::pvecfg::version_text/ r '"$tmpf1"'' "$nodes"

# 验证修改是否成功
if grep -q 'cpupower' "$nodes"; then
    echo "已完成修改: $nodes ✅"
else
    echo "⛔ 检查对 $nodes 添加的内容未生效!"
    rm -f "$tmpf1"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容"
    echo && exit 1
fi

rm -f "$tmpf1"

# 修改 pvemanagerlib.js 文件前置步骤
tmpf2=$(mktemp /tmp/pve-manager-status.XXXXXX) || exit 1
cat > "$tmpf2" << 'EOF'
        {
            itemId: 'cpupower',
            colspan: 2,
            printBar: false,
            title: gettext('CPU能耗'),
            textField: 'cpupower',
            renderer:function(value){
                function colorizeCpuMode(mode) {
                    if (mode === 'powersave') return `<span style="color:green; font-weight:bold;">${mode}</span>`;
                    if (mode === 'performance') return `<span style="color:red; font-weight:bold;">${mode}</span>`;
                    return `<span style="color:orange; font-weight:bold;">${mode}</span>`;
                }
                function colorizeCpuPower(power) {
                    const powerNum = parseFloat(power);
                    if (powerNum < 20) return `<span style="color:green; font-weight:bold;">${power} W</span>`;
                    if (powerNum < 50) return `<span style="color:orange; font-weight:bold;">${power} W</span>`;
                    return `<span style="color:red; font-weight:bold;">${power} W</span>`;
                }
                const w0 = value.split('\n')[0].split(' ')[0];
                const w1 = value.split('\n')[1].split(' ')[0];
                return `CPU电源模式: ${colorizeCpuMode(w0)} | CPU功耗: ${colorizeCpuPower(w1)}`
            }
        },
        {
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率'),
            textField: 'cpufreq',
            renderer:function(value){
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:green; font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:orange; font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:red; font-weight:bold;">${freq} MHz</span>`;
                }
                const f0 = value.match(/cpu MHz.*?([\d]+)/)[1];
                const f1 = value.match(/CPU min MHz.*?([\d]+)/)[1];
                const f2 = value.match(/CPU max MHz.*?([\d]+)/)[1];
                return `CPU实时: ${colorizeCpuFreq(f0)} | 最小: ${f1} MHz | 最大: ${f2} MHz `
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('传感器'),
            textField: 'sensors',
            renderer: function(value) {
                function colorizeCpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeGpuTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeAcpiTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 60) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 80) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                function colorizeFanRpm(rpm) {
                    const rpmNum = parseFloat(rpm);
                    if (rpmNum < 1500) return `<span style="color:green; font-weight:bold;">${rpm}转/分钟</span>`;
                    if (rpmNum < 3000) return `<span style="color:orange; font-weight:bold;">${rpm}转/分钟</span>`;
                    return `<span style="color:red; font-weight:bold;">${rpm}转/分钟</span>`;
                }
                value = value.replace(/Â/g, '');
                let data = [];
                let cpus = value.matchAll(/^(?:coretemp-isa|k10temp-pci)-(\w{4})$\n.*?\n((?:Package|Core|Tctl)[\s\S]*?^\n)+/gm);
                for (const cpu of cpus) {
                    let cpuNumber = parseInt(cpu[1], 10);
                    data[cpuNumber] = {
                        packages: [],
                        cores: []
                    };

                    let packages = cpu[2].matchAll(/^(?:Package id \d+|Tctl):\s*\+([^°C ]+).*$/gm);
                    for (const package of packages) {
                        data[cpuNumber]['packages'].push(package[1]);
                    }
                    let cores = cpu[2].matchAll(/^Core (\d+):\s*\+([^°C ]+).*$/gm);
                    for (const core of cores) {
                        var corecombi = `核心 ${core[1]}: ${colorizeCpuTemp(core[2])}`
                        data[cpuNumber]['cores'].push(corecombi);
                    }
                }

                let output = '';
                for (const [i, cpu] of data.entries()) {
                    if (cpu.packages.length > 0) {
                        for (const packageTemp of cpu.packages) {
                            output += `CPU ${i}: ${colorizeCpuTemp(packageTemp)} | `;
                        }
                    }

                    let gpus = value.matchAll(/^amdgpu-pci-(\w*)$\n((?!edge:)[ \S]*?\n)*((?:edge)[\s\S]*?^\n)+/gm);
                    for (const gpu of gpus) {
                        let gpuNumber = 0;
                        data[gpuNumber] = {
                            edges: []
                        };

                        let edges = gpu[3].matchAll(/^edge:\s*\+([^°C ]+).*$/gm);
                        for (const edge of edges) {
                            data[gpuNumber]['edges'].push(edge[1]);
                        }

                        for (const [k, gpu] of data.entries()) {
                            if (gpu.edges.length > 0) {
                                output += '核显: ';
                                for (const edgeTemp of gpu.edges) {
                                    output += `${colorizeGpuTemp(edgeTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let acpitzs = value.matchAll(/^acpitz-acpi-(\d*)$\n.*?\n((?:temp)[\s\S]*?^\n)+/gm);
                    for (const acpitz of acpitzs) {
                        let acpitzNumber = parseInt(acpitz[1], 10);
                        data[acpitzNumber] = {
                            acpisensors: []
                        };

                        let acpisensors = acpitz[2].matchAll(/^temp\d+:\s*\+([^°C ]+).*$/gm);
                        for (const acpisensor of acpisensors) {
                            data[acpitzNumber]['acpisensors'].push(acpisensor[1]);
                        }

                        for (const [k, acpitz] of data.entries()) {
                            if (acpitz.acpisensors.length > 0) {
                                output += '主板: ';
                                for (const acpiTemp of acpitz.acpisensors) {
                                    output += `${colorizeAcpiTemp(acpiTemp)}, `;
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }

                    let FunStates = value.matchAll(/^(?:[a-zA-z]{2,3}\d{4}|dell_smm)-isa-(\w{4})$\n((?![ \S]+: *\d+ +RPM)[ \S]*?\n)*((?:[ \S]+: *\d+ RPM)[\s\S]*?^\n)+/gm);
                    for (const FunState of FunStates) {
                        let FanNumber = 0;
                        data[FanNumber] = {
                            rotationals: [],
                            cpufans: [],
                            motherboardfans: [],
                            pumpfans: [],
                            systemfans: []
                        };

                        let rotationals = FunState[3].match(/^([ \S]+: *[0-9]\d* +RPM)[ \S]*?$/gm);
                        for (const rotational of rotationals) {
                            if (rotational.toLowerCase().indexOf("pump") !== -1 || rotational.toLowerCase().indexOf("opt") !== -1){
                                let pumpfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const pumpfan of pumpfans) {
                                    data[FanNumber]['pumpfans'].push(pumpfan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("cpu") !== -1 || rotational.toLowerCase().indexOf("processor") !== -1){
                                let cpufans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const cpufan of cpufans) {
                                    data[FanNumber]['cpufans'].push(cpufan[1]);
                                }
                            } else if (rotational.toLowerCase().indexOf("motherboard") !== -1){
                                let motherboardfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const motherboardfan of motherboardfans) {
                                    data[FanNumber]['motherboardfans'].push(motherboardfan[1]);
                                }
                            }  else {
                                let systemfans = rotational.matchAll(/^[ \S]+: *([1-9]\d*) +RPM[ \S]*?$/gm);
                                for (const systemfan of systemfans) {
                                    data[FanNumber]['systemfans'].push(systemfan[1]);
                                }
                            }
                        }

                        for (const [j, FunState] of data.entries()) {
                            if (FunState.cpufans.length > 0 || FunState.motherboardfans.length > 0 || FunState.pumpfans.length > 0 || FunState.systemfans.length > 0) {
                                output += '风扇: ';
                                if (FunState.cpufans.length > 0) {
                                    output += 'CPU-';
                                    for (const cpufan_value of FunState.cpufans) {
                                        output += `${colorizeFanRpm(cpufan_value)}, `;
                                    }
                                }

                                if (FunState.motherboardfans.length > 0) {
                                    output += '主板-';
                                    for (const motherboardfan_value of FunState.motherboardfans) {
                                        output += `${colorizeFanRpm(motherboardfan_value)}, `;
                                    }
                                }

                                if (FunState.pumpfans.length > 0) {
                                    output += '水冷-';
                                    for (const pumpfan_value of FunState.pumpfans) {
                                        output += `${colorizeFanRpm(pumpfan_value)}, `;
                                    }
                                }

                                if (FunState.systemfans.length > 0) {
                                    if (FunState.cpufans.length > 0 || FunState.pumpfans.length > 0) {
                                        output += '系统-';
                                    }
                                    for (const systemfan_value of FunState.systemfans) {
                                        output += `${colorizeFanRpm(systemfan_value)}, `;
                                    }
                                }
                                output = output.slice(0, -2);
                                output += ' | ';
                            } else if (FunState.cpufans.length == 0 && FunState.pumpfans.length == 0 && FunState.systemfans.length == 0) {
                                output += ' 风扇: 停转';
                                output += ' | ';
                            } else {
                                output = output.slice(0, -2);
                            }
                        }
                    }
                    output = output.slice(0, -2);

                    if (cpu.cores.length > 1) {
                        output += '\n';
                        for (j = 1;j < cpu.cores.length;) {
                            for (const coreTemp of cpu.cores) {
                                output += `${coreTemp} | `;
                                j++;
                                if ((j-1) % 4 == 0){
                                    output = output.slice(0, -2);
                                    output += '\n';
                                }
                            }
                        }
                        output = output.slice(0, -2);
                    }
                    output += '\n';
                }

                output = output.slice(0, -2);
                return output.replace(/\n/g, '<br>');
            }
        },
        {
            itemId: 'corefreq',
            colspan: 2,
            printBar: false,
            title: gettext('核心频率'),
            textField: 'cpufreq',
            renderer: function(value) {
                function colorizeCpuFreq(freq) {
                    const freqNum = parseFloat(freq);
                    if (freqNum < 1500) return `<span style="color:green; font-weight:bold;">${freq} MHz</span>`;
                    if (freqNum < 3000) return `<span style="color:orange; font-weight:bold;">${freq} MHz</span>`;
                    return `<span style="color:red; font-weight:bold;">${freq} MHz</span>`;
                }
                const freqMatches = value.matchAll(/^cpu MHz\s*:\s*([\d\.]+)/gm);
                const frequencies = [];

                for (const match of freqMatches) {
                    const coreNum = frequencies.length + 1;
                    frequencies.push(`线程 ${coreNum}: ${colorizeCpuFreq(parseInt(match[1]))}`);
                }

                if (frequencies.length === 0) {
                    return '无法获取CPU频率信息';
                }

                const groupedFreqs = [];
                for (let i = 0; i < frequencies.length; i += 4) {
                    const group = frequencies.slice(i, i + 4);
                    groupedFreqs.push(group.join(' | '));
                }

                return groupedFreqs.join('<br>');
            }
        },
EOF

for x in {0..9}; do
    for dev in "/dev/nvme${x}" "/dev/nvme${x}n1"; do
        if [ -b "$dev" ]; then
            cat >> "$tmpf2" << EOF
        {
            itemId: 'nvme${x}-status',
            colspan: 2,
            printBar: false,
            title: gettext('NVMe${x}硬盘'),
            textField: 'nvme${x}_status',
            renderer:function(value){
                function getSsdLifeColor(life) {
                    const lifeNum = parseFloat(life);
                    if (lifeNum < 50) return 'red';
                    if (lifeNum < 80) return 'orange';
                    return 'green';
                }
                function colorizeSsdModel(model, life) {
                    const color = getSsdLifeColor(life);
                    return \`<span style="color:\${color}; font-weight:bold;">\${model}</span>\`;
                }
                function colorizeSsdLife(life) {
                    const color = getSsdLifeColor(life);
                    return \`<span style="color:\${color}; font-weight:bold;">\${life}%</span>\`;
                }
                function colorizeSsdTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 50) return \`<span style="color:green; font-weight:bold;">\${temp}°C</span>\`;
                    if (tempNum < 70) return \`<span style="color:orange; font-weight:bold;">\${temp}°C</span>\`;
                    return \`<span style="color:red; font-weight:bold;">\${temp}°C</span>\`;
                }
                function colorizeSsdLoad(load) {
                    const loadNum = parseFloat(load);
                    if (loadNum < 50) return \`<span style="color:green; font-weight:bold;">\${load}%</span>\`;
                    if (loadNum < 80) return \`<span style="color:orange; font-weight:bold;">\${load}%</span>\`;
                    return \`<span style="color:red; font-weight:bold;">\${load}%</span>\`;
                }
                function colorizeIoSpeed(speed) {
                    const speedNum = parseFloat(speed);
                    if (speedNum > 1000) return \`<span style="color:red; font-weight:bold;">\${speed}MB/s</span>\`;
                    if (speedNum < 100) return \`<span style="color:green; font-weight:bold;">\${speed}MB/s</span>\`;
                    return \`<span style="color:orange; font-weight:bold;">\${speed}MB/s</span>\`;
                }
                function colorizeIoLatency(latency) {
                    const latencyNum = parseFloat(latency);
                    if (latencyNum > 10) return \`<span style="color:red; font-weight:bold;">\${latency}ms</span>\`;
                    if (latencyNum < 1) return \`<span style="color:green; font-weight:bold;">\${latency}ms</span>\`;
                    return \`<span style="color:orange; font-weight:bold;">\${latency}ms</span>\`;
                }
                if (value.length > 0) {
                    value = value.replace(/Â/g, '');
                    let data = [];
                    let nvmeNumber = -1;

                    let nvmes = value.matchAll(/(^(?:Model|Total|Temperature:|Available Spare:|Percentage|Data|Power|Unsafe|Integrity Errors|nvme)[\s\S]*)+/gm);
                    
                    for (const nvme of nvmes) {
                        if (/Model Number:/.test(nvme[1])) {
                            nvmeNumber++; 
                            data[nvmeNumber] = {
                                Models: [],
                                Integrity_Errors: [],
                                Capacitys: [],
                                Temperatures: [],
                                Available_Spares: [],
                                Useds: [],
                                Reads: [],
                                Writtens: [],
                                Cycles: [],
                                Hours: [],
                                Shutdowns: [],
                                States: [],
                                r_kBs: [],
                                r_awaits: [],
                                w_kBs: [],
                                w_awaits: [],
                                utils: []
                            };
                        }

                        if (nvmeNumber === -1) continue;

                        let Models = nvme[1].matchAll(/^Model Number: *([ \S]*)$/gm);
                        for (const Model of Models) {
                            data[nvmeNumber]['Models'].push(Model[1]);
                        }

                        let Integrity_Errors = nvme[1].matchAll(/^Media and Data Integrity Errors: *([ \S]*)$/gm);
                        for (const Integrity_Error of Integrity_Errors) {
                            data[nvmeNumber]['Integrity_Errors'].push(Integrity_Error[1]);
                        }

                        let Capacitys = nvme[1].matchAll(/^(?=Total|Namespace)[^:]+Capacity:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Capacity of Capacitys) {
                            data[nvmeNumber]['Capacitys'].push(Capacity[1]);
                        }

                        let Temperatures = nvme[1].matchAll(/^Temperature: *([\d]*)[ \S]*$/gm);
                        for (const Temperature of Temperatures) {
                            data[nvmeNumber]['Temperatures'].push(Temperature[1]);
                        }

                        let Available_Spares = nvme[1].matchAll(/^Available Spare: *([\d]*%)[ \S]*$/gm);
                        for (const Available_Spare of Available_Spares) {
                            data[nvmeNumber]['Available_Spares'].push(Available_Spare[1]);
                        }

                        let Useds = nvme[1].matchAll(/^Percentage Used: *([ \S]*)%$/gm);
                        for (const Used of Useds) {
                            data[nvmeNumber]['Useds'].push(Used[1]);
                        }

                        let Reads = nvme[1].matchAll(/^Data Units Read:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Read of Reads) {
                            data[nvmeNumber]['Reads'].push(Read[1]);
                        }

                        let Writtens = nvme[1].matchAll(/^Data Units Written:[^\[]*\[([ \S]*)\]$/gm);
                        for (const Written of Writtens) {
                            data[nvmeNumber]['Writtens'].push(Written[1]);
                        }

                        let Cycles = nvme[1].matchAll(/^Power Cycles: *([ \S]*)$/gm);
                        for (const Cycle of Cycles) {
                            data[nvmeNumber]['Cycles'].push(Cycle[1]);
                        }

                        let Hours = nvme[1].matchAll(/^Power On Hours: *([ \S]*)$/gm);
                        for (const Hour of Hours) {
                            data[nvmeNumber]['Hours'].push(Hour[1]);
                        }

                        let Shutdowns = nvme[1].matchAll(/^Unsafe Shutdowns: *([ \S]*)$/gm);
                        for (const Shutdown of Shutdowns) {
                            data[nvmeNumber]['Shutdowns'].push(Shutdown[1]);
                        }

                        let States = nvme[1].matchAll(/^nvme\S+(( *\d+\.\d{2}){22})/gm);
                        for (const State of States) {
                            data[nvmeNumber]['States'].push(State[1]);
                            const IO_array = [...State[1].matchAll(/\d+\.\d{2}/g)];
                            if (IO_array.length > 0) {
                                data[nvmeNumber]['r_kBs'].push(IO_array[1]);
                                data[nvmeNumber]['r_awaits'].push(IO_array[4]);
                                data[nvmeNumber]['w_kBs'].push(IO_array[7]);
                                data[nvmeNumber]['w_awaits'].push(IO_array[10]);
                                data[nvmeNumber]['utils'].push(IO_array[21]);
                            }
                        }
                    }

                    let output = '';
                    for (const [i, nvme] of data.entries()) {
                        if (i > 0) output += '<br><br>';

                        if (nvme.Models.length > 0) {
                            output += colorizeSsdModel(nvme.Models[0], 100 - Number(nvme.Useds[0]));

                            if (nvme.Integrity_Errors.length > 0) {
                                for (const nvmeIntegrity_Error of nvme.Integrity_Errors) {
                                    if (nvmeIntegrity_Error != 0) {
                                        output += ' (';
                                        output += \`0E: \${nvmeIntegrity_Error}-故障！\`;
                                        if (nvme.Available_Spares.length > 0) {
                                            output += ', ';
                                            for (const Available_Spare of nvme.Available_Spares) {
                                                output += \`备用空间: \${Available_Spare}\`;
                                            }
                                        }
                                        output += ')';
                                    }
                                }
                            }
                        }

                        if (nvme.Capacitys.length > 0) {
                            output += ' | ';
                            for (const nvmeCapacity of nvme.Capacitys) {
                                output += \`容量: \${nvmeCapacity.replace(/ |,/gm, '')}\`;
                            }
                        }
                        output += '<br>';

                        if (nvme.Useds.length > 0) {
                            for (const nvmeUsed of nvme.Useds) {
                                output += \`寿命: \${colorizeSsdLife(100-Number(nvmeUsed))} \`;
                                if (nvme.Reads.length > 0) {
                                    output += '(';
                                    for (const nvmeRead of nvme.Reads) {
                                        output += \`已读 \${nvmeRead.replace(/ |,/gm, '')}\`;
                                        output += ')';
                                    }
                                }

                                if (nvme.Writtens.length > 0) {
                                    output = output.slice(0, -1);
                                    output += ', ';
                                    for (const nvmeWritten of nvme.Writtens) {
                                        output += \`已写 \${nvmeWritten.replace(/ |,/gm, '')}\`;
                                    }
                                    output += ')';
                                }
                            }
                        }

                        if (nvme.Temperatures.length > 0) {
                            output += ' | ';
                            for (const nvmeTemperature of nvme.Temperatures) {
                                output += \`温度: \${colorizeSsdTemp(nvmeTemperature)}\`;
                            }
                        }

                        if (nvme.utils.length > 0) {
                            output += ' | ';
                            for (const nvme_util of nvme.utils) {
                                output += \`负载: \${colorizeSsdLoad(nvme_util)}\`;
                            }
                        }
                        output += '<br>';

                        if (nvme.States.length > 0) {
                            output += 'I/O: ';
                            if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                output += '读-';
                                if (nvme.r_kBs.length > 0) {
                                    for (const nvme_r_kB of nvme.r_kBs) {
                                        var nvme_r_mB = \`\${nvme_r_kB}\` / 1024;
                                        nvme_r_mB = nvme_r_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_r_mB)}\`;
                                    }
                                }
                                if (nvme.r_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_r_await of nvme.r_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_r_await)}\`;
                                    }
                                }
                            }

                            if (nvme.w_kBs.length > 0 || nvme.w_awaits.length > 0) {
                                if (nvme.r_kBs.length > 0 || nvme.r_awaits.length > 0) {
                                    output += ' / ';
                                }
                                output += '写-';
                                if (nvme.w_kBs.length > 0) {
                                    for (const nvme_w_kB of nvme.w_kBs) {
                                        var nvme_w_mB = \`\${nvme_w_kB}\` / 1024;
                                        nvme_w_mB = nvme_w_mB.toFixed(2);
                                        output += \`速度 \${colorizeIoSpeed(nvme_w_mB)}\`;
                                    }
                                }
                                if (nvme.w_awaits.length > 0) {
                                    output += ', ';
                                    for (const nvme_w_await of nvme.w_awaits) {
                                        output += \`延迟 \${colorizeIoLatency(nvme_w_await)}\`;
                                    }
                                }
                            }
                        }

                        if (nvme.Cycles.length > 0) {
                            output += '<br>';
                            for (const nvmeCycle of nvme.Cycles) {
                                output += \`通电: \${nvmeCycle.replace(/ |,/gm, '')}次\`;
                            }

                            if (nvme.Shutdowns.length > 0) {
                                output += ', ';
                                for (const nvmeShutdown of nvme.Shutdowns) {
                                    output += \`不安全断电\${nvmeShutdown.replace(/ |,/gm, '')}次\`;
                                    break
                                }
                            }

                            if (nvme.Hours.length > 0) {
                                output += ', ';
                                for (const nvmeHour of nvme.Hours) {
                                    output += \`累计\${nvmeHour.replace(/ |,/gm, '')}小时\`;
                                }
                            }
                        }
                    }
                    return output;

                } else {
                    return '提示: 未安装 NVMe硬盘 或已直通 NVMe 控制器!';
                }
            },
        },
EOF
            break
        fi
    done
done

cat >> "$tmpf2" << 'EOF'
        {
            itemId: 'sata_status',
            colspan: 2,
            printBar: false,
            title: gettext('SATA硬盘'),
            textField: 'sata_status',
            renderer: function(value) {
                function colorizeHddTemp(temp) {
                    const tempNum = parseFloat(temp);
                    if (tempNum < 40) return `<span style="color:green; font-weight:bold;">${temp}°C</span>`;
                    if (tempNum < 50) return `<span style="color:orange; font-weight:bold;">${temp}°C</span>`;
                    return `<span style="color:red; font-weight:bold;">${temp}°C</span>`;
                }
                if (!value || value.trim().length === 0) {
                    return '提示: 未发现 /dev/sd* 设备 (未安装SATA硬盘, 或SATA控制器/磁盘已直通给虚拟机)';
                }
                value = value.replace(/Â/g, '');

                function parseBlock(name, block) {
                    block = block || '';

                    // 休眠盘: smartctl -n standby 不会唤醒磁盘
                    if (/STANDBY/i.test(block)) {
                        return `<strong>${name}</strong><br>状态: 休眠中 (未唤醒磁盘读取SMART)`;
                    }

                    // 型号: ATA(Model Family/Device Model), 或 SCSI/SAS(Vendor/Product)
                    let family = (block.match(/Model Family:\s*(.+)/) || [,''])[1].trim();
                    let dmodel = (block.match(/Device Model:\s*(.+)/) || [,''])[1].trim();
                    let mnumber = (block.match(/Model Number:\s*(.+)/) || [,''])[1].trim();
                    let vendor = (block.match(/^Vendor:\s*(.+)/m) || [,''])[1].trim();
                    let product = (block.match(/^Product:\s*(.+)/m) || [,''])[1].trim();

                    let model = '';
                    if (dmodel) {
                        model = dmodel;
                        if (family && family !== '-' && family !== dmodel && dmodel.indexOf(family) === -1) {
                            model = `${family} - ${dmodel}`;
                        }
                    } else if (mnumber) {
                        model = mnumber;
                    } else if (vendor || product) {
                        model = `${vendor} ${product}`.replace(/\s+/g, ' ').trim();
                    } else {
                        model = name;
                    }

                    // 设备类型
                    let devType = '';
                    if (/Solid State Device/i.test(block)) {
                        devType = 'SSD';
                    } else if (/Rotation Rate:\s*(\d+)/i.test(block)) {
                        devType = 'HDD';
                    }

                    // 容量
                    let capacity = (block.match(/User Capacity:[^\[]*\[(.+?)\]/) || [,''])[1].trim().replace(/\s+/g, '');

                    // 通电时间: ATA 属性9, 或 SCSI/SAS 日志
                    let hours = '';
                    let mHours = block.match(/^\s*9\s+Power_On_Hours\b.*?-\s*(\d+)/m);
                    if (mHours) {
                        hours = mHours[1];
                    } else {
                        mHours = block.match(/hours:minutes\s+(\d+)/i)
                              || block.match(/number of hours power[^\d=]*=\s*([\d.]+)/i)
                              || block.match(/Accumulated power on time[^\d]*(\d+)/i);
                        if (mHours) hours = mHours[1];
                    }

                    // 通电次数: ATA 属性12
                    let cycles = '';
                    let mCycles = block.match(/^\s*12\s+Power_Cycle_Count\b.*?-\s*(\d+)/m);
                    if (mCycles) cycles = mCycles[1];

                    // 温度: 优先 ATA 属性194(摄氏度), 回退190(部分老希捷口径不同),
                    // 再回退 SCSI "Current Drive Temperature" 或裸 "Temperature:" 行
                    let temp = '';
                    let mTemp = block.match(/^\s*194\s+\S+\s+.*?-\s*(\d+)/m)
                             || block.match(/^\s*190\s+\S+\s+.*?-\s*(\d+)/m)
                             || block.match(/Current Drive Temperature:\s*(\d+)/i)
                             || block.match(/^Temperature:\s*(\d+)/m);
                    if (mTemp) temp = mTemp[1];

                    // SMART 健康状态
                    let health = '';
                    let mHealth = block.match(/SMART overall-health self-assessment test result:\s*(\w+)/i)
                               || block.match(/SMART Health Status:\s*(\w+)/i);
                    if (mHealth) {
                        let h = mHealth[1].toUpperCase();
                        health = (h === 'PASSED' || h === 'OK') ? '正常' : '警告!';
                    }

                    // 关键健康预警属性 (ATA), 仅在原始值非0时红字提示
                    let alerts = [];
                    const warnAttrs = [
                        [/^\s*5\s+Reallocated_Sector_Ct\b.*?-\s*(\d+)/m, '重映射扇区', '已替换坏道, 请关注并备份'],
                        [/^\s*197\s+Current_Pending_Sector\b.*?-\s*(\d+)/m, '待映射扇区', '存在不稳定扇区'],
                        [/^\s*198\s+Offline_Uncorrectable\b.*?-\s*(\d+)/m, '无法纠正扇区', '严重, 请立即备份'],
                        [/^\s*187\s+Reported_Uncorrect\b.*?-\s*(\d+)/m, '报告性不可纠正错误', ''],
                        [/^\s*199\s+UDMA_CRC_Error_Count\b.*?-\s*(\d+)/m, 'CRC接口错误', '多为SATA线松动/老化或接口接触不良'],
                    ];
                    for (const [reWarn, warnLabel, warnTip] of warnAttrs) {
                        const mWarn = block.match(reWarn);
                        if (mWarn && parseInt(mWarn[1], 10) !== 0) {
                            alerts.push(`${warnLabel}: ${mWarn[1]}${warnTip ? ` (${warnTip})` : ''}`);
                        }
                    }

                    let out = `<strong>${model}</strong>`;
                    if (devType) out += ` [${devType}]`;
                    out += '<br>';

                    let parts = [];
                    if (capacity) parts.push(`容量: ${capacity}`);
                    if (hours) parts.push(`通电: ${hours}小时`);
                    if (cycles) parts.push(`次数: ${cycles}`);
                    if (temp) parts.push(`温度: ${colorizeHddTemp(temp)}`);
                    if (health) parts.push(`SMART: ${health}`);
                    if (parts.length === 0) {
                        parts.push('提示: 设备存在但无法读取SMART详情 (如为USB硬盘盒/RAID卡, 可尝试 smartctl -d sat 或 -d megaraid,N)');
                    }
                    out += parts.join(' | ');
                    if (alerts.length > 0) {
                        out += `<br><span style="color:red; font-weight:bold;">⚠ ${alerts.join(' | ')}</span>`;
                    }
                    return out;
                }

                let outputs = [];
                // 按后端写入的 ===/dev/sdX=== 标记切分, 捕获组保证空块也不错位
                let chunks = value.split(/^(===\/dev\/sd[a-z]+===)$/m);
                for (let i = 1; i < chunks.length; i += 2) {
                    let name = chunks[i].replace(/=/g, '');
                    outputs.push(parseBlock(name, chunks[i + 1] || ''));
                }

                // 兼容无设备标记的旧版后端输出, 将整段当作一块盘解析
                if (outputs.length === 0) {
                    outputs.push(parseBlock('SATA硬盘', value));
                }

                return outputs.join('<br><br>');
            }
        },
EOF

cat >> "$tmpf2" << 'EOF'

        {
            itemId: 'hardware-log',
            colspan: 2,
            printBar: false,
            title: gettext('硬件监控日志'),
            textField: 'hardware_log_tail',
            renderer: function(value) {
                let latest = value || '';
                window.__pveHwLogLatest = latest;

                // 事件委托只绑定一次 (renderer 会随状态轮询反复执行)
                if (!window.__pveHwLogDelegated) {
                    window.__pveHwLogDelegated = true;
                    Ext.getBody().on('click', function(ev, target) {
                        if (Ext.fly(target).hasCls('pve-hwlog-link')) {
                            ev.preventDefault();
                            window.pveShowHardwareLog();
                        }
                    }, null, { delegate: 'a.pve-hwlog-link' });
                }

                if (!window.pveShowHardwareLog) {
                    window.pveShowHardwareLog = function() {
                        // 动态获取当前节点名, 拿不到时回退 localhost (PVE API 支持本机别名)
                        let node = 'localhost';
                        let view = Ext.ComponentQuery.query('pveNodeStatus')[0];
                        if (view && view.pveSelNode && view.pveSelNode.data && view.pveSelNode.data.node) {
                            node = view.pveSelNode.data.node;
                        }

                        let timer = null;
                        let win = Ext.create('Ext.window.Window', {
                            title: gettext('硬件监控日志') + ' (/var/log/pve-hardware/hardware.log)',
                            width: 880,
                            height: 600,
                            modal: true,
                            layout: 'fit',
                            bodyPadding: 10,
                            items: [{
                                xtype: 'textareafield',
                                itemId: 'hwlogbody',
                                readOnly: true,
                                grow: false,
                                fieldStyle: 'font-family: Consolas, Monaco, "Courier New", monospace; font-size: 12px; line-height: 150%;',
                                value: window.__pveHwLogLatest || gettext('暂无日志, 正在等待定时任务首次采集...')
                            }],
                            buttons: [
                                {
                                    xtype: 'checkbox',
                                    itemId: 'hwlogauto',
                                    boxLabel: gettext('自动刷新(10秒)'),
                                    margin: '0 10 0 0',
                                    listeners: {
                                        change: function(cb, checked) {
                                            if (timer) { clearInterval(timer); timer = null; }
                                            if (checked) {
                                                timer = setInterval(reload, 10000);
                                            }
                                        }
                                    }
                                },
                                '->',
                                { text: gettext('刷新'), handler: function() { reload(); } },
                                { text: gettext('关闭'), handler: function() { win.close(); } }
                            ],
                            listeners: {
                                close: function() {
                                    if (timer) { clearInterval(timer); timer = null; }
                                }
                            }
                        });

                        function scrollBottom() {
                            let field = win.down('#hwlogbody');
                            if (field && field.inputEl && field.inputEl.dom) {
                                field.inputEl.dom.scrollTop = field.inputEl.dom.scrollHeight;
                            }
                        }

                        function reload() {
                            Proxmox.Utils.API2Request({
                                url: '/nodes/' + node + '/status',
                                method: 'GET',
                                success: function(resp) {
                                    let v = (resp.result && resp.result.data && resp.result.data.hardware_log_tail) || '';
                                    win.down('#hwlogbody').setValue(v || gettext('日志为空'));
                                    scrollBottom();
                                },
                                failure: function(resp) {
                                    Ext.Msg.alert(gettext('错误'), resp.htmlStatus || resp.statusText || 'request failed');
                                }
                            });
                        }

                        win.show();
                        scrollBottom();
                    };
                }

                let lineCount = latest.trim() ? latest.trim().split('\n').length : 0;
                return '<a href="#" class="pve-hwlog-link" style="text-decoration:underline;">'
                     + '📜 ' + gettext('查看硬件监控日志') + '</a>'
                     + ' <span style="color:#888;font-size:11px;">/var/log/pve-hardware/hardware.log · '
                     + gettext('每5分钟采集 · 保留30天 · 当前') + lineCount + gettext('行') + '</span>';
            }
        },
EOF

# 计算插入行号
ln=$(sed -n '/pveversion/,+10{/},/{=;q}}' $pvemanagerlib)

# 在实际修改前检查行号是否有效, 若无效则报错退出停止修改
if ! [[ "$ln" =~ ^[0-9]+$ ]]; then
    echo "⛔ 在 $pvemanagerlib 中计算插入位置失败, 操作终止!"
    rm -f "$tmpf2"
    echo -e "⚠️ 锚点'pveversion', 文件可能已更新或与当前版本不兼容"
    echo && exit 1
fi

# 应用更改
sed -i "${ln}r $tmpf2" "$pvemanagerlib"

# 验证修改是否成功
if grep -q "itemId: 'cpupower'" "$pvemanagerlib"; then
    echo "已完成修改: $pvemanagerlib ✅"
else
    echo "⛔ 检查对 $pvemanagerlib 添加的内容未生效!"
    rm -f "$tmpf2"
    echo -e "⚠️ 请检查文件权限或手动检查文件内容"
    echo && exit 1
fi

rm -f "$tmpf2"



# 强制概要页面监控信息右对齐
patch_widgets=(
    "widget.pveDcGuests"
    "widget.pveNodeStatus"
)

for widget_alias in "${patch_widgets[@]}"; do
    # 寻找起始行
    start_line=$(sed -n "/$widget_alias/=" "$pvemanagerlib" | head -n1)

    [ -z "$start_line" ] && echo "错误: 修补点不存在 ($widget_alias) ⛔ " && continue

    # 在目标后20行内寻找关键字
    rel_line=$(sed -n "$((start_line)),+$((20))p" "$pvemanagerlib" \
        | sed -n "/width: '100%'/=" \
        | head -n1)

    [ -z "$rel_line" ] && echo "错误: 未找到关键字 ($widget_alias) ⛔ " && continue

    target_line=$((start_line + rel_line - 1))

    # 检查是否已经存在
    next_line=$(sed -n "$((target_line+1))p" "$pvemanagerlib")

    if echo "$next_line" | grep -q "^[[:space:]]*textAlign: 'right',"; then
        echo "警告: 修补点已存在 ($widget_alias) ⚠️"
        continue
    fi

    # 插入更改
    sed -i "${target_line}a\\$(sed -n "${target_line}s/^\([[:space:]]*\).*/\1/p" "$pvemanagerlib")textAlign: 'right'," "$pvemanagerlib"

done

echo && sleep 0.5

####################   zh-CN 本地化   ####################

echo -e "🌏 正在完善 zh-CN 中文本地化:"

pve_major_ver=$(echo "$pvever" | cut -d'.' -f1)
pve_i18n_CN="/usr/share/pve-i18n/pve-lang-zh_CN.js"

case "$pve_major_ver" in
    "8")
        # PVE 8: 添加缺失的中文翻译项目
        echo -e "正在检查并补全 PVE 8 缺失的中文翻译..."

        PVE8_TRANSLATIONS=(
            '"599449289":["传入"]'
            '"669411099":["发送"]'
        )

        # 前置锚点检查
        if ! grep -q "^__proxmox_i18n_msgcat__ =" "$pve_i18n_CN"; then
            echo -e "⛔ 未找到翻译字典中的锚点 (__proxmox_i18n_msgcat__ =), 操作终止!"
            echo -e "⚠️ 文件可能已更新或与当前版本不兼容."
            echo && exit 1
        fi
        
        # 开始逐条处理翻译项目
        for item in "${PVE8_TRANSLATIONS[@]}"; do
            # 提取哈希值作为唯一检查标识
            hash_id=$(echo "$item" | cut -d'"' -f2)
            # 提取中文翻译文本用于日志输出
            zh_text=$(echo "$item" | cut -d'"' -f4)

            # 首先检查哈希值在字典中是否已经存在
            if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                echo -e "已存在 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ➡️"
            else
                # 开始执行单次插入
                # 在 }; 前插入一个逗号, 加上当前项目后再闭合 };
                sed -i "/^__proxmox_i18n_msgcat__ =/ s/};$/,${item}\};/" "$pve_i18n_CN"
                
                # 完成后验证插入结果
                if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                    echo -e "已添加 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ✅"
                else
                    echo -e "未生效 PVE 8 中缺失的中文翻译: [$hash_id] => $zh_text ⛔"
                fi
            fi
        done

        # PVE 8: 补全缺失的fieldTitles
        patch_titles=(
            "netin netout|Incoming Outgoing"
            "diskread diskwrite|Reads Writes"
        )

        for item in "${patch_titles[@]}"; do
            IFS='|' read -r fields_en titles_en <<< "$item"
            read -r f1 f2 <<< "$fields_en"
            read -r t1 t2 <<< "$titles_en"

            fields_anchor="fields: ['$f1', '$f2']"
            titles_insert="fieldTitles: [gettext('$t1'), gettext('$t2')]"

            fields_label="$f1/$f2"

            # 前置锚点检查
            if ! grep -Fq "$fields_anchor" "$pvemanagerlib"; then
                echo -e "⛔ 未找到 $fields_label 的锚点, 操作终止!"
                echo -e "⚠️ 锚点 \"fields: ['$f1', '$f2']\", 文件可能已更新或与当前版本不兼容."
                echo && exit 1
            fi

            # 检查fieldTitles在文件中是否已经存在
            if grep -Fq "$titles_insert" "$pvemanagerlib"; then
                echo -e "$fields_label 图表按钮的中文翻译已被修正, 跳过该步骤 ➡️"
                continue
            fi

            # 执行插入操作
            sed -i "s/^\([[:space:]]*\)fields: \['$f1', '$f2'\],/&\n\1$titles_insert,/" "$pvemanagerlib"

            # 完成后验证插入结果
            if grep -Fq "$titles_insert" "$pvemanagerlib"; then
                echo -e "已添加 PVE 8 中缺失的字段标题: $fields_label => $t1/$t2 ✅"
            else
                echo -e "未生效 PVE 8 中缺失的字段标题: $fields_label => $t1/$t2 ⛔"
            fi
        done
        ;;
    "9")
        # PVE 9: 添加缺失的中文翻译项目
        echo -e "正在检查并补全 PVE 9 缺失的中文翻译..."

        PVE9_TRANSLATIONS=(
            '"1208454600":["平均值"]'
            '"1653956129":["最大值"]'
            '"871356310":["服务器负载"]'
            '"1299201244":["网络流量"]'
            '"755456338":["CPU 压力停滞"]'
            '"858045066":["IO 压力停滞"]'
            '"431218371":["内存压力停滞"]'
            '"1102487829":["内存使用率"]'
            '"517429357":["主机内存使用量"]'
            '"1075229421":["主机内存使用量"]'
        )

        # 全局前置检查：确保翻译字典的锚点行确实存在
        if ! grep -q "^__proxmox_i18n_msgcat__ =" "$pve_i18n_CN"; then
            echo -e "⛔ 未找到翻译字典中的锚点 (__proxmox_i18n_msgcat__ =), 操作终止!"
            echo -e "⚠️ 文件可能已更新或与当前版本不兼容."
            echo && exit 1
        fi
        
        # 开始逐条处理翻译项目
        for item in "${PVE9_TRANSLATIONS[@]}"; do
            # 提取哈希值作为唯一检查标识
            hash_id=$(echo "$item" | cut -d'"' -f2)
            # 提取中文翻译文本用于日志输出
            zh_text=$(echo "$item" | cut -d'"' -f4)

            # 首先检查哈希值在字典中是否已经存在
            if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                echo -e "已存在 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ➡️"
            else
                # 开始执行单次插入
                # 在 }; 前插入一个逗号, 加上当前项目后再闭合 };
                sed -i "/^__proxmox_i18n_msgcat__ =/ s/};$/,${item}\};/" "$pve_i18n_CN"
                
                # 完成后验证插入结果
                if grep -q "\"$hash_id\":" "$pve_i18n_CN"; then
                    echo -e "已添加 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ✅"
                else
                    echo -e "未生效 PVE 9 中缺失的中文翻译: [$hash_id] => $zh_text ⛔"
                fi
            fi
        done
        ;;
    *)
        echo -e "⚠️ 不支持的PVE版本 ($pvever) 跳过 zh-CN 本地化."
        ;;
esac

echo && sleep 0.5

####################   调整页面高度   ####################

echo -e "🎚️ 正在调整概要页面高度 (固定高度改为最小高度, 面板随内容自适应):"

# PVE 原状态面板使用固定 height。按行数估算写死高度并不可靠:
# 硬盘数量变化、SMART 预警换行、长型号换行、浏览器缩放都会使实际内容超出,
# 进而裁切面板下方的"软件源状态"等行。改为 minHeight:
# 保留 PVE 默认最小高度, 同时允许面板由内容自然撑开, 不再遮挡任何行。
# 范围限定在 PVE.node.StatusView 类定义内, 只替换其首个 height 属性。
# 区间终点 [Hh]eight: 同时匹配 "height:" 与已替换出的 "minHeight:",
# 因此未修改时命中数字型 height 才替换; 已替换过则天然跳过, 重复执行幂等,
# 也不会误伤后续其它组件的 height
status_block=$(sed -n "/Ext.define('PVE.node.StatusView'/,/[Hh]eight:/p" "$pvemanagerlib")
if echo "$status_block" | grep -Eq '^[[:space:]]*height:[[:space:]]*[0-9]+,'; then
    sed -i -E "/Ext.define\('PVE.node.StatusView'/,/[Hh]eight:/{s/^([[:space:]]*)height: *[0-9]+,/\1minHeight: 300,/}" "$pvemanagerlib"
    if sed -n "/Ext.define('PVE.node.StatusView'/,/[Hh]eight:/p" "$pvemanagerlib" | grep -q 'minHeight: 300,'; then
        echo "已将状态面板固定高度改为 minHeight: 300 (内容自适应, 不会再遮挡软件源状态行) ✅"
    else
        echo "⚠️ 状态面板高度替换未生效, 请检查 $pvemanagerlib 版本是否兼容"
    fi
else
    echo "未发现待替换的固定 height 属性 (可能已调整过), 跳过 ➡️"
fi

echo && sleep 0.5

####################   修改全部完成后重启服务   ####################

echo -e "🔁 等待服务 pveproxy.service 重启..."
timeout 10s systemctl restart pveproxy.service &> /dev/null
restart_status=$?
if [ $restart_status -ne 0 ]; then
    if [ $restart_status -eq 124 ]; then
        echo -e "\n⛔ 重启服务 pveproxy.service 超时 (timeout 10s)"
    else
        echo -e "\n⛔ 重启服务 pveproxy.service 失败 ($restart_status)"
    fi
    echo -e "\n⚠️ 请检查服务状态信息以排查问题\n"
    systemctl status pveproxy.service --no-pager
    echo && exit 1
fi

echo -e "\n✅ 修改完成, 请使用 Ctrl + F5 刷新浏览器 Proxmox VE Web 管理页面缓存"
echo -e "📜 硬件监控日志: /var/log/pve-hardware/hardware.log (每5分钟采集, 概要页「硬件监控日志」行可点击查看, 日志保留30天)\n"
