#!/bin/bash
# 飞牛OS虚拟机QCow2备份Shell脚本（全交互式定时任务版）
# 用法：
#   1. 交互式备份：sudo ./vm_backup.sh
#   2. 一键备份全部：sudo ./vm_backup.sh -v
#   3. 交互式定时任务管理：sudo ./vm_backup.sh -c
# 特性：全可视化菜单、无需编写时间格式、root权限保障、后台运行不中断

# ===================== 配置项 =====================
# 备份目标目录（请修改为实际路径）
BACKUP_DIR="/vol4/1000/12T存储（重要文件）/虚拟机备份"
# 保留最新备份份数
KEEP_BACKUP_COUNT=3
# 虚拟机关机超时时间（秒）
SHUTDOWN_TIMEOUT=120
# 虚拟机开机等待时间（秒）
BOOT_WAIT_TIME=30
# 备份日志文件
LOG_FILE="/var/log/vm_backup.log"
# 定时任务日志文件
CRON_LOG_FILE="/var/log/vm_backup_cron.log"
# 脚本绝对路径（自动识别）
SCRIPT_PATH=$(readlink -f "$0")
# 备份文件时间戳
BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)
# ==================== 配置项结束 ====================

# 确保脚本后台运行
ensure_background_run() {
    if [[ ! -n "$VM_BACKUP_BACKGROUND" && "$1" != "interactive" ]]; then
        export VM_BACKUP_BACKGROUND=1
        nohup "$0" "$@" > "${LOG_FILE}" 2>&1 &
        echo "脚本已转入后台运行，日志文件：${LOG_FILE}"
        exit 0
    fi
}

# 日志输出函数
log() {
    local MSG="[$(date +%Y-%m-%d\ %H:%M:%S)] $1"
    echo "${MSG}"
    if [[ -n "$VM_BACKUP_BACKGROUND" ]]; then
        echo "${MSG}" >> "${LOG_FILE}"
    fi
}

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        log "错误：未找到$1命令，请确认已安装"
        exit 1
    fi
}

# 初始化备份目录
init_backup_dir() {
    if [ ! -d "${BACKUP_DIR}" ]; then
        log "创建备份目录：${BACKUP_DIR}"
        mkdir -p "${BACKUP_DIR}" || {
            log "错误：创建备份目录失败"
            exit 1
        }
    fi
}

# 格式化文件大小
format_size() {
    local SIZE=$1
    if [ ${SIZE} -ge 1073741824 ]; then
        echo "$(( SIZE / 1073741824 )) GB"
    elif [ ${SIZE} -ge 1048576 ]; then
        echo "$(( SIZE / 1048576 )) MB"
    elif [ ${SIZE} -ge 1024 ]; then
        echo "$(( SIZE / 1024 )) KB"
    else
        echo "${SIZE} B"
    fi
}

# 获取所有虚拟机详细信息
get_all_vms_detail() {
    log "========================================"
    log "检测到以下虚拟机（含详细信息）："
    log "========================================"
    VM_NAMES=$(virsh list --all --name | grep -v '^$' | sort)
    
    if [ -z "${VM_NAMES}" ]; then
        log "未检测到任何虚拟机"
        exit 0
    fi

    VM_INFO=()
    INDEX=1
    for VM_NAME in ${VM_NAMES}; do
        VM_STATUS=$(virsh list --all | grep -w "${VM_NAME}" | awk '{print $3}')
        [ -z "${VM_STATUS}" ] && VM_STATUS="未知"
        
        QCOW2_PATH=$(virsh dumpxml "${VM_NAME}" | grep 'source file' | grep -o '/.*\.qcow2' | head -1 | sed 's/[ \t]*$//')
        
        if [ -n "${QCOW2_PATH}" ] && [ -f "${QCOW2_PATH}" ]; then
            QCOW2_SIZE=$(stat -c %s "${QCOW2_PATH}")
            QCOW2_SIZE_FORMATTED=$(format_size ${QCOW2_SIZE})
            VM_INFO+=("${VM_NAME}|${VM_STATUS}|${QCOW2_PATH}|${QCOW2_SIZE}|${QCOW2_SIZE_FORMATTED}")
            echo "[$INDEX] 名称：${VM_NAME} | 状态：${VM_STATUS} | 路径：${QCOW2_PATH} | 大小：${QCOW2_SIZE_FORMATTED}"
        else
            QCOW2_SIZE_FORMATTED="未知"
            VM_INFO+=("${VM_NAME}|${VM_STATUS}|${QCOW2_PATH}|0|${QCOW2_SIZE_FORMATTED}")
            echo "[$INDEX] 名称：${VM_NAME} | 状态：${VM_STATUS} | 路径：${QCOW2_PATH} | 大小：${QCOW2_SIZE_FORMATTED}（无效文件）"
        fi
        INDEX=$((INDEX + 1))
    done
    echo ""
}

