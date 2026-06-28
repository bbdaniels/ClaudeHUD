#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.0.0
# source: ClaudeHUD/Resources/Scripts/vault-email-ingest.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# Email → Obsidian-vault ingestion. Closes two leaks in the task
# lifecycle: (IN) email action items never become vault tasks, and
# (OUT) completed tasks vanish. This watches mail LOCALLY and READ-ONLY
# (sqlite3 -readonly against Spark's messages.sqlite — no IPC, no
# foreground app, never sends or modifies mail) and:
#   * captures asks/notes/completions from received + sent mail,
#   * the cloud refresh (separately) echoes completions.
#
# Architecture (mirrors vault-ingest.sh): the LLM classifies, the SHELL
# applies. `claude -p` is READ-ONLY (Read,Grep,Glob) over a TEMP dir
# holding only a candidate-emails file + a compact project roster the
# shell pre-builds; the worker never roams the vault and never writes
# it. The shell does every vault write (atomic + locked), so the risky
# Tasks.md mutation stays auditable and git-reversible (obsidian-sync
# commits it; the morning daily-note run log is the audit surface).
#
# Modes:
#   (default) / --run        scan + classify + apply now.
#   --audit                  list candidate emails since last-run; no
#                            model call, no writes.
#   --dry-run                full classify; print decisions; NO vault
#                            writes, NO processed.tsv / last-run update.
#   --since <YYYY-MM-DD|epoch>  override the scan floor for this run.
#
# Safety invariants (spec §11):
#   * Read-only against mail; never sends/modifies email.
#   * Auto-complete ONLY on a single exact ## Active match, confidence
#     >= 0.80, and the matched bullet has NO nested children; otherwise
#     RECORD-ONLY (never edits ## Active).
#   * Per-project buffer (Email Triage.md) is left NON-EMPTY on any
#     per-project failure (visible backlog) and pks are marked processed
#     ONLY after a successful apply (so failures retry next run).
# =====================================================================
set -u

# ---- identifiers / paths (spec §1) ----
VAULT="/Users/bbdaniels/Documents/Obsidian"   # resolved exactly as vault-ingest.sh (confirmed)
STATE="$HOME/.claude/hud/email-ingest"
PROMPT="${VAULT_EMAIL_INGEST_PROMPT:-$HOME/.claude/scripts/vault-email-ingest-prompt.md}"   # override = testability only
CLAUDE="${VAULT_EMAIL_INGEST_CLAUDE:-$HOME/.local/bin/claude}"   # override = testability only
LOG="$HOME/Library/Logs/vault-email-ingest.log"
PROCESSED="$STATE/processed.tsv"
LASTRUN="$STATE/last-run"
LOCK="$STATE/.lock"
MODEL="${VAULT_EMAIL_INGEST_MODEL:-claude-haiku-4-5}"
LOOKBACK_SECS=21600     # 6h safety lookback below last-run (processed.tsv dedups overlap)
BOOTSTRAP_SECS=259200   # no last-run -> floor = now - 3 days
MAX_CANDIDATES=200      # cap per run (log if capped)

export VAULT_EMAIL_INGEST=1
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$STATE"
: >> "$PROCESSED" 2>/dev/null || true

