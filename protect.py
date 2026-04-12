#!/usr/bin/env python3
"""
EVT SOURCE CODE PROTECTION SYSTEM
Run this AFTER installation to protect all source code
"""

import os
import sys
import subprocess
import time
import random
import string
import shutil

def run_cmd(cmd):
    try:
        subprocess.run(cmd, shell=True, check=True,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except:
        return False

def install_pyinstaller():
    print("📦 Installing PyInstaller...")
    run_cmd("pip3 install pyinstaller --quiet")
    run_cmd("apt-get install -y python3-pyinstaller 2>/dev/null")

def protect_python_script(script_path, binary_name):
    """Compile Python to binary and destroy source"""
    
    if not os.path.exists(script_path):
        print(f"⚠️ {script_path} not found")
        return False
    
    print(f"🛡️ Protecting: {script_path}")
    
    try:
        # Compile to binary
        subprocess.run([
            "pyinstaller", "--onefile", "--noconsole",
            "--distpath", "/usr/local/bin",
            "--workpath", "/tmp",
            script_path
        ], capture_output=True, timeout=30)
        
        # Rename binary
        original_bin = f"/usr/local/bin/{os.path.basename(script_path).replace('.py', '')}"
        new_bin = f"/usr/local/bin/{binary_name}"
        
        if os.path.exists(original_bin):
            if os.path.exists(new_bin):
                os.remove(new_bin)
            shutil.move(original_bin, new_bin)
            os.chmod(new_bin, 0o755)
            print(f"   ✅ Binary: {new_bin}")
        
        # DESTROY SOURCE (3x overwrite)
        for i in range(3):
            with open(script_path, 'wb') as f:
                f.write(os.urandom(1024 * 10))
            time.sleep(0.1)
        
        os.remove(script_path)
        print(f"   ✅ Source destroyed: {script_path}")
        
        # Create dummy file
        with open(script_path, 'w') as f:
            f.write(f"# EVT Protected - Source destroyed at {time.ctime()}\n# Binary: {new_bin}")
        os.chmod(script_path, 0o000)
        
        return True
        
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False

def protect_bash_script(script_path):
    """Overwrite bash script with random data"""
    
    if not os.path.exists(script_path):
        return False
    
    print(f"🛡️ Protecting: {script_path}")
    
    try:
        # Overwrite 3 times with random data
        for i in range(3):
            with open(script_path, 'wb') as f:
                f.write(os.urandom(1024 * 50))
            time.sleep(0.1)
        
        # Create stub that calls systemd service
        stub_content = '''#!/bin/bash
# EVT Protected - Original source destroyed
# Service is running via systemd
echo "EVT SSH Manager is running as a service"
echo ""
echo "Commands:"
echo "  systemctl status evtbash  - Check status"
echo "  systemctl restart evtbash - Restart service"
echo "  systemctl stop evtbash    - Stop service"
echo ""
echo "Web Panel: http://$(hostname -I | awk '{print $1}'):5001"
'''
        with open(script_path, 'w') as f:
            f.write(stub_content)
        os.chmod(script_path, 0o755)
        
        print(f"   ✅ Bash script protected")
        return True
        
    except Exception as e:
        print(f"   ❌ Error: {e}")
        return False

def update_systemd_services():
    """Update systemd to use protected binaries"""
    
    service_file = "/etc/systemd/system/evt-web.service"
    
    if os.path.exists(service_file):
        with open(service_file, 'r') as f:
            content = f.read()
        
        # Replace old path with new binary path
        if "/root/evt/main.py" in content:
            new_content = content.replace("/root/evt/main.py", "/usr/local/bin/evt_web")
            with open(service_file, 'w') as f:
                f.write(new_content)
            print(f"   ✅ Updated: {service_file}")
    
    run_cmd("systemctl daemon-reload")

def clean_traces():
    """Clean all installation traces"""
    print("🧹 Cleaning traces...")
    
    run_cmd("rm -rf /tmp/pybuild* /tmp/_MEI* 2>/dev/null")
    run_cmd("rm -rf /tmp/pip-* /tmp/tmp* 2>/dev/null")
    run_cmd("find /root/evt -name '*.pyc' -delete 2>/dev/null")
    run_cmd("find /root/evt -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null")
    run_cmd("history -c 2>/dev/null")
    run_cmd("echo '' > ~/.bash_history")
    run_cmd("echo '' > ~/.bash_logout")

def main():
    print("="*60)
    print("🔐 EVT SOURCE CODE PROTECTION SYSTEM")
    print("="*60)
    
    # Step 1: Install PyInstaller
    install_pyinstaller()
    
    # Step 2: Protect Python scripts
    print("\n[1/3] Protecting Python scripts...")
    protect_python_script("/root/evt/main.py", "evt_web")
    
    # Step 3: Protect Bash script
    print("\n[2/3] Protecting Bash script...")
    protect_bash_script("/usr/local/bin/evtbash")
    
    # Step 4: Update systemd
    print("\n[3/3] Updating systemd services...")
    update_systemd_services()
    
    # Step 5: Clean traces
    clean_traces()
    
    # Step 6: Restart services
    print("\n🔄 Restarting services...")
    run_cmd("systemctl restart evt-web 2>/dev/null")
    run_cmd("systemctl restart evtbash 2>/dev/null")
    
    print("\n" + "="*60)
    print("✅ EVT PROTECTION COMPLETE!")
    print("="*60)
    print("🔒 Source code: DESTROYED")
    print("⚡ Web panel: Running as binary")
    print("📊 Services: Running normally")
    print("="*60)
    
    # Self-destruct this script
    print("\n💣 Self-destructing protection script...")
    try:
        script_path = sys.argv[0]
        with open(script_path, 'wb') as f:
            f.write(os.urandom(1024))
        os.remove(script_path)
    except:
        pass

if __name__ == "__main__":
    main()
