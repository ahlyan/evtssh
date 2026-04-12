#!/bin/bash

# ============================================
# EVT SSH MANAGER - COMPLETE BASH SCRIPT
# IP already verified by Cloudflare Worker
# ============================================

# ===== CHECK AND INSTALL DEPENDENCIES ONCE =====
if [ ! -f "/root/.evt_deps_installed" ]; then
    echo -e "${YELLOW}[📦] Installing dependencies (first time only)...${NC}"
    apt update -y &>/dev/null
    apt install -y python3-pip net-tools screen curl wget jq uuid-runtime &>/dev/null
    pip3 install flask flask-login requests waitress &>/dev/null
    touch /root/.evt_deps_installed
    echo -e "${GREEN}[✅] Dependencies installed${NC}"
fi

# Color Definitions
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
NC='\033[0m'

# ============================================
# ASK FOR CUSTOM PANEL LOGIN CREDENTIALS
# ============================================

CRED_FILE="/root/.evt_panel_creds.json"

if [ ! -f "$CRED_FILE" ]; then
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}🔐 FIRST TIME SETUP - PANEL LOGIN CREDENTIALS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""
    read -p " Panel Login Username (default: admin): " PANEL_USER
    read -p " Panel Login Password (default: admin123): " PANEL_PASS
    read -p " Panel License Key (default: EVT-LICENSE): " PANEL_KEY
    
    [ -z "$PANEL_USER" ] && PANEL_USER="admin"
    [ -z "$PANEL_PASS" ] && PANEL_PASS="admin123"
    [ -z "$PANEL_KEY" ] && PANEL_KEY="EVT-LICENSE"
    
    cat > "$CRED_FILE" << EOF
{
    "admin_username": "$PANEL_USER",
    "admin_password": "$PANEL_PASS",
    "license_key": "$PANEL_KEY"
}
EOF
    chmod 600 "$CRED_FILE"
    echo ""
    echo -e "${GREEN}[✅] Panel credentials saved!${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    sleep 2
fi

# ============================================
# DEPENDENCIES CHECK
# ============================================

if ! command -v netstat &> /dev/null; then
    apt update -y &> /dev/null
    apt install net-tools lsb-release python3 screen psmisc lsof curl wget jq uuid-runtime -y &> /dev/null
fi

# ============================================
# CONFIGURATION FILES
# ============================================

CONFIG_FILE="/etc/evt_config"
USER_DB="/etc/evt_users.db"
KEYS_DB="/root/keys.json"
BACKUP_FILE="/root/backup.txt"
RESTORE_FILE="/root/restore.txt"

[ ! -f "$USER_DB" ] && touch "$USER_DB"

# ============================================
# INITIAL SETUP
# ============================================

do_initial_setup() {
    clear
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}${NC}${YELLOW}           -- INITIAL SERVER SETUP --${NC}${CYAN}            ${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────┘${NC}"
    read -p " ◇ Enter your DOMAIN (Default: evtvip.com): " input_dom
    read -p " ◇ Enter your NAMESERVER (Default: ns.evtvip.com): " input_ns
    [ -z "$input_dom" ] && input_dom="evtvip.com"
    [ -z "$input_ns" ] && input_ns="ns.evtvip.com"
    echo "DOMAIN=\"$input_dom\"" > "$CONFIG_FILE"
    echo "NS_DOMAIN=\"$input_ns\"" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    source "$CONFIG_FILE"
}

[ ! -f "$CONFIG_FILE" ] && do_initial_setup
source "$CONFIG_FILE"

# ============================================
# KEYS.JSON FUNCTIONS
# ============================================

load_keys_json() {
    if [ ! -f "$KEYS_DB" ]; then
        echo "{}"
    else
        cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null || echo "{}"
    fi
}

get_keys_total_users() {
    if [ -f "$KEYS_DB" ]; then
        local total=$(cat "$KEYS_DB" 2>/dev/null | jq '.keys | length' 2>/dev/null)
        echo "${total:-0}"
    else
        echo "0"
    fi
}

sync_keys_to_system() {
    echo -e "${YELLOW}[🔄] Syncing users from keys.json to system...${NC}"
    
    if [ ! -f "$KEYS_DB" ]; then
        echo -e "${RED}[❌] keys.json not found!${NC}"
        return 1
    fi
    
    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
    if [ -z "$keys_data" ] || [ "$keys_data" = "null" ]; then
        echo -e "${RED}[❌] Invalid keys.json format!${NC}"
        return 1
    fi
    
    local synced=0
    local errors=0
    local user_list=""
    
    while IFS= read -r line; do
        local key=$(echo "$line" | cut -d'|' -f1)
        local username=$(echo "$line" | cut -d'|' -f2)
        local password=$(echo "$line" | cut -d'|' -f3)
        local expiry=$(echo "$line" | cut -d'|' -f4)
        local limit=$(echo "$line" | cut -d'|' -f5)
        
        if [[ -n "$username" && -n "$password" && "$username" != "null" ]]; then
            if id "$username" &>/dev/null; then
                echo "$username:$password" | chpasswd &>/dev/null
                echo -e "${GREEN}[✓] Updated: $username${NC}"
            else
                if [[ "$expiry" != "No Expiry" && -n "$expiry" && "$expiry" != "null" ]]; then
                    useradd -e "$expiry" -M -s /bin/false "$username" &>/dev/null
                else
                    useradd -M -s /bin/false "$username" &>/dev/null
                fi
                echo "$username:$password" | chpasswd &>/dev/null
                echo -e "${GREEN}[✓] Created: $username${NC}"
            fi
            
            sed -i "/^$username hard/d" /etc/security/limits.conf &>/dev/null
            echo "$username hard maxlogins ${limit:-1}" >> /etc/security/limits.conf
            sed -i "/^$username:/d" "$USER_DB" &>/dev/null
            echo "$username:$password" >> "$USER_DB"
            
            synced=$((synced + 1))
            user_list="$user_list\n   ${GREEN}✓${NC} $username"
        fi
    done < <(cat "$KEYS_DB" | jq -r '.keys | to_entries[] | "\(.key)|\(.value.username)|\(.value.password)|\(.value.expiry)|\(.value.limit)"' 2>/dev/null)
    
    echo -e "${GREEN}[✅] Sync completed!${NC}"
    echo -e "${CYAN}   - Synced: $synced users${NC}"
    echo -e "${CYAN}   - Errors: $errors${NC}"
    
    if [ -n "$user_list" ]; then
        echo -e "\n${YELLOW}Users after sync:${NC}"
        echo -e "$user_list"
    fi
    
    return 0
}

# ============================================
# AUTO KILLER FUNCTION
# ============================================

