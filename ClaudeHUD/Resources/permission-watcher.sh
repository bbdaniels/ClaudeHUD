#!/bin/zsh
# Permission approval hook for ClaudeHUD
# Installed as a PreToolUse hook (no matcher) in ~/.claude/settings.json
#
# Flow:
#   1. Claude Code calls this hook before running a tool
#   2. Script checks if HUD is alive (heartbeat file)
#   3. For permission-requiring tools, writes pending request and blocks
#   4. ClaudeHUD shows Approve/Deny buttons
#   5. Script reads the decision and outputs it to stdout
#   6. If timeout or HUD not running, exits with no output (normal flow)

HUD_DIR="$HOME/.claude/hud"
HEARTBEAT="$HUD_DIR/heartbeat"
PENDING_DIR="$HUD_DIR/pending"
DECISION_DIR="$HUD_DIR/decisions"

# Read tool info from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('tool_name', ''))
except:
    print('')
" 2>/dev/null)

# Only block for tools that commonly require permission
case "$TOOL_NAME" in
    Bash|Edit|Write|NotebookEdit) ;;
    *) exit 0 ;;
esac

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

# Poll for decision (timeout 90s, poll every 0.3s)
POLLS=300
for i in $(seq 1 $POLLS); do
    DECISION_FILE="$DECISION_DIR/$ID.json"
    if [ -f "$DECISION_FILE" ]; then
        cat "$DECISION_FILE"
        rm -f "$DECISION_FILE" "$PENDING_DIR/$ID.json"
        exit 0
    fi
    sleep 0.3
done

# Timeout — clean up, fall through to normal terminal prompt
rm -f "$PENDING_DIR/$ID.json"
exit 0
