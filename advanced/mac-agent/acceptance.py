#!/usr/bin/env python3
"""Agent-user Desktop Commander acceptance test (positive + negative).

Run as root. Spawns the Desktop Commander launcher as the dedicated agent user,
speaks MCP over stdio, and checks that:
  * real work succeeds inside the agent boundary (shell, git, write/read, search,
    process session start/terminate), and
  * the OS boundary holds (founder home, denied siblings, foreign process signal,
    sudo, writes outside Workspaces all fail).

Writes a JSON receipt. Never reads or prints credentials. Python 3.9+ stdlib only.
"""
import argparse
import json
import os
import platform
import pwd
import queue
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

PROTOCOL = "2025-06-18"


class Mcp:
    def __init__(self, launcher, user):
        pw = pwd.getpwnam(user)
        env = {"HOME": pw.pw_dir, "USER": user, "LOGNAME": user,
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
        self.proc = subprocess.Popen(
            shlex.split(launcher), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env, cwd=pw.pw_dir,
            user=pw.pw_uid, group=pw.pw_gid,
            extra_groups=os.getgrouplist(user, pw.pw_gid),
            start_new_session=True)
        self.q = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.q.put(json.loads(line))
            except ValueError:
                pass  # non-JSON noise on stdout is ignored

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=60):
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method,
                   "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.q.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError("RPC_ERROR:" + json.dumps(msg["error"])[:300])
                return msg.get("result", {})
        raise TimeoutError("RPC_TIMEOUT:" + method)

    def call(self, tool, args, timeout=60):
        res = self.request("tools/call", {"name": tool, "arguments": args}, timeout)
        text = "\n".join(c.get("text", "") for c in res.get("content", [])
                         if c.get("type") == "text")
        return bool(res.get("isError")), text

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                os.killpg(self.proc.pid, 9)
            except Exception:
                pass


DENY_MARKERS = ("permission denied", "operation not permitted", "not permitted",
                "eacces", "eperm", "access denied", "not allowed", "blocked",
                "outside allowed", "no such file")