# 交互式选择虚拟机
select_vm() {
    local VM_COUNT=${#VM_INFO[@]}
    read -p "请输入要备份的虚拟机序号（单个/多个，空格分隔）：" SELECTED_INDEXES
    
    if [ -z "${SELECTED_INDEXES}" ]; then
        log "错误：未输入任何序号"
        exit 1
    fi

    SELECTED_VMS=()
    for INDEX in ${SELECTED_INDEXES}; do
        if ! [[ "${INDEX}" =~ ^[0-9]+$ ]] || [ ${INDEX} -lt 1 ] || [ ${INDEX} -gt ${VM_COUNT} ]; then
            log "错误：序号${INDEX}无效（1-${VM_COUNT}）"
            exit 1
        fi
        ARRAY_INDEX=$((INDEX - 1))
        SELECTED_VMS+=("${VM_INFO[${ARRAY_INDEX}]}")
    done

    echo ""
    log "你选择的虚拟机："
    for VM in "${SELECTED_VMS[@]}"; do
        IFS='|' read -r VM_NAME VM_STATUS _ _ QCOW2_SIZE_FORMATTED <<< "${VM}"
        echo "→ 名称：${VM_NAME} | 状态：${VM_STATUS} | 大小：${QCOW2_SIZE_FORMATTED}"
    done
    echo ""
    read -p "确认备份？(y/n)：" CONFIRM
    if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
        log "取消备份"
        exit 0
    fi
}

# 等待虚拟机关机
wait_vm_shutdown() {
    local VM_NAME=$1
    local START_TIME=$(date +%s)
    
    while [ $(( $(date +%s) - START_TIME )) -lt ${SHUTDOWN_TIMEOUT} ]; do
        VM_STATUS=$(virsh list --all | grep -w "${VM_NAME}" | awk '{print $3}')
        if [[ "${VM_STATUS}" =~ ^(shut|off)$ ]]; then
            log "[${VM_NAME}] 已关机"
            return 0
        fi
        sleep 5
    done
    
    log "[${VM_NAME}] 关机超时"
    return 1
}

# 关闭虚拟机
shutdown_vm() {
    local VM_NAME=$1
    local VM_STATUS=$(virsh list --all | grep -w "${VM_NAME}" | awk '{print $3}')
    
    if [[ "${VM_STATUS}" =~ ^(shut|off)$ ]]; then
        log "[${VM_NAME}] 已关机"
        return 0
    fi

    log "[${VM_NAME}] 优雅关机..."
    if virsh shutdown "${VM_NAME}" &> /dev/null && wait_vm_shutdown "${VM_NAME}"; then
        return 0
    fi

    log "[${VM_NAME}] 强制关机..."
    if virsh destroy "${VM_NAME}" &> /dev/null && wait_vm_shutdown "${VM_NAME}"; then
        return 0
    fi

    log "[${VM_NAME}] 关机失败"
    return 1
}

# 启动虚拟机
start_vm() {
    local VM_NAME=$1
    log "[${VM_NAME}] 开机中..."
    
    if virsh start "${VM_NAME}" &> /dev/null; then
        sleep ${BOOT_WAIT_TIME}
        if virsh list | grep -w "${VM_NAME}" &> /dev/null; then
            log "[${VM_NAME}] 开机成功"
            return 0
        fi
    fi
    
    log "[${VM_NAME}] 开机失败"
    return 1
}

# 备份QCow2文件
backup_qcow2() {
    local VM_NAME=$1
    local QCOW2_PATH=$2
    local BACKUP_FILE="${BACKUP_DIR}/${VM_NAME}_${BACKUP_SUFFIX}.qcow2"

    if [ ! -f "${QCOW2_PATH}" ]; then
        log "[${VM_NAME}] 源文件不存在"
        return 1
    fi

    log "[${VM_NAME}] 开始备份：${QCOW2_PATH} → ${BACKUP_FILE}"
    if rsync -av --sparse "${QCOW2_PATH}" "${BACKUP_FILE}" &> /dev/null; then
        SRC_SIZE=$(stat -c %s "${QCOW2_PATH}")
        DST_SIZE=$(stat -c %s "${BACKUP_FILE}")
        
        if [ "${SRC_SIZE}" -eq "${DST_SIZE}" ]; then
            BACKUP_SIZE_FORMATTED=$(format_size ${DST_SIZE})
            log "[${VM_NAME}] 备份完成，大小：${BACKUP_SIZE_FORMATTED}"
            return 0
        else
            log "[${VM_NAME}] 备份大小不一致"
            rm -f "${BACKUP_FILE}"
        fi
    else
        log "[${VM_NAME}] 备份失败"
    fi

    return 1
}

# 清理旧备份
clean_old_backups() {
    local VM_NAME=$1
    BACKUP_FILES=$(ls -1t "${BACKUP_DIR}/${VM_NAME}_"*".qcow2" 2>/dev/null | grep -E "${VM_NAME}_[0-9]{8}_[0-9]{6}\.qcow2")
    
    if [ -z "${BACKUP_FILES}" ]; then
        log "[${VM_NAME}] 无旧备份需清理"
        return 0
    fi

    FILES_ARRAY=($BACKUP_FILES)
    FILE_COUNT=${#FILES_ARRAY[@]}

    if [ ${FILE_COUNT} -gt ${KEEP_BACKUP_COUNT} ]; then
        DELETE_COUNT=$(( FILE_COUNT - KEEP_BACKUP_COUNT ))
        log "[${VM_NAME}] 清理${DELETE_COUNT}份旧备份"
        
        for ((i=${KEEP_BACKUP_COUNT}; i<${FILE_COUNT}; i++)); do
            FILE_TO_DELETE=${FILES_ARRAY[$i]}
            if rm -f "${FILE_TO_DELETE}"; then
                log "[${VM_NAME}] 删除旧备份：$(basename "${FILE_TO_DELETE}")"
            else
                log "[${VM_NAME}] 删除失败：${FILE_TO_DELETE}"
            fi
        done
    else
        log "[${VM_NAME}] 备份数量≤${KEEP_BACKUP_COUNT}，无需清理"
    fi
}

# 处理单个虚拟机备份
process_single_vm() {
    local VM_INFO=$1
    IFS='|' read -r VM_NAME ORIG_STATUS QCOW2_PATH _ QCOW2_SIZE_FORMATTED <<< "${VM_INFO}"
    log ""
    log "----------------------------------------"
    log "处理虚拟机：${VM_NAME}（大小：${QCOW2_SIZE_FORMATTED}）"
    log "----------------------------------------"

    if [ ! -f "${QCOW2_PATH}" ]; then
        log "[${VM_NAME}] 跳过：无效文件"
        return 1
    fi

    # 关机 → 备份 → 清理 → 开机
    if ! shutdown_vm "${VM_NAME}"; then
        log "[${VM_NAME}] 关机失败，跳过"
        return 1
    fi

    BACKUP_SUCCESS=0
    if backup_qcow2 "${VM_NAME}" "${QCOW2_PATH}"; then
        BACKUP_SUCCESS=1
        clean_old_backups "${VM_NAME}"
    fi

    if [[ "${ORIG_STATUS}" =~ ^(running|on)$ ]]; then
        start_vm "${VM_NAME}"
    else
        log "[${VM_NAME}] 原关机状态，无需开机"
    fi

    return ${BACKUP_SUCCESS}
}

# ===================== 交互式定时任务管理 =====================
# 显示定时任务主菜单
show_cron_menu() {
    clear
    echo "========================================"
    echo "      虚拟机备份定时任务管理菜单        "
    echo "========================================"
    echo "1. 查看已添加的定时任务"
    echo "2. 添加新的定时任务（可视化选择时间）"
    echo "3. 删除定时任务"
    echo "4. 退出"
    echo "========================================"
    read -p "请输入操作序号（1-4）：" CRON_ACTION
}

# 查看定时任务
view_cron_jobs() {
    echo ""
    echo "========================================"
    echo "          已添加的备份定时任务          "
    echo "========================================"
    # 筛选当前脚本的定时任务并保存到临时文件（避免子shell问题）
    sudo crontab -u root -l 2>/dev/null | grep -F "${SCRIPT_PATH} -v" > /tmp/cron_jobs.tmp
    CRON_ENTRIES=$(cat /tmp/cron_jobs.tmp)
    
    if [ -z "${CRON_ENTRIES}" ]; then
        echo "暂无备份定时任务"
    else
        # 格式化输出（逐行读取临时文件，避免子shell）
        INDEX=1
        while IFS= read -r LINE; do
            if [ -n "${LINE}" ]; then
                # 解析crontab规则
                MINUTE=$(echo "${LINE}" | awk '{print $1}')
                HOUR=$(echo "${LINE}" | awk '{print $2}')
                DAY=$(echo "${LINE}" | awk '{print $3}')
                MONTH=$(echo "${LINE}" | awk '{print $4}')
                WEEK=$(echo "${LINE}" | awk '{print $5}')
                
                # 转换为易读描述
                DESC=""
                if [ "${MINUTE}" = "0" ] && [ "${HOUR}" != "*" ] && [ "${DAY}" = "*" ] && [ "${MONTH}" = "*" ] && [ "${WEEK}" = "*" ]; then
                    DESC="每天${HOUR}点整执行"
                elif [ "${MINUTE}" = "0" ] && [ "${HOUR}" != "*" ] && [ "${DAY}" = "*" ] && [ "${MONTH}" = "*" ] && [ "${WEEK}" != "*" ]; then
                    WEEK_DESC=$(case ${WEEK} in
                        0) echo "周日";;
                        1) echo "周一";;
                        2) echo "周二";;
                        3) echo "周三";;
                        4) echo "周四";;
                        5) echo "周五";;
                        6) echo "周六";;
                        *) echo "每周${WEEK}天";;
                    esac)
                    DESC="${WEEK_DESC}${HOUR}点整执行"
                elif [ "${MINUTE}" = "0" ] && [ "${HOUR}" != "*" ] && [ "${DAY}" != "*" ] && [ "${MONTH}" = "*" ] && [ "${WEEK}" = "*" ]; then
                    DESC="每月${DAY}号${HOUR}点整执行"
                else
                    DESC="自定义规则：分${MINUTE} 时${HOUR} 日${DAY} 月${MONTH} 周${WEEK}"
                fi
                
                echo "[$INDEX] ${DESC}"
                echo "        原始规则：${MINUTE} ${HOUR} ${DAY} ${MONTH} ${WEEK}"
                echo "        日志文件：${CRON_LOG_FILE}"
                INDEX=$((INDEX + 1))
            fi
        done < /tmp/cron_jobs.tmp
    fi
    rm -f /tmp/cron_jobs.tmp
    echo "========================================"
    read -p "按回车键返回主菜单..."
}

