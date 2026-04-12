#!/bin/bash

# ============================================
# EVT SSH MANAGER - COMPLETE BASH SCRIPT
# IP already verified by Cloudflare Worker
# Version: 2.0 - Full Integrated
# ============================================

# ===== COLOR DEFINITIONS (Must be first) =====
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
BLUE='\033[1;34m'
NC='\033[0m'

# ===== CHECK AND INSTALL DEPENDENCIES ONCE =====
if [ ! -f "/root/.evt_deps_installed" ]; then
    echo -e "${YELLOW}[📦] Installing dependencies (first time only)...${NC}"
    apt update -y &>/dev/null
    apt install -y python3-pip net-tools screen curl wget jq uuid-runtime git &>/dev/null
    pip3 install flask flask-login requests waitress &>/dev/null
    touch /root/.evt_deps_installed
    echo -e "${GREEN}[✅] Dependencies installed${NC}"
fi

# ============================================
# CONFIGURATION FILES
# ============================================
CONFIG_FILE="/etc/evt_config"
USER_DB="/etc/evt_users.db"
KEYS_DB="/root/keys.json"
BACKUP_FILE="/root/backup.txt"
RESTORE_FILE="/root/restore.txt"
CRED_FILE="/root/.evt_panel_creds.json"
PANEL_DIR="/root/evt"
VPS_IP=""

[ ! -f "$USER_DB" ] && touch "$USER_DB"

# ============================================
# GET VPS IP FUNCTION
# ============================================
get_vps_ip() {
    VPS_IP=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null)
    [ -z "$VPS_IP" ] && VPS_IP=$(curl -s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
    [ -z "$VPS_IP" ] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$VPS_IP" ] && VPS_IP="127.0.0.1"
    echo "$VPS_IP"
}

# ============================================
# ASK FOR CUSTOM PANEL LOGIN CREDENTIALS
# ============================================
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
        echo '{"keys":{}}' > "$KEYS_DB"
    fi
    cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null || echo '{"keys":{}}'
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
        echo '{"keys":{}}' > "$KEYS_DB"
    fi
    
    local keys_data=$(cat "$KEYS_DB" 2>/dev/null | jq . 2>/dev/null)
    if [ -z "$keys_data" ] || [ "$keys_data" = "null" ]; then
        echo -e "${RED}[❌] Invalid keys.json format!${NC}"
        return 1
    fi
    
    local synced=0
    
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
        fi
    done < <(cat "$KEYS_DB" | jq -r '.keys | to_entries[] | "\(.key)|\(.value.username)|\(.value.password)|\(.value.expiry)|\(.value.limit)"' 2>/dev/null)
    
    echo -e "${GREEN}[✅] Sync completed! Synced: $synced users${NC}"
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
    
    echo -e "${GREEN}✅ User created successfully!${NC}"
    echo -e "${YELLOW}Key ID: $key_id${NC}"
    return 0
}

# ============================================
# DELETE USER FUNCTION
# ============================================
delete_user_with_keys() {
    local username="$1"
    
    if ! id "$username" &>/dev/null; then
        echo -e "${RED}User not found!${NC}"
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
    
    echo -e "${GREEN}✅ User deleted successfully!${NC}"
    return 0
}