auto_killer() {
    local current_sec=$(date +%s)
    local current_date=$(date +%Y-%m-%d)
    local killed=0
    local deleted=0
    
    if [ -f "$KEYS_DB" ]; then
        local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
        local updated=false
        
        while IFS= read -r line; do
            local key=$(echo "$line" | cut -d'|' -f1)
            local expiry=$(echo "$line" | cut -d'|' -f2)
            local username=$(echo "$line" | cut -d'|' -f3)
            
            if [[ "$expiry" != "null" && "$expiry" != "No Expiry" && -n "$expiry" ]]; then
                if [[ "$expiry" < "$current_date" ]]; then
                    userdel -f "$username" &>/dev/null
                    sed -i "/^$username:/d" "$USER_DB" &>/dev/null
                    sed -i "/$username hard maxlogins/d" /etc/security/limits.conf &>/dev/null
                    keys_data=$(echo "$keys_data" | jq "del(.keys[\"$key\"])")
                    updated=true
                    deleted=$((deleted + 1))
                fi
            fi
        done < <(echo "$keys_data" | jq -r '.keys | to_entries[] | "\(.key)|\(.value.expiry)|\(.value.username)"' 2>/dev/null)
        
        if [ "$updated" = true ]; then
            echo "$keys_data" > "$KEYS_DB"
        fi
    fi
    
    if [ -s "$USER_DB" ]; then
        while IFS=: read -r u p; do
            [[ -z "$u" || "$u" == "root" ]] && continue
            if ! id "$u" &>/dev/null; then continue; fi
            
            exp_date_raw=$(chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
            if [[ -n "$exp_date_raw" && "$exp_date_raw" != "never" ]]; then
                exp_sec=$(date -d "$exp_date_raw" +%s 2>/dev/null)
                if [[ -n "$exp_sec" && "$exp_sec" -le "$current_sec" ]]; then
                    userdel -f "$u" &>/dev/null
                    sed -i "/^$u:/d" "$USER_DB"
                    sed -i "/$u hard maxlogins/d" /etc/security/limits.conf
                    deleted=$((deleted + 1))
                fi
            fi
        done < "$USER_DB"
    fi
    
    if [ -s "$USER_DB" ]; then
        while IFS=: read -r u p; do
            [[ -z "$u" || "$u" == "root" ]] && continue
            if ! id "$u" &>/dev/null; then continue; fi
            
            local max_limit=$(grep -E "^$u[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | head -n 1)
            [ -z "$max_limit" ] && max_limit=1
            
            local session_pids=$(pgrep -u "$u" sshd 2>/dev/null | sort -rn)
            local count=$(echo "$session_pids" | wc -w)
            
            if [ "$count" -gt "$max_limit" ]; then
                local excess=$((count - max_limit))
                local excess_pids=$(echo "$session_pids" | head -n "$excess")
                for pid in $excess_pids; do
                    kill -9 "$pid" &>/dev/null
                    killed=$((killed + 1))
                done
            fi
        done < "$USER_DB"
    fi
    
    if [ $deleted -gt 0 ] || [ $killed -gt 0 ]; then
        echo -e "${YELLOW}[AUTO] Deleted: $deleted expired users, Killed: $killed excess connections${NC}"
    fi
}

# ============================================
# AUTO RESTART SERVICE
# ============================================

setup_auto_restart() {
    local service_name="evtbash"
    local script_path="/usr/local/bin/evtbash"
    local service_file="/etc/systemd/system/${service_name}.service"
    local web_service_file="/etc/systemd/system/evt-web.service"
    
    # Copy script to /usr/local/bin
    cp "$0" "$script_path" 2>/dev/null
    chmod +x "$script_path"
    
    # Create main service file
    cat > "$service_file" << EOF
[Unit]
Description=EVT SSH Manager - Permanent Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/bin/bash $script_path
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evtbash
NoNewPrivileges=no
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    # Create web panel service file
    cat > "$web_service_file" << EOF
[Unit]
Description=EVT Web Panel - Permanent Service
After=network.target evtbash.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/evt
ExecStart=/usr/bin/python3 /root/evt/main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=evt-web

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload &>/dev/null
    systemctl enable "$service_name" &>/dev/null
    systemctl enable evt-web &>/dev/null
    systemctl start "$service_name" &>/dev/null
    systemctl start evt-web &>/dev/null
    
    echo -e "${GREEN}[✅] Auto-restart services configured!${NC}"
    echo -e "${GREEN}[✅] EVT Dashboard will auto-start on reboot${NC}"
    echo -e "${GREEN}[✅] Web Panel will auto-start on reboot${NC}"
}

check_auto_restart() {
    if [ ! -f "/etc/systemd/system/evtbash.service" ]; then
        echo -e "${YELLOW}[⚠️] Auto-restart not configured. Setting up...${NC}"
        setup_auto_restart
    fi
}

# ============================================
# PORT CHECK FUNCTIONS
# ============================================

check_port() {
    local service=$1
    local result=$(netstat -tunlp 2>/dev/null | grep LISTEN | grep -i "$service" | awk '{print $4}' | sed 's/.*://' | sort -u | xargs)
    [ -z "$result" ] && echo "None" || echo "$result"
}

get_ports() {
    SSH_PORT=$(check_port "sshd")
    WS_PORT=$(netstat -tunlp 2>/dev/null | grep LISTEN | grep -E 'python|node|ws-st|proxy|litespeed|go-ws' | awk '{print $4}' | sed 's/.*://' | sort -u | xargs); [ -z "$WS_PORT" ] && WS_PORT="None"
    SQUID_PORT=$(check_port "squid")
    DROPBEAR_PORT=$(check_port "dropbear")
    STUNNEL_PORT=$(netstat -tunlp 2>/dev/null | grep LISTEN | grep -E 'stunnel|stunnel4' | awk '{print $4}' | sed 's/.*://' | sort -u | xargs); [ -z "$STUNNEL_PORT" ] && STUNNEL_PORT="None"
    OHP_PORT=$(check_port "ohp")
    OVPN_TCP=$(netstat -tunlp 2>/dev/null | grep LISTEN | grep openvpn | grep tcp | awk '{print $4}' | sed 's/.*://' | sort -u | xargs); [ -z "$OVPN_TCP" ] && OVPN_TCP="None"
    OVPN_UDP=$(netstat -tunlp 2>/dev/null | grep udp | grep openvpn | awk '{print $4}' | sed 's/.*://' | sort -u | xargs); [ -z "$OVPN_UDP" ] && OVPN_UDP="None"
    OVPN_SSL="$STUNNEL_PORT"
}

get_slowdns_key_info() {
    if [ -f "/etc/dnstt/server.pub" ]; then
        DNS_PUB_KEY=$(cat "/etc/dnstt/server.pub" 2>/dev/null | tr -d '\n\r ')
    else
        DNS_PUB_KEY=$(find /etc/dnstt -name "*.pub" 2>/dev/null | xargs cat 2>/dev/null | head -n 1 | tr -d '\n\r ')
    fi
    [ -z "$DNS_PUB_KEY" ] && DNS_PUB_KEY="None"
}

# ============================================
# USER INFO FUNCTION
# ============================================

show_user_info() {
    local username="$1"
    
    clear
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}${NC}${YELLOW}               -- USER INFORMATION --${NC}${CYAN}                        ${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    
    if id "$username" &>/dev/null; then
        local pass=$(grep "^$username:" "$USER_DB" 2>/dev/null | cut -d: -f2)
        local exp_date=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        [ -z "$exp_date" ] || [[ "$exp_date" == "never" ]] && exp_date="No Expiry"
        local limit=$(grep -E "^$username[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}')
        [ -z "$limit" ] && limit="1"
        local online_count=$(pgrep -u "$username" sshd 2>/dev/null | wc -l)
        
        printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Username" "$username"
        printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Password" "${pass:-N/A}"
        printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Expiry Date" "$exp_date"
        printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Limit" "$limit Device(s)"
        printf "${CYAN}${NC} %-16s : ${YELLOW}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Online" "$online_count / $limit"
    else
        printf "${CYAN}${NC} %-16s : ${RED}%-40s${NC} ${CYAN}${NC}\n" "[SYSTEM] Status" "User not found in system!"
    fi
    
    if [ -f "$KEYS_DB" ]; then
        local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
        if [ -n "$keys_data" ] && [ "$keys_data" != "null" ]; then
            local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$username\") | .key" 2>/dev/null)
            
            if [[ -n "$key" && "$key" != "null" && "$key" != "" ]]; then
                local keys_pass=$(echo "$keys_data" | jq -r ".keys[\"$key\"].password" 2>/dev/null)
                local keys_expiry=$(echo "$keys_data" | jq -r ".keys[\"$key\"].expiry" 2>/dev/null)
                local keys_limit=$(echo "$keys_data" | jq -r ".keys[\"$key\"].limit" 2>/dev/null)
                local keys_created_by=$(echo "$keys_data" | jq -r ".keys[\"$key\"].created_by" 2>/dev/null)
                local keys_created_at=$(echo "$keys_data" | jq -r ".keys[\"$key\"].created_at" 2>/dev/null)
                
                echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
                printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Key" "$key"
                printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Password" "${keys_pass:-N/A}"
                printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Expiry" "${keys_expiry:-N/A}"
                printf "${CYAN}${NC} %-16s : ${GREEN}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Limit" "${keys_limit:-1} Device(s)"
                printf "${CYAN}${NC} %-16s : ${YELLOW}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Created By" "${keys_created_by:-Unknown}"
                printf "${CYAN}${NC} %-16s : ${YELLOW}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Created At" "${keys_created_at:-Unknown}"
            else
                printf "${CYAN}${NC} %-16s : ${RED}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Status" "User not found in keys.json!"
            fi
        else
            printf "${CYAN}${NC} %-16s : ${RED}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Status" "keys.json is empty or invalid!"
        fi
    else
        printf "${CYAN}${NC} %-16s : ${RED}%-40s${NC} ${CYAN}${NC}\n" "[KEYS.JSON] Status" "keys.json not found!"
    fi
    
    get_slowdns_key_info
    get_ports
    
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    printf "${CYAN}${NC} %-16s : ${YELLOW}%-40s${NC} ${CYAN}${NC}\n" "Domain" "$DOMAIN"
    printf "${CYAN}${NC} %-16s : ${YELLOW}%-40s${NC} ${CYAN}${NC}\n" "NS Domain" "$NS_DOMAIN"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}${NC} ${WHITE}Publickey:${NC}                                                                   ${CYAN}${NC}"
    printf "${CYAN}${NC} ${CYAN}%-59s${NC} ${CYAN}${NC}\n" "${DNS_PUB_KEY:0:59}"
    [ ${#DNS_PUB_KEY} -gt 59 ] && printf "${CYAN}${NC} ${CYAN}%-59s${NC} ${CYAN}${NC}\n" "${DNS_PUB_KEY:59}"
    echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "SSH Port" "$SSH_PORT"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "SSH Websocket" "$WS_PORT"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "Squid Port" "$SQUID_PORT"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "Dropbear Port" "$DROPBEAR_PORT"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "Stunnel Port" "$STUNNEL_PORT"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "OVPN TCP" "$OVPN_TCP"
    printf "${CYAN}${NC} %-16s : ${WHITE}%-40s${NC} ${CYAN}${NC}\n" "OVPN UDP" "$OVPN_UDP"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
}

# ============================================
# CREATE USER FUNCTION
# ============================================

create_user_with_keys() {
    local username="$1"
    local password="$2"
    local days="$3"
    local limit="$4"
    
    if id "$username" &>/dev/null; then
        echo -e "${RED}User already exists!${NC}"
        return 1
    fi
    
    if [ -f "$KEYS_DB" ]; then
        local existing=$(cat "$KEYS_DB" 2>/dev/null | jq -r ".keys[] | select(.username == \"$username\") | .username" 2>/dev/null)
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo -e "${RED}User already exists in keys.json!${NC}"
            return 1
        fi
    fi
    
    local exp_date=$(date -d "+$days days" +"%Y-%m-%d" 2>/dev/null)
    
    useradd -e "$exp_date" -M -s /bin/false "$username" &>/dev/null
    echo "$username:$password" | chpasswd &>/dev/null
    sed -i "/$username hard maxlogins/d" /etc/security/limits.conf &>/dev/null
    echo "$username hard maxlogins $limit" >> /etc/security/limits.conf
    echo "$username:$password" >> "$USER_DB"
    
    local key_id="EVT-$(uuidgen | tr -d '-' | cut -c1-8 | tr 'a-z' 'A-Z')"
    local created_at=$(date "+%Y-%m-%d %H:%M:%S")
    
    if [ -f "$KEYS_DB" ]; then
        local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
        if [ -z "$keys_data" ] || [ "$keys_data" = "null" ]; then
            keys_data='{"keys":{}}'
        fi
        keys_data=$(echo "$keys_data" | jq ".keys[\"$key_id\"] = {
            \"username\": \"$username\",
            \"password\": \"$password\",
            \"expiry\": \"$exp_date\",
            \"limit\": $limit,
            \"created_by\": \"Bash Script\",
            \"created_at\": \"$created_at\"
        }")
        echo "$keys_data" > "$KEYS_DB"
    else
        cat > "$KEYS_DB" << EOF
{
  "keys": {
    "$key_id": {
      "username": "$username",
      "password": "$password",
      "expiry": "$exp_date",
      "limit": $limit,
      "created_by": "Bash Script",
      "created_at": "$created_at"
    }
  }
}
EOF
    fi
    
    echo -e "${GREEN}User created successfully!${NC}"
    return 0
}

# ============================================
# DELETE USER FUNCTION
# ============================================

delete_user_with_keys() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User not found in system!${NC}"
        return 1
    fi
    
    pkill -u "$username" &>/dev/null
    userdel -f "$username" &>/dev/null
    sed -i "/^$username:/d" "$USER_DB" &>/dev/null
    sed -i "/$username hard maxlogins/d" /etc/security/limits.conf &>/dev/null
    
    if [ -f "$KEYS_DB" ]; then
        local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
        local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$username\") | .key" 2>/dev/null)
        if [[ -n "$key" && "$key" != "null" ]]; then
            keys_data=$(echo "$keys_data" | jq "del(.keys[\"$key\"])")
            echo "$keys_data" > "$KEYS_DB"
        fi
    fi
    
    echo -e "${GREEN}User deleted successfully!${NC}"
    return 0
}

# ============================================
# SYSTEM INFO FUNCTIONS
# ============================================

get_system_info() {
    auto_killer
    OS_NAME=$(lsb_release -ds 2>/dev/null | cut -c 1-20); [ -z "$OS_NAME" ] && OS_NAME="Ubuntu 20.04"
    UPTIME_VAL=$(uptime -p 2>/dev/null | sed 's/up //; s/ hours\?,/h/; s/ minutes\?/m/; s/ days\?,/d/' | cut -c 1-12)
    RAM_TOTAL=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    RAM_USED_PERC=$(free 2>/dev/null | grep Mem | awk '{printf("%.2f%%", $3/$2*100)}')
    CPU_CORES=$(nproc 2>/dev/null); CPU_LOAD=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{printf("%.2f%%", $2 + $4)}')
    
    TOTAL_USERS=$(wc -l < "$USER_DB" 2>/dev/null)
    KEYS_TOTAL=$(get_keys_total_users)
    
    ONLINE_USERS=0
    if [ -s "$USER_DB" ]; then
        while IFS=: read -r u p; do
            [[ -z "$u" || "$u" == "root" ]] && continue
            if id "$u" &>/dev/null; then
                count=$(pgrep -u "$u" sshd 2>/dev/null | wc -l)
                ONLINE_USERS=$((ONLINE_USERS + count))
            fi
        done < "$USER_DB"
    fi
}

draw_dashboard() {
    get_system_info
    clear
    echo -e "                     ${RED}EVT SSH Manager${NC}"
    echo -e " ${CYAN}───────────────────────────────────────────────────────────────────────${NC}"
    printf " ${CYAN}${NC}  ${BLUE}%-23s${NC}  ${BLUE}%-23s${NC}  ${BLUE}%-22s${NC} ${CYAN}${NC}\n" "◇  SYSTEM" "◇  RAM MEMORY" "◇  PROCESS"
    printf " ${CYAN}${NC}  ${RED}OS:${NC} %-19s  ${RED}Total:${NC} %-16s  ${RED}CPU cores:${NC} %-12s ${CYAN}${NC}\n" "$OS_NAME" "$RAM_TOTAL" "$CPU_CORES"
    printf " ${CYAN}${NC}  ${RED}Up Time:${NC} %-14s  ${RED}In use:${NC} %-15s  ${RED}In use:${NC} %-15s ${CYAN}${NC}\n" "$UPTIME_VAL" "$RAM_USED_PERC" "$CPU_LOAD"
    echo -e " ${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
    printf " ${CYAN}${NC}  ${GREEN}◇  Online:${NC} %-12s  ${RED}◇  Expired:${NC} %-13s  ${YELLOW}◇  Users:${NC} %-6s ${CYAN}${NC}\n" "$ONLINE_USERS" "0" "$TOTAL_USERS"
    printf " ${CYAN}${NC}  ${GREEN}◇  Keys.json Users:${NC} %-6s                                          ${CYAN}${NC}\n" "$KEYS_TOTAL"
    echo -e " ${CYAN}└──────────────────────────────────────────────────────────────────────────┘${NC}"
}

display_user_table() {
    auto_killer
    clear
    echo -e " ${CYAN}────────────────┬──────────────┬─────────────────────┬───────────────${NC}"
    printf " ${CYAN}${NC} ${YELLOW}%-15s${NC} ${CYAN}${NC} ${YELLOW}%-12s${NC} ${CYAN}${NC} ${YELLOW}%-19s${NC} ${CYAN}${NC} ${YELLOW}%-15s${NC} ${CYAN}${NC}\n" "Username" "Password" "Status/Limit" "Expiry Date"
    echo -e " ${CYAN}───────────────┼──────────────┼─────────────────────┼──────────────${NC}"
    if [ ! -s "$USER_DB" ]; then
        printf " ${CYAN}${NC} %-66s ${CYAN}${NC}\n" "${RED}No created users found.${NC}"
    else
        while IFS=: read -r username pass_find; do
            if id "$username" &>/dev/null; then
                exp_t=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                [ -z "$exp_t" ] || [[ "$exp_t" == "never" ]] && exp_t="No Expiry"
                count_on=$(pgrep -u "$username" sshd 2>/dev/null | wc -l)
                u_limit=$(grep -E "^$username[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | head -n 1)
                [ -z "$u_limit" ] && u_limit="1"
                if [ "$count_on" -gt 0 ]; then stat_print="${GREEN}${count_on}/${u_limit} Online${NC}"; else stat_print="${RED}Offline${NC}"; fi
                printf " ${CYAN}${NC} %-15s ${CYAN}${NC} %-12s ${CYAN}${NC} %-28b ${CYAN}${NC} %-15s ${CYAN}${NC}\n" "$username" "$pass_find" "$stat_print" "$exp_t"
            fi
        done < "$USER_DB"
    fi
    echo -e " ${CYAN}└─────────────────┴──────────────┴─────────────────────┴─────────────────┘${NC}"
}

# ============================================
# PORT MANAGER FUNCTIONS
# ============================================

get_port_v2() {
    local ports=$(netstat -tunlp | grep -i "$1" | awk '{print $4}' | awk -F: '{print $NF}' | sort -nu | xargs)
    [ -z "$ports" ] && echo -e "${RED}OFF${NC}" || echo -e "${YELLOW}$ports${NC}"
}

get_proxy_status() {
    local check=$(netstat -tunlp | grep "python3" | awk '{print $4}' | awk -F: '{print $NF}' | sort -nu | xargs)
    [ -z "$check" ] && echo -e "${RED}OFF${NC}" || echo -e "${YELLOW}$check${NC}"
}

check_st() {
    if netstat -tunlp | grep -qi "$1" > /dev/null; then echo -e "${GREEN}●${NC}"; else echo -e "${RED}○${NC}"; fi
}

setup_ws_proxy() {
    echo ""
    read -p " Enter Port (e.g., 80, 8080, 2052): " p_port
    [[ -z "$p_port" ]] && return
    fuser -k $p_port/tcp &> /dev/null
    
    cat <<EOF > /usr/local/bin/proxy_$p_port.py
import socket, threading, select
def forward(source, destination):
    string_list = [source, destination]
    while True:
        read_list, _, _ = select.select(string_list, [], [], 10)
        if not read_list: continue
        for sock in read_list:
            try:
                data = sock.recv(16384)
                if not data: return
                if sock is source: destination.sendall(data)
                else: source.sendall(data)
            except: return
def handler(client, address):
    try:
        header = client.recv(16384).decode('utf-8', errors='ignore')
        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.connect(('127.0.0.1', 22))
        if "Upgrade: websocket" in header or "GET" in header or "CONNECT" in header:
            client.sendall(b"HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n")
        forward(client, target)
    except: pass
    finally: client.close()
def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', $p_port))
    server.listen(1000)
    while True:
        client, address = server.accept()
        threading.Thread(target=handler, args=(client, address), daemon=True).start()
if __name__ == '__main__': main()
EOF
    chmod +x /usr/local/bin/proxy_$p_port.py
    
    # Create systemd service for auto-start on reboot
    cat > /etc/systemd/system/proxy_$p_port.service << EOF
[Unit]
Description=WebSocket Proxy on port $p_port
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/proxy_$p_port.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable proxy_$p_port.service
    systemctl start proxy_$p_port.service
    
    echo -e "${GREEN}✅ Port $p_port opened and will survive reboot!${NC}"
    sleep 2
}

gerenciar_proxy() {
    while true; do
        clear
        echo -e "${BLUE}╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍${NC}"
        echo -e "      ${CYAN}PROXY SOCKS MANAGER${NC}"
        echo -e "${BLUE}╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍${NC}"
        echo -e " ${NC}ACTIVE PORTS: $(get_proxy_status)${NC}"
        echo ""
        echo -e " ${CYAN}[1]${NC} • OPEN PORT"
        echo -e " ${CYAN}[2]${NC} • STOP ALL"
        echo -e " ${CYAN}[0]${NC} • BACK"
        echo ""
        read -p " SELECT: " opt
        case $opt in
            1) setup_ws_proxy ;;
            2) pkill -f "proxy_" && echo -e "${RED}Stopped All!${NC}" && sleep 1 ;;
            0) break ;;
        esac
    done
}