# 可视化选择定时任务时间
select_cron_time() {
    echo ""
    echo "========================================"
    echo "          选择定时任务执行时间          "
    echo "========================================"
    echo "请选择执行周期类型："
    echo "1. 每天执行"
    echo "2. 每周执行"
    echo "3. 每月执行"
    read -p "输入类型序号（1-3）：" TIME_TYPE

    CRON_RULE=""
    case ${TIME_TYPE} in
        1)
            # 每天执行
            read -p "请输入每天执行的小时（0-23）：" HOUR
            if ! [[ "${HOUR}" =~ ^[0-9]+$ ]] || [ ${HOUR} -lt 0 ] || [ ${HOUR} -gt 23 ]; then
                echo "错误：小时输入无效"
                sleep 2
                return 1
            fi
            CRON_RULE="0 ${HOUR} * * *"
            echo "已选择：每天${HOUR}点整执行"
            ;;
        2)
            # 每周执行
            read -p "请输入每周执行的星期（0=周日,1=周一...6=周六）：" WEEK
            if ! [[ "${WEEK}" =~ ^[0-6]$ ]]; then
                echo "错误：星期输入无效（0-6）"
                sleep 2
                return 1
            fi
            read -p "请输入执行的小时（0-23）：" HOUR
            if ! [[ "${HOUR}" =~ ^[0-9]+$ ]] || [ ${HOUR} -lt 0 ] || [ ${HOUR} -gt 23 ]; then
                echo "错误：小时输入无效"
                sleep 2
                return 1
            fi
            WEEK_DESC=$(case ${WEEK} in
                0) echo "周日";;
                1) echo "周一";;
                2) echo "周二";;
                3) echo "周三";;
                4) echo "周四";;
                5) echo "周五";;
                6) echo "周六";;
            esac)
            CRON_RULE="0 ${HOUR} * * ${WEEK}"
            echo "已选择：每周${WEEK_DESC}${HOUR}点整执行"
            ;;
        3)
            # 每月执行
            read -p "请输入每月执行的日期（1-31）：" DAY
            if ! [[ "${DAY}" =~ ^[0-9]+$ ]] || [ ${DAY} -lt 1 ] || [ ${DAY} -gt 31 ]; then
                echo "错误：日期输入无效（1-31）"
                sleep 2
                return 1
            fi
            read -p "请输入执行的小时（0-23）：" HOUR
            if ! [[ "${HOUR}" =~ ^[0-9]+$ ]] || [ ${HOUR} -lt 0 ] || [ ${HOUR} -gt 23 ]; then
                echo "错误：小时输入无效"
                sleep 2
                return 1
            fi
            CRON_RULE="0 ${HOUR} ${DAY} * *"
            echo "已选择：每月${DAY}号${HOUR}点整执行"
            ;;
        *)
            echo "错误：无效的类型序号"
            sleep 2
            return 1
            ;;
    esac

    echo ""
    read -p "确认添加此定时任务？(y/n)：" CONFIRM
    if [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
        # 备份原有crontab
        sudo crontab -u root -l 2>/dev/null > /tmp/root_crontab.bak
        # 移除重复任务
        grep -vF "${SCRIPT_PATH} -v" /tmp/root_crontab.bak > /tmp/root_crontab.new
        # 构建定时任务命令
        CRON_CMD="${CRON_RULE} export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin && nohup ${SCRIPT_PATH} -v > ${CRON_LOG_FILE} 2>&1 &"
        echo "${CRON_CMD}" >> /tmp/root_crontab.new
        # 应用新crontab
        sudo crontab -u root /tmp/root_crontab.new
        rm -f /tmp/root_crontab.bak /tmp/root_crontab.new
        echo "定时任务添加成功！"
    else
        echo "取消添加定时任务"
    fi
    sleep 2
}