# ============================================
# SHOW USER INFO
# ============================================
show_user_info() {
    local username="$1"
    
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                    USER INFORMATION${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    if id "$username" &>/dev/null; then
        local pass=$(grep "^$username:" "$USER_DB" 2>/dev/null | cut -d: -f2)
        local exp_date=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        [ -z "$exp_date" ] || [[ "$exp_date" == "never" ]] && exp_date="No Expiry"
        local limit=$(grep -E "^$username[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}')
        [ -z "$limit" ] && limit="1"
        local online_count=$(pgrep -u "$username" sshd 2>/dev/null | wc -l)
        
        echo -e " ${GREEN}Username:${NC} $username"
        echo -e " ${GREEN}Password:${NC} ${pass:-N/A}"
        echo -e " ${GREEN}Expiry Date:${NC} $exp_date"
        echo -e " ${GREEN}Device Limit:${NC} $limit"
        echo -e " ${GREEN}Online Sessions:${NC} $online_count / $limit"
    else
        echo -e " ${RED}User not found!${NC}"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
}

# ============================================
# DISPLAY USER TABLE
# ============================================
display_user_table() {
    auto_killer
    clear
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    printf " ${YELLOW}%-20s %-15s %-20s %-15s${NC}\n" "Username" "Password" "Status/Limit" "Expiry Date"
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
    
    if [ ! -s "$USER_DB" ]; then
        echo -e " ${RED}No users found.${NC}"
    else
        while IFS=: read -r username pass_find; do
            if id "$username" &>/dev/null; then
                exp_t=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                [ -z "$exp_t" ] || [[ "$exp_t" == "never" ]] && exp_t="No Expiry"
                count_on=$(pgrep -u "$username" sshd 2>/dev/null | wc -l)
                u_limit=$(grep -E "^$username[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | head -n 1)
                [ -z "$u_limit" ] && u_limit="1"
                
                if [ "$count_on" -gt 0 ]; then
                    stat_print="${GREEN}${count_on}/${u_limit} Online${NC}"
                else
                    stat_print="${RED}Offline${NC}"
                fi
                printf " ${CYAN}%-20s${NC} ${WHITE}%-15s${NC} %-20b ${YELLOW}%-15s${NC}\n" "$username" "$pass_find" "$stat_print" "$exp_t"
            fi
        done < "$USER_DB"
    fi
    echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
}

# ============================================
# SYSTEM INFO
# ============================================
get_system_info() {
    auto_killer
    OS_NAME=$(lsb_release -ds 2>/dev/null | cut -c 1-20)
    [ -z "$OS_NAME" ] && OS_NAME="Ubuntu 20.04"
    UPTIME_VAL=$(uptime -p 2>/dev/null | sed 's/up //; s/ hours\?,/h/; s/ minutes\?/m/; s/ days\?,/d/' | cut -c 1-12)
    RAM_TOTAL=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    RAM_USED_PERC=$(free 2>/dev/null | grep Mem | awk '{printf("%.2f%%", $3/$2*100)}')
    CPU_CORES=$(nproc 2>/dev/null)
    CPU_LOAD=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{printf("%.2f%%", $2 + $4)}')
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
    local vps_ip=$(get_vps_ip)
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${RED}              EVT SSH MANAGER - VPS: ${GREEN}$vps_ip${RED}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e " ${BLUE}▰▰▰ SYSTEM INFO ▰▰▰${NC}"
    echo -e "   ${CYAN}OS:${NC} $OS_NAME"
    echo -e "   ${CYAN}Uptime:${NC} $UPTIME_VAL"
    echo -e "   ${CYAN}RAM:${NC} $RAM_USED_PERC / $RAM_TOTAL"
    echo -e "   ${CYAN}CPU:${NC} $CPU_LOAD ($CPU_CORES cores)"
    echo ""
    echo -e " ${BLUE}▰▰▰ USER STATS ▰▰▰${NC}"
    echo -e "   ${CYAN}Total Users:${NC} $TOTAL_USERS"
    echo -e "   ${CYAN}Online Users:${NC} $ONLINE_USERS"
    echo -e "   ${CYAN}Keys.json Users:${NC} $KEYS_TOTAL"
    echo ""
}

# ============================================
# START WEB PANEL (app.py)
# ============================================
start_web_panel() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}[🚀] Starting EVT Web Panel...${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    mkdir -p "$PANEL_DIR"
    
    # Download app.py from Cloudflare Worker
    echo -e "${YELLOW}[📥] Downloading app.py...${NC}"
    curl -sSL "https://premium.evtvip.indevs.in/app.py" -o "$PANEL_DIR/app.py" 2>/dev/null
    curl -sSL "https://evt-panel.snaymyo969s.workers.dev/app.py" -o "$PANEL_DIR/app.py" 2>/dev/null
    
    if [ ! -f "$PANEL_DIR/app.py" ]; then
        echo -e "${RED}[❌] Failed to download app.py!${NC}"
        return 1
    fi
    
    chmod 644 "$PANEL_DIR/app.py"
    
    # Install Python packages if needed
    if ! python3 -c "import flask" 2>/dev/null; then
        echo -e "${YELLOW}[📦] Installing Python packages...${NC}"
        pip3 install flask flask-login requests waitress 2>/dev/null
    fi
    
    # Kill existing processes
    pkill -f "python.*app.py" 2>/dev/null
    fuser -k 5001/tcp 2>/dev/null
    screen -X -S evt_web quit 2>/dev/null
    
    # Start web panel in screen
    cd "$PANEL_DIR"
    screen -dmS evt_web python3 app.py
    sleep 3
    
    if pgrep -f "python.*app.py" > /dev/null; then
        local vps_ip=$(get_vps_ip)
        echo -e "${GREEN}[✅] Web Panel started successfully!${NC}"
        echo -e "${GREEN}[🌐] Access at: http://$vps_ip:5001${NC}"
        echo -e "${YELLOW}[🔑] Login with your credentials${NC}"
    else
        echo -e "${RED}[❌] Failed to start web panel${NC}"
    fi
}

# ============================================
# STOP WEB PANEL
# ============================================
stop_web_panel() {
    echo -e "${YELLOW}[🛑] Stopping web panel...${NC}"
    pkill -f "python.*app.py" 2>/dev/null
    screen -X -S evt_web quit 2>/dev/null
    fuser -k 5001/tcp 2>/dev/null
    echo -e "${GREEN}[✅] Web panel stopped${NC}"
}

# ============================================
# SETUP SYSTEMD SERVICE
# ============================================
setup_systemd_service() {
    local service_name="evtbash"
    local script_path="/usr/local/bin/evtbash"
    
    cp "$0" "$script_path" 2>/dev/null
    chmod +x "$script_path"
    
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=EVT SSH Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/bin/bash $script_path
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name"
    
    echo -e "${GREEN}[✅] Auto-start service configured!${NC}"
}

# ============================================
# PORT MANAGER (Simplified)
# ============================================
port_manager_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║        PORT MANAGER                    ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo -e " ${YELLOW}[1]${NC} Change SSH Port"
        echo -e " ${YELLOW}[2]${NC} Install Dropbear (143, 110)"
        echo -e " ${YELLOW}[3]${NC} Install SSL Tunnel (443)"
        echo -e " ${YELLOW}[4]${NC} Setup WebSocket Proxy"
        echo -e " ${YELLOW}[5]${NC} Show All Ports"
        echo -e " ${YELLOW}[0]${NC} Back"
        echo ""
        read -p " Select option: " port_opt
        
        case $port_opt in
            1) 
                read -p " New SSH Port: " ssh_port
                sed -i "s/^Port .*/Port $ssh_port/" /etc/ssh/sshd_config
                systemctl restart ssh
                echo -e "${GREEN}SSH port changed to $ssh_port${NC}"
                sleep 2
                ;;
            2)
                apt-get install -y dropbear
                cat > /etc/default/dropbear << 'EOF'