# ---- Spark messages.sqlite auto-detect (mirror SparkService.msgPath) ----
spark_db() {
  local appSupport="$HOME/Library/Application Support"
  local p
  for p in \
    "$appSupport/Spark Desktop/core-data/messages.sqlite" \
    "$appSupport/com.readdle.SparkDesktop/core-data/messages.sqlite" \
    "$appSupport/com.readdle.SparkDesktop-setapp/db/messages.sqlite" \
    "$appSupport/com.readdle.SparkDesktop/db/messages.sqlite" \
    "$appSupport/Spark/db/messages.sqlite" ; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Read-only sqlite (mirror SparkService.runSQLite arg order/flags).
sql_ro() {  # $1=db  $2=sql
  /usr/bin/sqlite3 -readonly -separator '|' "$1" "$2" 2>>"$LOG"
}

# Does the messages table carry a thread/conversation column? Probed via
# PRAGMA so v1 degrades cleanly if Spark's schema differs. On THIS machine
# the column is `conversationPk` (with `imapThreadId` as a fallback). Prints
# the column name (empty if none).
thread_col() {  # $1=db
  local cols
  cols="$(sql_ro "$1" "PRAGMA table_info(messages);")"
  if printf '%s\n' "$cols" | grep -q '|conversationPk|'; then printf 'conversationPk'; return 0; fi
  if printf '%s\n' "$cols" | grep -q '|imapThreadId|'; then printf 'imapThreadId'; return 0; fi
  return 0
}

# ---- floor (lower time bound, epoch seconds) ----
# last-run minus 6h lookback; bootstrap (no last-run) = now - 3 days; an
# explicit --since (epoch or YYYY-MM-DD) overrides for this run.
compute_floor() {  # $1 = optional --since value ("" if none)
  local now since
  now="$(date +%s)"
  if [ -n "${1:-}" ]; then
    case "$1" in
      (*[!0-9]*)
        since="$(date -j -f '%Y-%m-%d' "$1" '+%s' 2>/dev/null)"
        [ -z "$since" ] && since="$((now - BOOTSTRAP_SECS))"
        ;;
      (*) since="$1" ;;
    esac
    printf '%s' "$since"; return 0
  fi
  if [ -f "$LASTRUN" ]; then
    local lr; lr="$(tr -dc '0-9' < "$LASTRUN" 2>/dev/null)"
    if [ -n "$lr" ]; then printf '%s' "$((lr - LOOKBACK_SECS))"; return 0; fi
  fi
  printf '%s' "$((now - BOOTSTRAP_SECS))"
}

# ---- candidate pull (spec §4) ----
# Emits TSV rows the python helpers consume, one per email:
#   direction\tpk\tfromDisplay\tsubject\tdateISO\tepoch\tthread\tshortBody
# RECEIVED: inInbox=1 AND inSent=0 AND inDrafts=0 AND receivedDate>floor
#           AND COALESCE(category,1) <> 4   (4 ≈ newsletter/bulk)
# SENT:     inSent=1 AND inDrafts=0 AND receivedDate>floor
# Ordered receivedDate ASC, capped at MAX_CANDIDATES (caller logs if capped).
# `tc` (thread col) is interpolated only when present; otherwise a constant
# '' is selected so column positions stay fixed.
pull_candidates() {  # $1=db  $2=floor  $3=thread_col(maybe empty)
  local db="$1" floor="$2" tc="$3" tsel
  if [ -n "$tc" ]; then tsel="COALESCE($tc,'')"; else tsel="''"; fi
  # TAB-separated output to match the `IFS=$'\t'` read loops below (NOT the
  # pipe-delimited sql_ro, whose `|`-output the read loops can't split). Both
  # subject and shortBody are flattened (CR/LF/TAB -> space) so no field can
  # contain the delimiter or a newline and break the line-oriented parse.
  # shortBody is a preview (spec §4); the python builder also clamps its length.
  /usr/bin/sqlite3 -readonly -separator "$(printf '\t')" "$db" "
    SELECT 'received', pk, messageFrom,
           REPLACE(REPLACE(REPLACE(COALESCE(subject,''),char(13),' '),char(10),' '),char(9),' '),
           strftime('%Y-%m-%d', receivedDate, 'unixepoch'), receivedDate,
           $tsel,
           REPLACE(REPLACE(REPLACE(COALESCE(shortBody,''),char(13),' '),char(10),' '),char(9),' ')
    FROM messages
    WHERE inInbox=1 AND inSent=0 AND inDrafts=0
      AND receivedDate > $floor AND COALESCE(category,1) <> 4
    UNION ALL
    SELECT 'sent', pk, messageFrom,
           REPLACE(REPLACE(REPLACE(COALESCE(subject,''),char(13),' '),char(10),' '),char(9),' '),
           strftime('%Y-%m-%d', receivedDate, 'unixepoch'), receivedDate,
           $tsel,
           REPLACE(REPLACE(REPLACE(COALESCE(shortBody,''),char(13),' '),char(10),' '),char(9),' ')
    FROM messages
    WHERE inSent=1 AND inDrafts=0 AND receivedDate > $floor
    ORDER BY 6 ASC
  " 2>>"$LOG"
}

# ===================================================================
#  Mode dispatch (mirror vault-ingest.sh)
# ===================================================================
MODE="run"
SINCE=""
case "${1:-}" in
  ""|--run)   MODE="run" ;;
  --audit)    MODE="audit" ;;
  --dry-run)  MODE="dry-run" ;;
  --since)    MODE="run"; SINCE="${2:-}" ;;
  *) echo "usage: $0 [--run|--audit|--dry-run|--since <YYYY-MM-DD|epoch>]"; exit 2 ;;
esac
# --since may also be combined with an explicit mode arg ($1=mode $2=--since $3=val)
if [ "${2:-}" = "--since" ]; then SINCE="${3:-}"; fi

DB="$(spark_db)" || { echo "$(date -u +%FT%TZ) no Spark messages.sqlite found in any candidate path" | tee -a "$LOG"; exit 0; }
TC="$(thread_col "$DB")"
FLOOR="$(compute_floor "$SINCE")"

# ---------------- --audit ----------------
# List candidate emails since last-run; NO model call, NO writes. Drops
# pks already in processed.tsv so the list reflects what a run would do.
if [ "$MODE" = "audit" ]; then
  echo "=== vault-email-ingest --audit $(date -u +%FT%TZ) ==="
  echo "db: $DB"
  echo "thread column: ${TC:-<none>}"
  echo "floor: $FLOOR ($(date -r "$FLOOR" '+%Y-%m-%d %H:%M' 2>/dev/null))"
  n=0; r=0; s=0
  while IFS='	' read -r dir pk from subj date epoch thread body; do
    [ -z "$pk" ] && continue
    grep -q "^$pk	" "$PROCESSED" 2>/dev/null && continue
    n=$((n+1)); [ "$dir" = "received" ] && r=$((r+1)); [ "$dir" = "sent" ] && s=$((s+1))
    echo "  [$dir] pk=$pk $date  $from — $subj"
  done <<EOF