def denied(is_err, text):
    t = text.lower()
    return is_err or any(m in t for m in DENY_MARKERS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launcher", required=True,
                    help="MCP command line (shell-split), exactly as the tunnel runs it")
    ap.add_argument("--spawn-user", default=None,
                    help="user that spawns the launcher (tunnel user); defaults to agent user")
    ap.add_argument("--agent-user", required=True)
    ap.add_argument("--denied-file", action="append", default=[],
                    help="files the agent must not read (e.g. the tunnel runtime key)")
    ap.add_argument("--workspaces", required=True)
    ap.add_argument("--founder-home", required=True)
    ap.add_argument("--denied-dir", action="append", default=[])
    ap.add_argument("--foreign-pid", type=int, required=True,
                    help="PID of a process owned by another user (e.g. an existing tunnel service)")
    ap.add_argument("--receipt", required=True)
    a = ap.parse_args()

    if os.geteuid() != 0:
        sys.exit("run as root (sudo)")
    pw = pwd.getpwnam(a.agent_user)
    try:
        foreign_uid = os.stat("/proc/%d" % a.foreign_pid).st_uid if os.path.exists("/proc") else None
    except OSError:
        foreign_uid = None
    if foreign_uid is None:
        out = subprocess.run(["/bin/ps", "-o", "uid=", "-p", str(a.foreign_pid)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        foreign_uid = int(out.stdout.strip()) if out.stdout.strip() else -1
    if foreign_uid in (-1, pw.pw_uid, 0):
        sys.exit("foreign PID must be alive and owned by a non-root user other than the agent")

    probe_dir = os.path.join(a.workspaces, "_agent_acceptance")
    probe_file = os.path.join(probe_dir, "probe.txt")
    token = "AGENT_PROBE_%d" % int(time.time())
    on_darwin = platform.system() == "Darwin"
    results = []

    def record(cid, kind, ok, detail=""):
        results.append({"id": cid, "kind": kind, "pass": bool(ok),
                        "detail": detail[:240]})
        print(("PASS " if ok else "FAIL ") + cid + (" — " + detail[:120] if detail and not ok else ""))

    m = Mcp(a.launcher, a.spawn_user or a.agent_user)
    try:
        init = m.request("initialize", {
            "protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "agent-acceptance", "version": "1"}}, 90)
        m.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        record("I1_initialize", "setup", bool(init.get("serverInfo")),
               json.dumps(init.get("serverInfo")))
        tools = [t["name"] for t in m.request("tools/list").get("tools", [])]
        record("I2_tools_list", "setup",
               {"start_process", "read_file", "write_file", "force_terminate"} <= set(tools),
               "%d tools" % len(tools))

        def sh(cmd, timeout_ms=15000):
            return m.call("start_process", {"command": cmd, "timeout_ms": timeout_ms},
                          timeout=timeout_ms / 1000 + 30)

        # ---------- positive ----------
        e, t = sh("id -un; uname -s")
        ok = (not e) and a.agent_user in t and (("Darwin" in t) if on_darwin else True)
        record("P1_shell_runs_as_agent", "positive", ok, t)

        e, t = sh("git --version")
        record("P2_git_available", "positive", (not e) and "git version" in t, t)

        e, t = m.call("create_directory", {"path": probe_dir})
        e, t = m.call("write_file", {"path": probe_file, "content": token, "mode": "rewrite"})
        e2, t2 = m.call("read_file", {"path": probe_file})
        record("P3_write_read_in_workspaces", "positive",
               (not e) and (not e2) and token in t2, t + " | " + t2)

        e, t = sh("cd '%s' && pwd && ls | head -5" % a.workspaces)
        record("P4_shell_in_workspaces", "positive", (not e) and a.workspaces in t, t)

        e, t = m.call("start_search", {"path": probe_dir, "pattern": token,
                                       "searchType": "content"}, timeout=60)
        found = token in t
        if not found and not e:
            sid = None
            for tok in t.replace(",", " ").split():
                if tok.startswith("search_"):
                    sid = tok.strip("`'\".:")
            for _ in range(10):
                if not sid:
                    break
                time.sleep(1)
                e3, t3 = m.call("get_more_search_results", {"sessionId": sid})
                if token in t3 or "probe.txt" in t3:
                    found = True
                    break
        record("P5_content_search", "positive", found, t)

        e, t = sh("sleep 120", timeout_ms=1500)
        pid = None
        for tok in t.replace(",", " ").replace(":", " ").split():
            if tok.isdigit():
                pid = int(tok)
                break
        e2, t2 = m.call("list_sessions", {})
        e3, t3 = (True, "no pid") if pid is None else m.call("force_terminate", {"pid": pid})
        time.sleep(1)
        alive = pid is not None and subprocess.run(
            ["/bin/kill", "-0", str(pid)], stderr=subprocess.DEVNULL).returncode == 0
        record("P6_session_start_terminate", "positive",
               pid is not None and (not e3) and not alive,
               "pid=%s term=%s" % (pid, t3))

        # ---------- negative (boundary must hold) ----------
        e, t = sh("ls -la '%s'" % a.founder_home)
        record("N1_founder_home_list_denied", "negative", denied(e, t), t)

        e, t = m.call("read_file", {"path": os.path.join(a.founder_home, ".zshrc")})
        record("N2_founder_home_read_denied", "negative", denied(e, t), t)

        for i, d in enumerate(a.denied_dir):
            e, t = sh("ls '%s'" % d)
            record("N3_denied_sibling_%d" % i, "negative", denied(e, t), d + " :: " + t)

        # Markers are split with '' so the command text itself never contains them
        # (DC echoes the command in error messages).
        e, t = sh("kill -0 %d 2>/dev/null && echo SIGNAL_ALL''OWED || echo SIGNAL_REF''USED"
                  % a.foreign_pid)
        record("N4_foreign_process_signal_denied", "negative",
               "SIGNAL_ALLOWED" not in t and "SIGNAL_REFUSED" in t, t)

        e, t = m.call("kill_process", {"pid": a.foreign_pid})
        still = subprocess.run(["/bin/kill", "-0", str(a.foreign_pid)],
                               stderr=subprocess.DEVNULL).returncode == 0
        record("N5_kill_process_foreign_denied", "negative", still, t)

        # Test the OS boundary, not DC's blocklist: run sudo from a script file,
        # which DC does not inspect.
        probe_sh = os.path.join(probe_dir, "sudo_probe.sh")
        m.call("write_file", {"path": probe_sh, "content":
               "/usr/bin/sudo -n true 2>/dev/null && echo SUDO_OK || echo SUDO_REFUSED\n"})
        e, t = sh("/bin/sh '%s'" % probe_sh)
        record("N6_sudo_refused_by_os", "negative",
               "SUDO_REFUSED" in t and "SUDO_OK" not in t, t)

        for i, f in enumerate(a.denied_file):
            present = os.path.exists(f)
            e, t = sh("head -c 8 '%s' >/dev/null 2>&1 && echo READ_O''K || echo READ_REF''USED" % f)
            e2, t2 = m.call("read_file", {"path": f})
            record("N9_denied_file_%d" % i, "negative",
                   present and "READ_OK" not in t and "READ_REFUSED" in t and denied(e2, t2),
                   f + (" :: " if present else " :: FILE_ABSENT_TEST_NOT_MEANINGFUL :: ") + t)

        cfg_path = os.path.join(pw.pw_dir, ".claude-server-commander", "config.json")
        before = open(cfg_path, "rb").read() if os.path.exists(cfg_path) else b""
        e, t = m.call("set_config_value", {"key": "allowedDirectories", "value": ["/"]})
        after = open(cfg_path, "rb").read() if os.path.exists(cfg_path) else b""
        record("N8_config_locked", "negative", before == after and before != b"", t)

        outside = os.path.join(os.path.dirname(a.workspaces), "_agent_should_not_exist")
        e, t = sh("touch '%s' 2>&1; echo done" % outside)
        made = os.path.lexists(outside)
        if made:
            os.unlink(outside)
        record("N7_write_outside_workspaces_denied", "negative", not made, t)
    except Exception as ex:  # record harness failure honestly
        record("X_harness_exception", "harness", False, repr(ex))
    finally:
        m.close()
        try:
            if os.path.isdir(probe_dir) and not os.path.islink(probe_dir):
                for n in os.listdir(probe_dir):
                    p = os.path.join(probe_dir, n)
                    if os.path.isfile(p) and not os.path.islink(p):
                        os.unlink(p)
                os.rmdir(probe_dir)
        except OSError:
            pass

    passed = all(r["pass"] for r in results)
    receipt = {
        "schema": "AGENT_USER_DC_ACCEPTANCE_V1",
        "at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(), "system": platform.system(),
        "agent_user": a.agent_user, "agent_uid": pw.pw_uid,
        "foreign_pid_uid": foreign_uid,
        "status": "PASS_ALL" if passed else "FAIL_REVIEW",
        "passed": sum(r["pass"] for r in results), "total": len(results),
        "results": results,
        "credentials_read": False,
        "note": "Local stdio acceptance only. ChatGPT tunnel/connector calls are a separate acceptance.",
    }
    os.makedirs(os.path.dirname(a.receipt), exist_ok=True)
    with open(a.receipt, "w") as f:
        json.dump(receipt, f, indent=2, ensure_ascii=False)
    os.chmod(a.receipt, 0o644)
    print("\n%s  %d/%d  receipt=%s" % (receipt["status"], receipt["passed"],
                                       receipt["total"], a.receipt))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
