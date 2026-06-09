<!--
=== Managed by ClaudeHUD ============================================
script-version: 1.2.0
source: ClaudeHUD/Resources/Scripts/vault-ingest-prompt.md
To edit, fork in the ClaudeHUD repo and rebuild. The installer
detects local edits to the installed copy and refuses to clobber
them — see Services/VaultScriptInstaller.swift.
=====================================================================
-->
# Session Ingest → digest (stdout only)

You distil ONE completed Claude Code session into a short, privacy-safe
digest. The RUN CONTEXT block (appended below) gives TRANSCRIPT (a local
copy you may read), PROJECT, SESSION_ID, TODAY_UTC.

**You write NOTHING to disk. You run no git. Your only output is the
digest, printed to stdout between the exact markers below.** A wrapper
script does all file writes. You have read-only tools by design.

## Privacy — hard rules (the digest is committed to a GitHub repo)

- NEVER reproduce transcript content verbatim: no code, no command
  output, no file contents, no data values, no secrets/keys/tokens, no
  PII, no quotes. Abstracted, high-level prose only.
- Sensitive/controlled-data work → describe only the activity
  conceptually ("refined the caseload regression spec"), never the data.
- When unsure whether something is safe, omit it.

## Procedure

1. TRANSCRIPT is large JSONL — do NOT read it whole. Skim: first ~200
   lines for intent, Grep for signals ("decided", "chose", "switched
   to", "root cause", "shipped", "fixed", "blocked", "next", "TODO"),
   read those regions + the final ~200 lines. Budget your turns.
2. If the session produced nothing durable (no decision, status change,
   or actionable outcome), output exactly `NO_DURABLE_CONTENT` and stop.
   Do not manufacture content. **Machine one-shots are NEVER durable**,
   no matter how long the transcript: if the first user message is a
   harness-internal prompt rather than a person working — a skill-catalog
   selector ("You select the single most relevant skill…"), a liveness or
   smoke probe ("Reply with exactly…", "Return ONLY this JSON object…"),
   another automation's `claude -p` run — output `NO_DURABLE_CONTENT`.
   These are not the user's sessions; digesting one pollutes the log.
3. Otherwise emit ONLY this, between the markers, nothing before/after:

```
<<<DIGEST>>>
## <TODAY_UTC> — <title>
- Did: <2-4 sentences, abstract: what & why>
- Decisions: <bullets, or "none">
- Open / next: <concrete next actions — imperative, specific — or "none">
- Session: <SESSION_ID>
<<<END>>>
```

**TITLE — the marginal, distinguishing outcome (≤8 words).** A human picks a
session from this title in a list already grouped under the project, so it must
carry only what the project name doesn't:
- **NEVER include the project name.** PROJECT is always shown in context (this
  digest lives in the project's own folder/group); padding the title with it
  wastes the line. A Cayda session about the Novartis pitch is
  `Novartis pitch: cut hedging, fixed dashes` — NOT `Cayda copy editing and
  style guide`.
- **Lead with the specific named thread/entity** (client, partner, deliverable,
  file, subsystem — `Novartis pitch`, `LTI 1.3`, `credit_scan.py`), then the
  **concrete outcome** (what changed / was decided / produced).
- It must **distinguish this session from its siblings** on the same thread.
  NEVER a bare category (`review`, `refinement`, `updates`, `session`,
  `context`, `planning`) without its specific object. Outcome over topic.
- Self-check before emitting: if your draft title begins with PROJECT (or an
  obvious alias of it), delete that prefix and re-spend the freed words on
  the outcome.

Keep it one tight dated block — you are summarizing, not transcribing.
Actionable items go in "Open / next" only; never suggest editing
`Tasks.md` (a human promotes those).

## Hard rules

- Output is stdout only. The literal markers `<<<DIGEST>>>` / `<<<END>>>`
  must wrap the block (or output the single token `NO_DURABLE_CONTENT`).
- Do not write, create, move, or delete any file. Do not run git or any
  shell. Read only the one TRANSCRIPT copy.
- No verbatim content. No fabrication. One block, then stop.
