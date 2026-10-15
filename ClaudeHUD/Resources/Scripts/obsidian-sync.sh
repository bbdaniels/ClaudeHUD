#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.2.0
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
# A failed fetch or push is not retried in-run: launchd runs this every 15
# minutes and the next run picks up where this one stopped. (The in-run
# retry loop existed for iCloud's EDEADLK on dataless files; the vault left
# iCloud on 2026-10-15 and the loop was removed.)

set -e
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

VAULT="/Users/bbdaniels/Projects/obsidian"
cd "$VAULT"

# --- single-instance lock --------------------------------------------
# Concurrent syncers (cron + cockpit + ad-hoc sessions) racing
# `git pull --rebase` / `git rebase --abort` is what corrupts
# the git dir's rebase-merge and wedges the vault. Serialize with an atomic
# mkdir lock; a dead holder's lock is reclaimed so we never deadlock ourselves.
#
# Ask git where its directory is rather than spelling VAULT/.git, so the
# script stays right whether .git is a directory or a gitfile.
GITDIR="$(git rev-parse --absolute-git-dir)"
LOCKDIR="$GITDIR/obsidian-sync.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  holder="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) another sync running (pid $holder) — skipping"
    exit 0
  fi
  rm -rf "$LOCKDIR"; mkdir "$LOCKDIR"
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

# NOTE: launchd self-heal is its own job (com.bbdaniels.ensure-launchagents),
# decoupled from this sync script so a failing sync cannot take it down.

echo "===== $(date -u +%FT%TZ) sync start ====="

# Self-heal: clear any leftover rebase from a crashed/old run before we
# start. We hold the lock, so no other git is active. Try a clean abort;
# if the rebase dir is corrupt (e.g. missing head-name), force-remove it.
# This is what turns a wedge into a self-recovering blip.
if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; then
  echo "  clearing leftover rebase state"
  git rebase --abort 2>/dev/null || true
  rm -rf "$GITDIR/rebase-merge" "$GITDIR/rebase-apply"
fi

git fetch origin main --quiet

# Pre-clean: drop any local untracked Daily Note that origin has a version of.
git ls-tree -r --name-only -z origin/main -- "Daily Notes/" \
  | while IFS= read -r -d '' f; do
      if [ -f "$f" ] && ! git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        echo "  pre-clean (local scratch → agent version): $f"
        rm -f -- "$f"
      fi
    done

# Stage everything (modifications + new files + deletions) and commit if non-empty.
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Local vault sync: $(date -u +%Y-%m-%dT%H:%MZ)"
fi

# Rebase local commit (if any) on top of remote. With pre-clean done, conflicts
# should be impossible, but abort cleanly if one slips through.
if ! git pull --rebase origin main; then
  echo "REBASE CONFLICT — aborting; nothing left wedged (next run starts clean):"
  git status || true
  git rebase --abort 2>/dev/null || true
  rm -rf "$GITDIR/rebase-merge" "$GITDIR/rebase-apply"
  exit 1
fi

git push origin main

echo "===== $(date -u +%FT%TZ) sync ok ====="
