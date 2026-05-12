#!/usr/bin/env python3
"""
EVT AUTO PROTECTION - PERMANENT MODE (WITH AUTO REPAIR)
=========================================================
- Compiles app.py to binary
- Creates systemd service for auto-start on boot
- Runs in background permanently
- DESTROYS all source code files
- Survives VPS reboot
- AUTO REPAIR if binary is corrupted or missing
- Returns to original directory after execution
"""

import os
import sys
import subprocess
import time

def run_cmd(cmd):
    try:
        subprocess.run(cmd, shell=True, check=True,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except:
        return False

def install_pyinstaller():
    """Install PyInstaller for compiling Python to binary"""
    run_cmd("pip3 install pyinstaller --quiet")
    run_cmd("apt-get install -y python3-pyinstaller 2>/dev/null")

def find_app_py():
    """Find app.py in possible locations"""
    possible_paths = [
        "/tmp/app.py",
        "/root/app.py",
        "/root/evt/app.py",
        "/root/auto.py",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "app.py"),
        os.getcwd() + "/app.py",
        os.getcwd() + "/auto.py"
    ]
    
    for path in possible_paths:
        if path and os.path.exists(path):
            return path
    return None

def download_app_from_github():
    """Download app.py from GitHub if not found locally"""
    print("[📥] Downloading app.py from GitHub...")
    try:
        subprocess.run([
            "wget", "-q", "-O", "/tmp/app.py",
            "https://raw.githubusercontent.com/ahlyan/evt/refs/heads/main/app.py"
        ], timeout=30, check=True)
        if os.path.exists("/tmp/app.py") and os.path.getsize("/tmp/app.py") > 10000:
            print("[✅] app.py downloaded successfully!")
            return "/tmp/app.py"
        else:
            print("[❌] Download failed or file too small")
            return None
    except:
        print("[❌] Failed to download app.py")
        return None

def check_binary_valid():
    """Check if binary exists and is valid"""
    binary_path = "/usr/local/bin/evt_manager"
    if not os.path.exists(binary_path):
        return False
    if os.path.getsize(binary_path) < 1000000:  # Less than 1MB is suspicious
        return False
    return True

def protect_app_py():
    """Compile app.py to binary and destroy source"""
    app_path = find_app_py()
    
    # If not found, try to download from GitHub
    if not app_path:
        print("[⚠️] app.py not found locally. Attempting to download...")
        app_path = download_app_from_github()
    
    if not app_path:
        print("[❌] Could not find or download app.py!")
        return False
    
    print(f"[🛡️] Found app.py at: {app_path}")
    
    try:
        # Compile to binary using PyInstaller
        subprocess.run([
            "pyinstaller", "--onefile", "--noconsole",
            "--distpath", "/usr/local/bin",
            "--workpath", "/tmp/pybuild",
            "--specpath", "/tmp",
            "--name", "evt_manager",
            app_path
        ], capture_output=True, timeout=120)
        
        binary_path = "/usr/local/bin/evt_manager"
        if os.path.exists(binary_path):
            os.chmod(binary_path, 0o755)
            print(f"[✅] Binary created: {binary_path}")
        else:
            print("[❌] Binary not created!")
            return False
        
        # Destroy source (3x overwrite with random data)
        for i in range(3):
            with open(app_path, 'wb') as f:
                f.write(os.urandom(1024 * 50))
            time.sleep(0.2)
        
        # Remove original
        os.remove(app_path)
        print(f"[✅] Source destroyed: {app_path}")
        
        return True
    except Exception as e:
        print(f"[❌] Error: {e}")
        return False

def self_destruct_all_sources():
    """DESTROY ALL SOURCE CODE FILES - No trace left behind"""
    # Destroy Python files in /root/evt directory
    if os.path.exists("/root/evt"):
        for root, dirs, files in os.walk("/root/evt"):
            for file in files:
                if file.endswith(".py"):
                    file_path = os.path.join(root, file)
                    try:
                        for i in range(3):
                            with open(file_path, 'wb') as f:
                                f.write(os.urandom(1024 * 50))
                            time.sleep(0.1)
                        os.remove(file_path)
                    except:
                        pass
    
    # Destroy app.py in /tmp and /root
    for py_file in ["/tmp/app.py", "/root/app.py", "/root/auto.py"]:
        if os.path.exists(py_file):
            try:
                for i in range(3):
                    with open(py_file, 'wb') as f:
                        f.write(os.urandom(1024 * 50))
                    time.sleep(0.1)
                os.remove(py_file)
            except:
                pass
    
    # Destroy all Python cache files
    run_cmd("find /tmp -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null")
    run_cmd("find /root -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null")
    run_cmd("find /tmp -name '*.pyc' -delete 2>/dev/null")
    run_cmd("find /root -name '*.pyc' -delete 2>/dev/null")
    run_cmd("find /tmp -name '*.pyo' -delete 2>/dev/null")
    run_cmd("find /root -name '*.pyo' -delete 2>/dev/null")
    
    return True

