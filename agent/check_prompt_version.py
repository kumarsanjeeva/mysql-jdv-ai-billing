# agent/check_prompt_version.py -- offline proof of the prompt/tool-description versions, no
# network, no key, no database (a fake model replaces the LLM).
#   1. v1 reproduces BOTH hashes recorded in results/29 before the versioning edit.
#   2. v2 differs from v1 only in the create_order description (the unit rule) and in one added
#      system-prompt bullet (the duplicate rule).
#   3. The L5 scripted turn matches each version, and each version's transcript header and file
#      name carry the version.
#   4. The runner refuses to start when any target file already exists, before any model call.
#   5. AGENT_PROMPT_VERSION is required: unset or unknown exits with a message.
# The prompt text is fixed when agent.py is imported, so v1 and v2 are read in child processes.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check AGENT_PROMPT_VERSION=v1 AGENT_TODAY=2026-10-21 \
#             python -m agent.check_prompt_version >> results/29_prompt_version_offline_check.txt

import difflib
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"
RECORD = RESULTS / "29_prompt_version_offline_check.txt"
MARKER = "- Before create_order, show the customer the items, subtotal, GST and total, and wait for them to agree.\n"


def sha(text):
    """Return the sha256 of a text as hex."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def child(folder):
    """Inside a child process: print the prompt, tool definitions, L5 turn and L5 transcript of this version as JSON."""
    os.environ["MYSQL_HOST"], os.environ["MYSQL_PORT"] = "localhost", "3306"
    from agent import agent, live_scenarios, tools

    def fake(messages, log):
        """Reply with fixed text; no tool calls."""
        return ({"role": "assistant", "content": "ok"}, ["ok"], [], "end_turn", (1, 1, 0))
    agent.call_llm, live_scenarios.RESULTS, sys.argv = fake, Path(folder), ["live_scenarios"]
    live_scenarios.main()
    l5 = [turns for name, turns in live_scenarios.SCENARIOS if name == "L5_balance"][0]
    files = sorted(p.name for p in Path(folder).glob("*.txt"))
    l5_text = (Path(folder) / f"agent_live_gemini_offline-check_{agent.PROMPT_VERSION}_L5_balance.txt").read_text(encoding="utf-8")
    print("=====JSON=====")
    print(json.dumps({"system": agent.SYSTEM, "schemas": tools.schemas(agent.PROMPT_VERSION), "l5_turns": l5,
                      "files": files, "l5_transcript": l5_text}))


def read_version(version):
    """Run a child for one prompt version and return its JSON data."""
    folder = tempfile.mkdtemp(prefix="pv_")
    env = {**os.environ, "AGENT_PROMPT_VERSION": version}
    r = subprocess.run([sys.executable, "-m", "agent.check_prompt_version", "--child", folder], env=env,
                       capture_output=True, text=True, encoding="utf-8")
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout.split("=====JSON=====")[1])


def exit_text(env_extra):
    """Import agent.agent in a child with the given AGENT_PROMPT_VERSION setting; return (exit code, message)."""
    env = {**os.environ, "AGENT_PROMPT_VERSION": ""}  # empty = unset to agent.py, and python-dotenv will not refill a name that is already present
    env.update(env_extra)
    r = subprocess.run([sys.executable, "-c", "from agent import agent"], env=env, capture_output=True, text=True)
    return r.returncode, (r.stderr or r.stdout).strip()


def main():
    """Run the checks and print PASS lines."""
    print("# PART 2 -- offline proof, run after the versioning edit "
          f"(AGENT_TODAY={os.environ.get('AGENT_TODAY')}, model string 'offline-check', fake model)")
    recorded = dict(re.findall(r"^(SYSTEM_SHA256|SCHEMAS_SHA256) = ([0-9a-f]{64})$", RECORD.read_text(encoding="utf-8"), re.M))
    v1, v2 = read_version("v1"), read_version("v2")

    # 1. v1 reproduces both recorded hashes
    system_hash, schemas_hash = sha(v1["system"]), sha(json.dumps(v1["schemas"], sort_keys=True))
    print(f"v1 SYSTEM_SHA256  = {system_hash}\n   recorded before the edit = {recorded['SYSTEM_SHA256']}")
    print(f"v1 SCHEMAS_SHA256 = {schemas_hash}\n   recorded before the edit = {recorded['SCHEMAS_SHA256']}")
    assert system_hash == recorded["SYSTEM_SHA256"] and schemas_hash == recorded["SCHEMAS_SHA256"]
    print("PASS  v1 reproduces BOTH recorded hashes exactly")

    # 2. v2 differs from v1 only in the create_order description and the one system-prompt bullet
    from agent import agent, tools
    assert [s["name"] for s in v1["schemas"]] == [s["name"] for s in v2["schemas"]]
    changed = [a["name"] for a, b in zip(v1["schemas"], v2["schemas"]) if a != b]
    assert changed == ["create_order"], changed
    a, b = v1["schemas"][3], v2["schemas"][3]
    assert {k for k in a if a[k] != b[k]} == {"description"} and b["description"] == a["description"] + tools.UNIT_RULE_V2
    print(f"PASS  tools: only create_order differs, only in 'description', which is the v1 text + UNIT_RULE_V2:\n      ...{b['description'][-200:]}")
    diff = [l for l in difflib.unified_diff(v1["system"].splitlines(), v2["system"].splitlines(), lineterm="", n=0)
            if not l.startswith(("---", "+++", "@@"))]
    assert diff and all(l.startswith("+") for l in diff), diff
    assert v1["system"].replace(MARKER, MARKER + agent.DUPLICATE_RULE_V2 + "\n") == v2["system"]
    print("PASS  system prompt: v2 = v1 with exactly one bullet inserted right after the 'Before create_order, show the customer…' bullet; nothing removed. Added lines:")
    for l in diff:
        print("      " + l)

    # 3. L5 text and headers per version
    want = {"v1": "By UPI, the full remaining balance on the order you just created.",
            "v2": "By UPI, the full remaining balance on her open order for tomorrow's pickup."}
    for ver, data in (("v1", v1), ("v2", v2)):
        assert data["l5_turns"][1] == want[ver], data["l5_turns"]
        t = data["l5_transcript"].splitlines()
        assert f"# Prompt/tool-description version: {ver}" in t and f"# L5 scripted turn wording: {ver}" in t
        assert f"USER: {want[ver]}" in t and f"agent_live_gemini_offline-check_{ver}_L5_balance.txt" in data["files"]
        print(f"PASS  {ver}: L5 scripted turn is \"{want[ver]}\"; header lines '# Prompt/tool-description version: {ver}' and "
              f"'# L5 scripted turn wording: {ver}' present; file names carry '_{ver}_': {data['files']}")
    assert v1["l5_turns"][0] == v2["l5_turns"][0]
    print("PASS  the first L5 message is identical in v1 and v2")

    # 4. the no-overwrite guard
    from agent import live_scenarios
    seen = []

    def fake(messages, log):
        """Record that a model call happened; reply with fixed text."""
        seen.append(1)
        return ({"role": "assistant", "content": "ok"}, ["ok"], [], "end_turn", (1, 1, 0))
    os.environ["MYSQL_HOST"], os.environ["MYSQL_PORT"] = "localhost", "3306"
    folder = Path(tempfile.mkdtemp(prefix="guard_"))
    agent.call_llm, live_scenarios.RESULTS = fake, folder

    def run(argv):
        """Run the runner with arguments; return True if it exited (refused or stopped)."""
        sys.argv = ["live_scenarios", *argv]
        try:
            live_scenarios.main()
        except SystemExit as e:
            run.message = str(e)
            return True
        return False
    assert not run(["L1"]) and seen
    target = folder / f"agent_live_gemini_offline-check_{agent.PROMPT_VERSION}_L1_normal_order.txt"
    before, calls = sha(target.read_text(encoding="utf-8")), len(seen)
    assert run(["L1"]) and len(seen) == calls and sha(target.read_text(encoding="utf-8")) == before
    print(f"PASS  guard: with {target.name} already present the runner refused to start, made 0 model calls, and left the file unchanged.")
    print("      refusal message: " + run.message.replace("\n", " | "))
    assert run([]) and len(seen) == calls
    print("PASS  guard: a full L1-L5 run also refuses while the L1 file exists (the whole run is checked before any call)")
    (folder / target.name).unlink()
    (folder / f"agent_live_gemini_offline-check_{agent.PROMPT_VERSION}_L3_wrong_business.txt").write_text("keep me", encoding="utf-8")
    assert run(["--from", "L2"]) and len(seen) == calls
    print("PASS  guard: '--from L2' refuses when only the L3 file exists")
    names = [f"agent_live_gemini_gemini-3.1-flash-lite_{v}_{n}.txt" for v in ("v1", "v2")
             for n in ("L1_normal_order", "L2_price_pressure", "L3_wrong_business", "L4_idempotency", "L5_balance")]
    # The real v1/v2 runs are committed now, so these ten files are expected to exist (this check once asserted the opposite).
    missing = [n for n in names if not (RESULTS / n).exists()]  # any of the ten that is absent
    assert not missing, missing  # fail, naming the absent files
    print("PASS  the 10 final-name flash-lite files (v1/v2 x L1-L5) exist in results/")  # the old '*_v1_run4' claim is dropped: this code never checked it

    # 5. the version is required
    for extra, label in (({}, "unset"), ({"AGENT_PROMPT_VERSION": "v3"}, "v3")):
        code, msg = exit_text(extra)
        assert code != 0 and "AGENT_PROMPT_VERSION must be v1 or v2" in msg, (label, code, msg)
        print(f"PASS  AGENT_PROMPT_VERSION {label}: exits with: {msg}")
    print("RESULT: v1 is byte-identical to the pre-versioning prompt and tools; v2 differs only by the two rules; headers, file names, L5 text and the no-overwrite guard behave as specified.")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--child":
        child(sys.argv[2])
    else:
        main()
