# agent/check_gemini_pacing.py -- offline test of the Gemini 429 wait and the 13-second
# pacing, with a fake clock and a fake sleep (a sleep just moves the fake clock), so
# nothing waits and no network is used. It reuses the fake client from check_gemini_retry.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_gemini_pacing

import re

from agent import agent
from agent.check_gemini_retry import FakeClient, FakeModels, api_error, good_reply

# The error text from the stopped run (no key in it).
FAILED_RUN_TEXT = ("You exceeded your current quota, please check your plan and billing details. "
                   "For more information on this error, head to: https://ai.google.dev/gemini-api/docs/rate-limits. "
                   "To monitor your current usage, head to: https://ai.dev/rate-limit. "
                   "* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, "
                   "limit: 5, model: gemini-3.6-flash Please retry in 59.398929665s.")


class TimedModels(FakeModels):
    """FakeModels that also records the fake-clock time at which each request started."""

    def generate_content(self, model, contents, config):
        """Record the start time, then behave like FakeModels."""
        self.starts.append(agent._clock())
        return super().generate_content(model, contents, config)


def setup(outcomes):
    """Install a fake client, fake clock and fake sleep; return (client, sleeps, log lines, clock list)."""
    client, sleeps, lines, now = FakeClient(outcomes), [], [], [0.0]
    client.models = TimedModels(outcomes)
    client.models.starts = []
    agent._gemini_client, agent._last_start = client, None
    agent._clock = lambda: now[0]

    def fake_sleep(seconds):
        """Record a wait and move the fake clock forward by it."""
        sleeps.append(seconds)
        now[0] += seconds
    agent._sleep = fake_sleep
    return client, sleeps, lines, now


def call(lines):
    """Call Gemini once through the real code path; return the texts, or the LLMError text."""
    try:
        return agent.call_gemini([{"role": "user", "content": "hi"}], lines.append)[1]
    except agent.LLMError as e:
        return f"LLMError: {e}"


def main():
    """Run checks a to e."""
    old = re.search(r"retry(?:Delay)?\D{0,12}(\d+)", FAILED_RUN_TEXT, re.I)
    print(f"info) the OLD pattern, run on this exact text, returns {old.group(1)}s -- so the 21s seen in the stopped run "
          "was not a misreading of this text; this text came with the SECOND 429 (the first 429's text was not logged).")

    # (a) the wait chosen for the failed run's error text
    client, sleeps, lines, now = setup([api_error(429, FAILED_RUN_TEXT, "RESOURCE_EXHAUSTED"), good_reply()])
    result = call(lines)
    print(f"(a) text only        : waits={sleeps} log={lines} result={result}")
    assert len(sleeps) == 1 and abs(sleeps[0] - 61.398929665) < 0.001 and result == ["ok"] and client.models.calls == 2
    # same text plus the SDK's retryDelay field ('59s'): the text is read first
    from google.genai import errors
    both = errors.APIError(429, {"error": {"code": 429, "message": FAILED_RUN_TEXT, "status": "RESOURCE_EXHAUSTED",
                                           "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "59s"}]}})
    client, sleeps, lines, now = setup([both, good_reply()])
    result = call(lines)
    print(f"(a) text + field     : waits={sleeps} (text 'retry in 59.39s' preferred over field '59s')")
    assert abs(sleeps[0] - 61.398929665) < 0.001
    # field only, no 'retry in' text
    field_only = errors.APIError(429, {"error": {"code": 429, "message": "Quota exceeded for requests per minute", "status": "RESOURCE_EXHAUSTED",
                                                 "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "59s"}]}})
    client, sleeps, lines, now = setup([field_only, good_reply()])
    call(lines)
    print(f"(a) field only      : waits={sleeps} (SDK retryDelay field '59s' + 2)")
    assert sleeps == [61.0]
    # a huge delay is capped at 90s
    client, sleeps, lines, now = setup([api_error(429, "Please retry in 500s.", "RESOURCE_EXHAUSTED"), good_reply()])
    call(lines)
    print(f"(a) cap             : waits={sleeps} (server asked 500s, capped at 90)")
    assert sleeps == [90]

    # (b) a second 429 after the retry stops
    client, sleeps, lines, now = setup([api_error(429, FAILED_RUN_TEXT, "RESOURCE_EXHAUSTED")] * 2)
    result = call(lines)
    print(f"(b) 429 twice        : API calls={client.models.calls} waits={sleeps} result={result[:70]}...")
    assert client.models.calls == 2 and len(sleeps) == 1 and result.startswith("LLMError: Gemini request failed (HTTP 429)")

    # (c) a daily-quota 429: one call, no wait
    client, sleeps, lines, now = setup([api_error(429, "GenerateRequestsPerDayPerProjectPerModel-FreeTier exceeded", "RESOURCE_EXHAUSTED"), good_reply()])
    result = call(lines)
    print(f"(c) daily quota      : API calls={client.models.calls} waits={sleeps} result={result[:60]}...")
    assert client.models.calls == 1 and sleeps == [] and result.startswith("LLMError: Gemini daily quota exhausted")

    # (d) and (e) six back-to-back calls
    client, sleeps, lines, now = setup([good_reply() for _ in range(6)])
    for _ in range(6):
        call(lines)
    starts = list(client.models.starts)
    gaps = [round(b - a, 3) for a, b in zip(starts, starts[1:])]
    print(f"(d) six calls        : start times (fake seconds)={starts}")
    print(f"                       gaps={gaps}  total={starts[-1] - starts[0]}s  waits={sleeps}")
    print(f"                       pacing lines logged: {len(lines)}; first: {lines[0]}")
    assert starts[-1] - starts[0] >= 65 and all(g >= 13 for g in gaps)
    print(f"(e) first call       : started at fake t={starts[0]} with no wait before it (waits recorded before call 1: 0)")
    assert starts[0] == 0.0 and len(sleeps) == 5

    # pacing also holds across scenarios: the clock state is process-wide, not per call
    now[0] += 5
    client.models.outcomes = [good_reply()]
    call(lines)
    print(f"    next call 5s later (a new scenario, same process): waited {sleeps[-1]:.1f}s -> start gap {client.models.starts[-1] - starts[-1]}s")
    assert client.models.starts[-1] - starts[-1] >= 13

    print("RESULT: 429 wait = server delay + 2s (max 90s), one retry; daily quota stops at once; pacing >= 13s between starts (fake clock, no network).")


if __name__ == "__main__":
    main()