def repair_binary_if_needed():
    """Check and repair binary if missing or corrupted"""
    if check_binary_valid():
        print("[✅] Binary is valid and working")
        return True
    
    print("[⚠️] Binary is missing or corrupted! Auto-repairing...")
    
    # Try to find app.py or download it
    app_path = find_app_py()
    if not app_path:
        app_path = download_app_from_github()
    
    if app_path:
        return protect_app_py()
    
    print("[❌] Cannot repair - no app.py source available")
    return False

def run_in_background():
    """Run binary in background with nohup"""
    run_cmd("pkill -f evt_manager 2>/dev/null")
    run_cmd("systemctl stop evt-manager 2>/dev/null")
    run_cmd("screen -S evt -X quit 2>/dev/null")
    time.sleep(1)
    run_cmd("nohup /usr/local/bin/evt_manager > /var/log/evt_manager.log 2>&1 &")
    time.sleep(2)
    return True

def create_systemd_service():
    """Create systemd service for auto-start on boot (PERMANENT)"""
    service_content = '''[Unit]
Description=EVT SSH Manager - Permanent Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/evt_manager
Restart=always
RestartSec=5
User=root
WorkingDirectory=/root
StandardOutput=null
StandardError=null
SyslogIdentifier=evt-manager

[Install]
WantedBy=multi-user.target
'''
    
    with open("/etc/systemd/system/evt-manager.service", "w") as f:
        f.write(service_content)
    
    run_cmd("systemctl daemon-reload")
    run_cmd("systemctl enable evt-manager")
    run_cmd("systemctl restart evt-manager")
    return True

def create_watchdog():
    """Create watchdog to ensure service keeps running"""
    watchdog_script = '''#!/bin/bash
# EVT Watchdog - Ensures service keeps running
while true; do
    if ! pgrep -f "evt_manager" > /dev/null; then
        echo "$(date): evt_manager not running, restarting..." >> /var/log/evt_watchdog.log
        /usr/local/bin/evt_manager > /var/log/evt_manager.log 2>&1 &
    fi
    sleep 10
done
'''
    watchdog_path = "/usr/local/bin/evt_watchdog.sh"
    with open(watchdog_path, "w") as f:
        f.write(watchdog_script)
    os.chmod(watchdog_path, 0o755)
    
    watchdog_service = '''[Unit]
Description=EVT Watchdog - Auto Restart Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/evt_watchdog.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
'''
    with open("/etc/systemd/system/evt-watchdog.service", "w") as f:
        f.write(watchdog_service)
    
    run_cmd("systemctl daemon-reload")
    run_cmd("systemctl enable evt-watchdog")
    run_cmd("systemctl restart evt-watchdog")
    return True

def create_evt_command():
    """Create 'evt' command for easy access"""
    cmd_content = '''#!/bin/bash
# EVT Command - Easy access to panel management
case "$1" in
    status)
        systemctl status evt-manager
        ;;
    restart)
        systemctl restart evt-manager
        echo "EVT Manager restarted"
        ;;
    stop)
        systemctl stop evt-manager
        echo "EVT Manager stopped"
        ;;
    start)
        systemctl start evt-manager
        echo "EVT Manager started"
        ;;
    logs)
        tail -f /var/log/evt_manager.log
        ;;
    watchdog)
        systemctl status evt-watchdog
        ;;
    repair)
        echo "Running repair..."
        /usr/local/bin/evt_repair
        ;;
    *)
        echo "EVT SSH Manager - Commands:"
        echo "  evt status   - Check service status"
        echo "  evt restart  - Restart panel"
        echo "  evt stop     - Stop panel"
        echo "  evt start    - Start panel"
        echo "  evt logs     - View live logs"
        echo "  evt watchdog - Check watchdog status"
        echo "  evt repair   - Repair binary if corrupted"
        echo ""
        echo "Web Panel: http://$(hostname -I | awk '{print $1}'):5000"
        ;;
esac
'''
    with open("/usr/local/bin/evt", "w") as f:
        f.write(cmd_content)
    os.chmod("/usr/local/bin/evt", 0o755)
    
    with open("/root/.bashrc", "a") as f:
        f.write('\nalias evt="/usr/local/bin/evt"\n')
    
    return True

