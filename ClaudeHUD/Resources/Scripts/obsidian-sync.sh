#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.0.0
# source: ClaudeHUD/Resources/Scripts/obsidian-sync.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# Daily Obsidian vault sync (bidirectional):
#   - Pulls agent-authored cleanup commits from GitHub
#   - Commits and pushes any local changes from the laptop
# Daily Notes are agent-managed: local untracked versions are scratch and get
# replaced by the agent's cleaned versions when origin has them.
# Retries on transient APFS "Resource deadlock avoided" from Spotlight/Dropbox
# racing with git on file reads.

set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

VAULT="/Users/bbdaniels/Documents/Obsidian"
cd "$VAULT"

# NOTE: launchd self-heal is now its own job (com.bbdaniels.ensure-launchagents),
# decoupled from this sync script because sync is exactly what dies in a
# macOS migration (it touches TCC-protected ~/Documents and loses FDA).

retry() {
  local n=0 max=4
  while ! "$@"; do
    n=$((n+1))
    if [ $n -ge $max ]; then
      echo "FAILED after $max attempts: $*"
      return 1
    fi
    echo "  retry $n/$max after failure..."
    sleep 3
  done
}

echo "===== $(date -u +%FT%TZ) sync start ====="

retry git fetch origin main --quiet

# Pre-clean: drop any local untracked Daily Note that origin has a version of.
git ls-tree -r --name-only -z origin/main -- "Daily Notes/" \
  | while IFS= read -r -d '' f; do
      if [ -f "$f" ] && ! git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        echo "  pre-clean (local scratch → agent version): $f"
        rm -f -- "$f"
      fi
    done

# Stage everything (modifications + new files + deletions) and commit if non-empty.
retry git add -A
if ! git diff --cached --quiet; then
  git commit -m "Local vault sync: $(date -u +%Y-%m-%dT%H:%MZ)"
fi

# Rebase local commit (if any) on top of remote. With pre-clean done, conflicts
# should be impossible, but abort cleanly if one slips through.
if ! retry git pull --rebase origin main; then
  echo "REBASE FAILED — aborting. Manual fix needed:"
  git status
  git rebase --abort || true
  exit 1
fi

retry git push origin main

echo "===== $(date -u +%FT%TZ) sync ok ====="