inst_ssl() {
    echo -e "${YELLOW}Setting up SSL Tunnel on port 443...${NC}"
    apt-get install stunnel4 -y &> /dev/null
    openssl genrsa -out /etc/stunnel/stunnel.key 2048 &> /dev/null
    openssl req -new -x509 -key /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt -days 1095 -subj "/CN=SSHPLUS" &> /dev/null
    cat /etc/stunnel/stunnel.key /etc/stunnel/stunnel.crt > /etc/stunnel/stunnel.pem
    cat <<EOF > /etc/stunnel/stunnel.conf
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[ssh]
accept = 443
connect = 127.0.0.1:22
EOF
    sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
    service stunnel4 restart &> /dev/null
    systemctl restart stunnel4 &> /dev/null
    echo -e "${GREEN}SSL Tunnel Active!${NC}"; sleep 2
}

inst_dropbear() {
    echo -e "${YELLOW}Setting up Dropbear on ports 143 and 110...${NC}"
    
    if ! command -v dropbear &> /dev/null; then
        apt-get install -y dropbear
    fi
    
    if [ -f "/etc/default/dropbear" ]; then
        cp /etc/default/dropbear /etc/default/dropbear.backup.$(date +%s)
    fi
    
    cat > /etc/default/dropbear << 'EOF'
# Dropbear configuration
NO_START=0
DROPBEAR_PORT=143
DROPBEAR_EXTRA_ARGS="-p 110"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
    
    mkdir -p /etc/dropbear
    
    if [ ! -f "/etc/dropbear/dropbear_rsa_host_key" ]; then
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 &> /dev/null
    fi
    if [ ! -f "/etc/dropbear/dropbear_dss_host_key" ]; then
        dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key &> /dev/null
    fi
    if [ ! -f "/etc/dropbear/dropbear_ecdsa_host_key" ]; then
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key -s 521 &> /dev/null
    fi
    
    if command -v ufw &> /dev/null; then
        ufw allow 143/tcp &> /dev/null
        ufw allow 110/tcp &> /dev/null
        ufw reload &> /dev/null
    fi
    
    iptables -A INPUT -p tcp --dport 143 -j ACCEPT &> /dev/null
    iptables -A INPUT -p tcp --dport 110 -j ACCEPT &> /dev/null
    
    if command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    systemctl restart dropbear &> /dev/null || service dropbear restart &> /dev/null
    
    sleep 2
    if pgrep -x "dropbear" > /dev/null; then
        echo -e "${GREEN}✓ Dropbear started successfully on ports: 143 and 110${NC}"
    else
        echo -e "${RED}✗ Failed to start dropbear. Trying to start manually...${NC}"
        dropbear -p 143 -p 110 -R &> /dev/null &
        sleep 1
        if pgrep -x "dropbear" > /dev/null; then
            echo -e "${GREEN}✓ Dropbear started manually on ports: 143 and 110${NC}"
        else
            echo -e "${RED}✗ Could not start dropbear${NC}"
        fi
    fi
    
    echo -e "${GREEN}Dropbear configured on ports 143 and 110!${NC}"
    sleep 2
}

