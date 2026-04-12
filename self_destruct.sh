#!/bin/bash
# EVT SELF-DESTRUCT SCRIPT
# Destroys source code after installation (fallback)

echo "🧨 EVT SELF-DESTRUCT ACTIVATED"

# Destroy Python files
if [ -d "/root/evt" ]; then
    find /root/evt -name "*.py" -type f 2>/dev/null | while read file; do
        echo "Destroying: $file"
        for i in 1 2 3; do
            dd if=/dev/urandom of="$file" bs=1K count=10 status=none 2>/dev/null
        done
        rm -f "$file"
    done
fi

# Destroy app.py if exists
if [ -f "/root/app.py" ]; then
    for i in 1 2 3; do
        dd if=/dev/urandom of="/root/app.py" bs=1K count=10 status=none 2>/dev/null
    done
    rm -f "/root/app.py"
fi

# Remove cache
rm -rf /root/evt/__pycache__ 2>/dev/null
find /root/evt -name "*.pyc" -delete 2>/dev/null

# Remove this script
rm -f /root/self_destruct.sh 2>/dev/null

echo "✅ Source code destruction completed"
