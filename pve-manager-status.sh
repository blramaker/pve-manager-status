#!/bin/bash
# pve-manager-status.sh
# Last Modified: 2026-09-16 (SATA fix + 硬件监控日志采集/界面日志查看; 日志纯ASCII化修复弹窗乱码)

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

# 采集脚本: 由 cron 每12小时以 root 调用, 仅记录硬件指标 (不含序列号等敏感信息)
cat > "$HWLOG_SCRIPT" << 'LOGEOF'
#!/bin/bash
# pve-hardware-log.sh - 硬件监控信息定时采集 (由 pve-manager-status.sh 安装维护)
# 调用方: /etc/cron.d/pve-hardware-log (每12小时, 00:00/12:00)
# 输出:   /var/log/pve-hardware/hardware.log (logrotate 每日轮转, 保留180天)

LOGDIR="/var/log/pve-hardware"
LOGFILE="$LOGDIR/hardware.log"
mkdir -p "$LOGDIR"

# 日志必须为纯 ASCII: cron 环境无 LANG, 且经 Perl backtick/PVE API/浏览器多段
# 字节链路传输, 任何非 ASCII 字节(中文/度数符号等)都可能因编码假设不一致而乱码。
# LC_ALL=C 让 smartctl/sensors 等子进程输出确定的英文/ASCII; 末尾再用 tr 兜底,
# 物理上保证写入文件的每个字节 < 128, 乱码不可能发生。
export LC_ALL=C

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
            echo "$d: STANDBY (disk asleep, SMART skipped)"
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
        for spec in "5 Reallocated_Sector:Reallocated" "197 Current_Pending_Sector:PendingSector" "198 Offline_Uncorrectable:OfflineUncorrect" "187 Reported_Uncorrect:ReportedUncorrect" "199 UDMA_CRC_Error_Count:UDMA_CRC"; do
            id="${spec%% *}"
            name="${spec#*:}"
            v="$(printf '%s' "$info" | ata_raw "$id")"
            if [ -n "$v" ] && [ "$v" -ne 0 ] 2>/dev/null; then
                warns="${warns}${name}=${v};"
            fi
        done
        echo "$d ${model:-UNKNOWN-MODEL}: ${temp:-N/A}C POH=${hours:-N/A}h SMART=${health:-N/A}${warns:+ WARN[$warns]}"
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
        echo "$d ${model:-UNKNOWN-MODEL}: ${temp:-N/A}C POH=${hours:-N/A}h LifeLeft=${life} SMART=${health:-N/A}"
    done

    echo ""
# tr 兜底: 无论 smartctl/sensors/型号字段吐出什么非 ASCII 字节, 一律剥除,
# 只保留制表符/换行/回车和可打印 ASCII (八进制 11 12 15 40-176)
} 2>&1 | LC_ALL=C tr -cd '\11\12\15\40-\176' >> "$LOGFILE"
LOGEOF
chmod 0755 "$HWLOG_SCRIPT"

# cron 定时任务: 每12小时采集一次 (每天 00:00 与 12:00)
cat > /etc/cron.d/pve-hardware-log << 'CRONEOF'
# pve-hardware-log - 硬件监控信息定时采集 (由 pve-manager-status.sh 维护)
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 */12 * * * root /usr/local/bin/pve-hardware-log.sh
CRONEOF
chmod 0644 /etc/cron.d/pve-hardware-log