$(pull_candidates "$DB" "$FLOOR" "$TC")
EOF
  echo "-- $n candidate(s) (recv $r / sent $s); cap is $MAX_CANDIDATES --"
  [ "$n" = 0 ] && echo "  (none)"
  exit 0
fi

# ===================================================================
#  run / dry-run: build candidate file + roster, classify, apply
# ===================================================================
DRY=0; [ "$MODE" = "dry-run" ] && DRY=1
ts_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
today_local="$(date '+%Y-%m-%d')"     # completion (YYYY-MM-DD) — local, matches VaultManager
date_utc="$(date -u +%F)"             # Session Log heading + daily-note filename — UTC, matches cleaner
echo "===== $ts_utc vault-email-ingest ($MODE) floor=$FLOOR model=$MODEL ====="
[ -x "$CLAUDE" ] && [ -f "$PROMPT" ] || { echo "precond fail (claude or prompt missing)"; exit 0; }

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/vemail.XXXXXX")"
trap 'rm -rf "$tmpd"' EXIT
CAND="$tmpd/candidates.txt"
ROSTER="$tmpd/roster.md"

# ---- build the candidate file (drop already-processed pks; cap; log) ----
# (Plain shell-built text file the worker reads; no vault content here.)
raw_count=0; cand_count=0; recv_count=0; sent_count=0; capped=0
: > "$CAND"
{
  while IFS='	' read -r dir pk from subj date epoch thread body; do
    [ -z "$pk" ] && continue
    raw_count=$((raw_count+1))
    grep -q "^$pk	" "$PROCESSED" 2>/dev/null && continue
    if [ "$cand_count" -ge "$MAX_CANDIDATES" ]; then capped=1; continue; fi
    cand_count=$((cand_count+1))
    [ "$dir" = "received" ] && recv_count=$((recv_count+1))
    [ "$dir" = "sent" ] && sent_count=$((sent_count+1))
    # extract display name like SparkService.extractDisplayName (quoted name,
    # else local-part before <, else raw field)
    disp="$(printf '%s' "$from" | python3 -c '
import sys
s = sys.stdin.read().strip()
q1 = s.find("\"")
if q1 != -1:
    q2 = s.find("\"", q1+1)
    if q2 != -1:
        print(s[q1+1:q2]); raise SystemExit
lt = s.find("<")
if lt != -1:
    nm = s[:lt].strip()
    if nm: print(nm); raise SystemExit
print(s)
' 2>/dev/null)"
    [ -z "$disp" ] && disp="$from"
    # clamp body preview length (privacy + token budget); single line only
    body_clamped="$(printf '%s' "$body" | cut -c1-600)"
    printf '%s\n' '----'
    printf 'PK: %s\nDIRECTION: %s\nFROM: %s\nDATE: %s\nSUBJECT: %s\n' \
      "$pk" "$dir" "$disp" "$date" "$subj"
    [ -n "$TC" ] && [ -n "$thread" ] && printf 'THREAD: %s\n' "$thread"
    printf 'BODY: %s\n' "$body_clamped"
  done <<EOF
$(pull_candidates "$DB" "$FLOOR" "$TC")
EOF
} >> "$CAND"
echo "candidates: $cand_count of $raw_count pulled (recv $recv_count / sent $sent_count)$([ "$capped" = 1 ] && echo " [CAPPED at $MAX_CANDIDATES]")"

if [ "$cand_count" -eq 0 ]; then
  echo "no new candidates — nothing to do"
  if [ "$DRY" -eq 0 ]; then date +%s > "$LASTRUN"; fi
  exit 0
fi

# ---- build the roster (spec §5): shell enumerates $VAULT/*/Tasks.md ----
# For each: frontmatter project/aka/cwds/status + CURRENT ## Active titles
# (bold titles AND plain top-level bullet text). This is the ONLY vault
# content the worker reads. The python builder mirrors VaultProjectService
# .parseActiveTasks' notion of an Active top-level bullet (`-` marker, the
# `## Active`..next-`## ` window). Also emits a name->folder map kept in the
# shell (roster.map) for the apply step.
ROSTER_MAP="$tmpd/roster.map"   # TSV: project_name<TAB>folder_name
VAULT_DIR="$VAULT" ROSTER_OUT="$ROSTER" MAP_OUT="$ROSTER_MAP" python3 <<'PY'
import os, re
vault = os.environ["VAULT_DIR"]
roster_out = os.environ["ROSTER_OUT"]
map_out = os.environ["MAP_OUT"]

FM = re.compile(r'^---\n(.*?)\n---\n', re.DOTALL)

def frontmatter(txt):
    m = FM.match(txt)
    return m.group(1) if m else ""

def scalar(fm, key):
    m = re.search(r'^%s\s*:\s*(.+)$' % re.escape(key), fm, re.MULTILINE)
    if not m:
        return ""
    return m.group(1).strip().strip("'\"")