NO_START=0
DROPBEAR_PORT=143
DROPBEAR_EXTRA_ARGS="-p 110"
EOF
                systemctl restart dropbear
                echo -e "${GREEN}Dropbear installed on ports 143 and 110${NC}"
                sleep 2
                ;;
            3)
                apt-get install stunnel4 -y
                openssl genrsa -out /etc/stunnel/stunnel.key 2048
                openssl req -new -x509 -key /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt -days 1095 -subj "/CN=SSHPLUS"
                cat /etc/stunnel/stunnel.key /etc/stunnel/stunnel.crt > /etc/stunnel/stunnel.pem
                cat > /etc/stunnel/stunnel.conf << 'EOF'
cert = /etc/stunnel/stunnel.pem
[ssh]
accept = 443
connect = 127.0.0.1:22
EOF
                sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4
                systemctl restart stunnel4
                echo -e "${GREEN}SSL Tunnel active on port 443${NC}"
                sleep 2
                ;;
            4)
                read -p " Enter WebSocket Port: " ws_port
                cat > /usr/local/bin/proxy_$ws_port.py << EOF
import socket, threading, select
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $ws_port))
s.listen(1000)
while True:
    c, a = s.accept()
    threading.Thread(target=lambda: exec('try:\n d=c.recv(4096)\n t=socket.socket();t.connect(("127.0.0.1",22))\n t.send(d)\n while 1:\n  r,_,_=select.select([c,t],[],[],10)\n  if c in r: t.send(c.recv(4096))\n  if t in r: c.send(t.recv(4096))\nexcept:pass\nc.close()')).start()
EOF
                python3 /usr/local/bin/proxy_$ws_port.py &
                echo -e "${GREEN}WebSocket proxy on port $ws_port${NC}"
                sleep 2
                ;;
            5)
                clear
                echo -e "${CYAN}Current Ports:${NC}"
                netstat -tunlp | grep LISTEN | awk '{print $4, $7}' | sed 's/.*://' | sort -n | uniq
                read -p " Press Enter..."
                ;;
            0) break ;;
        esac
    done
}

