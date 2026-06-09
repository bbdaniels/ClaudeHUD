#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.8.2
# source: ClaudeHUD/Resources/Scripts/vault-ingest.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# 1.8.2 (2026-06-09):
#  * --backfill settle window. Skip transcripts modified in the last
#    2 hours: the idempotency key is name+bytes, so a LIVE session
#    otherwise re-digests on every 30-min tick as it grows, stacking
#    near-duplicate Session Log blocks (observed: two blocks for one
#    session in a single afternoon) and burning a Haiku call each.
#    Close-out digests are unaffected — they run via the SessionEnd
#    hook (phase 1), which has no settle window — so a RESUMED old
#    session still re-digests the moment it ends. Mirrors the Swift
#    cockpit's pendingMinAge.
# 1.8.1 (2026-06-09):
#  * Machine detection refined: a promptSource:"sdk" record alone no
#    longer condemns a session — real interactive sessions can carry an
#    injected selector prompt as their FIRST user record yet contain a
#    person's typed work after it (found: 1 of 7,617 transcripts; its
#    "machine" verdict would have suppressed digests of real work).
#    Now: entrypoint "sdk-cli" or a machine first-prompt is definitive;
#    sdk-sourced records are SKIPPED; "<command>" wrappers count as
#    interactive evidence; scan up to 2000 lines for a real prompt;
#    at window end, machine only if sdk records were seen and no
#    interactive evidence was.
# 1.8.0 (2026-06-09):
#  * Machine-session skip. Programmatic `claude -p` one-shots (skill-tip
#    catalog selectors, remote-control liveness probes PONG/SMOKE_OK,
#    managed-prompt pipelines) are detected structurally — their first
#    user record carries entrypoint "sdk-cli" / promptSource "sdk" —
#    and marked .done WITHOUT a model call, in both phase-1 and
#    --backfill. Before this, Haiku backfills occasionally digested a
#    skill-selector query as if it were real work ("Skill-selection
#    query re: patient risk scoring"), polluting Session Log.md AND the
#    HUD title sidecars (a sidecar used to bypass the HUD's drop
#    filters). Saves the wasted model calls too. Mirrored by
#    SessionHistoryService.classifyHead + VaultIngestService.
#  * Title sidecars drop a leading "<project>: " prefix (the digest
#    title rule forbids it, but pre-rule digests and occasional model
#    slips carry it; the HUD list is already grouped by project).
#    Applied in write_title_sidecar and --backfill-titles.
# 1.7.0 (2026-06-09):
#  * Oversized-transcript guard. Before the digest, a transcript whose
#    temp copy exceeds ~480KB is reduced to head (100KB) + tail (260KB)
#    with the middle elided, keeping it under the model's 200K-token
#    context. Without this, long sessions (>~200K tokens) failed
#    `claude -p` with "prompt is too long" -> rc=1 -> never marked .done
#    -> requeued every --backfill cycle. Because --backfill takes the
#    alphabetically-first 10 pending each run, these perma-failures
#    squatted the slots and STARVED all healthy pending sessions (incl.
#    research). A close-out digest's signal lives at the start (task) and
#    end (outcome), so head+tail preserves it; the elided middle is noted
#    inline so the model knows the transcript is partial.
# 1.6.1 (2026-06-08):
#  * Digest `claude -p` now runs with --strict-mcp-config (and no
#    --mcp-config), so it loads ZERO MCP servers. The digest only needs
#    Read/Grep/Glob over a temp transcript copy; it never needs Google
#    Drive / Obsidian / etc. Without this, every digest (per-SessionEnd +
#    the 30-min --backfill batch of 10) booted the GLOBAL `google-drive`
#    MCP server from ~/.claude.json, which re-ran the Google OAuth sign-in
#    flow on each start (its persisted token had been moved out of the
#    live path → no silent refresh). --allowedTools gates tool USE, not
#    server SPAWN, so the OAuth fired regardless of the Read/Grep/Glob
#    whitelist. Same spirit as 1.3.0's TCC-surface reduction.
# 1.6.0 (2026-06-07):
#  * HUD session-title sidecars. After a successful digest, the digest's
#    "## <date> — <title>" heading is written to
#    ~/.claude/hud/session-titles/<sid>.txt; the Swift HUD prefers it as
#    the history-list label over Claude Code's ai-title, which freezes on
#    the opening turn (every magic-launched session otherwise reads
#    "context load" no matter what work followed). New --backfill-titles
#    mode rebuilds every sidecar from the digests already in each project's
#    Session Log.md / Misc/Session Inbox.md — pure text parsing, no model
#    calls. Consumed by SessionHistoryService.loadSidecarTitles.
# 1.5.0 (2026-06-04):
#  * Digest `claude -p` now runs with cwd=$tmpd (the throwaway copy dir),
#    so its OWN session transcript records a cwd that the ingest filter
#    rejects (not under a real project; gone after exit). Stops the
#    feedback loop where every ingest spawned a fresh ingestible session
#    — latent under the cron, acute under a bulk backfill drain.
# 1.4.0 (2026-06-04):
#  * Digest model is overridable via $VAULT_INGEST_MODEL (default
#    unchanged: claude-sonnet-4-6). Lets a one-time bulk backlog drain
#    run on a cheaper/faster model (haiku) without touching normal
#    cron/hook operation.
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