def listfield(fm, key):
    # supports `key: [a, b]`, `key: ~`/empty, and block lists of `- item`
    out = []
    lines = fm.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r'^%s\s*:(.*)$' % re.escape(key), line)
        if not m:
            continue
        inline = m.group(1).strip()
        if inline and inline not in ("[]", "~"):
            inline = inline.strip("[]")
            for part in inline.split(","):
                p = part.strip().strip("'\"")
                if p:
                    out.append(p)
        for j in range(i + 1, len(lines)):
            s = lines[j].strip()
            if s.startswith("- "):
                out.append(s[2:].strip().strip("'\""))
            elif lines[j][:1].isspace() and s:
                continue
            else:
                break
        break
    return out

def active_titles(txt):
    # Mirror parseActiveTasks: enter on `## Active`, leave at next `## `.
    # A top-level `- ` bullet is a task; for `- **Bold**: rest` we keep the
    # bold title; otherwise the bullet text (first line). Nested `  - ` lines
    # are children, not titles. One title per top-level bullet.
    titles = []
    in_active = False
    bold = re.compile(r'^-\s+\*\*(.+?)\*\*\s*:?')
    top = re.compile(r'^-\s+(.*)$')
    cbox = re.compile(r'^\[[ xX]\]\s*(.*)$')
    for raw in txt.split("\n"):
        if not in_active:
            t = raw.strip()
            if t == "## Active" or raw.startswith("## Active "):
                in_active = True
            continue
        if raw.startswith("## "):
            break
        if re.match(r'^\s{2,}-\s+', raw):   # nested child — skip
            continue
        m = top.match(raw)
        if not m:
            continue
        inner = m.group(1)
        cm = cbox.match(inner)
        if cm:
            inner = cm.group(1)
        bm = bold.match("- " + inner)
        if bm:
            titles.append(bm.group(1).strip())
        else:
            ttl = inner.strip()
            ttl = re.split(r':\s', ttl, 1)[0].strip()
            if ttl:
                titles.append(ttl)
    # de-dup, keep order
    seen = set(); uniq = []
    for t in titles:
        if t and t not in seen:
            seen.add(t); uniq.append(t)
    return uniq

