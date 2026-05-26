#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.0.0
# source: ClaudeHUD/Resources/Scripts/vault-ingest.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# SessionEnd hook — distil a COMPLETED Claude session into the Obsidian
# wiki (Karpathy "ingest"). Canonical-project model: the wiki is the sole
# authority for project↔session mapping (schema.md §"Canonical project
# model"); cwd is resolved against each project's Tasks.md `cwds:`
# claims — never fuzzy-matched, never guessed.
#
# Modes:
#   (default, stdin JSON)  SessionEnd hook: cheap filters + loop guard,
#                          then DETACH phase 2.
#   --run S T C            phase 2 worker (session_id transcript cwd).
#   --audit                local sweep: list likely un-ingested / failed
#                          transcripts (the cloud Action cannot see these).
#
# Design notes (addresses the stress-test findings):
#  * `claude -p` is READ-ONLY (Read,Grep,Glob) over a TEMP COPY of the one
#    transcript and prints the digest to stdout between markers. The shell
#    does all vault writes. → no bypassPermissions blast radius, no
#    half-written-file race.
#  * `.done` only on success+nonempty; `.failed` otherwise (retried/visible).
#  * idempotency key = transcript basename + byte size (resumed/grown
#    transcripts re-ingest).
set -u
VAULT="/Users/bbdaniels/Documents/Obsidian"
STATE="$HOME/.claude/ingest-state"
PROMPT="$HOME/.claude/scripts/vault-ingest-prompt.md"
CLAUDE="${VAULT_INGEST_CLAUDE:-$HOME/.local/bin/claude}"   # override = testability only
LOG="/tmp/vault-ingest.out"
FLOOR=6000
mkdir -p "$STATE"

# ---- resolver: cwd -> vault project folder via Tasks.md cwds: ----
# Prints the project folder name, or empty for unclaimed (→ Misc inbox).
resolve_project() {
  python3 - "$1" "$VAULT" <<'PY'
import sys, os, fnmatch, re
cwd, vault = sys.argv[1], sys.argv[2]
FM = re.compile(r'^---\n(.*?)\n---\n', re.DOTALL)
def claims(folder):
    dash = os.path.join(vault, folder, "Tasks.md")   # cwds: live in Tasks.md
    if not os.path.isfile(dash): return []
    try: txt = open(dash, encoding="utf-8", errors="replace").read()
    except Exception: return []
    m = FM.match(txt)
    if not m: return []
    out, key = [], None
    for line in m.group(1).splitlines():
        s = line.strip()
        if re.match(r'^(cwds|migrated-from)\s*:', line):
            key = True
            inline = line.split(":", 1)[1].strip()
            if inline and inline not in ("[]", "~"):
                out.append(inline.strip("'\"[] "))
            continue
        if key and s.startswith("- "):
            out.append(s[2:].strip().strip("'\""))
            continue
        if line and not line[0].isspace():
            key = None
    return [p for p in out if p.startswith("/")]
best, blen = "", -1
for folder in sorted(os.listdir(vault)):
    if not os.path.isdir(os.path.join(vault, folder)) or folder.startswith("."):
        continue
    for pat in claims(folder):
        if cwd == pat or fnmatch.fnmatch(cwd, pat) or \
           cwd == pat.rstrip("/*") or cwd.startswith(pat.rstrip("*").rstrip("/") + "/"):
            if len(pat) > blen:
                best, blen = folder, len(pat)
print(best)
PY
}

# ---------------- --audit ----------------
if [ "${1:-}" = "--audit" ]; then
  echo "=== vault-ingest --audit $(date -u +%FT%TZ) ==="
  echo "-- .failed markers (ingest errored; will retry on next SessionEnd) --"
  ls -1 "$STATE"/*.failed 2>/dev/null | sed 's#.*/#  #' || echo "  (none)"
  echo "-- transcripts >${FLOOR}B, no .done, modified <14d (possibly un-ingested) --"
  found=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    b=$(wc -c < "$f" 2>/dev/null | tr -d ' '); [ "${b:-0}" -lt "$FLOOR" ] && continue
    key="$(basename "$f").$b.done"
    [ -f "$STATE/$key" ] && continue
    echo "  $f (${b}B)"; found=1
  done <<EOF
$(find "$HOME/.claude/projects" -name '*.jsonl' -mtime -14 2>/dev/null)
EOF
  [ "$found" = 0 ] && echo "  (none)"
  exit 0
fi