# 删除定时任务（修复数组为空问题）
delete_cron_job() {
    echo ""
    echo "========================================"
    echo "          删除备份定时任务              "
    echo "========================================"
    # 筛选当前脚本的定时任务并保存到临时文件
    sudo crontab -u root -l 2>/dev/null | grep -F "${SCRIPT_PATH} -v" > /tmp/cron_jobs_del.tmp
    CRON_ENTRIES=$(cat /tmp/cron_jobs_del.tmp)
    
    if [ -z "${CRON_ENTRIES}" ]; then
        echo "暂无备份定时任务可删除"
        read -p "按回车键返回主菜单..."
        rm -f /tmp/cron_jobs_del.tmp
        return 0
    fi

    # 读取任务到数组（避免子shell问题）
    CRON_ARRAY=()
    while IFS= read -r LINE; do
        if [ -n "${LINE}" ]; then
            CRON_ARRAY+=("${LINE}")
        fi
    done < /tmp/cron_jobs_del.tmp

    # 列出任务
    INDEX=1
    echo "当前备份定时任务列表："
    for LINE in "${CRON_ARRAY[@]}"; do
        MINUTE=$(echo "${LINE}" | awk '{print $1}')
        HOUR=$(echo "${LINE}" | awk '{print $2}')
        DAY=$(echo "${LINE}" | awk '{print $3}')
        MONTH=$(echo "${LINE}" | awk '{print $4}')
        WEEK=$(echo "${LINE}" | awk '{print $5}')
        
        # 简易描述
        if [ "${DAY}" = "*" ] && [ "${WEEK}" = "*" ]; then
            DESC="每天${HOUR}点"
        elif [ "${WEEK}" != "*" ]; then
            DESC="每周${WEEK} ${HOUR}点"
        else
            DESC="每月${DAY}号 ${HOUR}点"
        fi
        echo "[$INDEX] ${DESC} (规则：${MINUTE} ${HOUR} ${DAY} ${MONTH} ${WEEK})"
        INDEX=$((INDEX + 1))
    done

    echo ""
    read -p "请输入要删除的任务序号（输入all删除全部）：" DEL_INDEX
    if [ -z "${DEL_INDEX}" ]; then
        echo "取消删除"
        read -p "按回车键返回主菜单..."
        rm -f /tmp/cron_jobs_del.tmp
        return 0
    fi

    # 备份原有crontab
    sudo crontab -u root -l 2>/dev/null > /tmp/root_crontab_del.bak

    if [ "${DEL_INDEX}" = "all" ]; then
        # 删除所有备份任务
        grep -vF "${SCRIPT_PATH} -v" /tmp/root_crontab_del.bak > /tmp/root_crontab_del.new
        echo "已删除所有备份定时任务"
    else
        # 验证序号
        if ! [[ "${DEL_INDEX}" =~ ^[0-9]+$ ]] || [ ${DEL_INDEX} -lt 1 ] || [ ${DEL_INDEX} -gt ${#CRON_ARRAY[@]} ]; then
            echo "错误：序号无效（有效范围1-${#CRON_ARRAY[@]}）"
            rm -f /tmp/root_crontab_del.bak /tmp/cron_jobs_del.tmp
            read -p "按回车键返回主菜单..."
            return 1
        fi
        # 获取要删除的行
        DEL_LINE="${CRON_ARRAY[$((DEL_INDEX - 1))]}"
        # 排除要删除的行
        grep -vxF "${DEL_LINE}" /tmp/root_crontab_del.bak > /tmp/root_crontab_del.new
        echo "已删除序号${DEL_INDEX}的定时任务"
    fi

    # 应用新crontab
    sudo crontab -u root /tmp/root_crontab_del.new
    # 清理临时文件
    rm -f /tmp/root_crontab_del.bak /tmp/root_crontab_del.new /tmp/cron_jobs_del.tmp

    echo ""
    read -p "删除完成，按回车键返回主菜单..."
}

# 定时任务管理主逻辑
cron_manage() {
    while true; do
        show_cron_menu
        case ${CRON_ACTION} in
            1)
                view_cron_jobs
                ;;
            2)
                select_cron_time
                ;;
            3)
                delete_cron_job
                ;;
            4)
                clear
                log "退出定时任务管理"
                exit 0
                ;;
            *)
                echo "错误：无效的操作序号，请输入1-4"
                sleep 2
                ;;
        esac
    done
}