blocks = []
mapping = []
for folder in sorted(os.listdir(vault)):
    fpath = os.path.join(vault, folder)
    if not os.path.isdir(fpath) or folder.startswith("."):
        continue
    tasks = os.path.join(fpath, "Tasks.md")
    if not os.path.isfile(tasks):
        continue
    try:
        txt = open(tasks, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    fm = frontmatter(txt)
    name = scalar(fm, "project") or folder
    status = scalar(fm, "status")
    akas = listfield(fm, "aka")
    cwds = listfield(fm, "cwds")
    titles = active_titles(txt)
    mapping.append("%s\t%s" % (name, folder))
    lines = ["## %s" % name]
    if akas:
        lines.append("- aka: %s" % ", ".join(akas))
    if cwds:
        lines.append("- cwds: %s" % ", ".join(cwds))
    if status:
        lines.append("- status: %s" % status)
    if titles:
        lines.append("- active tasks:")
        for t in titles:
            lines.append("  - %s" % t)
    else:
        lines.append("- active tasks: (none)")
    blocks.append("\n".join(lines))

with open(roster_out, "w", encoding="utf-8") as f:
    f.write("# Vault project roster\n\n")
    f.write("Each `## <name>` is a project. `project` in your output MUST equal\n")
    f.write("one of these names EXACTLY, or the literal string `Misc`.\n\n")
    f.write("\n\n".join(blocks))
    f.write("\n")

with open(map_out, "w", encoding="utf-8") as f:
    f.write("\n".join(mapping) + ("\n" if mapping else ""))
PY
echo "roster: $(grep -c '^## ' "$ROSTER" 2>/dev/null) project(s)"

# ---- classifier worker (spec §6) — mirror vault-ingest.sh flags ----
# READ-ONLY (Read,Grep,Glob over tmp only). It never writes the vault.
prompt_text="$(cat "$PROMPT")

--- RUN CONTEXT ---
CANDIDATES: $CAND
ROSTER: $ROSTER
TODAY_UTC: $date_utc"

out="$(cd "$tmpd" && "$CLAUDE" -p \
  --model "$MODEL" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --strict-mcp-config \
  --add-dir "$tmpd" \
  --max-turns 20 \
  "$prompt_text" 2>>"$LOG")"
rc=$?
echo "claude rc=$rc"
if [ "$rc" -ne 0 ]; then
  echo "CLASSIFY FAILED (rc=$rc) — no writes, pks not marked processed; will retry next run"
  exit 0
fi

# Extract the JSONL strictly between markers.
DECISIONS="$tmpd/decisions.jsonl"
printf '%s' "$out" | awk '/<<<ASSIGN>>>/{f=1;next} /<<<END>>>/{f=0} f' > "$DECISIONS"
dec_lines="$(grep -c '{' "$DECISIONS" 2>/dev/null)"; dec_lines="${dec_lines:-0}"
echo "decisions parsed: $dec_lines line(s)"
if [ "$dec_lines" -eq 0 ]; then
  echo "no decisions emitted — nothing to apply"
  if [ "$DRY" -eq 0 ]; then date +%s > "$LASTRUN"; fi
  exit 0
fi

# ===================================================================
#  Apply step (spec §8) — deterministic, atomic, locked, per-project.
#  All vault mutation is done by python3 helpers invoked from the shell;
#  the LLM never touches disk. The Tasks.md completion write reproduces
#  VaultManager.toggleObsidianTodo byte-for-byte (LF, `-`, lowercase
#  `[x]`, ` (YYYY-MM-DD)`, move Active->after `## Completed`, bump
#  `updated:`).
# ===================================================================

append_atomic() {  # $1=file  $2=content-to-append  (mirror vault-ingest.sh)
  local f="$1" tmp; tmp="$(mktemp "${f}.XXXXXX.tmp")"
  { [ -f "$f" ] && cat "$f"; printf '%s\n' "$2"; } > "$tmp"
  mv -f "$tmp" "$f"
}

# Per-vault lock (mkdir is atomic). Best-effort: ~40s then proceed.
locked=0
for _ in $(seq 1 80); do
  if mkdir "$LOCK" 2>/dev/null; then locked=1; break; fi
  sleep 0.5
done
cleanup() { [ "$locked" = 1 ] && rmdir "$LOCK" 2>/dev/null; rm -rf "$tmpd"; }
trap cleanup EXIT
[ "$locked" = 1 ] || echo "WARN: proceeding without lock (timeout)"

# ---- python apply engine ----------------------------------------------------
# Reads DECISIONS + ROSTER_MAP; performs FILL→DRAIN→EMPTY per project; prints:
#   * a "PROCESSED\t<pk>" line for every pk in a project that applied cleanly
#     (the shell appends these to processed.tsv — pk marked processed ONLY
#     after a successful apply),
#   * a "RUNLOG\t<json>" summary line for the daily-note block,
#   * human-readable progress to stderr (-> the log).
# In dry-run it makes NO writes and emits no PROCESSED lines.
APPLY_OUT="$tmpd/apply.out"
VAULT_DIR="$VAULT" DECISIONS="$DECISIONS" ROSTER_MAP="$ROSTER_MAP" \
TODAY_LOCAL="$today_local" DATE_UTC="$date_utc" DRY="$DRY" \
python3 <<'PY' > "$APPLY_OUT"
import os, sys, json, re

vault       = os.environ["VAULT_DIR"]
dpath       = os.environ["DECISIONS"]
mappath     = os.environ["ROSTER_MAP"]
today_local = os.environ["TODAY_LOCAL"]   # completion (YYYY-MM-DD), matches VaultManager local today
date_utc    = os.environ["DATE_UTC"]      # Session Log heading, matches cleaner
DRY         = os.environ.get("DRY", "0") == "1"

def log(msg):
    sys.stderr.write(msg + "\n")

# name -> folder path
folder_of = {}
for line in open(mappath, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not line:
        continue
    name, folder = (line.split("\t", 1) + [""])[:2]
    folder_of[name] = os.path.join(vault, folder)

def write_atomic(path, content):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)

def append_atomic(path, text):
    # append `text` (already newline-terminated as needed) preserving LF
    cur = ""
    if os.path.isfile(path):
        cur = open(path, encoding="utf-8", errors="replace").read()
    write_atomic(path, cur + text)

# ---- Tasks.md helpers (byte-compatible with VaultManager) -------------------
def is_list_line(s):
    return re.match(r'^\s*-\s', s) is not None

def bullet_title(line):
    # `- **Title**: body` -> "Title"; else None. Mirrors the bold split used
    # by VaultManager.parseListItem / VaultProjectService.splitBullet.
    m = re.match(r'^\s*-\s+\*\*(.+?)\*\*\s*:', line)
    if m:
        return m.group(1).strip()
    m = re.match(r'^\s*-\s+\[[ xX]\]\s+\*\*(.+?)\*\*\s*:', line)
    if m:
        return m.group(1).strip()
    return None

def active_window(lines):
    # indices [start, end) of the body of `## Active` (exclusive of headings).
    start = end = None
    for i, ln in enumerate(lines):
        t = ln.strip()
        if start is None:
            if t == "## Active" or ln.startswith("## Active "):
                start = i + 1
            continue
        if ln.startswith("## "):
            end = i
            break
    if start is None:
        return (None, None)
    if end is None:
        end = len(lines)
    return (start, end)

def has_nested_children(lines, idx, end):
    # A matched bullet at `idx` has children if the immediately following
    # lines (before the next top-level `- ` bullet / heading / blank-gap to a
    # new top bullet) include a nested `  - ` bullet. Mirrors parseActiveTasks'
    # nested-bullet detection (indent >= 2, `-` marker).
    j = idx + 1
    while j < end:
        ln = lines[j]
        if re.match(r'^\s{2,}-\s', ln):
            return True
        if re.match(r'^-\s', ln):      # next top-level task
            return False
        if ln.startswith("## ") or ln.startswith("### "):
            return False
        # blank or indented continuation prose -> keep scanning
        j += 1
    return False

def find_active_match(lines, title):
    # Return list of indices of UNCHECKED `## Active` bullets whose bold title
    # == title exactly. (We only ever auto-complete on exactly one.)
    start, end = active_window(lines)
    if start is None:
        return [], (start, end)
    hits = []
    for i in range(start, end):
        ln = lines[i]
        if "[ ] " not in ln:
            continue
        if not is_list_line(ln):
            continue
        bt = bullet_title(ln)
        if bt is not None and bt == title:
            hits.append(i)
    return hits, (start, end)

def ensure_completed_section(lines):
    # Return index of the `## Completed` heading, creating it at end if absent.
    for i, ln in enumerate(lines):
        if ln.strip().startswith("## Completed"):
            return i
    # append a new section (mirror VaultManager: "", "## Completed")
    lines.append("")
    lines.append("## Completed")
    return len(lines) - 1

def bump_updated(lines):
    for i, ln in enumerate(lines):
        if ln.startswith("updated:"):
            lines[i] = "updated: %s" % today_local
            return

def ensure_triage_section(lines):
    # `## Triage` created immediately BEFORE `## Completed` if present, else at
    # end of file (spec §8). Returns index just after the `## Triage` heading
    # where new bullets are inserted (we append at the END of the Triage body).
    for i, ln in enumerate(lines):
        if ln.strip() == "## Triage" or ln.startswith("## Triage "):
            # find end of triage body
            j = i + 1
            while j < len(lines) and not lines[j].startswith("## "):
                j += 1
            return j  # insert position (end of triage section)
    # create it
    comp = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("## Completed"):
            comp = i
            break
    block = ["## Triage", ""]
    if comp is not None:
        # insert before ## Completed
        lines[comp:comp] = block
        return comp + 2   # right after `## Triage` + its blank line
    else:
        if lines and lines[-1].strip() != "":
            lines.append("")
        lines.append("## Triage")
        lines.append("")
        return len(lines)

# ---- load + group decisions by project ----
by_project = {}
order = []
for raw in open(dpath, encoding="utf-8", errors="replace"):
    raw = raw.strip()
    if not raw:
        continue
    try:
        d = json.loads(raw)
    except Exception as e:
        log("  ! skipping unparseable decision line: %s" % e)
        continue
    proj = d.get("project") or "Misc"
    by_project.setdefault(proj, [])
    if proj not in order:
        order.append(proj)
    by_project[proj].append(d)

# ---- tallies for the run log ----
tally = dict(notes=0, todos=0, auto=0, recorded=0, skipped=0)
auto_list = []        # (title, project, from, date, pk, conf)
recorded_list = []    # (title, project, pk)
backlog = []          # projects whose buffer was left non-empty
processed_pks = []

def fmt_buffer_line(d):
    return "- %s | %s | %s | %s (msg %s)" % (
        d.get("direction", "?"), d.get("from", "?"),
        d.get("date", "?"), d.get("subject", "?"), d.get("pk", "?"))

def session_log_block(d):
    title = (d.get("title") or d.get("subject") or "Email").strip()
    return (
        "\n## %s — Email: %s\n"
        "- Did: %s\n"
        "- Decisions: none\n"
        "- Open / next: none\n"
        "- Source: email %s, %s (msg %s)\n"
    ) % (date_utc, title, d.get("summary", ""),
         d.get("from", "?"), d.get("date", "?"), d.get("pk", "?"))

def triage_bullet(d):
    return "- [ ] **%s**: %s ↳ email %s, %s (msg %s)" % (
        (d.get("title") or d.get("subject") or "Untitled").strip(),
        d.get("summary", ""), d.get("from", "?"),
        d.get("date", "?"), d.get("pk", "?"))

for proj in order:
    items = by_project[proj]
    # resolve folder; Misc / unknown -> the Misc folder
    if proj in folder_of:
        pdir = folder_of[proj]
    else:
        pdir = os.path.join(vault, "Misc")
        proj_label = proj
    os.makedirs(pdir, exist_ok=True) if not DRY else None
    nonskip = [d for d in items if d.get("action") != "skip"]
    tally["skipped"] += sum(1 for d in items if d.get("action") == "skip")
    if not nonskip:
        # nothing to drain; the skipped pks are still consumed (processed)
        for d in items:
            processed_pks.append(d.get("pk", ""))
        continue

    buf = os.path.join(pdir, "Email Triage.md")
    log("-- project: %s (%d non-skip / %d total) --" % (proj, len(nonskip), len(items)))

    try:
        # (a) FILL the buffer with ALL routed non-skip raw items (crash-safety)
        if not DRY:
            queue_lines = ["---", "type: email-triage-buffer",
                           "maintained_by: vault-email-ingest (transient; healthy state is empty)",
                           "---", "", "# %s — Email Triage" % proj, "",
                           "## Queue"]
            for d in nonskip:
                queue_lines.append(fmt_buffer_line(d))
            write_atomic(buf, "\n".join(queue_lines) + "\n")

        # (b) DRAIN each decision
        tasks_path = os.path.join(pdir, "Tasks.md")
        for d in nonskip:
            action = d.get("action")
            pk = d.get("pk", "")
            if action == "note":
                if not DRY:
                    append_atomic(os.path.join(pdir, "Session Log.md"), session_log_block(d))
                tally["notes"] += 1
                log("   note -> Session Log (pk %s)" % pk)

            elif action == "todo":
                if not DRY:
                    if not os.path.isfile(tasks_path):
                        raise RuntimeError("Tasks.md missing for %s" % proj)
                    lines = open(tasks_path, encoding="utf-8", errors="replace").read().split("\n")
                    ins = ensure_triage_section(lines)
                    lines.insert(ins, triage_bullet(d))
                    # NOTE: do NOT bump updated: for todos (not human-confirmed)
                    write_atomic(tasks_path, "\n".join(lines))
                tally["todos"] += 1
                log("   todo -> ## Triage (pk %s)" % pk)

            elif action == "complete":
                matched = d.get("matched_active")
                try:
                    conf = float(d.get("confidence", 0))
                except Exception:
                    conf = 0.0
                did_auto = False
                if not os.path.isfile(tasks_path):
                    # no Tasks.md -> cannot auto-complete; record-only below
                    lines = None
                else:
                    lines = open(tasks_path, encoding="utf-8", errors="replace").read().split("\n")

                # ---- AUTO-COMPLETE GATE (spec §8/§11) ----
                # single exact ## Active match AND conf >= 0.80 AND matched
                # bullet has NO nested children.
                if (matched and lines is not None and conf >= 0.80):
                    hits, (astart, aend) = find_active_match(lines, matched)
                    if len(hits) == 1 and not has_nested_children(lines, hits[0], aend):
                        idx = hits[0]
                        removed = lines[idx]
                        del lines[idx]
                        # VaultManager: removed.replace("[ ] "->"[x] ") + " (today)"
                        completed = removed.replace("[ ] ", "[x] ", 1) + " (%s)" % today_local
                        # + provenance suffix (spec §8)
                        completed = completed + " ↳ per email %s, %s (msg %s)" % (
                            d.get("from", "?"), d.get("date", "?"), pk)
                        comp_idx = ensure_completed_section(lines)
                        lines.insert(comp_idx + 1, completed)
                        bump_updated(lines)
                        if not DRY:
                            write_atomic(tasks_path, "\n".join(lines))
                        tally["auto"] += 1
                        auto_list.append((matched, proj, d.get("from", "?"),
                                          d.get("date", "?"), pk, "%.2f" % conf))
                        log("   complete -> AUTO-COMPLETE '%s' conf %.2f (pk %s)" % (matched, conf, pk))
                        did_auto = True

                # ---- RECORD-ONLY (safe degrade; never touches ## Active) ----
                if not did_auto:
                    title = (d.get("title") or d.get("subject") or "Completed").strip()
                    rec = "- [x] **%s** (%s) ↳ per email %s, %s (msg %s) [unmatched — review]" % (
                        title, today_local, d.get("from", "?"), d.get("date", "?"), pk)
                    if lines is None:
                        lines = ["---", "project: %s" % proj, "updated: %s" % today_local,
                                 "---", "", "# %s — Tasks" % proj, ""]
                    comp_idx = ensure_completed_section(lines)
                    lines.insert(comp_idx + 1, rec)
                    bump_updated(lines)
                    if not DRY:
                        # ensure Tasks.md exists for Misc-style record-only
                        write_atomic(tasks_path, "\n".join(lines))
                    tally["recorded"] += 1
                    recorded_list.append((title, proj, pk))
                    log("   complete -> RECORD-ONLY (pk %s)%s" % (
                        pk, "" if matched is None else " [no safe match]"))

            # mark pk processed (collected; written only on full project success)
            processed_pks.append(pk)

        # (c) EMPTY the buffer back to baseline on full success
        if not DRY:
            baseline = "\n".join(["---", "type: email-triage-buffer",
                                  "maintained_by: vault-email-ingest (transient; healthy state is empty)",
                                  "---", "", "# %s — Email Triage" % proj, ""]) + "\n"
            write_atomic(buf, baseline)

    except Exception as e:
        # leave buffer NON-EMPTY (visible backlog); do NOT mark these pks
        # processed -> they retry next run. Roll back this project's pks.
        for d in nonskip:
            pk = d.get("pk", "")
            if pk in processed_pks:
                # only drop the ones added in THIS project's loop
                pass
        # remove this project's pks from the processed list
        proj_pks = set(d.get("pk", "") for d in nonskip)
        processed_pks[:] = [p for p in processed_pks if p not in proj_pks]
        backlog.append(proj)
        log("   ! FAILED applying project %s: %s — buffer left populated, pks NOT marked processed" % (proj, e))
        continue

# ---- emit PROCESSED lines (dry-run emits none) ----
if not DRY:
    for pk in processed_pks:
        if pk:
            print("PROCESSED\t%s" % pk)

# ---- emit run-log summary as JSON for the shell to format ----
summary = {
    "scanned": len(open(dpath, encoding="utf-8", errors="replace").read().strip().split("\n")) if os.path.getsize(dpath) else 0,
    "notes": tally["notes"], "todos": tally["todos"],
    "auto": tally["auto"], "recorded": tally["recorded"], "skipped": tally["skipped"],
    "auto_list": [{"title": t, "project": p, "from": fr, "date": dt, "pk": pk, "conf": c}
                  for (t, p, fr, dt, pk, c) in auto_list],
    "recorded_list": [{"title": t, "project": p, "pk": pk} for (t, p, pk) in recorded_list],
    "backlog": backlog,
}
print("RUNLOG\t" + json.dumps(summary))
PY
apply_rc=$?
# Surface the python helper's stderr-style progress (it went to our stderr,
# already in the log via the run's redirection). Print captured stdout lines.
if [ "$apply_rc" -ne 0 ]; then
  echo "APPLY ENGINE rc=$apply_rc — see log; pks NOT marked processed for failed projects"
fi

# ---- consume PROCESSED + RUNLOG from the apply engine ----
RUNLOG_JSON=""
new_pks=0
while IFS='	' read -r tag payload; do
  case "$tag" in
    PROCESSED)
      [ -z "$payload" ] && continue
      if [ "$DRY" -eq 0 ]; then
        # processed.tsv schema: <pk>\t<receivedDate_epoch>\t<action>\t<project>
        # epoch/action/project are best-effort from decisions; dedup is by pk.
        meta="$(python3 - "$payload" "$DECISIONS" <<'PY'