port_manager_menu() {
    while true; do
        clear
        local OS=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"')
        echo -e "${NC}$OS              $(date)"
        echo -e "${BLUE}╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍${NC}"
        echo -e "              ${NC}CONNECTION${NC}"
        echo -e "${BLUE}╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍${NC}"
        echo -e "  ${CYAN}SERVICE: ${NC}OPENSSH PORT: $(get_port_v2 sshd)"
        echo -e "  ${CYAN}SERVICE: ${NC}OPENVPN: PORT: $(get_port_v2 openvpn)"
        echo -e "  ${CYAN}SERVICE: ${NC}PROXY SOCKS PORT: $(get_proxy_status)"
        echo -e "  ${CYAN}SERVICE: ${NC}SSL TUNNEL PORT: $(get_port_v2 stunnel)"
        echo -e "  ${CYAN}SERVICE: ${NC}DROPBEAR PORT: $(get_port_v2 dropbear)"
        echo -e "  ${CYAN}SERVICE: ${NC}SQUID PORT: $(get_port_v2 squid)"
        echo -e "${BLUE}╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍${NC}"
        echo ""
        echo -e " ${CYAN}[01]${NC} ⇒ OPENSSH $(check_st sshd)"
        echo -e " ${CYAN}[02]${NC} ⇒ SQUID PROXY $(check_st squid)"
        echo -e " ${CYAN}[03]${NC} ⇒ DROPBEAR $(check_st dropbear)"
        echo -e " ${CYAN}[04]${NC} ⇒ OPENVPN $(check_st openvpn)"
        echo -e " ${CYAN}[05]${NC} ⇒ PROXY SOCKS $(check_st python3)"
        echo -e " ${CYAN}[06]${NC} ⇒ SSL TUNNEL $(check_st stunnel)"
        echo -e " ${CYAN}[12]${NC} ⇒ WEBSOCKET - Corrector $(check_st python3)"
        echo -e " ${CYAN}[00]${NC} ⇒ BACK ${RED}<<<${NC}"
        echo ""
        read -p "  SELECT OPTION: " port_choice
        case $port_choice in
            1|01) read -p "SSH Port: " p; sed -i "s/^Port .*/Port $p/" /etc/ssh/sshd_config; service ssh restart ;;
            2|02) apt-get install squid -y; service squid restart ;;
            3|03) inst_dropbear ;;
            4|04) wget https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh -O /tmp/ovpn.sh && chmod +x /tmp/ovpn.sh && /tmp/ovpn.sh ;;
            5|05|12) gerenciar_proxy ;;
            6|06) inst_ssl ;;
            0|00) break ;;
            *) echo -e "${RED}Invalid Option!${NC}"; sleep 1 ;;
        esac
    done
}