# ============================================
# SLOWDNS MANAGER
# ============================================
run_slowdns_manager() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                 SLOWDNS MANAGER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    local SCRIPT_URL="https://raw.githubusercontent.com/bugfloyd/dnstt-deploy/main/dnstt-deploy.sh"
    local SCRIPT_PATH="/usr/local/bin/dnstt-deploy"
    
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo -e "${YELLOW}[📥] Downloading dnstt-deploy...${NC}"
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
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                 BACKUP USERS TO TELEGRAM${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    if [ ! -s "$USER_DB" ]; then
        echo -e "${RED}No users to backup!${NC}"
        sleep 2
        return
    fi
    
    > "$BACKUP_FILE"
    while IFS=: read -r u p; do
        [[ -z "$u" || "$u" == "root" ]] && continue
        if ! id "$u" &>/dev/null; then continue; fi
        exp_raw=$(chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        [[ "$exp_raw" == "never" || -z "$exp_raw" ]] && exp_f="never" || exp_f=$(date -d "$exp_raw" +"%Y-%m-%d" 2>/dev/null || echo "never")
        lim=$(grep -E "^$u[[:space:]]+hard[[:space:]]+maxlogins" /etc/security/limits.conf 2>/dev/null | awk '{print $4}' | head -n 1)
        [ -z "$lim" ] && lim="1"
        echo "$u:$p:$exp_f:$lim" >> "$BACKUP_FILE"
    done < "$USER_DB"
    
    read -p " Bot Token: " TG_TOKEN
    read -p " Chat ID: " TG_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}Missing info!${NC}"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}Sending backup...${NC}"
    curl -s -F document=@"$BACKUP_FILE" "https://api.telegram.org/bot$TG_TOKEN/sendDocument?chat_id=$TG_CHATID" > /dev/null
    echo -e "${GREEN}Backup sent!${NC}"
    sleep 2
}

user_restore() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                 RESTORE USERS FROM RAW LINK${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    
    read -p " Paste Raw Link: " raw_link
    if [ -z "$raw_link" ]; then return; fi
    
    echo -e "${YELLOW}Downloading backup...${NC}"
    wget -q -O "$BACKUP_FILE" "$raw_link"
    
    if [ ! -s "$BACKUP_FILE" ]; then
        echo -e "${RED}Download failed!${NC}"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}Restoring users...${NC}"
    while IFS=: read -r u p exp lim; do
        [[ -z "$u" ]] && continue
        if id "$u" &>/dev/null; then
            echo -e "Skipped: $u (exists)"
            continue
        fi
        if [[ "$exp" == "never" || -z "$exp" ]]; then
            useradd -M -s /bin/false "$u" &>/dev/null
        else
            useradd -e "$exp" -M -s /bin/false "$u" &>/dev/null
        fi
        echo "$u:$p" | chpasswd &>/dev/null
        echo "$u hard maxlogins ${lim:-1}" >> /etc/security/limits.conf
        echo "$u:$p" >> "$USER_DB"
        echo -e "Restored: $u"
    done < "$BACKUP_FILE"
    
    echo -e "${GREEN}Restore completed!${NC}"
    sleep 2
}

# ============================================
# MAIN MENU
# ============================================

# Start auto-killer in background
(
    while true; do
        auto_killer
        sleep 10
    done
) &

# Setup systemd service
setup_systemd_service

# Start web panel
start_web_panel

