#!/usr/bin/env python3
"""ClaudeHUD Slack supervisory MCP server (Phase 3 — ASK-YOU spine).

One stdio MCP server, configured per Slack-spawned turn via --mcp-config so it
NEVER affects the operator's hand-started sessions. It exposes exactly two tools:

  * approve     — the `--permission-prompt-tool`. Claude calls it before any tool
                  that needs permission. Implements the risk-tiered policy (3.2):
                  auto-approve reads + in-repo edits as FAST LOCAL RETURNS (no
                  Slack round-trip, per gap H28), hard-deny the floor by rule
                  (S4), and gate the genuinely consequential (Bash, network,
                  deletes, executes-later writes) by parking on Slack. ExitPlanMode
                  is gated as the plan-approval card (3.3).

  * ask_human   — the clarifying-question transport (3.1). Always round-trips to
                  Slack; maps AskUserQuestion-shaped {header, options} 1:1 onto a
                  Block Kit poll, blocks until the operator taps or replies, and
                  returns the chosen answers.

The blocking mechanism is the file relay (the proven permission-watcher.sh shape):
write a request JSON, poll for a decision JSON written by ClaudeHUD when the
operator acts. The Slack 3s-ack-vs-human-minutes problem dissolves because the
WebSocket envelope is acked instantly by ClaudeHUD; only THIS local RPC parks.

Every parked prompt carries a hard timeout (gap A4/E4); on timeout it resolves to
a SAFE DEFAULT (deny for permissions, "no answer" for questions) so a dropped tap
can never wedge the turn forever. Concurrency is naturally multiplexed: each call
is keyed by a fresh promptId, so channel A parking for hours cannot stall channel
B (gap H27).

Env (set by ClaudeHUD in the mcp-config `env` block):
  HUD_SLACK_RELAY_DIR   relay root (requests/ + decisions/ live under it)
  HUD_SLACK_CHANNEL     Slack channel id this turn belongs to
  HUD_SLACK_GENERATION  the turn's generation id (stale-prompt hygiene, 3.4)
  HUD_SLACK_CWD         the turn's working directory (in-repo classification)
  HUD_SLACK_TIMEOUT     per-prompt timeout seconds (default 1800)

stdio JSON-RPC only; pure stdlib so it runs under /usr/bin/python3 with no deps.
"""

import json
import os
import sys
import time
import uuid

RELAY_DIR = os.environ.get("HUD_SLACK_RELAY_DIR", os.path.expanduser("~/.claude/hud/slack"))
CHANNEL = os.environ.get("HUD_SLACK_CHANNEL", "")
GENERATION = os.environ.get("HUD_SLACK_GENERATION", "0")
CWD = os.environ.get("HUD_SLACK_CWD", os.getcwd())
try:
    TIMEOUT = float(os.environ.get("HUD_SLACK_TIMEOUT", "1800"))
except ValueError:
    TIMEOUT = 1800.0

REQUESTS_DIR = os.path.join(RELAY_DIR, "requests")
DECISIONS_DIR = os.path.join(RELAY_DIR, "decisions")
LOG_PATH = os.path.join(RELAY_DIR, "mcp.log")

# Tool classification (3.2). Reads + in-repo edits are auto-approved as fast local
# returns; everything consequential is gated; the floor is hard-denied by rule.
READ_TOOLS = {"Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "Task"}
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
# Network / exec / destructive — always gated.
GATE_TOOLS = {"Bash", "WebFetch", "WebSearch", "BashOutput", "KillBash"}

# Executes-later denylist (gap B10): a write to any of these runs code later or
# mutates the agent's own permissions, so it is NEVER auto-approved regardless of
# cwd — it is gated as a high-risk write even inside the repo.
EXECUTES_LATER = (
    ".claude/", ".git/", ".github/", ".husky/",
    "Makefile", "makefile",
    "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    "Cargo.toml", "Cargo.lock", "pyproject.toml", "setup.py",
    "Gemfile", "Gemfile.lock", "go.mod",
    ".gitlab-ci.yml", ".travis.yml", "Dockerfile", "docker-compose",
)


def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} [{CHANNEL[:8]}/{GENERATION}] {msg}\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Risk policy (3.2 / S4)
# ---------------------------------------------------------------------------

def _within_cwd(path):
    if not path:
        return False
    try:
        ap = os.path.realpath(os.path.expanduser(path))
        base = os.path.realpath(CWD)
        return ap == base or ap.startswith(base + os.sep)
    except Exception:
        return False


