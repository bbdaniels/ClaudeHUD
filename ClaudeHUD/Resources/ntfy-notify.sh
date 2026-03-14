#!/bin/bash
# Send push notifications (ntfy.sh mobile + macOS desktop)
# Usage: echo '{"json":"..."}' | ntfy-notify.sh <hook_type>
#
# Environment vars:
#   NTFY_TOPIC   - ntfy.sh topic name (optional; skips mobile push if unset)
#   NTFY_DESKTOP - set to 1 to show macOS desktop notification

# The Notification hook is redundant with PermissionRequest -- skip it
[ "$1" = "notification" ] && exit 0

TITLE="Claude ($(basename "$PWD"))"
STAMPFILE="${TMPDIR:-/tmp}/ntfy-last-sent"

# Dedup: skip if sent within last 3 seconds
if [ -f "$STAMPFILE" ]; then
  LAST=$(cat "$STAMPFILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  [ $((NOW - LAST)) -lt 3 ] && exit 0
fi
date +%s > "$STAMPFILE"

INPUT=$(cat)

BODY=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    hook = sys.argv[1] if len(sys.argv) > 1 else ''
    inp = d.get('tool_input', {})
    tool = d.get('tool_name', '')

    def get_question():
        qs = inp.get('questions', [])
        if qs:
            return qs[0].get('question', '')[:200]
        return inp.get('question', '')[:200]

    if hook == 'ask':
        print(get_question() or 'Has a question')
    elif hook == 'permission':
        desc = inp.get('description', '')
        cmd = inp.get('command', inp.get('file_path', ''))
        if desc:
            print(desc[:200])
        elif cmd:
            print(str(cmd)[:200])
        elif tool == 'AskUserQuestion':
            print(get_question() or 'Has a question')
        else:
            print(tool or 'Needs permission')
    else:
        print(tool or 'Needs attention')
except:
    print('Needs attention')
" "$1" 2>/dev/null)

BODY="${BODY:- }"

# Desktop notification via osascript
if [ "${NTFY_DESKTOP:-0}" = "1" ]; then
    SAFE_BODY=$(echo "$BODY" | sed "s/\"/'/g")
    SAFE_TITLE=$(echo "$TITLE" | sed "s/\"/'/g")
    osascript -e "display notification \"$SAFE_BODY\" with title \"$SAFE_TITLE\"" 2>/dev/null &
fi

# Mobile push via ntfy.sh
if [ -n "$NTFY_TOPIC" ]; then
    curl -s -H "Title: $TITLE" -d "$BODY" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
fi