# Main loop
while true; do
    draw_dashboard
    echo ""
    echo -e " ${YELLOW}[01]${NC} CREATE USER          ${YELLOW}[07]${NC} CHANGE EXPIRY DATE"
    echo -e " ${YELLOW}[02]${NC} CREATE TEST USER     ${YELLOW}[08]${NC} CHANGE DEVICE LIMIT"
    echo -e " ${YELLOW}[03]${NC} DELETE USER          ${YELLOW}[09]${NC} LIST ALL USERS"
    echo -e " ${YELLOW}[04]${NC} USER DETAILS         ${YELLOW}[10]${NC} RESET DOMAIN/NS"
    echo -e " ${YELLOW}[05]${NC} CHANGE USERNAME      ${YELLOW}[11]${NC} PORT MANAGER"
    echo -e " ${YELLOW}[06]${NC} CHANGE PASSWORD      ${YELLOW}[12]${NC} SLOWDNS MANAGER"
    echo -e " ${YELLOW}[13]${NC} BACKUP TO TELEGRAM   ${YELLOW}[14]${NC} RESTORE FROM LINK"
    echo -e " ${YELLOW}[15]${NC} RESTART WEB PANEL    ${YELLOW}[16]${NC} STOP WEB PANEL"
    echo -e " ${YELLOW}[17]${NC} SYNC KEYS.JSON       ${YELLOW}[99]${NC} SYSTEM INFO"
    echo -e " ${YELLOW}[00]${NC} EXIT (Service keeps running)"
    echo ""
    read -p " ◇ Select option: " opt
    
    case $opt in
        1|01)
            clear
            echo -e "${CYAN}--- CREATE NEW USER ---${NC}"
            read -p " Username: " user
            id "$user" &>/dev/null && echo -e "${RED}User exists!${NC}" && sleep 1 && continue
            read -p " Password: " pass
            read -p " Days (expiry): " days
            read -p " Device Limit: " user_limit
            create_user_with_keys "$user" "$pass" "$days" "$user_limit"
            show_user_info "$user"
            read -p " Press Enter..."
            ;;
        2|02)
            user="test_$(head /dev/urandom | tr -dc 0-9 | head -c 4)"
            create_user_with_keys "$user" "123" "1" "1"
            show_user_info "$user"
            read -p " Press Enter..."
            ;;
        3|03)
            display_user_table
            read -p " Username to delete: " user
            delete_user_with_keys "$user"
            read -p " Press Enter..."
            ;;
        4|04)
            display_user_table
            read -p " Username to view: " user
            show_user_info "$user"
            read -p " Press Enter..."
            ;;
        5|05)
            display_user_table
            read -p " Old username: " old_u
            read -p " New username: " new_u
            if id "$old_u" &>/dev/null && ! id "$new_u" &>/dev/null; then
                usermod -l "$new_u" "$old_u"
                sed -i "s/^$old_u:/$new_u:/" "$USER_DB"
                sed -i "s/$old_u hard/$new_u hard/" /etc/security/limits.conf
                echo -e "${GREEN}Username changed!${NC}"
            else
                echo -e "${RED}Cannot change!${NC}"
            fi
            read -p " Press Enter..."
            ;;
        6|06)
            display_user_table
            read -p " Username: " user
            read -p " New password: " pass
            echo "$user:$pass" | chpasswd
            sed -i "s/^$user:.*/$user:$pass/" "$USER_DB"
            echo -e "${GREEN}Password changed!${NC}"
            read -p " Press Enter..."
            ;;
        7|07)
            display_user_table
            read -p " Username: " user
            read -p " Expiry date (YYYY-MM-DD): " exp_date
            usermod -e "$exp_date" "$user"
            echo -e "${GREEN}Expiry date changed!${NC}"
            read -p " Press Enter..."
            ;;
        8|08)
            display_user_table
            read -p " Username: " user
            read -p " Device limit: " limit
            sed -i "/$user hard maxlogins/d" /etc/security/limits.conf
            echo "$user hard maxlogins $limit" >> /etc/security/limits.conf
            echo -e "${GREEN}Limit changed!${NC}"
            read -p " Press Enter..."
            ;;
        9|09)
            display_user_table
            read -p " Press Enter..."
            ;;
        10)
            rm -f "$CONFIG_FILE"
            do_initial_setup
            ;;
        11) port_manager_menu ;;
        12) run_slowdns_manager ;;
        13) user_backup ;;
        14) user_restore ;;
        15)
            start_web_panel
            read -p " Press Enter..."
            ;;
        16)
            stop_web_panel
            read -p " Press Enter..."
            ;;
        17)
            sync_keys_to_system
            read -p " Press Enter..."
            ;;
        99)
            clear
            get_system_info
            echo -e "${CYAN}System Details:${NC}"
            echo "  OS: $OS_NAME"
            echo "  Uptime: $UPTIME_VAL"
            echo "  RAM: $RAM_USED_PERC / $RAM_TOTAL"
            echo "  CPU: $CPU_LOAD ($CPU_CORES cores)"
            echo "  Users: $TOTAL_USERS"
            echo "  Online: $ONLINE_USERS"
            read -p " Press Enter..."
            ;;
        0|00)
            echo -e "${GREEN}Exiting menu. Service running in background.${NC}"
            echo -e "${YELLOW}To re-enter: screen -r evt_dashboard${NC}"
            echo -e "${YELLOW}To stop service: systemctl stop evtbash${NC}"
            exit 0
            ;;
        *) sleep 1 ;;
    esac
done