import sys, json
pk = sys.argv[1]
for line in open(sys.argv[2], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if str(d.get("pk")) == pk:
        print("%s\t%s" % (d.get("action",""), d.get("project","")))
        break
PY
)"
        action="$(printf '%s' "$meta" | cut -f1)"
        proj="$(printf '%s' "$meta" | cut -f2)"
        # receivedDate epoch from the candidate file's source DB (numeric pk
        # only — pk is LLM-echoed, so guard the interpolation defensively;
        # a non-numeric pk is still recorded so it won't reprocess).
        case "$payload" in
          (''|*[!0-9]*) epoch=0 ;;
          (*) epoch="$(sql_ro "$DB" "SELECT receivedDate FROM messages WHERE pk=$payload LIMIT 1;" 2>/dev/null)" ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$payload" "${epoch:-0}" "$action" "$proj" >> "$PROCESSED"
        new_pks=$((new_pks+1))
      fi
      ;;
    RUNLOG)
      RUNLOG_JSON="$payload"
      ;;
  esac
done <<EOF
$(cat "$APPLY_OUT")
EOF
echo "marked processed: $new_pks pk(s)$([ "$DRY" -eq 1 ] && echo " (dry-run: none persisted)")"

# ---- daily-note run log (spec §9) ----
# Append to Daily Notes/<UTC>.md (same file the cleaner uses; both append
# independently). Atomic. Skipped in dry-run.
if [ "$DRY" -eq 0 ] && [ -n "$RUNLOG_JSON" ]; then
  daily="$VAULT/Daily Notes/$date_utc.md"
  mkdir -p "$VAULT/Daily Notes"
  hhmm_local="$(date '+%H:%M')"
  block="$(RUNLOG="$RUNLOG_JSON" HHMM="$hhmm_local" RECV="$recv_count" SENT="$sent_count" SCANNED="$cand_count" python3 <<'PY'