# ============================================
# SLOWDNS MANAGER
# ============================================

run_slowdns_manager() {
    local SCRIPT_URL="https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh"
    local SCRIPT_PATH="/usr/local/bin/dnstt-deploy"
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo -e "${YELLOW}Downloading dnstt-deploy...${NC}"
        curl -Ls "$SCRIPT_URL" -o "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
    bash "$SCRIPT_PATH"
}

# ============================================
# BACKUP & RESTORE
# ============================================

user_backup() {
    clear
    echo -e "${CYAN}--- TELEGRAM USER BACKUP ---${NC}"
    if [ ! -s "$USER_DB" ]; then echo -e "${RED}No users to backup!${NC}"; sleep 2; return; fi
    > "$BACKUP_FILE"
    while IFS=: read -r u p; do
        [[ -z "$u" || "$u" == "root" ]] && continue
        if ! id "$u" &>/dev/null; then continue; fi
        exp_raw=$(chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        if [[ "$exp_raw" == "never" || -z "$exp_raw" ]]; then exp_f="never"; else exp_f=$(date -d "$exp_raw" +"%Y-%m-%d" 2>/dev/null || echo "never"); fi
        lim=$(grep -E "^$u[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | head -n 1); [ -z "$lim" ] && lim="1"
        echo "$u:$p:$exp_f:$lim" >> "$BACKUP_FILE"
    done < "$USER_DB"
    echo -e "${YELLOW}Enter Telegram Bot Info:${NC}"
    read -p " Bot Token: " TG_TOKEN
    read -p " Chat ID: " TG_CHATID
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then echo -e "${RED}Missing Info!${NC}"; sleep 2; return; fi
    echo -e "${YELLOW}Sending backup.txt to Telegram...${NC}"
    res=$(curl -s -F document=@"$BACKUP_FILE" "https://api.telegram.org/bot$TG_TOKEN/sendDocument?chat_id=$TG_CHATID&caption=User_Backup_File")
    if echo "$res" | grep -q '"ok":true'; then echo -e "\n${GREEN}Backup sent successfully!${NC}"; else echo -e "\n${RED}Failed to send!${NC}"; fi
    read -p " Press [Enter] to continue..."
}

user_restore() {
    clear
    echo -e "${CYAN}--- RAW LINK RESTORE (backup.txt) ---${NC}"
    read -p " Paste Raw Link: " raw_link
    if [ -z "$raw_link" ]; then return; fi
    echo -e "${YELLOW}Downloading backup.txt...${NC}"
    wget -q -O "$BACKUP_FILE" "$raw_link"
    if [ ! -s "$BACKUP_FILE" ]; then echo -e "${RED}Download failed!${NC}"; sleep 2; return; fi
    echo -e "${YELLOW}Restoring users...${NC}"
    while IFS=: read -r u p exp lim; do
        [[ -z "$u" ]] && continue
        if id "$u" &>/dev/null; then echo -e "Skipped: ${YELLOW}$u${NC} (User exists)"; continue; fi
        if [[ "$exp" == "never" || -z "$exp" ]]; then useradd -M -s /bin/false "$u" &>/dev/null; else useradd -e "$exp" -M -s /bin/false "$u" &>/dev/null; fi
        echo "$u:$p" | chpasswd &>/dev/null
        echo "$u hard maxlogins ${lim:-1}" >> /etc/security/limits.conf
        echo "$u:$p" >> "$USER_DB"
        echo -e "Restored: ${GREEN}$u${NC}"
    done < "$BACKUP_FILE"
    
    sync_keys_to_system &>/dev/null
    echo -e "\n${GREEN}Restore Completed!${NC}"; sleep 2
}

# ============================================
# PYTHON APP MANAGEMENT
# ============================================

start_python_app() {
    pkill -f "python.*main.py" 2>/dev/null
    pkill -f "screen.*evt_app" 2>/dev/null
    pkill -f "evt_web" 2>/dev/null
    
    # Kill any process using port 5001
    fuser -k 5001/tcp 2>/dev/null
    
    # Download app.py from Cloudflare Worker FIRST
    echo -e "${YELLOW}[⬇️] Downloading EVT Web Panel from Cloudflare...${NC}"
    bash <(curl -sSL premium-ui.evtvip.indevs.in/app.py) -o /root/app.py
    chmod 644 /root/app.py
    
    if [ -f "/root/app.py" ]; then
        echo -e "${YELLOW}[🔄] Setting up Python Web Panel...${NC}"
        mkdir -p /root/evt
        cp /root/app.py /root/evt/main.py
        cd /root/evt
        
        # Install pyinstaller for protection
        if ! command -v pyinstaller &> /dev/null; then
            echo -e "${YELLOW}[📦] Installing PyInstaller for protection...${NC}"
            pip3 install pyinstaller --quiet 2>/dev/null || true
        fi
        
        # Check if requirements already installed (to avoid delay)
        if ! python3 -c "import flask" 2>/dev/null; then
            echo -e "${YELLOW}[📦] Installing Python packages (first time only)...${NC}"
            pip3 install flask flask-login requests waitress 2>/dev/null || true
        else
            echo -e "${GREEN}[✅] Python packages already installed${NC}"
        fi
        
        # Kill any existing screen session
        screen -X -S evt_app quit 2>/dev/null
        sleep 1
        
        # Start new screen session
        screen -dmS evt_app python3 main.py
        sleep 5
        
        # Check if process is running
        if pgrep -f "python.*main.py" > /dev/null; then
            echo -e "${GREEN}[✅] Web Panel started on port 5001${NC}"
        else
            echo -e "${YELLOW}[⚠️] Web Panel starting slowly, checking again...${NC}"
            sleep 5
            if pgrep -f "python.*main.py" > /dev/null; then
                echo -e "${GREEN}[✅] Web Panel started on port 5001${NC}"
            else
                echo -e "${RED}[❌] Failed to start Web Panel${NC}"
            fi
        fi
    else
        echo -e "${RED}[❌] Download failed! Web Panel not available${NC}"
    fi
}

# ============================================
# MAIN DASHBOARD
# ============================================

check_auto_restart

(
    while true; do
        auto_killer
        sleep 10
    done
) &

# Get VPS IP for display only
VPS_IP=$(curl -s --connect-timeout 10 https://api.ipify.org 2>/dev/null)
[ -z "$VPS_IP" ] && VPS_IP=$(curl -s --connect-timeout 10 https://icanhazip.com 2>/dev/null)
[ -z "$VPS_IP" ] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

clear
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}${NC}${YELLOW}               EVT SSH MANAGER - VPS: ${GREEN}$VPS_IP${YELLOW}${NC}${CYAN}                ${NC}"
echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
sleep 2

# Start Python App in background
start_python_app

# ============================================
# RUN PROTECTION & CREATE PERSISTENT DASHBOARD
# ============================================

if [ ! -f "/root/.evt_protection_done" ]; then
    echo -e "${YELLOW}[🔐] Running protection...${NC}"
    
    # Download and run protection
    curl -sSL "https://raw.githubusercontent.com/KhaingMon7/Maungthunya-evt-panel/main/protect.py" -o /root/protect.py
    chmod +x /root/protect.py
    cd /root && python3 protect.py
    
    # Remove app.py but keep protect.py (it will self-destruct)
    rm -f /root/app.py /root/self_destruct.sh
    
    # Create persistent dashboard screen
    screen -X -S evt_dashboard quit 2>/dev/null
    cd /root/evt
    screen -dmS evt_dashboard /usr/local/bin/evt_web
    
    # Fix service to use binary
    cat > /etc/systemd/system/evt-web.service << 'EOF'
[Unit]
Description=EVT Web Panel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/evt_web
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart evt-web
    
    # Create evt command
    echo "alias evt='screen -r evt_dashboard'" >> /root/.bashrc
    echo "alias evt='screen -r evt_dashboard'" >> /root/.profile
    
    cat > /usr/local/bin/evt << 'EVTEOF'
#!/bin/bash
if screen -ls | grep -q "evt_dashboard"; then
    screen -r evt_dashboard
else
    echo "Dashboard not running. Starting..."
    cd /root/evt
    screen -dmS evt_dashboard /usr/local/bin/evt_web
    sleep 1
    screen -r evt_dashboard
fi
EVTEOF
    chmod +x /usr/local/bin/evt
    
    source /root/.bashrc 2>/dev/null
    
    touch /root/.evt_protection_done
    echo -e "${GREEN}[✅] Protection done! Type 'evt' to access dashboard${NC}"
fi

# Main dashboard loop (this will run in screen)
while true; do
    draw_dashboard
    echo ""
    echo -e " ${YELLOW}[01]${NC} CREATE USER          ${YELLOW}[07]${NC} CHANGE DATE"
    echo -e " ${YELLOW}[02]${NC} CREATE TEST USER     ${YELLOW}[08]${NC} CHANGE LIMIT"
    echo -e " ${YELLOW}[03]${NC} REMOVE USER          ${YELLOW}[09]${NC} CHECK ALL PORTS"
    echo -e " ${YELLOW}[04]${NC} USER INFO (FULL)     ${YELLOW}[10]${NC} RESET DOMAIN/NS"
    echo -e " ${YELLOW}[05]${NC} CHANGE USERNAME      ${YELLOW}[11]${NC} ${RED}REINSTALL UBUNTU 20${NC}"
    echo -e " ${YELLOW}[06]${NC} CHANGE PASSWORD      ${YELLOW}[12]${NC} BACKUP TO TELEGRAM"
    echo -e " ${YELLOW}[13]${NC} RESTORE FROM RAW LINK ${BLUE}[14]${NC} ${BLUE}PORT MANAGER${NC}"
    echo -e " ${YELLOW}[15]${NC} SYNC KEYS.JSON       ${BLUE}[16]${NC} ${BLUE}SLOWDNS MANAGER${NC}"
    echo -e " ${YELLOW}[17]${NC} ${GREEN}RESTART PYTHON APP${NC}  ${BLUE}[99]${NC} ${BLUE}AUTO KILLER STATUS${NC}"
    echo -e " ${YELLOW}[00]${NC} EXIT"
    echo ""
    read -t 60 -p " ◇ Select Option: " opt
    case $opt in
        1|01) 
            while true; do 
                clear; echo -e "${CYAN}--- CREATE NEW USER ---${NC}"; 
                read -p "Username: " user; 
                id "$user" &>/dev/null && echo -e "${RED}Already exists!${NC}" && sleep 1 && continue; 
                read -p "Password: " pass; 
                read -p "Days: " days; 
                read -p "Limit: " user_limit; 
                create_user_with_keys "$user" "$pass" "$days" "$user_limit"
                if [ $? -eq 0 ]; then
                    show_user_info "$user"
                    echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; 
                    [[ "$nav" != "c" ]] && break; 
                else
                    sleep 2
                fi
            done ;;
        2|02) 
            while true; do 
                user="test_$(head /dev/urandom | tr -dc 0-9 | head -c 4)"; 
                pass="123"; user_limit="1"; days="1"
                create_user_with_keys "$user" "$pass" "$days" "$user_limit"
                if [ $? -eq 0 ]; then
                    show_user_info "$user"
                    echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; 
                    [[ "$nav" != "c" ]] && break; 
                fi
            done ;;
        3|03) 
            while true; do 
                display_user_table; echo -e " [1] Remove User [2] Remove ALL"; 
                read -p " Select: " rm_opt; 
                if [[ "$rm_opt" == "1" ]]; then 
                    read -p " Username: " user; 
                    delete_user_with_keys "$user"
                elif [[ "$rm_opt" == "2" ]]; then 
                    read -p " Confirm Delete ALL? (y/n): " confirm; 
                    if [[ "$confirm" == "y" ]]; then
                        while IFS=: read -r u p; do 
                            userdel -f "$u" &>/dev/null
                            sed -i "/$u hard maxlogins/d" /etc/security/limits.conf
                        done < "$USER_DB"
                        > "$USER_DB"
                        echo '{"keys":{}}' > "$KEYS_DB"
                        echo -e "${GREEN}All users cleared!${NC}"
                    fi
                fi; 
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; 
                [[ "$nav" != "c" ]] && break; 
            done ;;
        4|04) 
            while true; do 
                display_user_table
                echo ""
                read -p " Enter username to view details: " user_info
                if [[ -n "$user_info" ]]; then
                    show_user_info "$user_info"
                fi
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; 
                [[ "$nav" != "c" ]] && break; 
            done ;;
        5|05) 
            while true; do 
                display_user_table; read -p "Old Username: " old_u; 
                [ -z "$old_u" ] && break; 
                if ! id "$old_u" &>/dev/null; then echo -e "${RED}User not found!${NC}"; sleep 1; continue; fi; 
                read -p "New Username: " new_u; [ -z "$new_u" ] && continue; 
                if id "$new_u" &>/dev/null; then echo -e "${RED}New name already exists!${NC}"; sleep 1; continue; fi; 
                pkill -u "$old_u" &>/dev/null; sleep 0.5; 
                usermod -l "$new_u" "$old_u" &>/dev/null && groupmod -n "$new_u" "$old_u" &>/dev/null; 
                sed -i "s/^$old_u:/$new_u:/" "$USER_DB"; 
                sed -i "s/$old_u hard/$new_u hard/" /etc/security/limits.conf; 
                
                if [ -f "$KEYS_DB" ]; then
                    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
                    local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$old_u\") | .key" 2>/dev/null)
                    if [[ -n "$key" && "$key" != "null" ]]; then
                        keys_data=$(echo "$keys_data" | jq ".keys[\"$key\"].username = \"$new_u\"")
                        echo "$keys_data" > "$KEYS_DB"
                    fi
                fi
                
                echo -e "${GREEN}Username changed successfully!${NC}"; 
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; [[ "$nav" != "c" ]] && break; 
            done ;;
        6|06) 
            while true; do 
                display_user_table; read -p "Username: " user; read -p "New Password: " pass; 
                echo "$user:$pass" | chpasswd &>/dev/null && sed -i "s/^$user:.*/$user:$pass/" "$USER_DB"; 
                if [ -f "$KEYS_DB" ]; then
                    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
                    local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$user\") | .key" 2>/dev/null)
                    if [[ -n "$key" && "$key" != "null" ]]; then
                        keys_data=$(echo "$keys_data" | jq ".keys[\"$key\"].password = \"$pass\"")
                        echo "$keys_data" > "$KEYS_DB"
                    fi
                fi
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; [[ "$nav" != "c" ]] && break; 
            done ;;
        7|07) 
            while true; do 
                display_user_table; read -p "Username: " user; read -p "Date (YYYY-MM-DD): " exp_date; 
                usermod -e "$exp_date" "$user" &>/dev/null; 
                if [ -f "$KEYS_DB" ]; then
                    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
                    local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$user\") | .key" 2>/dev/null)
                    if [[ -n "$key" && "$key" != "null" ]]; then
                        keys_data=$(echo "$keys_data" | jq ".keys[\"$key\"].expiry = \"$exp_date\"")
                        echo "$keys_data" > "$KEYS_DB"
                    fi
                fi
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; [[ "$nav" != "c" ]] && break; 
            done ;;
        8|08) 
            while true; do 
                display_user_table; read -p "Username: " user; read -p "Limit: " user_limit; 
                sed -i "/$user hard maxlogins/d" /etc/security/limits.conf; 
                echo "$user hard maxlogins $user_limit" >> /etc/security/limits.conf; 
                if [ -f "$KEYS_DB" ]; then
                    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
                    local key=$(echo "$keys_data" | jq -r ".keys | to_entries[] | select(.value.username == \"$user\") | .key" 2>/dev/null)
                    if [[ -n "$key" && "$key" != "null" ]]; then
                        keys_data=$(echo "$keys_data" | jq ".keys[\"$key\"].limit = $user_limit")
                        echo "$keys_data" > "$KEYS_DB"
                    fi
                fi
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; [[ "$nav" != "c" ]] && break; 
            done ;;
        9|09) 
            while true; do 
                clear; get_ports; echo -e "${CYAN}Current Ports:${NC}"; 
                echo "SSH: $SSH_PORT"; echo "WS: $WS_PORT"; echo "Squid: $SQUID_PORT"; 
                echo "Dropbear: $DROPBEAR_PORT"; echo "Stunnel: $STUNNEL_PORT"; 
                echo ""; read -p " ◇ Return to Menu (m) or Continue (c)?: " nav; [[ "$nav" != "c" ]] && break; 
            done ;;
        10) rm -f "$CONFIG_FILE"; do_initial_setup ;;
        11) clear; read -p "New Root Password: " re_pass; read -p "Confirm (y/n): " confirm; [[ "$confirm" == "y" ]] && apt update -y && apt install gawk tar wget curl -y && wget -qO reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh && bash reinstall.sh ubuntu 20.04 --password "$re_pass" && reboot ;;
        12) user_backup ;;
        13) user_restore ;;
        14) port_manager_menu ;;
        15) 
            clear
            echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}${NC}${YELLOW}               -- SYNC KEYS.JSON --${NC}${CYAN}                           ${NC}"
            echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
            sync_keys_to_system
            echo ""
            read -p " Press [Enter] to continue..."
            ;;
        16) run_slowdns_manager ;;
        17)
            clear
            echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}${NC}${YELLOW}               -- RESTART PYTHON APP --${NC}${CYAN}                        ${NC}"
            echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
            start_python_app
            echo ""
            read -p " Press [Enter] to continue..."
            ;;
        99) 
            clear
            echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}${NC}${YELLOW}               -- AUTO KILLER STATUS --${NC}${CYAN}                        ${NC}"
            echo -e "${CYAN}────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}${NC} ${GREEN}● Auto Killer is running in background${NC}                           ${CYAN}${NC}"
            echo -e "${CYAN}${NC} ${GREEN}● Checks every 10 seconds${NC}                                         ${CYAN}${NC}"
            echo -e "${CYAN}${NC} ${GREEN}● Auto deletes expired users${NC}                                      ${CYAN}${NC}"
            echo -e "${CYAN}${NC} ${GREEN}● Auto kills users exceeding limit${NC}                                ${CYAN}${NC}"
            echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
            sleep 3
            ;;
        0|00) 
            echo -e "${RED}[⚠️] Cannot exit! Service must run permanently.${NC}"
            echo -e "${YELLOW}[💡] Use 'systemctl stop evtbash' to stop service${NC}"
            sleep 2
            ;;
        *) sleep 1 ;;
    esac
done