# ===================== 主流程 =====================
main() {
    # 捕获中断信号
    trap '' SIGINT SIGTERM SIGHUP

    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        log "错误：请使用root权限运行（sudo ./vm_backup.sh）"
        exit 1
    fi

    # 检查依赖
    check_command "virsh"
    check_command "rsync"
    check_command "crontab"

    # 定时任务管理
    if [ "$1" = "-c" ]; then
        cron_manage
        exit 0
    fi

    # 初始化备份目录
    init_backup_dir

    # 一键备份全部
    if [ "$1" = "-v" ]; then
        ensure_background_run
        log "========================================"
        log "一键备份所有虚拟机（后台运行）"
        log "========================================"
        get_all_vms_detail
        SELECTED_VMS=("${VM_INFO[@]}")
    else
        # 交互式备份
        ensure_background_run "interactive"
        get_all_vms_detail
        select_vm
    fi

    # 执行备份
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    FAILED_VMS=""
    TOTAL_COUNT=${#SELECTED_VMS[@]}

    log ""
    log "========================================"
    log "开始备份，共${TOTAL_COUNT}台虚拟机"
    log "========================================"

    for ITEM in "${SELECTED_VMS[@]}"; do
        IFS='|' read -r VM_NAME _ _ _ _ <<< "${ITEM}"
        if process_single_vm "${ITEM}"; then
            SUCCESS_COUNT=$(( SUCCESS_COUNT + 1 ))
        else
            FAIL_COUNT=$(( FAIL_COUNT + 1 ))
            FAILED_VMS+="${VM_NAME} "
        fi
    done

    # 汇总结果
    log ""
    log "========================================"
    log "备份完成 | 总计：${TOTAL_COUNT} | 成功：${SUCCESS_COUNT} | 失败：${FAIL_COUNT}"
    log "========================================"
    if [ -n "${FAILED_VMS}" ]; then
        log "失败虚拟机：${FAILED_VMS}"
    fi
    log "备份目录：${BACKUP_DIR}"
    log "日志文件：${LOG_FILE}"
}

# 启动主流程
main "$@"