def create_repair_command():
    """Create repair command for emergency"""
    repair_content = '''#!/usr/bin/env python3
import os
import subprocess
import sys

# Kill existing processes
os.system("pkill -f evt_manager 2>/dev/null")
os.system("systemctl stop evt-manager 2>/dev/null")

# Download app.py
subprocess.run(["wget", "-q", "-O", "/tmp/app.py", 
               "https://raw.githubusercontent.com/ahlyan/evt/refs/heads/main/app.py"], timeout=30)

# Compile
subprocess.run([
    "pyinstaller", "--onefile", "--noconsole",
    "--distpath", "/usr/local/bin",
    "--workpath", "/tmp/pybuild",
    "--specpath", "/tmp",
    "--name", "evt_manager",
    "/tmp/app.py"
], timeout=120)

# Restart service
os.system("chmod +x /usr/local/bin/evt_manager")
os.system("systemctl restart evt-manager")

print("✅ Repair completed!")
'''
    with open("/usr/local/bin/evt_repair", "w") as f:
        f.write(repair_content)
    os.chmod("/usr/local/bin/evt_repair", 0o755)
    return True

def clean_traces():
    """Clean all installation traces"""
    run_cmd("rm -rf /tmp/pybuild* /tmp/_MEI* 2>/dev/null")
    run_cmd("rm -rf /tmp/pip-* /tmp/tmp* 2>/dev/null")
    run_cmd("rm -rf ~/.cache/pip 2>/dev/null")
    run_cmd("rm -rf /root/.cache/pip 2>/dev/null")
    run_cmd("rm -rf /root/evt/__pycache__ 2>/dev/null")
    run_cmd("history -c 2>/dev/null")
    run_cmd("rm -f ~/.bash_history ~/.python_history 2>/dev/null")
    run_cmd("rm -f /root/.bash_history /root/.python_history 2>/dev/null")

def main():
    original_dir = os.getcwd()
    
    print("\n" + "="*60)
    print("🔐 EVT PROTECTION SYSTEM")
    print("="*60)
    
    # Step 1: Install PyInstaller
    install_pyinstaller()
    
    # Step 2: Check binary and repair if needed
    print("\n[1/5] Checking binary status...")
    if not check_binary_valid():
        print("[⚠️] Binary needs repair!")
        protect_app_py()
    else:
        print("[✅] Binary is valid")
    
    # Step 3: Compile/Reprotect app.py
    print("\n[2/5] Ensuring protection...")
    if not check_binary_valid():
        protect_app_py()
    
    # Step 4: Destroy all source files
    print("\n[3/5] Destroying source files...")
    self_destruct_all_sources()
    
    # Step 5: Setup services
    print("\n[4/5] Setting up services...")
    run_in_background()
    create_systemd_service()
    create_watchdog()
    create_evt_command()
    create_repair_command()
    
    # Step 6: Clean traces
    print("\n[5/5] Cleaning traces...")
    clean_traces()
    
    # Final status
    print("\n" + "="*60)
    if check_binary_valid():
        print("✅ EVT PROTECTION COMPLETE!")
        print("   🔒 All source code has been DESTROYED")
        print("   ⚡ Panel is running in BACKGROUND")
        print("   🔄 VPS reboot? Panel auto-start will handle it")
        print("   🔧 Binary auto-repair is enabled")
        print("   📋 Commands: evt status, evt restart, evt logs")
    else:
        print("⚠️ EVT PROTECTION PARTIAL!")
        print("   📥 Binary may need manual repair")
        print("   🔧 Run: evt_repair")
    
    print("="*60)
    
    # Return to original directory
    os.chdir(original_dir)
    
    # Self-destruct this script
    try:
        script_path = sys.argv[0]
        for i in range(3):
            with open(script_path, 'wb') as f:
                f.write(os.urandom(1024))
            time.sleep(0.2)
        os.remove(script_path)
    except:
        pass

if __name__ == "__main__":
    main()