import os, json
s = json.loads(os.environ["RUNLOG"])
hh = os.environ["HHMM"]
recv = os.environ["RECV"]; sent = os.environ["SENT"]; scanned = os.environ["SCANNED"]
lines = []
lines.append("## Email Ingest — %s" % hh)
lines.append("- Scanned: %s (recv %s / sent %s); notes %d, todos %d, auto-completed %d, recorded-unmatched %d, skipped %d" % (
    scanned, recv, sent, s.get("notes",0), s.get("todos",0), s.get("auto",0), s.get("recorded",0), s.get("skipped",0)))
auto = s.get("auto_list", [])
if auto:
    lines.append("- Auto-completed:")
    for a in auto:
        lines.append("  - **%s** (%s) — per email %s, %s (msg %s), conf %s" % (
            a["title"], a["project"], a["from"], a["date"], a["pk"], a["conf"]))
else:
    lines.append("- Auto-completed: none")
rec = s.get("recorded_list", [])
if rec:
    lines.append("- Recorded (unmatched, review): %s" % ", ".join(
        "**%s** (%s, msg %s)" % (r["title"], r["project"], r["pk"]) for r in rec))
else:
    lines.append("- Recorded (unmatched, review): none")
bk = s.get("backlog", [])
lines.append("- Backlog (triage notes left non-empty): %s" % (", ".join(bk) if bk else "none"))
print("\n".join(lines))
PY
)"
  append_atomic "$daily" "
$block"
  echo "run log appended to: $daily"
fi

# ---- last-run state ----
# Set last-run to the run start time ONLY on a real (non-dry) run. The 6h
# lookback + processed.tsv dedup make a slightly-early floor harmless; we
# intentionally do NOT advance last-run in dry-run.
if [ "$DRY" -eq 0 ]; then
  date +%s > "$LASTRUN"
fi

# ---- dry-run: print the decisions for inspection ----
if [ "$DRY" -eq 1 ]; then
  echo "--- DRY RUN decisions (no writes performed) ---"
  cat "$DECISIONS"
fi

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) vault-email-ingest done ($MODE) ====="
exit 0
