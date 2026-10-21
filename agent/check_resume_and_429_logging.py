# agent/check_resume_and_429_logging.py -- offline tests, no network, no key, no database:
#   (a)(b) `--from L2` runs L2..L5 in order with their scripted turns, never sends the L1
#          text, and writes the CONTINUATION line into every header it produces; plain runs
#          and refused options (--from L1, unknown codes) behave as specified.
#   (c)(d) a long fake 429 error text is logged in full (redacted, capped at 4000 chars) with
#          the quota names found and the pattern that made it "daily"; a fake key in the
#          error text never appears.
# Transcripts of the resume test go to a temporary folder, never to results/.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_resume_and_429_logging <temp folder>

import os
import sys
from pathlib import Path

from agent import agent, live_scenarios
from agent.check_gemini_pacing import call, setup
from agent.check_gemini_retry import api_error, good_reply
from agent.check_scripted_turns import SEEN, fake_model, run, transcript

FAKE_KEY = "FAKE-KEY-0123456789-NOT-REAL"
CONTINUATION = ("# CONTINUATION RUN: started at L2. Conversation history from earlier scenarios is NOT present. "
                "The database already holds rows from earlier runs (e.g. order 77 from run 3).")


def main():
    """Run checks a to d."""
    folder = Path(sys.argv[1])
    folder.mkdir(parents=True, exist_ok=True)
    for f in folder.glob("*.txt"):
        f.unlink()
    texts = {name: turns for name, turns in live_scenarios.SCENARIOS}

    # (a) --from L2 sends L2, L3, L4 (+scripted), L5 (+scripted), in order, never the L1 text
    run(["--from", "L2"], fake_model("ok"), folder)
    want = [texts["L2_price_pressure"][0], texts["L3_wrong_business"][0], *texts["L4_idempotency"], *texts["L5_balance"]]
    print("(a) user messages the fake model saw, in order:")
    for s in SEEN:
        print(f"      - {s}")
    assert SEEN == want, SEEN
    l1 = texts["L1_normal_order"][0]
    assert SEEN[0] != l1 and SEEN.count(l1) == 1 and SEEN.index(l1) == SEEN.index(texts["L4_idempotency"][0])
    print("(a) PASS  exactly L2, L3, L4 + 'Yes, go ahead.', L5 + the scripted L5 turn; L1 was not run. "
          "(The L1 wording appears once, only as the L4 message: L4 repeats L1 by design.)")

    # (b) continuation line in every transcript produced, and only there
    for name in ("L2_price_pressure", "L3_wrong_business", "L4_idempotency", "L5_balance"):
        text = transcript(folder, name)
        assert CONTINUATION in text.splitlines(), name
        print(f"(b) PASS  {name}: header has the CONTINUATION line")
    assert not (folder / f"agent_live_gemini_offline-check_{agent.PROMPT_VERSION}_L1_normal_order.txt").exists()
    print("    " + CONTINUATION)
    print("(b) PASS  no L1 transcript was produced")
    for f in folder.glob("*.txt"):
        f.unlink()
    run([], fake_model("ok"), folder)
    assert all("CONTINUATION" not in transcript(folder, n) for n, _ in live_scenarios.SCENARIOS)
    print("(b) PASS  a normal run (no options) has no CONTINUATION line in any header")
    for argv, why in ((["--from", "L1"], "--from L1 refused"), (["--from", "L9"], "unknown code refused"),
                      (["--from"], "missing value refused"), (["--from", "L2", "L3"], "--from plus names refused")):
        assert run(argv, fake_model("ok"), folder) and not SEEN, argv
        print(f"(b) PASS  {why} ({' '.join(argv)}): exited before any model call")

    # (c) a long fake 429: the full text is logged, the daily pattern and quota names are logged
    long_text = ("You exceeded your current quota, please check your plan and billing details. " + "x" * 120 +
                 f" key={FAKE_KEY} " + "padding-" * 40 +
                 "* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, "
                 "model: gemini-3.6-flash quotaId: GenerateRequestsPerDayPerProjectPerModel-FreeTier "
                 f"END-MARKER-PAST-300-CHARS {FAKE_KEY}")
    assert len(long_text) > 300 and long_text.index("END-MARKER") > 300
    os.environ["GEMINI_API_KEY"] = FAKE_KEY
    client, sleeps, lines, now = setup([api_error(429, long_text, "RESOURCE_EXHAUSTED"), good_reply()])
    result = call(lines)
    print("(c) log lines for a daily-quota 429:")
    for l in lines:
        print(f"      {l[:230]}{' ...' if len(l) > 230 else ''}")
    joined = "\n".join(lines)
    assert "END-MARKER-PAST-300-CHARS" in joined and "[redacted]" in joined
    assert "classified as DAILY quota: matched 'PerDay'" in joined
    assert "generate_content_free_tier_requests" in joined and "GenerateRequestsPerDayPerProjectPerModel-FreeTier" in joined
    assert client.models.calls == 1 and sleeps == [] and result.startswith("LLMError: Gemini daily quota exhausted")
    print("(c) PASS  full text (past 300 chars) logged; matched pattern 'PerDay' logged; both quota names listed; 1 call, no wait")

    # (d) the fake key never appears, in the log or in the LLMError text
    assert FAKE_KEY not in joined and FAKE_KEY not in result
    print("(d) PASS  the fake key is not in the transcript lines or in the LLMError text; '[redacted]' is")

    # per-minute classification is logged too, and the cap is 4000 characters
    client, sleeps, lines, now = setup([api_error(429, "Quota exceeded for requests per minute " + "y" * 5000, "RESOURCE_EXHAUSTED"), good_reply()])
    call(lines)
    assert any("classified as per-minute" in l for l in lines) and any("(4000 of " in l for l in lines)
    first = [l for l in lines if l.startswith("[429 full text")][0]
    print(f"(c) PASS  per-minute 429: classification logged; a 5000+ char text is capped: {first[:60]}...")
    print("RESULT: resume option, continuation header, full 429 logging and redaction all behave as specified (fake model/clock, no network).")


if __name__ == "__main__":
    main()
