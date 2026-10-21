# agent/check_pacing_label.py -- offline test, no network, no key, no database:
#   1. the new Pacing label is in a scenario header and in the interactive header
#      for gemini-3.1-flash-lite (each model runs in a child process, see check_flash_lite_header);
#   2. Anthropic's Pacing line is still "none";
#   3. the 13-second gap behaviour is unchanged (the fake-clock pacing test is run again).
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=gemini-3.1-flash-lite python -m agent.check_pacing_label

import os
import subprocess
import sys

from agent import agent
from agent.check_flash_lite_header import run_child

LABEL = ("# Pacing: min 13s between model calls (conservative; chosen for the strictest free-tier limit seen, "
         "5 requests/min)")


def main():
    """Run the label checks, then the unchanged pacing-behaviour test."""
    scenario, interactive = run_child("gemini-3.1-flash-lite")
    for name, text in (("scenario header", scenario), ("interactive header", interactive)):
        assert LABEL in text.splitlines(), name
        print(f"PASS  gemini-3.1-flash-lite {name}: {LABEL}")
        assert "free tier: 5 requests/min)" not in text, name
    assert agent.PACE_SECONDS == 13
    print("PASS  PACE_SECONDS is still 13")
    env = {**os.environ, "AGENT_PROVIDER": "anthropic", "AGENT_MODEL": "offline-check"}
    r = subprocess.run([sys.executable, "-c", "from agent import agent; print(agent.PACING_NOTE)"],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout.strip() == "none", (r.stdout, r.stderr)
    print("PASS  Anthropic's Pacing line is still: none")
    print("---- 13s gap behaviour (agent.check_gemini_pacing, fake clock), run again ----")
    r = subprocess.run([sys.executable, "-m", "agent.check_gemini_pacing"], env={**os.environ, "AGENT_PROVIDER": "gemini",
                       "AGENT_MODEL": "gemini-3.1-flash-lite"}, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    print("\n".join(l for l in r.stdout.splitlines() if l.startswith(("(d)", "(e)", "    ", "                       "))))
    print("PASS  six calls still start 13s apart, the first call has no wait")
    print("RESULT: new pacing label in place; pacing behaviour unchanged (fake clock, no network).")


if __name__ == "__main__":
    main()
