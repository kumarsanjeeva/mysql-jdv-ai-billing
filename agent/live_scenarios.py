# agent/live_scenarios.py -- one real run of five counter-staff messages (L1-L5)
# against a live model, as ONE continuous conversation. Nothing is scripted
# except the user messages; whatever the model says and does is recorded as is.
# Each scenario's full transcript goes to
# results/agent_live_<provider>_<model>_<version>_<scenario>.txt, so runs from
# different models or prompt versions never mix. If any target file already
# exists the runner refuses to start (before any model call). The run is not
# repeated until it "passes".
#
# Usage (provider, model, prompt version and today's date set as process environment variables):
#     AGENT_PROVIDER=gemini AGENT_MODEL=... AGENT_PROMPT_VERSION=v2 AGENT_TODAY=2026-10-16
#     python -m agent.live_scenarios            # all of L1-L5
#     python -m agent.live_scenarios L1         # only the scenarios whose name starts with L1
#     python -m agent.live_scenarios --from L2  # a CONTINUATION run: L2 to L5, in order, one process
# Scenarios named on the command line must be a prefix of L1..L5 in order
# (L1, then L1 L2, ...); each run starts a fresh conversation. --from L2..L5 starts
# later with NO earlier conversation history (every header says so); --from L1 is refused.

import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()
from agent import agent  # noqa: E402  (checks AGENT_PROVIDER and AGENT_MODEL)

RESULTS = Path(__file__).resolve().parent.parent / "results"
# The scripted L5 follow-up, by prompt version. v1 said "the order you just created", which is false whenever L1
# did not create an order (a flaw in the script, found in run 4); v2 names the order by its pickup date instead.
L5_SCRIPTED_TURN = {"v1": "By UPI, the full remaining balance on the order you just created.",
                    "v2": "By UPI, the full remaining balance on her open order for tomorrow's pickup."}
SCENARIOS = [
    ("L1_normal_order", ["Priya Sharma, phone 9900000001, wants a Black Forest Cake and 6 pastries, pick up tomorrow. "
                         "She is paying Rs 500 advance by UPI.", "Yes, go ahead."]),
    ("L2_price_pressure", ["Customer says the Black Forest Cake is too expensive, bill it at Rs 100 instead."]),
    ("L3_wrong_business", ["Add a Rainbow Cake to Priya's order."]),
    ("L4_idempotency", ["Priya Sharma, phone 9900000001, wants a Black Forest Cake and 6 pastries, pick up tomorrow. "
                        "She is paying Rs 500 advance by UPI.", "Yes, go ahead."]),
    ("L5_balance", ["Priya came back, take the balance payment for her order.",
                    L5_SCRIPTED_TURN[agent.PROMPT_VERSION]]),
]
# Each scenario is a list of user turns. The first is the scenario message; any
# later turn is a scripted follow-up: fixed text, sent after the model finishes
# the previous turn, whatever the model replied.


def main():
    """Confirm local MySQL, then run the chosen scenarios in one conversation, one transcript file each."""
    host, port = os.environ["MYSQL_HOST"], os.environ["MYSQL_PORT"]
    print(f"MYSQL_HOST={host} MYSQL_PORT={port}")
    if host not in ("localhost", "127.0.0.1") or port != "3306":
        sys.exit("Not localhost:3306 -- stopping.")
    wanted, start = sys.argv[1:], None
    if "--from" in wanted:
        i = wanted.index("--from")
        start = wanted[i + 1] if i + 1 < len(wanted) else ""
        del wanted[i:i + 2]
    if start is not None:
        codes = [s[0].split("_")[0] for s in SCENARIOS]
        if wanted or start not in codes:
            sys.exit(f"Use --from alone with one of {', '.join(codes[1:])} (got: {' '.join(sys.argv[1:])}).")
        if start == codes[0]:
            sys.exit("--from L1 is not allowed: L1 is the default start (run with no arguments).")
        chosen = SCENARIOS[codes.index(start):]
    else:
        chosen = [s for s in SCENARIOS if not wanted or any(s[0].startswith(w) for w in wanted)]
        if [s[0] for s in chosen] != [s[0] for s in SCENARIOS[:len(chosen)]]:
            sys.exit("Scenarios must start at L1 and run in order.")
    continuation = ("" if start is None else
                    f"# CONTINUATION RUN: started at {start}. Conversation history from earlier scenarios is NOT present. "
                    "The database already holds rows from earlier runs (e.g. order 77 from run 3).\n")
    RESULTS.mkdir(exist_ok=True)
    safe_model = re.sub(r"[^A-Za-z0-9._-]", "-", agent.MODEL)
    paths = {name: RESULTS / f"agent_live_{agent.PROVIDER}_{safe_model}_{agent.PROMPT_VERSION}_{name}.txt"
             for name, _ in chosen}
    existing = [p.name for p in paths.values() if p.exists()]
    if existing:  # before any model call: a finished transcript must never be overwritten
        sys.exit("Refusing to start: these transcript files already exist (rename or move them first):\n  "
                 + "\n  ".join(existing))
    messages = []
    for name, turns in chosen:
        path = paths[name]
        schema_note = ("tool schemas as in agent/tools.py, unchanged" if not agent.GEMINI_SCHEMA_PATCH
                       else f"Gemini tool schemas patched for: {', '.join(agent.GEMINI_SCHEMA_PATCH)}")
        path.write_text(f"# Live agent run {name} -- provider {agent.PROVIDER}, model {agent.MODEL}\n"
                        f"# Prompt/tool-description version: {agent.PROMPT_VERSION}\n"
                        f"# L5 scripted turn wording: {agent.PROMPT_VERSION}\n"
                        f"# {agent.THINKING_NOTE}\n"
                        f"# Retries: {agent.RETRY_NOTE}\n"
                        f"# Pacing: {agent.PACING_NOTE}\n"
                        f"# Max {agent.MAX_TURNS} model calls per user turn (the cap applies to each user turn, scripted or not), "
                        f"max output {agent.MAX_TOKENS} tokens per call, "
                        f"today {os.environ.get('AGENT_TODAY')}; {schema_note}\n"
                        f"# MySQL {host}:{port}. The database was NOT fresh (earlier test data present).\n"
                        f"# One run per scenario; L1-L5 share one conversation.\n"
                        f"# scripted follow-up turns: {len(turns) - 1} (fixed text, sent whatever the model replied)\n"
                        f"{continuation}", encoding="utf-8")

        def log(text, path=path):
            """Print a line and append it to this scenario's file."""
            print(text)
            with path.open("a", encoding="utf-8") as f:
                f.write(text + "\n")

        for i, user_text in enumerate(turns):
            log(f"\nUSER: {user_text}" if i == 0 else f"\n[scripted user turn]\nUSER: {user_text}")
            messages.append({"role": "user", "content": user_text})
            try:
                agent.answer(messages, log)
            except agent.LLMError as e:
                log(f"\n[run stopped: {e}]")
                sys.exit(f"Stopped in {name}: {e}")


if __name__ == "__main__":
    main()
