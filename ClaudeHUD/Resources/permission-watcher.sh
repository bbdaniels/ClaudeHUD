#!/bin/zsh
# Permission approval hook for ClaudeHUD
# Installed as a PermissionRequest hook in ~/.claude/settings.json
#
# Flow:
#   1. Claude Code fires this hook when a permission dialog is about to show
#   2. Script checks: HUD alive?
#   3. Writes pending request and blocks waiting for HUD decision
#   4. ClaudeHUD shows Approve/Deny buttons
#   5. Script reads the decision and outputs it to stdout
#   6. If timeout or HUD not running, exits with no output (normal terminal prompt)

HUD_DIR="$HOME/.claude/hud"
HEARTBEAT="$HUD_DIR/heartbeat"
PENDING_DIR="$HUD_DIR/pending"
DECISION_DIR="$HUD_DIR/decisions"

# Read tool info from stdin
INPUT=$(cat)

# Check if HUD is alive (heartbeat within last 15 seconds)
if [ ! -f "$HEARTBEAT" ]; then
    exit 0
fi
LAST_BEAT=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $((NOW - LAST_BEAT)) -gt 15 ]; then
    exit 0
fi

# Write pending request
mkdir -p "$PENDING_DIR" "$DECISION_DIR"
ID=$(uuidgen | tr '[:upper:]' '[:lower:]')

echo "$INPUT" | python3 -c "
import json, sys, time, os
try:
    data = json.load(sys.stdin)
    data['id'] = '$ID'
    data['timestamp'] = time.time()
    data['project'] = os.path.basename(os.getcwd())
    data['project_path'] = os.getcwd()
    with open(os.path.join('$PENDING_DIR', '$ID.json'), 'w') as f:
        json.dump(data, f)
except Exception as e:
    sys.exit(1)
" 2>/dev/null

# If write failed, fall through
[ $? -ne 0 ] && exit 0

# Clean up pending file on any exit (including SIGTERM/SIGINT when user
# approves directly in Claude Code's terminal, killing this hook process)
trap 'rm -f "$PENDING_DIR/$ID.json"' EXIT INT TERM HUP PIPE

# Poll for decision (timeout 90s, poll every 0.3s)
# Touch the pending file each iteration as a heartbeat for the HUD.
POLLS=300
for i in $(seq 1 $POLLS); do
    DECISION_FILE="$DECISION_DIR/$ID.json"
    if [ -f "$DECISION_FILE" ]; then
        cat "$DECISION_FILE"
        rm -f "$DECISION_FILE" "$PENDING_DIR/$ID.json"
        exit 0
    fi
    touch "$PENDING_DIR/$ID.json" 2>/dev/null
    sleep 0.3
done

# Timeout — clean up, fall through to normal terminal prompt
rm -f "$PENDING_DIR/$ID.json"
exit 0
