# agent/check_gemini_retry.py -- offline test of the Gemini retry rules, no network
# and no key. A fake client raises or returns what each case needs, and a fake
# sleep records the waits instead of waiting. Each case prints what happened.
#
# Rules under test: HTTP 503 -> one retry after 30s, then stop; per-minute 429 ->
# one retry; daily-quota 429 -> no retry; any other error -> no retry.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_gemini_retry

from google.genai import errors, types

from agent import agent


class FakeModels:
    """Stands in for client.models: plays back a list of outcomes, one per call."""

    def __init__(self, outcomes):
        self.outcomes = list(outcomes)
        self.calls = 0

    def generate_content(self, model, contents, config):
        """Return or raise the next outcome."""
        self.calls += 1
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class FakeClient:
    """Stands in for genai.Client."""

    def __init__(self, outcomes):
        self.models = FakeModels(outcomes)


def api_error(code, message, status):
    """Build the SDK's own error object for an HTTP code."""
    return errors.APIError(code, {"error": {"code": code, "message": message, "status": status}})


def good_reply():
    """Build a real SDK response holding the text 'ok'."""
    return types.GenerateContentResponse(
        candidates=[types.Candidate(content=types.Content(role="model", parts=[types.Part(text="ok")]),
                                    finish_reason=types.FinishReason.STOP)],
        usage_metadata=types.GenerateContentResponseUsageMetadata(
            prompt_token_count=1, candidates_token_count=1, thoughts_token_count=0))


def run_case(label, outcomes):
    """Run call_gemini against the fake client; return (calls, sleeps, log lines, result or error text)."""
    client, sleeps, lines, now = FakeClient(outcomes), [], [], [0.0]
    agent._gemini_client = client
    agent._last_start = None  # fresh case: the first call is not paced
    agent._clock = lambda: now[0]  # fake clock: only the fake sleep moves it

    def fake_sleep(seconds):
        """Record a wait and move the fake clock forward by it."""
        sleeps.append(seconds)
        now[0] += seconds
    agent._sleep = fake_sleep
    try:
        result = agent.call_gemini([{"role": "user", "content": "hi"}], lines.append)[1]
    except agent.LLMError as e:
        result = f"LLMError: {e}"
    print(f"{label}\n    API calls={client.models.calls}  waits={sleeps}  log={lines}\n    result={result}")
    return client.models.calls, sleeps, lines, result


def main():
    """Run the cases and assert the rules."""
    m503 = "This model is currently experiencing high demand."
    calls, sleeps, lines, result = run_case("(a) 503 then success", [api_error(503, m503, "UNAVAILABLE"), good_reply()])
    assert calls == 2 and sleeps == [30] and lines == ["[503 UNAVAILABLE, waiting 30s, retrying once]"] and result == ["ok"]

    calls, sleeps, lines, result = run_case("(b) 503 twice", [api_error(503, m503, "UNAVAILABLE")] * 2)
    assert calls == 2 and sleeps == [30] and result.startswith("LLMError: Gemini request failed (HTTP 503)") and m503 in result
    assert lines == ["[503 UNAVAILABLE, waiting 30s, retrying once]"]

    for code, status in ((400, "INVALID_ARGUMENT"), (401, "UNAUTHENTICATED"), (403, "PERMISSION_DENIED"),
                         (404, "NOT_FOUND"), (500, "INTERNAL"), (504, "DEADLINE_EXCEEDED")):
        calls, sleeps, lines, result = run_case(f"(c) HTTP {code} stops", [api_error(code, "boom", status), good_reply()])
        assert calls == 1 and sleeps == [] and lines == [] and result.startswith(f"LLMError: Gemini request failed (HTTP {code})")
    calls, sleeps, lines, result = run_case("(c) non-HTTP failure stops", [RuntimeError("network down"), good_reply()])
    assert calls == 1 and sleeps == [] and result.startswith("LLMError: Gemini request failed (RuntimeError)")

    calls, sleeps, lines, result = run_case("(d) per-minute 429 retries once",
                                            [api_error(429, "Quota exceeded for requests per minute", "RESOURCE_EXHAUSTED"), good_reply()])
    assert calls == 2 and sleeps == [20] and result == ["ok"]
    calls, sleeps, lines, result = run_case("(d) per-minute 429 twice stops",
                                            [api_error(429, "Quota exceeded for requests per minute", "RESOURCE_EXHAUSTED")] * 2)
    assert calls == 2 and sleeps == [20] and result.startswith("LLMError: Gemini request failed (HTTP 429)")
    calls, sleeps, lines, result = run_case("(d) daily-quota 429 does not retry",
                                            [api_error(429, "GenerateRequestsPerDayPerProjectPerModel-FreeTier exceeded", "RESOURCE_EXHAUSTED"), good_reply()])
    assert calls == 1 and sleeps == [] and result.startswith("LLMError: Gemini daily quota exhausted")

    print("RESULT: all retry rules behave as specified (fake client and fake sleep; no network, no real wait).")


if __name__ == "__main__":
    main()
