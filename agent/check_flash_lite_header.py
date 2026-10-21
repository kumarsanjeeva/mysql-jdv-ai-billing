# agent/check_flash_lite_header.py -- offline test of the "Thinking" header line, no
# network, no key, no database. The thinking note is fixed when agent.py is imported,
# so each model is tested in its own child process (this same file with --child),
# with a fake model that reports 10 tokens in, 5 out, 7 thinking and never calls a tool.
#
# Usage:  python -m agent.check_flash_lite_header

import io
import os
import subprocess
import sys
import tempfile
from pathlib import Path

NOT_DOCUMENTED = "# thinking: default level not documented for this model; observed thought tokens are logged per call"
TABLE_LINE = ("# Thinking: thinking not configured; API default for gemini-3.6-flash per Google docs: On (medium); "
              "thought tokens count against the output cap")
TOKEN_LINE = "[tokens this call: 10 in, 5 out, 7 thinking]"


def child(folder):
    """Inside a child process: write one scenario transcript and one interactive transcript, print both."""
    os.environ["MYSQL_HOST"], os.environ["MYSQL_PORT"] = "localhost", "3306"
    from agent import agent, live_scenarios

    def fake(messages, log):
        """Reply with fixed text and fixed token counts; no tool calls."""
        return ({"role": "assistant", "content": "ok"}, ["ok"], [], "end_turn", (10, 5, 7))
    agent.call_llm = fake
    live_scenarios.RESULTS, sys.argv = Path(folder), ["live_scenarios", "L1"]
    live_scenarios.main()
    print("=====SCENARIO=====")
    print((Path(folder) / f"agent_live_gemini_{agent.MODEL}_{agent.PROMPT_VERSION}_L1_normal_order.txt").read_text(encoding="utf-8"))
    agent.TRANSCRIPT, sys.stdin = Path(folder) / "interactive.txt", io.StringIO("hello\n")
    agent.main()
    print("=====INTERACTIVE=====")
    print(agent.TRANSCRIPT.read_text(encoding="utf-8"))


def run_child(model):
    """Start a child process for one model; return (scenario transcript text, interactive transcript text)."""
    folder = tempfile.mkdtemp(prefix="hdr_")
    env = {**os.environ, "AGENT_PROVIDER": "gemini", "AGENT_MODEL": model}
    r = subprocess.run([sys.executable, "-m", "agent.check_flash_lite_header", "--child", folder],
                       env=env, capture_output=True, text=True, encoding="utf-8")
    assert r.returncode == 0, r.stderr
    scenario = r.stdout.split("=====SCENARIO=====")[1].split("=====INTERACTIVE=====")[0]
    return scenario, r.stdout.split("=====INTERACTIVE=====")[1]


def main():
    """Run checks a to c."""
    for model in ("gemini-3.1-flash-lite", "gemini-3.6-flash"):
        scenario, interactive = run_child(model)
        print(f"----- {model}: scenario transcript header and first lines -----")
        print("\n".join(scenario.strip().splitlines()[:11]))
        print(f"----- {model}: interactive transcript header -----")
        print("\n".join(interactive.strip().splitlines()[:6]))
        if model == "gemini-3.1-flash-lite":
            for name, text in (("scenario", scenario), ("interactive", interactive)):
                assert NOT_DOCUMENTED in text.splitlines(), name
                thinking_lines = [l for l in text.splitlines() if l.lower().startswith("# thinking")]
                assert thinking_lines == [NOT_DOCUMENTED], thinking_lines
                assert "On (" not in text and "not verified" not in text and "medium" not in text.lower(), name
            print("(a) PASS  flash-lite: both headers carry the exact 'not documented' line; no level is claimed "
                  "(no 'On (', no 'medium', no 'not verified')")
        else:
            for name, text in (("scenario", scenario), ("interactive", interactive)):
                assert TABLE_LINE in text.splitlines(), name
                assert "not documented" not in text
            print("(b) PASS  3.6-flash: both headers still say 'On (medium)' in the earlier wording")
        for name, text in (("scenario", scenario), ("interactive", interactive)):
            assert TOKEN_LINE in text.splitlines(), (model, name)
        print(f"(c) PASS  {model}: the per-call token line still prints 'in / out / thinking': {TOKEN_LINE}")
    print("RESULT: header wording is correct for a documented and an undocumented model (fake model, no network).")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--child":
        child(sys.argv[2])
    else:
        main()
