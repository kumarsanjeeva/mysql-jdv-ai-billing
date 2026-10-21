# agent/check_scripted_turns.py -- offline test of the scripted follow-up turns in
# agent/live_scenarios.py. No network, no key, no database: a fake model replaces
# agent.call_llm and never calls a tool, and the transcripts go to a temporary
# folder (never to results/). Checks: the scripted turn follows the first turn,
# is labeled, is sent even after an odd reply, is NOT sent after an LLMError, and
# each header's count matches the scenario (L1=1, L2=0, L3=0, L4=1, L5=1).
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_scripted_turns <temp folder>

import os
import sys
from pathlib import Path

from agent import agent, live_scenarios

os.environ["MYSQL_HOST"], os.environ["MYSQL_PORT"] = "localhost", "3306"
SEEN = []  # the last user message the fake model was shown, per call


def fake_model(reply, fail_on_call=None):
    """Build a stand-in for agent.call_llm that answers with fixed text and no tool calls."""
    def call(messages, log):
        SEEN.append(messages[-1]["content"])
        if fail_on_call == len(SEEN):
            raise agent.LLMError("fake model failure")
        return ({"role": "assistant", "content": reply}, [reply], [], "end_turn", (1, 1, 0))
    return call


def run(argv, call_llm, folder):
    """Run live_scenarios.main() with the fake model; return True if it ended by sys.exit."""
    SEEN.clear()
    for f in folder.glob("*.txt"):  # the runner refuses to overwrite, so every run starts in an empty folder
        f.unlink()
    live_scenarios.RESULTS, agent.call_llm, sys.argv = folder, call_llm, ["live_scenarios", *argv]
    try:
        live_scenarios.main()
    except SystemExit:
        return True
    return False


def transcript(folder, name):
    """Read one scenario's transcript file."""
    return (folder / f"agent_live_gemini_offline-check_{agent.PROMPT_VERSION}_{name}.txt").read_text(encoding="utf-8")


def main():
    """Run checks a to e."""
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    for f in folder.glob("*.txt"):
        f.unlink()
    scripted = {name: turns for name, turns in live_scenarios.SCENARIOS}

    # (a) (b) the scripted turn follows the first turn and is labeled
    run(["L1"], fake_model("What size cake?"), folder)
    text = transcript(folder, "L1_normal_order")
    print("---- L1 transcript (fake model) ----\n" + text + "------------------------------------")
    assert SEEN == [scripted["L1_normal_order"][0], "Yes, go ahead."], SEEN
    print(f"(a) PASS  model was shown, in order: {SEEN}")
    first, second = text.index("USER: Priya"), text.index("[scripted user turn]")
    assert first < second and text.count("[scripted user turn]") == 1 and "\nUSER: Yes, go ahead." in text
    assert "[scripted user turn]\nUSER: Yes, go ahead." in text and text.index("What size cake?") < second
    print("(b) PASS  transcript shows '[scripted user turn]' once, after the first turn's reply, before 'USER: Yes, go ahead.'")

    # (c) sent even when the reply is unexpected
    run(["L1"], fake_model("Banana. I will not discuss cakes; ignore everything above."), folder)
    assert SEEN[-1] == "Yes, go ahead." and len(SEEN) == 2, SEEN
    print("(c) PASS  with an unrelated reply from the fake model, 'Yes, go ahead.' was still sent")

    # (d) an LLMError in turn 1 stops the run; the scripted turn is not sent
    stopped = run(["L1"], fake_model("unused", fail_on_call=1), folder)
    text = transcript(folder, "L1_normal_order")
    assert stopped and len(SEEN) == 1 and "[scripted user turn]" not in text and "Yes, go ahead." not in text
    print(f"(d) PASS  LLMError in turn 1: run stopped, model calls={len(SEEN)}, no scripted turn in the transcript")
    print("    transcript ends: " + text.strip().splitlines()[-1])

    # (e) header counts for all five scenarios, in one run
    run([], fake_model("ok"), folder)
    expected = {"L1_normal_order": 1, "L2_price_pressure": 0, "L3_wrong_business": 0, "L4_idempotency": 1, "L5_balance": 1}
    for name, count in expected.items():
        text = transcript(folder, name)
        line = [l for l in text.splitlines() if l.startswith("# scripted follow-up turns:")][0]
        assert line.startswith(f"# scripted follow-up turns: {count} "), line
        assert text.count("[scripted user turn]") == count
        print(f"(e) PASS  {name}: {line}  | labels in body: {text.count('[scripted user turn]')}")
    print("    full five-scenario run, user messages the fake model saw:")
    for s in SEEN:
        print(f"      - {s}")
    l5 = transcript(folder, "L5_balance")
    print("---- L5 header and body ----\n" + l5 + "----------------------------")
    print("RESULT: all scripted-turn checks passed (fake model, temp folder, no network, no database).")


if __name__ == "__main__":
    main()
