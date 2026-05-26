#!/bin/bash
# === Managed by ClaudeHUD ============================================
# script-version: 1.0.0
# source: ClaudeHUD/Resources/Scripts/vault-reset.sh
# To edit, fork in the ClaudeHUD repo and rebuild. The installer
# detects local edits to the installed copy and refuses to clobber
# them — see Services/VaultScriptInstaller.swift.
# =====================================================================
# vault-reset.sh — the ONLY sanctioned way to reconcile the Obsidian vault
# to origin/main. It exists because on 2026-05-17 a bare
# `git reset --hard origin/main` discarded a local-only note (the edits
# lived only in an unpushed commit). This guard makes that impossible:
# it ALWAYS pushes local work up before it touches anything.
#
# HARD RULE: never run `git reset --hard` (or `git clean -fdx`) on the
# vault directly. Use this script. Default mode never loses data.
#
#   vault-reset.sh                 # push-safe reconcile (default; no loss)
#   vault-reset.sh --force-discard # discard local — ONLY after tagging a
#                                  #   backup ref first (still recoverable)
set -euo pipefail
export HOME="/Users/bbdaniels"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
VAULT="$HOME/Documents/Obsidian"
cd "$VAULT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
MODE="${1:-safe}"

echo "===== vault-reset ($MODE) $TS ====="

# Always capture a recovery ref of the exact current state first.
git tag -f "backup/vault-reset-$TS" HEAD >/dev/null 2>&1 || true

if [ "$MODE" = "--force-discard" ]; then
  # Even a forced discard must be recoverable: the tag above + a named
  # branch pin everything currently local before we throw it away.
  git add -A
  git commit -q -m "vault-reset: pre-discard snapshot $TS" 2>/dev/null || true
  git branch -f "backup/discard-$TS" HEAD
  git fetch origin main --quiet
  echo "Local state pinned at backup/discard-$TS — discarding to origin/main."
  git reset --hard origin/main
  echo "Done. Recover with: git reset --hard backup/discard-$TS"
  exit 0
fi

# ---- default: push-safe reconcile, never loses local work ----
# 1. Commit everything local (incl. project Tasks.md edits).
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "vault-reset: local autosave $TS"
  echo "Committed local changes."
fi
# 2. Push BEFORE integrating remote — this is the whole point.
git fetch origin main --quiet
if [ -n "$(git rev-list origin/main..HEAD)" ]; then
  # There are local commits not on origin. Rebase onto origin, then push.
  if ! git rebase origin/main; then
    echo "REBASE CONFLICT — aborting, NOTHING discarded. Local commits are"
    echo "intact on this branch and tagged backup/vault-reset-$TS."
    git rebase --abort || true
    exit 1
  fi
fi
git push origin main
git fetch origin main --quiet
# 3. Assert we are exactly in sync and nothing local-only remains.
if [ -n "$(git status --porcelain)" ] || [ -n "$(git rev-list origin/main..HEAD)" ]; then
  echo "ERROR: not fully synced after reconcile — refusing to claim safe."
  git status --short
  exit 1
fi
echo "Vault reconciled to origin/main with zero data loss. In sync."
