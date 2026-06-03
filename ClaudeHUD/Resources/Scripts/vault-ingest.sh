#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.3.0
# source: ClaudeHUD/Resources/Scripts/vault-ingest.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# 1.3.0 (2026-05-28):
#  * --backfill skips sessions whose resolved cwd is "/" or otherwise
#    outside $HOME. Matches phase-1's hook filter (which already
#    excludes these). These sessions resolve to Misc (unclaimed) with
#    no durable content, and `claude -p` invoked on them probes the
#    broadest possible TCC surface — triggers Dropbox / Documents /
#    Downloads permission prompts on every cycle. The phase-1 filter
#    already caught them at SessionEnd time; this brings --backfill
#    in line so the historical pile of cwd=/ transcripts stops
#    pinging.
# 1.2.0 (2026-05-28):
#  * --backfill now extracts cwd from the transcript's own JSON
#    metadata (a line carrying `"cwd":"..."`) instead of decoding the
#    encoded-path name. Eliminates the hyphen-in-project-name SKIPs
#    (estonia-qbs etc.). Falls back to the naive decode if no metadata
#    line is present.
#  * --backfill honors the PAUSED flag so a single pause toggle
#    stops both the SessionEnd hook and the periodic backfill job.
#  * Paired with com.bbdaniels.vault-backfill.plist (every 30 min
#    background drain via launchd; backfill 10 sessions per tick).
# 1.1.0 (2026-05-28):
#  * Phase-1 filter and --audit now skip subagent transcripts
#    (*/subagents/*) and home-cwd transcripts (project dir
#    -Users-bbdaniels exactly): they don't belong in the ingest queue.
#  * New --backfill [N] mode: run up to N pending eligible transcripts
#    in sequence (cockpit "Process backlog" button). Drains the
#    historical pile of un-ingested sessions one batch at a time.
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

# Predicate: should this transcript path be eligible for ingest?
# Centralises the file-level filters used by --audit, --backfill, and
# (informationally) the phase-1 SessionEnd hook. Mirror these in the
# Swift HUD's VaultIngestService.scanPendingTranscripts so the cockpit
# count agrees with what the worker will actually process.
#
#   Skip */subagents/*     — inner-agent transcripts, captured by parent
#   Skip -Users-bbdaniels/ — sessions with cwd == $HOME (already filtered
#                            by phase 1; this drops the historical pile)
is_ingest_eligible_path() {
  local p="$1"
  case "$p" in
    */subagents/*) return 1 ;;
    "$HOME/.claude/projects/-Users-bbdaniels/"*) return 1 ;;
  esac
  return 0
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
    is_ingest_eligible_path "$f" || continue
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

# ---------------- --backfill [N] ----------------
# Drain up to N pending eligible transcripts in sequence. Default N=10
# so a single periodic tick (or cockpit click) costs ~10 short Claude
# calls, not 1000+. Each one shells out to `--run` synchronously so we
# can stop on the first non-zero exit and keep the failure visible as
# `.failed`.
#
# cwd resolution: read the transcript's own JSON metadata
# (`"cwd":"..."`) — this is the cwd Claude Code recorded at session
# start and survives arbitrary hyphens in project directory names.
# Falls back to the naive encoded-dir decode if no metadata line is
# present (rare; only true for transcripts that never opened in a
# project context).
if [ "${1:-}" = "--backfill" ]; then
  [ -f "$STATE/PAUSED" ] && { echo "PAUSED — skipping backfill"; exit 0; }
  limit="${2:-10}"
  case "$limit" in (*[!0-9]*) limit=10;; esac
  [ "$limit" -lt 1 ] && limit=10
  echo "=== vault-ingest --backfill N=$limit $(date -u +%FT%TZ) ==="
  processed=0; skipped=0; failed=0
  while IFS= read -r f; do
    [ "$processed" -ge "$limit" ] && break
    [ -z "$f" ] && continue
    is_ingest_eligible_path "$f" || { skipped=$((skipped+1)); continue; }
    b=$(wc -c < "$f" 2>/dev/null | tr -d ' '); [ "${b:-0}" -lt "$FLOOR" ] && continue
    key="$(basename "$f").$b.done"
    [ -f "$STATE/$key" ] && continue
    # cwd from transcript JSON metadata; fall back to naive decode.
    cwd="$(grep -m1 -oE '"cwd":"[^"]*"' "$f" 2>/dev/null | sed 's/"cwd":"//; s/"$//')"
    if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
      proj_dir="$(dirname "$f" | sed "s#$HOME/.claude/projects/##" | sed 's#/subagents##')"
      cwd="/$(printf '%s' "$proj_dir" | tr '-' '/')"
    fi
    [ -d "$cwd" ] || { skipped=$((skipped+1)); continue; }
    # Same eligibility surface as phase-1 (the SessionEnd hook): cwd
    # must be a real subdir of $HOME, not vault, not .claude, not "/",
    # not /tmp etc. Stops `claude -p` from running with the broadest
    # possible TCC scope (Dropbox / Documents / Downloads prompts).
    case "$cwd" in
      "$VAULT"|"$VAULT"/*) skipped=$((skipped+1)); continue ;;
      "$HOME"|"$HOME/.claude"|"$HOME/.claude"/*) skipped=$((skipped+1)); continue ;;
      "$HOME"/*) ;;
      *) skipped=$((skipped+1)); continue ;;
    esac
    sid="$(basename "$f" .jsonl)"
    echo "backfill [$((processed+1))/$limit] sid=$sid cwd=$cwd"
    if bash "$0" --run "$sid" "$f" "$cwd"; then
      processed=$((processed+1))
    else
      failed=$((failed+1))
    fi
  done <<EOF
$(find "$HOME/.claude/projects" -name '*.jsonl' -mtime -14 2>/dev/null | sort)
EOF
  echo "=== backfill done: $processed processed, $skipped skipped, $failed failed ==="
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
  # Subagent transcripts are sub-process Claude calls — the parent's
  # session captures them, so they don't need their own digest.
  is_ingest_eligible_path "$tpath" || exit 0
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