def _hits_executes_later(path):
    if not path:
        return False
    p = path.replace(os.path.expanduser("~"), "~")
    name = os.path.basename(path)
    # Dotfiles in any home root, and any segment on the denylist.
    if name.startswith(".") and ("/" + name) in p and _is_home_dotfile(path):
        return True
    for needle in EXECUTES_LATER:
        if needle in path or name == needle:
            return True
    return False


def _is_home_dotfile(path):
    try:
        home = os.path.realpath(os.path.expanduser("~"))
        ap = os.path.realpath(os.path.expanduser(path))
        parent = os.path.dirname(ap)
        return parent == home and os.path.basename(ap).startswith(".")
    except Exception:
        return False


def hard_deny_reason(tool_name, tool_input):
    """The deny FLOOR (S4): cannot be overridden by any approval. Returns a reason
    string to deny, or None to fall through to the normal tiers."""
    if tool_name == "Bash":
        cmd = (tool_input.get("command") or "")
        low = cmd.lower()
        # rm -rf targeting outside the cwd (or root) is never allowed.
        if "rm -rf" in low or "rm -fr" in low:
            # Any absolute-path rm -rf that is not strictly inside cwd is floor-denied.
            for tok in cmd.split():
                if tok.startswith("/") and not _within_cwd(tok):
                    return "rm -rf targeting a path outside the working directory"
            if " /" in low or low.strip().endswith(" /"):
                return "rm -rf targeting the filesystem root"
    if tool_name in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if _is_home_dotfile(path):
            return "write to a home dotfile"
    return None


def classify(tool_name, tool_input):
    """Return one of: ('allow', None), ('gate', reason), ('deny', reason)."""
    deny = hard_deny_reason(tool_name, tool_input)
    if deny:
        return ("deny", deny)

    # ExitPlanMode is gated as the plan-approval card (3.3) — handled by the
    # caller, but classified as gate here so it round-trips.
    if tool_name == "ExitPlanMode":
        return ("gate", "plan ready for approval")

    if tool_name in READ_TOOLS:
        return ("allow", None)

    if tool_name in EDIT_TOOLS:
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if _hits_executes_later(path):
            return ("gate", "writes a file that executes later or changes permissions")
        if _within_cwd(path):
            return ("allow", None)
        return ("gate", "writes outside the working directory")

    if tool_name in GATE_TOOLS:
        return ("gate", "consequential action")

    # Our own MCP tools are always allowed (ask_human, approve).
    if tool_name.startswith("mcp__hud__"):
        return ("allow", None)

    # Unknown / MCP / everything else: gate to be safe (supervision over surprise).
    return ("gate", "unrecognized action")


# ---------------------------------------------------------------------------
# File relay (the blocking round-trip)
# ---------------------------------------------------------------------------

def park(kind, payload, reason=None):
    """Write a request and block until ClaudeHUD writes the matching decision (or
    the per-prompt timeout fires). Returns the decision dict, or None on timeout."""
    os.makedirs(REQUESTS_DIR, exist_ok=True)
    os.makedirs(DECISIONS_DIR, exist_ok=True)
    pid = uuid.uuid4().hex
    req = {
        "id": pid,
        "kind": kind,
        "channel": CHANNEL,
        "generation": GENERATION,
        "cwd": CWD,
        "reason": reason,
        "createdAt": time.time(),
        "payload": payload,
    }
    req_path = os.path.join(REQUESTS_DIR, pid + ".json")
    dec_path = os.path.join(DECISIONS_DIR, pid + ".json")
    tmp = req_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(req, f)
    os.replace(tmp, req_path)
    log(f"park kind={kind} id={pid[:8]} reason={reason}")

    deadline = time.time() + TIMEOUT
    try:
        while time.time() < deadline:
            if os.path.exists(dec_path):
                try:
                    with open(dec_path) as f:
                        decision = json.load(f)
                except (ValueError, OSError):
                    time.sleep(0.05)
                    continue
                _cleanup(req_path, dec_path)
                log(f"resolved id={pid[:8]} -> {decision.get('behavior') or 'answered'}")
                return decision
            # Touch the request as a liveness signal for the watcher.
            try:
                os.utime(req_path, None)
            except OSError:
                pass
            time.sleep(0.3)
    finally:
        # On any exit path, never leave a stale request file behind.
        if os.path.exists(req_path):
            try:
                os.remove(req_path)
            except OSError:
                pass
    log(f"timeout id={pid[:8]}")
    return None