# Predicate: is this transcript a programmatic `claude -p` one-shot rather
# than a person's working session? Skill-tip catalog selectors, remote
# control liveness probes (PONG / SMOKE_OK), and managed-prompt pipelines
# all pass the cwd + size filters (a selector prompt alone is ~20KB) but
# contain nothing durable — and a Haiku backfill sometimes digests one as
# real work anyway, polluting Session Log.md and the HUD title sidecars.
# Detect them structurally: the first user record of an SDK run carries
# entrypoint "sdk-cli" / promptSource "sdk" (every real session — terminal,
# VSCode, desktop, magic-launch, background job — records "cli"-family
# entrypoints). Prompt-prefix checks cover transcripts that predate those
# fields. Returns 0 = machine. Mirror: SessionHistoryService.classifyHead.
is_machine_transcript() {
  python3 - "$1" <<'PY'
import sys, json
MACH = ("You select the single most relevant skill", "# Session Ingest",
        "<!-- === Managed by ClaudeHUD", "Reply with exactly",
        "Return ONLY this JSON object")
# A promptSource:"sdk" record alone does NOT condemn: real interactive
# sessions can carry an injected selector prompt as their first user
# record yet hold a person's typed work later. Skip sdk records, treat
# "<command>" wrappers as interactive evidence, and keep scanning for a
# real prompt. entrypoint "sdk-cli" (the process WAS an SDK one-shot)
# and the known machine first-prompts stay definitive.
saw_sdk = saw_live = False
try:
    with open(sys.argv[1], errors="replace") as fh:
        for i, line in enumerate(fh):
            if i > 2000: break
            try: j = json.loads(line)
            except Exception: continue
            if j.get("type") != "user": continue
            if j.get("entrypoint") == "sdk-cli":
                sys.exit(0)                      # machine (definitive)
            c = (j.get("message") or {}).get("content")
            if j.get("promptSource") == "sdk":
                saw_sdk = True; continue         # injected selector — skip
            if not isinstance(c, str): continue  # tool results etc.
            t = c.strip()
            if t.startswith(MACH):
                sys.exit(0)                      # machine (pre-field one-shot)
            if not t: continue
            if t.startswith("<"):
                saw_live = True; continue        # command wrapper — interactive
            sys.exit(1)                          # real prompt -> real session
except Exception:
    pass
sys.exit(0 if (saw_sdk and not saw_live) else 1)
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
    is_ingest_eligible_path "$f" || continue
    b=$(wc -c < "$f" 2>/dev/null | tr -d ' '); [ "${b:-0}" -lt "$FLOOR" ] && continue
    key="$(basename "$f").$b.done"
    [ -f "$STATE/$key" ] && continue
    is_machine_transcript "$f" && continue
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
    # Settle window: skip transcripts still being written (modified in the
    # last 2h). A live session re-digests on every tick otherwise — the
    # idempotency key is name+bytes — stacking near-duplicate log blocks.
    # Close-outs digest via the SessionEnd hook regardless, so resumed
    # sessions are not delayed; this only quiets mid-session snapshots.
    if [ -n "$(find "$f" -mmin -120 2>/dev/null)" ]; then
      skipped=$((skipped+1)); continue
    fi
    # Machine one-shots: mark .done (no model call) and move on. The first
    # tick after deploy drains the historical pile this way, since this
    # loop walks the whole find list regardless of the processed limit.
    if is_machine_transcript "$f"; then
      : > "$STATE/$key"; skipped=$((skipped+1)); continue
    fi
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

# ---------------- --backfill-titles ----------------
# Rebuild every HUD session-title sidecar from the digests already written
# to each project's Session Log.md / Misc/Session Inbox.md. Pure text
# parsing — NO model calls. Pairs each "## <date> — <title>" heading with
# the "- Session: <uuid>" line that follows and writes
# ~/.claude/hud/session-titles/<uuid>.txt. Idempotent; safe to re-run.
if [ "${1:-}" = "--backfill-titles" ]; then
  dir="$HOME/.claude/hud/session-titles"
  mkdir -p "$dir"
  n="$(VAULT_DIR="$VAULT" OUTDIR="$dir" python3 <<'PY'
import os, re
vault = os.environ['VAULT_DIR']; outdir = os.environ['OUTDIR']
title_re = re.compile(r'^##\s+\d{4}-\d{2}-\d{2}\s*[—–-]+\s*(.+?)\s*$')
dash_re  = re.compile(r'^##\s+.*?\s[—–]\s+(.+?)\s*$')
sess_re  = re.compile(r'^-\s*Session:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
written = 0
for root, dirs, files in os.walk(vault):
    dirs[:] = [d for d in dirs if not d.startswith('.')]
    rel = os.path.relpath(root, vault)
    proj = '' if rel == '.' else rel.split(os.sep)[0]   # vault folder = project name
    for fn in files:
        if fn not in ('Session Log.md', 'Session Inbox.md'):
            continue
        cur = None
        for line in open(os.path.join(root, fn), encoding='utf-8', errors='replace'):
            m = title_re.match(line) or dash_re.match(line)
            if m:
                cur = m.group(1).strip()
                # Same "<project>: " strip as write_title_sidecar — pre-rule
                # digests keep the prefix in the vault forever; the sidecar
                # (a pure HUD label) need not.
                if proj:
                    pm = re.match(re.escape(proj) + r'[\s:—–-]+(.{8,})$', cur, re.IGNORECASE)
                    if pm:
                        t = pm.group(1).strip()
                        cur = t[:1].upper() + t[1:]
                continue
            s = sess_re.match(line)
            if s and cur:
                with open(os.path.join(outdir, s.group(1).lower() + '.txt'), 'w', encoding='utf-8') as f:
                    f.write(cur + '\n')
                written += 1
                cur = None
print(written)
PY
)"
  echo "backfill-titles: wrote $n sidecars to $dir"
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
  # Machine one-shots: mark .done so they never requeue; no model call.
  if is_machine_transcript "$tpath"; then
    : > "$STATE/$(basename "$tpath").$bytes.done"
    exit 0
  fi
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

# Oversized-transcript guard (1.7.0): a transcript over ~200K tokens makes
# `claude -p` fail "prompt is too long" (rc=1), which never marks .done and
# requeues every --backfill cycle, squatting the alphabetically-first slots
# and starving every healthy pending session. Keep the head (task/goal) and
# tail (decisions/outcome) — where a close-out digest's signal is — and elide
# the middle so the prompt stays under the context limit.
_tbytes="$(wc -c < "$tmpd/transcript.jsonl" 2>/dev/null | tr -d ' ')"
if [ "${_tbytes:-0}" -gt 480000 ]; then
  if { head -c 100000 "$tmpd/transcript.jsonl"
       printf '\n\n...[%s bytes of mid-session transcript elided to fit the model context]...\n\n' "$((_tbytes-360000))"
       tail -c 260000 "$tmpd/transcript.jsonl"
     } > "$tmpd/transcript.trunc" 2>/dev/null; then
    mv "$tmpd/transcript.trunc" "$tmpd/transcript.jsonl"
    echo "truncated oversized transcript: ${_tbytes} -> ~360000 bytes (head+tail)"
  fi
fi

prompt_text="$(cat "$PROMPT")

--- RUN CONTEXT ---
TRANSCRIPT: $tmpd/transcript.jsonl
PROJECT: $proj
SESSION_ID: $sid
SESSION_CWD: $cwd
TODAY_UTC: $(date -u +%Y-%m-%d)"

## Run from inside $tmpd so this digest session's OWN transcript records
## cwd=$tmpd — a throwaway dir, not a real project, gone after we exit.
## Both the cwd filter and the `[ -d "$cwd" ]` check then reject it, so
## machine-generated digest sessions never re-enter the ingest queue.
## (Without this the digest inherits a real-project cwd → infinite loop.)
out="$(cd "$tmpd" && "$CLAUDE" -p \
  --model "${VAULT_INGEST_MODEL:-claude-sonnet-4-6}" \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob" \
  --strict-mcp-config \
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

# HUD session-title sidecar. Pull the digest's "## <date> — <title>" heading
# (title only) and write it, keyed by session id, where the Swift HUD reads
# it (SessionHistoryService.loadSidecarTitles). This "what the session
# accomplished" label beats Claude Code's ai-title, which is generated from
# the opening turn and freezes at "context load" for every magic-launched
# vault session. Best-effort; an unparsable heading just leaves no sidecar
# (the HUD falls back to ai-title / first prompt). Never fatal to the ingest.
write_title_sidecar() {
  local s="$1" d="$2" p="${3:-}" title dir tmp
  [ -z "$s" ] && return 0
  title="$(printf '%s' "$d" | python3 -c '
import sys, re
proj = sys.argv[1] if len(sys.argv) > 1 else ""
date = re.compile(r"^##\s+\d{4}-\d{2}-\d{2}\s*[—–-]+\s*(.+?)\s*$")
dash = re.compile(r"^##\s+.*?\s[—–]\s+(.+?)\s*$")
title = ""
for line in sys.stdin:
    m = date.match(line) or dash.match(line)
    if m:
        title = m.group(1).strip(); break
# The title rule forbids leading with the project name (the HUD list and
# the Session Log are already grouped under it); strip the prefix when a
# pre-rule digest or a model slip includes it anyway. Keep >=8 chars so a
# degenerate title is never stripped to a stub.
if title and proj:
    m = re.match(re.escape(proj) + r"[\s:—–-]+(.{8,})$", title, re.IGNORECASE)
    if m:
        t = m.group(1).strip()
        title = t[:1].upper() + t[1:]
print(title)
' "$p" 2>/dev/null)"
  [ -z "$title" ] && return 0
  dir="$HOME/.claude/hud/session-titles"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$title" > "$tmp" && mv -f "$tmp" "$dir/$s.txt"
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
  write_title_sidecar "$sid" "$digest" "$proj"
else
  echo "no durable content${ledg:+ — ledger row only}"
fi

: > "$STATE/${key}.done"
rm -f "$STATE/$(basename "$tpath")".*.failed 2>/dev/null
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) vault-ingest done ($proj) ====="
exit 0