# ---------------- phase 1: SessionEnd hook ----------------
if [ "${1:-}" != "--run" ]; then
  [ -n "${VAULT_INGEST:-}" ] && exit 0          # loop guard (our own claude -p)
  [ -f "$STATE/PAUSED" ] && exit 0              # pause switch (vault maintenance)
  payload="$(cat 2>/dev/null)"
  rf() { printf '%s' "$payload" | python3 -c "import sys,json;print((json.load(sys.stdin) or {}).get('$1',''))" 2>/dev/null; }
  sid="$(rf session_id)"; tpath="$(rf transcript_path)"; cwd="$(rf cwd)"
  [ -z "$tpath" ] || [ ! -f "$tpath" ] && exit 0
  case "$cwd" in
    "$VAULT"|"$VAULT"/*) exit 0;;
    "$HOME"|"$HOME/.claude"|"$HOME/.claude"/*) exit 0;;
    "$HOME"/*) ;;                 # real work dirs only…
    *) exit 0;;                   # …excludes "/", transient/headless cwds
  esac
  [ -d "$cwd" ] || exit 0         # cwd must still exist
  bytes="$(wc -c < "$tpath" 2>/dev/null | tr -d ' ')"
  [ "${bytes:-0}" -lt "$FLOOR" ] && exit 0
  [ -f "$STATE/$(basename "$tpath").$bytes.done" ] && exit 0
  # Bounded retry: a poison transcript must not re-run Sonnet every
  # session-end. If it failed <6h ago, wait; older → allow a retry.
  fm="$STATE/$(basename "$tpath").$bytes.failed"
  [ -f "$fm" ] && [ -n "$(find "$fm" -mmin -360 2>/dev/null)" ] && exit 0
  VAULT_INGEST=1 nohup bash "$0" --run "$sid" "$tpath" "$cwd" >>"$LOG" 2>&1 &
  disown 2>/dev/null || true
  exit 0
fi

# ---------------- phase 2: detached worker ----------------
sid="${2:-}"; tpath="${3:-}"; cwd="${4:-}"
export VAULT_INGEST=1
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
bytes="$(wc -c < "$tpath" 2>/dev/null | tr -d ' ')"
key="$(basename "$tpath").${bytes}"
echo "===== $ts vault-ingest sid=$sid cwd=$cwd ====="
[ -x "$CLAUDE" ] && [ -f "$PROMPT" ] && [ -f "$tpath" ] || { echo "precond fail"; exit 0; }

proj="$(resolve_project "$cwd")"
if [ -n "$proj" ]; then
  target_dir="$VAULT/$proj"; logf="$target_dir/Session Log.md"; ledg="$target_dir/Sessions.md"
else
  # Unclaimed → inbox for human triage. Digest only; NO ledger table
  # (a real ledger row is added when a human/cleaner files it to a project).
  proj="Misc (unclaimed)"; target_dir="$VAULT/Misc"; logf="$target_dir/Session Inbox.md"; ledg=""
fi
mkdir -p "$target_dir"
echo "resolved project: $proj"

# Temp copy of ONLY this transcript; the agent gets read access to nothing else.
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/vingest.XXXXXX")"
trap 'rm -rf "$tmpd"' EXIT
cp "$tpath" "$tmpd/transcript.jsonl" 2>/dev/null || { echo "copy fail"; exit 0; }

prompt_text="$(cat "$PROMPT")

--- RUN CONTEXT ---
TRANSCRIPT: $tmpd/transcript.jsonl
PROJECT: $proj
SESSION_ID: $sid
SESSION_CWD: $cwd
TODAY_UTC: $(date -u +%Y-%m-%d)"

out="$("$CLAUDE" -p \
  --model claude-sonnet-4-6 \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --add-dir "$tmpd" \
  --max-turns 40 \
  "$prompt_text" 2>>"$LOG")"
rc=$?
echo "claude rc=$rc"

if [ "$rc" -ne 0 ]; then
  : > "$STATE/${key}.failed"
  echo "INGEST FAILED (rc=$rc) — marked .failed, will retry on next SessionEnd"
  exit 0
fi

# Extract the digest strictly between markers (model writes nothing to disk).
digest="$(printf '%s' "$out" | awk '/<<<DIGEST>>>/{f=1;next} /<<<END>>>/{f=0} f')"

append_atomic() {  # $1=file  $2=content-to-append
  local f="$1" tmp; tmp="$(mktemp "${f}.XXXXXX.tmp")"
  { [ -f "$f" ] && cat "$f"; printf '%s\n' "$2"; } > "$tmp"
  mv -f "$tmp" "$f"
}

# Per-target lock: real sessions ending close together run concurrent
# workers; serialize their read→append→mv so none is lost. mkdir is
# atomic. Best-effort: after ~40s give up the lock and proceed (a rare
# interleave beats hanging or dropping the digest).
LOCK="$target_dir/.ingest.lock"
locked=0
for _ in $(seq 1 80); do
  if mkdir "$LOCK" 2>/dev/null; then locked=1; break; fi
  sleep 0.5
done
cleanup() { [ "$locked" = 1 ] && rmdir "$LOCK" 2>/dev/null; rm -rf "$tmpd"; }
trap cleanup EXIT
[ "$locked" = 1 ] || echo "WARN: proceeding without lock (timeout)"

# Ledger row (provenance) — only for a resolved project, never the inbox.
if [ -n "$ledg" ]; then
  if [ ! -f "$ledg" ]; then
    printf '%s\n' "---" "type: session-ledger" "maintained_by: vault-ingest (append-only) + human curation" "---" "" "# $proj — Session Ledger" "" "Append-only. Automation proposes \`ingested\`/\`failed\` rows; humans + the cleaner curate (corrections are new \`reassigned\`/\`manual\` rows; prior rows never edited). See [[schema]] §Canonical project model." "" "| utc | session_id | cwd | transcript | status | notes |" "|-----|------------|-----|------------|--------|-------|" > "$ledg"
  fi
  append_atomic "$ledg" "| $ts | $sid | $cwd | $(basename "$tpath") | ingested | |"
fi

if [ -n "$digest" ]; then
  if [ ! -f "$logf" ]; then
    printf '%s\n' "# $proj — Session Log" "" "Privacy-safe digests of completed sessions (Karpathy ingest). Ledger: [[Sessions]]." > "$logf"
  fi
  append_atomic "$logf" "
$digest"
  echo "digest appended to: $logf"
else
  echo "no durable content${ledg:+ — ledger row only}"
fi

: > "$STATE/${key}.done"
rm -f "$STATE/$(basename "$tpath")".*.failed 2>/dev/null
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) vault-ingest done ($proj) ====="
exit 0
