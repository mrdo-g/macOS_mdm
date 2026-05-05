#!/bin/bash

set -euo pipefail

# --- Цвета ---
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
PUR='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

error_exit() { echo -e "${RED}ОШИБКА: $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}ПРЕДУПРЕЖДЕНИЕ: $1${NC}"; }
success()    { echo -e "${GRN}✓ $1${NC}"; }
info()       { echo -e "${BLU}ℹ $1${NC}"; }
header()     { echo -e "${CYAN}$1${NC}"; }

# --- Проверка окружения ---
check_environment() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Скрипт должен запускаться с правами root. Используйте sudo или запустите из Recovery."
    fi
    if [[ -d "/System/Library/CoreServices" && -e "/System/Library/CoreServices/SystemVersion.plist" ]]; then
        warn "Похоже, вы запустили скрипт в обычной системе, а не в Recovery."
        read -p "Продолжить? (y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
    fi
    info "Окружение проверено."
}

# --- Обнаружение томов (без переименования) ---
detect_volumes() {
    local system_vol=""
    local data_vol=""
    local system_candidates=()
    local data_candidates=()

    info "Поиск системного тома macOS..."
    for vol in /Volumes/*; do
        if [[ -d "$vol/System" && ! "$vol" =~ Data$ && ! "$vol" =~ Recovery ]]; then
            system_candidates+=("$(basename "$vol")")
        fi
    done

    if [[ ${#system_candidates[@]} -eq 0 ]]; then
        error_exit "Не удалось найти системный том. Убедитесь, что вы в Recovery и системный том смонтирован."
    elif [[ ${#system_candidates[@]} -eq 1 ]]; then
        system_vol="${system_candidates[0]}"
    else
        warn "Найдено несколько системных томов:"
        select choice in "${system_candidates[@]}"; do
            system_vol="$choice"
            break
        done
    fi
    success "Системный том: $system_vol"

    info "Поиск data-тома (с пользовательскими данными)..."
    for vol in /Volumes/*; do
        local name=$(basename "$vol")
        if [[ "$name" == "Data" ]] || [[ "$name" == *" - Data" ]] || [[ -d "$vol/Users" ]]; then
            data_candidates+=("$name")
        fi
    done
    if [[ ${#data_candidates[@]} -eq 0 ]]; then
        error_exit "Data-том не найден."
    elif [[ ${#data_candidates[@]} -eq 1 ]]; then
        data_vol="${data_candidates[0]}"
    else
        warn "Найдено несколько data-томов:"
        select choice in "${data_candidates[@]}"; do
            data_vol="$choice"
            break
        done
    fi
    success "Data-том: $data_vol"

    echo "$system_vol|$data_vol"
}

# --- Разблокировка Data-тома (FileVault) ---
unlock_data_volume() {
    local data_vol="$1"
    local data_path="/Volumes/$data_vol"
    if diskutil info "$data_vol" 2>/dev/null | grep -q "Mounted: Yes"; then
        info "Том $data_vol уже смонтирован."
        return 0
    fi
    if diskutil mount "$data_vol" 2>/dev/null; then
        success "Том $data_vol смонтирован."
        return 0
    fi
    warn "Том $data_vol зашифрован. Введите пароль для разблокировки."
    diskutil apfs unlockVolume "$data_vol" || error_exit "Не удалось разблокировать том $data_vol"
    success "Том $data_vol разблокирован и смонтирован."
}

# --- Поиск свободного UID ---
find_free_uid() {
    local dscl_path="$1"
    local used_uids
    used_uids=$(dscl -f "$dscl_path" localhost -list /Local/Default/Users UniqueID 2>/dev/null | awk '{print $2}' | sort -n)
    local uid=501
    while [[ $uid -lt 1000 ]]; do
        if ! echo "$used_uids" | grep -q "^${uid}$"; then
            echo "$uid"
            return 0
        fi
        ((uid++))
    done
    echo "1001"  # fallback
}

# --- Валидация имени пользователя ---
validate_username() {
    local username="$1"
    if [[ -z "$username" ]]; then
        echo "Имя не может быть пустым"
        return 1
    fi
    if [[ ${#username} -gt 31 ]]; then
        echo "Имя слишком длинное (макс. 31 символ)"
        return 1
    fi
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Имя может содержать только буквы, цифры, дефис и подчёркивание"
        return 1
    fi
    if [[ ! "$username" =~ ^[a-zA-Z_] ]]; then
        echo "Имя должно начинаться с буквы или подчёркивания"
        return 1
    fi
    return 0
}

# --- Проверка существования пользователя ---
user_exists() {
    local dscl_path="$1"
    local username="$2"
    dscl -f "$dscl_path" localhost -read "/Local/Default/Users/$username" &>/dev/null
}

# --- Создание локального администратора ---
create_admin_user() {
    local data_path="$1"
    local dscl_path="$2"
    local realName username passw validation_msg

    echo ""
    header "═══════════════════════════════════════"
    header "   Создание локального администратора"
    header "═══════════════════════════════════════"

    read -p "Полное имя (Enter = Apple): " realName
    realName="${realName:=Apple}"

    while true; do
        read -p "Имя учётной записи (Enter = Apple): " username
        username="${username:=Apple}"
        validation_msg=$(validate_username "$username") || {
            warn "$validation_msg"
            continue
        }
        if user_exists "$dscl_path" "$username"; then
            warn "Пользователь '$username' уже существует."
            read -p "Использовать другой? (y/n): " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                continue
            else
                break
            fi
        fi
        break
    done

    while true; do
        read -p "Пароль (Enter = 1234): " passw
        passw="${passw:=1234}"
        if [[ -z "$passw" ]]; then
            warn "Пароль не может быть пустым"
        else
            break
        fi
    done

    local uid
    uid=$(find_free_uid "$dscl_path")
    info "Создание пользователя $username (UID: $uid)..."

    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" || error_exit "Не удалось создать запись пользователя"
    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh"
    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RealName "$realName"
    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UniqueID "$uid"
    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20"
    dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username"
    dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$username" "$passw"
    dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username"

    mkdir -p "$data_path/Users/$username" || warn "Не удалось создать домашнюю директорию"
    touch "$data_path/private/var/db/.AppleSetupDone"

    success "Пользователь $username создан и добавлен в группу admin"
    echo "$username|$passw"
}

# --- Блокировка MDM-доменов в /etc/hosts (без gdmf.apple.com) ---
block_mdm_domains() {
    local system_path="$1"
    local hosts_file="$system_path/etc/hosts"
    local domains=(
        "deviceenrollment.apple.com"
        "mdmenrollment.apple.com"
        "iprofiles.apple.com"
        "acmdm.apple.com"
        "axm-adm-mdm.apple.com"
    )

    chflags nouchg "$hosts_file" 2>/dev/null || true
    cp "$hosts_file" "${hosts_file}.backup" 2>/dev/null || true

    for domain in "${domains[@]}"; do
        if ! grep -q "0.0.0.0 $domain" "$hosts_file" 2>/dev/null; then
            echo "0.0.0.0 $domain" >> "$hosts_file"
        fi
        if ! grep -q ":: $domain" "$hosts_file" 2>/dev/null; then
            echo ":: $domain" >> "$hosts_file"
        fi
    done

    chflags uchg "$hosts_file" 2>/dev/null || warn "Не удалось заблокировать hosts файл (возможно, SIP активен)"
    success "MDM-домены добавлены в hosts и файл защищён"
}

# --- Очистка и блокировка MDM-маркеров (расширенная) ---
clean_mdm_markers() {
    local system_path="$1"
    local data_path="$2"
    local config_path="$system_path/var/db/ConfigurationProfiles/Settings"
    mkdir -p "$config_path" 2>/dev/null || true

    # Удаление положительных маркеров активации
    rm -f "$config_path/.cloudConfigHasActivationRecord" 2>/dev/null
    rm -f "$config_path/.cloudConfigRecordFound" 2>/dev/null

    # Создание и защита негативных маркеров
    local markers=(
        ".cloudConfigProfileInstalled"
        ".cloudConfigRecordNotFound"
        ".cloudConfigNoActivationRecord"
        ".cloudConfigUserSkippedEnrollment"
        ".CloudConfigDelete"
    )
    for marker in "${markers[@]}"; do
        touch "$config_path/$marker" 2>/dev/null
        chflags uchg "$config_path/$marker" 2>/dev/null || true
    done

    # Флаг принудительного отключения демона с усиленной защитой
    local disable_flag="$system_path/var/db/.com.apple.mdmclient.daemon.forced_disable"
    touch "$disable_flag" 2>/dev/null
    chmod 000 "$disable_flag" 2>/dev/null || true
    chflags uchg "$disable_flag" 2>/dev/null || true

    # Удаление установленных профилей
    rm -rf "$system_path/var/db/ConfigurationProfiles/"*.mobileconfig 2>/dev/null
    rm -rf "$system_path/Library/ConfigurationProfiles/"*.mobileconfig 2>/dev/null

    # Удаление кэш-директории MDM
    if [[ -d "$data_path/private/var/db/mdm" ]]; then
        rm -rf "$data_path/private/var/db/mdm" 2>/dev/null
        success "Каталог /var/db/mdm удалён"
    else
        info "Каталог /var/db/mdm не обнаружен"
    fi

    # Прямая правка com.apple.ManagedClient.plist
    local plist="$config_path/com.apple.ManagedClient.plist"
    if ! /usr/libexec/PlistBuddy -c "Print" "$plist" &>/dev/null; then
        echo '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>' > "$plist"
    fi
    if /usr/libexec/PlistBuddy -c "Set :CloudConfigRecordFound false" "$plist" 2>/dev/null; then
        :
    else
        /usr/libexec/PlistBuddy -c "Add :CloudConfigRecordFound bool false" "$plist" 2>/dev/null || warn "Не удалось добавить CloudConfigRecordFound"
    fi
    if /usr/libexec/PlistBuddy -c "Set :CloudConfigHasActivationRecord false" "$plist" 2>/dev/null; then
        :
    else
        /usr/libexec/PlistBuddy -c "Add :CloudConfigHasActivationRecord bool false" "$plist" 2>/dev/null || warn "Не удалось добавить CloudConfigHasActivationRecord"
    fi
    if /usr/libexec/PlistBuddy -c "Set :CloudConfigProfileInstalled false" "$plist" 2>/dev/null; then
        :
    else
        /usr/libexec/PlistBuddy -c "Add :CloudConfigProfileInstalled bool false" "$plist" 2>/dev/null || warn "Не удалось добавить CloudConfigProfileInstalled"
    fi
    chflags uchg "$plist" 2>/dev/null || true
    success "MDM-маркеры очищены и заблокированы (включая plist и /var/db/mdm)"
}

# --- Отключение MDM-служб через launchctl ---
disable_mdm_services() {
    local dscl_path="$1"
    local services=(
        "com.apple.ManagedClient.cloudconfigurationd"
        "com.apple.ManagedClient.daemon"
        "com.apple.ManagedClient.enroll"
        "com.apple.mdmclient.daemon"
    )
    for svc in "${services[@]}"; do
        launchctl disable "system/$svc" 2>/dev/null || true
        launchctl bootout "system/$svc" 2>/dev/null || true
    done

    local user_ids
    user_ids=$(dscl -f "$dscl_path" localhost -list /Local/Default/Users UniqueID 2>/dev/null | awk '$2>=501 {print $2}')
    for uid in $user_ids; do
        launchctl disable "gui/$uid/com.apple.ManagedClientAgent.enrollagent" 2>/dev/null || true
        launchctl bootout "gui/$uid/com.apple.ManagedClientAgent.enrollagent" 2>/dev/null || true
        launchctl disable "user/$uid/com.apple.ManagedClientAgent.enrollagent" 2>/dev/null || true
        launchctl bootout "user/$uid/com.apple.ManagedClientAgent.enrollagent" 2>/dev/null || true
    done
    success "MDM-службы отключены"
}

# --- Опционально: удаление сторонних MDM-агентов ---
clean_third_party_mdm() {
    local system_path="$1"
    local data_path="$2"
    local vendors=("addigy" "jamf" "kandji" "mosyle" "intune" "falcon" "dorthus" "jumpcloud")
    local found=0

    for vendor in "${vendors[@]}"; do
        if find "$system_path/Library/LaunchDaemons" "$system_path/Library/LaunchAgents" "$data_path/Library/LaunchAgents" -iname "*$vendor*" 2>/dev/null | grep -q .; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        info "Сторонние MDM-агенты не обнаружены."
        return
    fi

    warn "Обнаружены следы сторонних MDM (Jamf, Kandji, Intune и др.)."
    read -p "Удалить их? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for vendor in "${vendors[@]}"; do
            find "$system_path/Library/LaunchDaemons" "$system_path/Library/LaunchAgents" "$data_path/Library/LaunchAgents" -iname "*$vendor*" -delete 2>/dev/null
        done
        success "Сторонние MDM-агенты удалены"
    else
        info "Очистка сторонних MDM пропущена"
    fi
}

# --- Опционально: сброс сетевых настроек ---
clean_network_configs() {
    local system_path="$1"
    warn "Очистка сетевых конфигураций удалит сохранённые Wi-Fi пароли и настройки VPN."
    read -p "Выполнить очистку? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local configs=(
            "com.apple.airport.preferences.plist"
            "com.apple.network.eapolclient.configuration.plist"
            "com.apple.wifi.message-tracer.plist"
            "NetworkInterfaces.plist"
            "preferences.plist"
        )
        for cfg in "${configs[@]}"; do
            rm -f "$system_path/Library/Preferences/SystemConfiguration/$cfg" 2>/dev/null
        done
        success "Сетевые конфигурации сброшены"
    else
        info "Очистка сети пропущена"
    fi
}

# --- Опционально: управление root ---
manage_root() {
    local dscl_path="$1"
    header "─────────────────────────────────────────"
    header "Управление учётной записью root"
    read -p "Сменить пароль root? (y/N): " change_root
    if [[ "$change_root" =~ ^[Yy]$ ]]; then
        read -s -p "Новый пароль root: " root_pass
        echo
        dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/root" "$root_pass" 2>/dev/null && success "Пароль root изменён" || warn "Не удалось изменить пароль"
    fi

    read -p "Отключить учётную запись root? (y/N): " disable_root
    if [[ "$disable_root" =~ ^[Yy]$ ]]; then
        dscl -f "$dscl_path" localhost -create "/Local/Default/Users/root" UserShell "/usr/bin/false" 2>/dev/null && success "Root отключён" || warn "Не удалось отключить root"
    fi
}

# --- ГЛАВНАЯ ФУНКЦИЯ ---
main() {
    clear
    header "╔═══════════════════════════════════════════════╗"
    header "║          MDM Bypass Ultimate Edition v1.3     ║"
    header "╚═══════════════════════════════════════════════╝"
    echo ""
    # --- Заставка с информацией об авторе и контактах ---
    echo -e "${PUR}=============================================${NC}"
    echo -e "${PUR}  Автор: Martin Grigoryan${NC}"
    echo -e "${PUR}  Поддержка и донат:${NC}"
    echo -e "${PUR}  Instagram: _mrdo_g${NC}"
    echo -e "${PUR}  Telegram: @mrd0_g${NC}"
    echo -e "${PUR}  При ошибках и вопросах обращайтесь${NC}"
    echo -e "${PUR}=============================================${NC}"
    echo ""

    check_environment

    volume_info=$(detect_volumes)
    system_volume=$(echo "$volume_info" | cut -d'|' -f1)
    data_volume=$(echo "$volume_info" | cut -d'|' -f2)

    system_path="/Volumes/$system_volume"
    data_path="/Volumes/$data_volume"
    dscl_path="$data_path/private/var/db/dslocal/nodes/Default"

    unlock_data_volume "$data_volume"

    if [[ ! -d "$system_path" || ! -d "$data_path" || ! -d "$dscl_path" ]]; then
        error_exit "Не удалось смонтировать системный или data-том."
    fi

    user_creds=$(create_admin_user "$data_path" "$dscl_path")
    username=$(echo "$user_creds" | cut -d'|' -f1)
    password=$(echo "$user_creds" | cut -d'|' -f2)

    block_mdm_domains "$system_path"
    clean_mdm_markers "$system_path" "$data_path"
    disable_mdm_services "$dscl_path"

    clean_third_party_mdm "$system_path" "$data_path"
    clean_network_configs "$system_path"
    manage_root "$dscl_path"

    echo ""
    success "═══════════════════════════════════════════════"
    success "        MDM Bypass успешно выполнен!"
    success "═══════════════════════════════════════════════"
    echo ""
    header "Дальнейшие действия:"
    echo -e "  1. Закройте этот терминал"
    echo -e "  2. Перезагрузите Mac: ${CYAN}reboot${NC}"
    echo -e "  3. Войдите с созданным пользователем:"
    echo -e "     Имя: ${YEL}$username${NC}  Пароль: ${YEL}$password${NC}"
    echo ""
    read -p "Перезагрузить сейчас? (y/N): " reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        info "Перезагрузка..."
        reboot
    else
        info "Вы можете перезагрузить позже командой 'reboot'"
    fi
}

main