def _cleanup(req_path, dec_path):
    for p in (req_path, dec_path):
        try:
            if os.path.exists(p):
                os.remove(p)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def tool_approve(args):
    """The --permission-prompt-tool. `args` carries the proposed tool call.
    Returns the PermissionResult JSON (as text) Claude expects."""
    tool_name = args.get("tool_name") or args.get("toolName") or ""
    tool_input = args.get("input") or args.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    verdict, reason = classify(tool_name, tool_input)

    if verdict == "allow":
        return _permission_text({"behavior": "allow", "updatedInput": tool_input})

    if verdict == "deny":
        # Hard-deny floor — no Slack round-trip, cannot be overridden.
        log(f"floor-deny {tool_name}: {reason}")
        return _permission_text({
            "behavior": "deny",
            "message": f"Blocked by ClaudeHUD safety floor: {reason}.",
        })

    # Gated — park on Slack and honor the operator's decision.
    kind = "plan" if tool_name == "ExitPlanMode" else "approve"
    decision = park(kind, {
        "tool_name": tool_name,
        "input": tool_input,
        "tool_use_id": args.get("tool_use_id") or "",
    }, reason=reason)

    if decision is None:
        return _permission_text({
            "behavior": "deny",
            "message": "No response from the operator before timeout; denied for safety.",
        })

    behavior = decision.get("behavior", "deny")
    out = {"behavior": behavior}
    if behavior == "allow":
        out["updatedInput"] = decision.get("updatedInput") or tool_input
        if decision.get("updatedPermissions"):
            out["updatedPermissions"] = decision["updatedPermissions"]
    else:
        out["message"] = decision.get("message") or "Denied by the operator."
    return _permission_text(out)


def tool_ask_human(args):
    """Clarifying-question transport (3.1). Always round-trips to Slack."""
    questions = args.get("questions") or []
    # Tolerate a single-question shorthand.
    if not questions and (args.get("question") or args.get("header")):
        questions = [{
            "header": args.get("header") or "Question",
            "question": args.get("question") or "",
            "multiSelect": bool(args.get("multiSelect")),
            "options": args.get("options") or [],
        }]
    decision = park("ask", {"questions": questions})
    if decision is None:
        return _text(json.dumps({
            "answered": False,
            "note": "The operator did not answer before the timeout.",
        }))
    answers = decision.get("answers") or []
    # Return both a machine form and a readable form so the model can proceed.
    readable = "\n".join(
        f"- {a.get('header', 'Q')}: {a.get('answer', '')}" for a in answers
    )
    return _text(json.dumps({"answered": True, "answers": answers}) +
                 ("\n\nOperator answered:\n" + readable if readable else ""))


def _permission_text(result):
    # The permission-prompt-tool returns its PermissionResult as the text of a
    # single content block (Claude parses the JSON out of it).
    return _text(json.dumps(result))


def _text(s):
    return {"content": [{"type": "text", "text": s}]}


# ---------------------------------------------------------------------------
# MCP stdio JSON-RPC plumbing
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "approve",
        "description": (
            "Permission gate for ClaudeHUD-supervised turns. Called automatically "
            "as the permission-prompt-tool; do not call directly."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "tool_name": {"type": "string"},
                "input": {"type": "object"},
            },
        },
    },
    {
        "name": "ask_human",
        "description": (
            "Ask the human operator a clarifying question when intent is ambiguous "
            "and you cannot safely proceed. Provide 2-4 options each with a short "
            "label and a one-line description; set multiSelect when several may "
            "apply. The operator answers in Slack and the chosen option(s) are "
            "returned. Prefer this over guessing on a consequential ambiguity."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "questions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "header": {"type": "string", "description": "<=12 char label"},
                            "question": {"type": "string"},
                            "multiSelect": {"type": "boolean"},
                            "options": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": {"type": "string"},
                                        "description": {"type": "string"},
                                    },
                                    "required": ["label"],
                                },
                            },
                        },
                        "required": ["header", "question", "options"],
                    },
                }
            },
            "required": ["questions"],
        },
    },
]


def handle(req):
    method = req.get("method")
    rid = req.get("id")

    if method == "initialize":
        return _ok(rid, {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "claudehud-slack", "version": "1.0.0"},
        })

    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response

    if method == "ping":
        return _ok(rid, {})

    if method == "tools/list":
        return _ok(rid, {"tools": TOOLS})

    if method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            if name == "approve":
                return _ok(rid, tool_approve(args))
            if name == "ask_human":
                return _ok(rid, tool_ask_human(args))
            return _err(rid, -32602, f"Unknown tool: {name}")
        except Exception as e:  # never crash the turn on a tool error
            log(f"tool error {name}: {e}")
            return _ok(rid, {"content": [{"type": "text", "text": f"tool error: {e}"}],
                             "isError": True})

    if rid is None:
        return None  # unknown notification
    return _err(rid, -32601, f"Method not found: {method}")


def _ok(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _err(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def main():
    log("server start")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        resp = handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
    log("server stop")


if __name__ == "__main__":
    main()