# 日志轮转: 每日一次, 压缩保留180天
cat > /etc/logrotate.d/pve-hardware-log << 'ROTEOF'
# pve-hardware-log logrotate config (由 pve-manager-status.sh 维护)
/var/log/pve-hardware/hardware.log {
    daily
    rotate 180
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
ROTEOF
chmod 0644 /etc/logrotate.d/pve-hardware-log

# 旧版日志可能含非 ASCII 字节(中文/度数符号), 在弹窗中显示为乱码。
# 检测到非纯 ASCII 的旧日志时归档一次, 由下方首次采集重建为纯 ASCII 日志。
if [ -s "$HWLOG_DIR/hardware.log" ] && LC_ALL=C grep -q '[^[:print:][:space:]]' "$HWLOG_DIR/hardware.log"; then
    mv "$HWLOG_DIR/hardware.log" "$HWLOG_DIR/hardware.log.garbled.$(date +%Y%m%d%H%M%S)"
    echo -e "  检测到含非 ASCII 字符的旧日志(弹窗会乱码), 已归档为 *.garbled.* 并重建 ✅"
fi

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

        my $cpufreqs = `lscpu | grep MHz`;
        my $threadfreqs = `cat /proc/cpuinfo | grep -i "cpu MHz"`;
        my $cpugov = `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`;
        my $cpupkgw = `sudo turbostat -S -q -s PkgWatt -i 0.1 -n 1 -c package 2>/dev/null | grep -v PkgWatt`;
        $res->{cpufreq} = $cpufreqs . $threadfreqs . "PVE_GOVERNOR: " . $cpugov . "PVE_PKGWATT: " . $cpupkgw;

        $res->{sensors} = `sudo sensors`;
EOF

for x in {0..9}; do
    for dev in "/dev/nvme${x}" "/dev/nvme${x}n1"; do
        if [ -b "$dev" ]; then
            cat >> "$tmpf1" << EOF

        my \$nvme${x}_info = \`sudo smartctl -a $dev | grep -E "Model Number|(?=Total|Namespace)[^:]+Capacity|Temperature:|Available Spare:|Percentage|Data Unit|Power Cycles|Power On Hours|Unsafe Shutdowns|Integrity Errors|SMART overall-health"\`;
        \$res->{nvme${x}_status} = \$nvme${x}_info;
EOF
            break
        fi
    done
done

cat >> "$tmpf1" << 'EOF'

        $res->{sata_status} = `for d in /dev/sd[a-z]; do [ -b "\$d" ] || continue; echo "===\$d==="; sudo smartctl -n standby -a "\$d" 2>/dev/null || true; bn=\$(basename "\$d"); awk -v dn="\$bn" '\$3==dn { print "PVESTATS:", \$6, \$10 }' /proc/diskstats; done | grep -Ei '^===|model|vendor|product:|user capacity|power_on_hours|power_cycle_count|power on|powered up|drive temperature|temperature|smart overall|smart health|rotation rate|solid state|standby|reallocated|pending|uncorrect|udma_crc|power-off|retract|emergency|pvestats'`;

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
if grep -q 'PVE_GOVERNOR' "$nodes"; then
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
            itemId: 'cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率(GHz)'),
            textField: 'cpufreq',
            renderer:function(value){
                const gz = (mhz) => (parseFloat(mhz) / 1000).toFixed(1);

                // 每核当前频率 (/proc/cpuinfo: cpu MHz : xxxx)
                const cores = [];
                let mm;
                const reCore = /^cpu MHz\s*:\s*([\d.]+)/gm;
                while ((mm = reCore.exec(value))) cores.push(parseFloat(mm[1]));

                // lscpu 标称范围 + 后端附带的调速器/封装功耗
                const minMhz = (value.match(/CPU min MHz\s*:\s*([\d.]+)/i) || [])[1];
                const maxMhz = (value.match(/CPU max MHz\s*:\s*([\d.]+)/i) || [])[1];
                const gov = (value.match(/PVE_GOVERNOR:\s*(\S+)/) || [])[1];
                const pkgw = (value.match(/PVE_PKGWATT:\s*([\d.]+)/) || [])[1];

                const parts = [];
                if (cores.length) {
                    const avg = cores.reduce((a, b) => a + b, 0) / cores.length;
                    const lo = Math.min.apply(null, cores);
                    const hi = Math.max.apply(null, cores);
                    parts.push(`${cores.length}核心 平均: <strong>${gz(avg)} GHz</strong> (当前: ${gz(lo)}~${gz(hi)})`);
                }
                if (minMhz && maxMhz) parts.push(`范围: ${gz(minMhz)}~${gz(maxMhz)} GHz`);
                if (pkgw) parts.push(`功耗: <strong>${parseFloat(pkgw).toFixed(1)}W</strong>`);
                if (gov) parts.push(`调速器: <strong>${gov.toUpperCase()}</strong>`);
                return parts.length ? parts.join(' | ') : '无法获取CPU频率信息';
            }
        },
        {
            itemId: 'sensors',
            colspan: 2,
            printBar: false,
            title: gettext('CPU温度'),
            textField: 'sensors',
            renderer: function(value) {
                value = (value || '').replace(/Â/g, '');
                const cTemp = (t) => {
                    const n = parseFloat(t);
                    const c = (n < 60) ? 'green' : ((n < 80) ? 'orange' : '#e04b4b');
                    return `<span style="color:${c};font-weight:bold;">${Math.round(n)}°C</span>`;
                };

                // 封装温度: Intel "Package id N", AMD "Tctl"/"Tdie"
                let mp = value.match(/Package id\s*\d+\s*:\s*\+?([\d.]+)/i)
                      || value.match(/^(?:Tctl|Tdie)\s*:\s*\+?([\d.]+)/im);
                const pkg = mp ? parseFloat(mp[1]) : NaN;

                // 各核心温度 (Core N), AMD 无 Core 行时用 Tdie/Tctl 充当
                const cores = [];
                let mc;
                const reCore = /^Core\s*\d+\s*:\s*\+?([\d.]+)/gim;
                while ((mc = reCore.exec(value))) cores.push(parseFloat(mc[1]));
                if (!cores.length && !isNaN(pkg) && /Tdie|Tctl/i.test(value)) cores.push(pkg);

                // 临界温度 crit
                const mcrit = value.match(/\bcrit(?:ical)?\s*=\s*\+?([\d.]+)/i);
                const crit = mcrit ? parseFloat(mcrit[1]) : NaN;

                const parts = [];
                if (!isNaN(pkg)) parts.push(`封装: ${cTemp(pkg)}`);
                if (cores.length) {
                    const avg = cores.reduce((a, b) => a + b, 0) / cores.length;
                    let s = `核心: 平均 ${cTemp(avg)}`;
                    if (cores.length > 1) {
                        const lo = Math.round(Math.min.apply(null, cores));
                        const hi = Math.round(Math.max.apply(null, cores));
                        s += ` (${lo}°C~${hi}°C)`;
                    }
                    parts.push(s);
                }
                if (!isNaN(crit)) parts.push(`临界: <span style="color:#e04b4b;font-weight:bold;">${Math.round(crit)}°C</span>`);

                // 核显温度 (AMD edge/junction 或 Intel GFX), 有则追加
                const mg = value.match(/(?:edge|junction|GFX|Graphics)[^+\n]*?\+?([\d.]+)/i);
                if (mg) parts.push(`核显: ${cTemp(mg[1])}`);

                // 风扇转速 (非零), 有则追加
                const fans = [];
                let mf;
                const reFan = /^fan\d+\s*:\s*(\d+)\s*RPM/gim;
                while ((mf = reFan.exec(value))) {
                    if (parseInt(mf[1], 10) > 0) fans.push(mf[1]);
                }
                if (fans.length) parts.push(`风扇: <strong>${fans.slice(0, 3).join('/')}转</strong>`);

                return parts.length ? parts.join(' | ') : '未获取到温度信息';
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
            title: gettext('NVME${x}'),
            textField: 'nvme${x}_status',
            renderer:function(value){
                value = (value || '').replace(/Â/g, '');
                const get = (re) => { const m = value.match(re); return m ? m[1].trim() : ''; };
                const cTemp = (t) => {
                    const n = parseFloat(t);
                    const c = n < 50 ? 'green' : (n < 70 ? 'orange' : '#e04b4b');
                    return \`<span style="color:\${c};font-weight:bold;">\${Math.round(n)}°C</span>\`;
                };
                const cLife = (v) => {
                    const n = parseFloat(v);
                    const c = n < 50 ? '#e04b4b' : (n < 80 ? 'orange' : 'green');
                    return \`<span style="color:\${c};font-weight:bold;">\${Math.round(n)}%</span>\`;
                };
                const cBad = (v) => \`<span style="color:#e04b4b;font-weight:bold;">\${v}</span>\`;
                // smartctl 方括号内人类可读容量统一换算成 T
                const toTB = (s) => {
                    const n = parseFloat(s.replace(/,/g, ''));
                    if (isNaN(n)) return s.trim();
                    if (/TB/i.test(s)) return n.toFixed(1) + 'T';
                    if (/GB/i.test(s)) return (n / 1024).toFixed(1) + 'T';
                    if (/MB/i.test(s)) return (n / 1048576).toFixed(1) + 'T';
                    return String(n);
                };

                const model = get(/^Model Number:\s*(.+)$/m);
                if (!model) return '<span style="color:#888;">未检测到硬盘（可能已直通或移除）</span>';

                const temp = get(/^Temperature:\s*(\d+)/m);
                const usedS = get(/^Percentage Used:\s*([\d.]+)/m);
                const life = (usedS === '') ? '' : String(Math.round(100 - parseFloat(usedS)));
                const unsafe = get(/^Unsafe Shutdowns:\s*([\d,]+)/m).replace(/,/g, '');
                const rd = get(/^Data Units Read:[^\[]*\[([^\]]+)\]/m);
                const wr = get(/^Data Units Written:[^\[]*\[([^\]]+)\]/m);
                const hours = get(/^Power On Hours:\s*([\d,]+)/m).replace(/,/g, '');
                const cycles = get(/^Power Cycles:\s*([\d,]+)/m).replace(/,/g, '');
                const integ = get(/^Media and Data Integrity Errors:\s*([\d,]+)/m).replace(/,/g, '');
                const spare = get(/^Available Spare:\s*(\d+%)/m);
                const hm = value.match(/SMART overall-health[^\n:]*:\s*(\w+)/i);
                const healthOK = hm ? (/^(PASSED|OK)$/.test(hm[1].toUpperCase())) : null;

                // 与 SATA 行完全一致的 7 列固定布局, 保证上下纵向对齐
                const COLS = '<colgroup>' +
                    '<col style="width:230px"><col style="width:95px"><col style="width:165px">' +
                    '<col style="width:85px"><col style="width:185px"><col style="width:95px">' +
                    '<col style="width:110px"></colgroup>';
                const td = (h) => \`<td style="padding:0 8px;text-align:center;white-space:nowrap;border-left:1px solid #cfcfcf;">\${h}</td>\`;
                const rows = [
                    \`<tr><td style="padding:0 8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;" title="\${model}"><strong>\${model}</strong></td>\`,
                    td(life !== '' ? \`健康: \${cLife(life)}\` : ''),
                    td((rd || wr) ? \`读写: \${rd ? toTB(rd) : '-'} / \${wr ? toTB(wr) : '-'}\` : ''),
                    td(temp ? \`温度: \${cTemp(temp)}\` : ''),
                    td((hours || cycles) ? \`通电: \${hours ? hours + '时' : ''}\${cycles ? ',次: ' + cycles : ''}\` : ''),
                    td(healthOK !== null ? (healthOK
                        ? 'SMART: <span style="color:green;font-weight:bold;">正常</span>'
                        : 'SMART: <span style="color:#e04b4b;font-weight:bold;">警告</span>') : ''),
                    td(unsafe !== '' ? ((parseInt(unsafe, 10) !== 0)
                        ? \`异常断电: \${cBad(unsafe)}\` : \`异常断电: \${unsafe}\`) : '')
                ];

                // 错误信息独占第二行, 从第5列(通电)开始, 与 SATA 行错误对齐
                const errs = [];
                if (integ !== '' && parseInt(integ, 10) !== 0) {
                    errs.push(cBad(\`完整性错误: \${integ}\` + (spare ? \` (备用空间\${spare})\` : '')));
                }
                if (healthOK === false) errs.push(cBad('SMART 自检未通过'));
                if (errs.length) {
                    rows.push(\`</tr><tr><td colspan="4" style="border-left:none;"></td><td colspan="3" style="padding:0 8px;text-align:left;white-space:nowrap;">\${errs.join(' ')}</td>\`);
                }
                return \`<table style="border-collapse:collapse;width:100%;table-layout:fixed;font-size:12px;line-height:22px;">\${COLS}<tbody>\${rows.join('')}</tr></tbody></table>\`;
            }
        },
EOF
            break
        fi
    done
done

# SATA 硬盘: 注入时按实际存在的 /dev/sd* 逐盘生成独立行, SSD/HDD 分类独立编号
__sata_ssd=0
__sata_hdd=0
__sata_first=1
for __d in /dev/sd[a-z]; do
    [ -b "$__d" ] || continue
    __ident="$("$SMARTCTL_PATH" -i "$__d" 2>/dev/null)"
    if printf '%s' "$__ident" | grep -qi 'Solid State Device'; then
        __title="固态硬盘$__sata_ssd"; __sata_ssd=$((__sata_ssd + 1))
    elif printf '%s' "$__ident" | grep -Eq 'Rotation Rate:[[:space:]]*[0-9]'; then
        __title="机械硬盘$__sata_hdd"; __sata_hdd=$((__sata_hdd + 1))
    else
        __title="硬盘${__d#/dev/}"
    fi

    if [ "$__sata_first" -eq 1 ]; then
        __sata_first=0
        cat >> "$tmpf2" << EOF
        {
            itemId: 'sata-${__d#/dev/}',
            colspan: 2,
            printBar: false,
            title: gettext('$__title'),
            textField: 'sata_status',
            renderer: function(value) {
                if (!window.__pveSata) {
                    window.__pveSata = function(dev, raw) {
                        raw = (raw || '').replace(/Â/g, '');
                        var cT = function(t) {
                            var n = parseFloat(t);
                            var c = n < 50 ? 'green' : (n < 60 ? 'orange' : '#e04b4b');
                            return \`<span style="color:\${c};font-weight:bold;">\${Math.round(n)}°C</span>\`;
                        };
                        var red = function(v) { return \`<span style="color:#e04b4b;font-weight:bold;">\${v}</span>\`; };
                        var grn = function(v) { return \`<span style="color:green;font-weight:bold;">\${v}</span>\`; };
                        var cLife = function(v) {
                            var c = v < 50 ? '#e04b4b' : (v < 80 ? 'orange' : 'green');
                            return \`<span style="color:\${c};font-weight:bold;">\${v}%</span>\`;
                        };

                        var chunks = raw.split(/^(===\/dev\/sd[a-z]+===)\$/m);
                        var block = '';
                        for (var i = 1; i < chunks.length; i += 2) {
                            if (chunks[i].replace(/=/g, '') === dev) { block = chunks[i + 1] || ''; break; }
                        }
                        if (!block) return '<span style="color:#888;">未检测到硬盘（可能已直通或移除）</span>';
                        var COLS = '<colgroup>' +
                            '<col style="width:230px"><col style="width:95px"><col style="width:165px">' +
                            '<col style="width:85px"><col style="width:185px"><col style="width:95px">' +
                            '<col style="width:110px"></colgroup>';
                        var tbl = function(inner) {
                            return \`<table style="border-collapse:collapse;width:100%;table-layout:fixed;font-size:12px;line-height:22px;">\${COLS}<tbody><tr>\${inner}</tr></tbody></table>\`;
                        };
                        if (/STANDBY/i.test(block)) {
                            return tbl(\`<td style="padding:0 8px;white-space:nowrap;"><strong>\${dev}</strong></td><td colspan="6" style="padding:0 8px;text-align:left;white-space:nowrap;color:#888;border-left:1px solid #cfcfcf;">休眠中（未唤醒读取SMART）</td>\`);
                        }

                        var g = function(re) { var m = block.match(re); return m ? m[1].trim() : ''; };
                        var family = g(/Model Family:\s*(.+)/);
                        var dmodel = g(/Device Model:\s*(.+)/);
                        var mnumber = g(/Model Number:\s*(.+)/);
                        var vendor = g(/^Vendor:\s*(.+)/m);
                        var product = g(/^Product:\s*(.+)/m);
                        var model = dmodel || mnumber || '';
                        if (dmodel && family && family !== '-' && family !== dmodel && dmodel.indexOf(family) === -1) {
                            model = family + ' - ' + dmodel;
                        }
                        if (!model && (vendor || product)) model = (vendor + ' ' + product).replace(/\s+/g, ' ').trim();
                        if (!model) model = dev;

                        var temp = g(/^\s*194\s+\S+\s+.*?-\s*(\d+)/m)
                                || g(/^\s*190\s+\S+\s+.*?-\s*(\d+)/m)
                                || g(/Current Drive Temperature:\s*(\d+)/i)
                                || g(/^Temperature:\s*(\d+)/m);
                        var hours = g(/^\s*9\s+Power_On_Hours\b.*?-\s*(\d+)/m);
                        if (!hours) {
                            var mh = block.match(/number of hours power[^\d=]*=\s*([\d.]+)/i)
                                  || block.match(/Accumulated power on time[^\d]*(\d+)/i);
                            if (mh) hours = mh[1];
                        }
                        var cycles = g(/^\s*12\s+Power_Cycle_Count\b.*?-\s*(\d+)/m);
                        var unsafe = g(/^\s*192\s+\S+.*?-\s*(\d+)/m);
                        // /proc/diskstats: 字段6=累计读扇区, 字段10=累计写扇区 (每扇区512字节, 开机以来)
                        var mIO = block.match(/^PVESTATS:\s*(\d+)\s+(\d+)/m);
                        var ioText = '';
                        if (mIO) {
                            var secToTB = function(sec) { return (sec * 512 / 1e12).toFixed(1) + 'T'; };
                            ioText = \`读写: \${secToTB(mIO[1])} / \${secToTB(mIO[2])}\`;
                        }
                        var hm = block.match(/SMART overall-health[^\n:]*:\s*(\w+)/i)
                              || block.match(/SMART Health Status:\s*(\w+)/i);
                        var healthOK = hm ? (/^(PASSED|OK)\$/.test(hm[1].toUpperCase())) : null;

                        // ATA 关键健康属性原始值 (HDD 无固件磨损百分比, 由这些属性估算健康度)
                        var attrV = function(re) {
                            var mA = block.match(re);
                            return mA ? parseInt(mA[1], 10) : null;
                        };
                        var v5   = attrV(/^\s*5\s+Reallocated_Sector_Ct\b.*?-\s*(\d+)/m);
                        var v197 = attrV(/^\s*197\s+Current_Pending_Sector\b.*?-\s*(\d+)/m);
                        var v198 = attrV(/^\s*198\s+Offline_Uncorrectable\b.*?-\s*(\d+)/m);
                        var v187 = attrV(/^\s*187\s+Reported_Uncorrect\b.*?-\s*(\d+)/m);
                        var v199 = attrV(/^\s*199\s+UDMA_CRC_Error_Count\b.*?-\s*(\d+)/m);
                        var ataHealth = (v5 !== null || v197 !== null || v198 !== null || v187 !== null);
                        var life = 100;
                        if (v5)   life -= Math.min(v5 * 2, 40);    // 重映射扇区
                        if (v197) life -= Math.min(v197 * 5, 30);   // 待映射扇区
                        if (v198) life -= Math.min(v198 * 10, 60);  // 无法纠正扇区
                        if (v187) life -= Math.min(v187, 20);       // 报告性不可纠正
                        if (healthOK === false) life = 0;           // SMART 整体自检失败
                        life = Math.max(0, life);

                        // 与 NVMe 行完全一致的 7 列固定布局; 机械盘无读写数据, 该列留空占位
                        var td = function(h) {
                            return \`<td style="padding:0 8px;text-align:center;white-space:nowrap;border-left:1px solid #cfcfcf;">\${h}</td>\`;
                        };
                        var tds = [
                            \`<td style="padding:0 8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;" title="\${model}"><strong>\${model}</strong></td>\`,
                            td(ataHealth ? \`<span title="根据SMART关键属性(5/197/198/187)估算">健康(估): \${cLife(life)}</span>\` : ''),
                            td(ioText),
                            td(temp ? \`温度: \${cT(temp)}\` : ''),
                            td((hours || cycles) ? \`通电: \${hours ? hours + '时' : ''}\${cycles ? ',次: ' + cycles : ''}\` : ''),
                            td(healthOK !== null ? (healthOK ? \`SMART: \${grn('正常')}\` : \`SMART: \${red('警告')}\`) : ''),
                            td((unsafe !== '' && parseInt(unsafe, 10) !== 0) ? \`异常断电: \${red(unsafe)}\` : '')
                        ];

                        // 非零预警属性移到第二行 (CRC 199 是线材/接口问题, 不计入健康扣分)
                        var alerts = [];
                        if (v5)   alerts.push('重映射扇区:' + v5);
                        if (v197) alerts.push('待映射扇区:' + v197);
                        if (v198) alerts.push('无法纠正扇区:' + v198);
                        if (v187) alerts.push('不可纠正:' + v187);
                        if (v199) alerts.push('CRC接口错误:' + v199 + '(多为SATA线问题)');
                        if (healthOK === false) alerts.unshift('SMART 自检未通过');
                        var inner = tds.join('') + '</tr>';
                        if (alerts.length) {
                            inner += \`<tr><td colspan="4" style="border-left:none;"></td><td colspan="3" style="padding:0 8px;text-align:left;white-space:nowrap;">\${red('⚠ ' + alerts.join(' '))}</td>\`;
                        }
                        return \`<table style="border-collapse:collapse;width:100%;table-layout:fixed;font-size:12px;line-height:22px;">\${COLS}<tbody><tr>\${inner}</tr></tbody></table>\`;
                    };
                }
                return window.__pveSata('$__d', value);
            }
        },
EOF
    else
        cat >> "$tmpf2" << EOF
        {
            itemId: 'sata-${__d#/dev/}',
            colspan: 2,
            printBar: false,
            title: gettext('$__title'),
            textField: 'sata_status',
            renderer: function(value) {
                return (window.__pveSata || function(){ return ''; })('$__d', value);
            }
        },
EOF
    fi
done

# 无任何 SATA 盘时给一个灰字占位行
if [ "$__sata_first" -eq 1 ]; then
    cat >> "$tmpf2" << 'EOF'
        {
            itemId: 'sata_status',
            colspan: 2,
            printBar: false,
            title: gettext('SATA硬盘'),
            textField: 'sata_status',
            renderer: function() {
                return '<span style="color:#888;">未检测到硬盘（可能已直通或移除）</span>';
            }
        },
EOF
fi

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
                     + gettext('每12小时采集 · 保留180天 · 当前') + lineCount + gettext('行') + '</span>';
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

# 验证修改是否成功 (cpufreq 是注入块首行的唯一标记, 旧版 cpupower 已合并删除)
if grep -q "itemId: 'cpufreq'" "$pvemanagerlib"; then
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
echo -e "📜 硬件监控日志: /var/log/pve-hardware/hardware.log (每12小时采集, 概要页「硬件监控日志」行可点击查看, 日志保留180天)\n"
