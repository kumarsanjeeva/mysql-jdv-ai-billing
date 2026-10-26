# agent/agent.py -- the chat loop between a person at the bakery counter and
# an LLM. The LLM answers in plain language and, when it needs data, calls
# the tools in agent/tools.py; this file only passes messages and tool
# results back and forth. It holds no business rules -- those are in MySQL.
#
# Everything specific to one LLM vendor sits in its own marked "LLM PROVIDER"
# section below (Anthropic, Gemini). AGENT_PROVIDER picks one; the loop and
# the tools do not change. To add a vendor, add a section and a table entry.
#
# The whole conversation (messages, every tool call with its input, every
# tool result, token usage) is printed and also saved to
# results/agent_transcript.txt.
#
# Usage:
#     python -m agent.agent
# Type a message and press Enter; an empty line, "quit" or "exit" ends the chat (Ctrl+C also stops it).
# Needs AGENT_PROVIDER ("anthropic" or "gemini"), AGENT_MODEL, AGENT_PROMPT_VERSION ("v1" or "v2") and that
# provider's key (ANTHROPIC_API_KEY or GEMINI_API_KEY) in .env or the environment.

import json
import os
import re
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

from agent import tools

load_dotenv()
TRANSCRIPT = Path(__file__).resolve().parent.parent / "results" / "agent_transcript.txt"
MAX_TURNS = 12     # model calls allowed per user message
MAX_TOKENS = 2048  # output cap per model call; a create_order call carries a whole order document
KEY_NAMES = ("ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY")

# Which wording of the system prompt and tool descriptions to use: v1 is the original; v2 adds two rules
# (see UNIT_RULE_V2 in agent/tools.py and DUPLICATE_RULE_V2 below). Required: no default.
PROMPT_VERSION = os.environ.get("AGENT_PROMPT_VERSION", "")
if PROMPT_VERSION not in ("v1", "v2"):
    sys.exit(f"AGENT_PROMPT_VERSION must be v1 or v2 (got: {PROMPT_VERSION or 'not set'}); there is no default.")
DUPLICATE_RULE_V2 = """- Before create_order, check the customer's open orders (from get_customer, then get_order on any with the same
  pickup date) for the same pickup date and the same items. If one matches, tell the staff member which order it is
  (id, status, balance due) and do not create another."""
DUPLICATE_BULLET = DUPLICATE_RULE_V2 + "\n" if PROMPT_VERSION == "v2" else ""

SYSTEM = f"""You are the billing assistant at the counter of Sunrise Bakers, MG Road outlet (outlet id 1).
You help staff take and manage customer orders. You can only act through your tools.

- Never invent a price, product, customer or order. Prices and GST rates come from search_catalog;
  customers from get_customer; orders from get_order.
- Before create_order, show the customer the items, subtotal, GST and total, and wait for them to agree.
{DUPLICATE_BULLET}- For GST-exclusive items: item gst_value = price x qty x gst_rate / 100; subtotal = sum of price x qty;
  total = subtotal - discount_value + gst_value. The database rejects a total that does not add up.
- Generate a new unique request_id for every create_order and every add_payment (for example
  "ord-" or "pay-" followed by random letters and digits). If you retry the same action, reuse its request_id.
- If a tool returns a MySQL error, tell the staff member what it means in plain words; do not work around it.
- Payments cannot be edited. A mistaken payment is corrected with a refund payment.
Business id {tools.BUSINESS_ID}. Today is {os.environ.get("AGENT_TODAY", "2026-09-26")}."""


class LLMError(Exception):
    """A model-API failure, already worded for a person and free of any key."""


def redact(text):
    """Replace the value of any API key found in the text with [redacted]."""
    for name in KEY_NAMES:
        value = os.environ.get(name)
        if value:
            text = text.replace(value, "[redacted]")
    return text


MODEL = os.environ.get("AGENT_MODEL", "")  # checked below, after the provider sections
_sleep = time.sleep  # the one place a provider waits; the offline retry test swaps it for a fake


# ===================== LLM PROVIDER (Anthropic) =====================
# Anthropic's Messages API. Our history is kept in its native shape: plain
# {"role", "content"} dicts; tool calls are "tool_use" blocks and tool results
# are "tool_result" blocks inside a user message.

THINKING_NOTE_ANTHROPIC = "Thinking: no extended thinking requested"  # the whole header line, after "# "
RETRY_NOTE_ANTHROPIC = "none (the Anthropic SDK's own defaults apply)"
_anthropic_client = None


def call_anthropic(messages, log):
    """Ask Claude for its next step (log is unused here); return (assistant_message, texts, tool_calls, stop_reason, (in, out, thoughts))."""
    global _anthropic_client
    import anthropic
    try:
        if _anthropic_client is None:
            _anthropic_client = anthropic.Anthropic()
        r = _anthropic_client.messages.create(model=MODEL, max_tokens=MAX_TOKENS, system=SYSTEM,
                                              tools=tools.schemas(PROMPT_VERSION), messages=messages)
    except anthropic.APIStatusError as e:
        raise LLMError(redact(f"Anthropic request failed (HTTP {e.status_code}): {e.message}")) from None
    except Exception as e:
        raise LLMError(redact(f"Anthropic request failed ({type(e).__name__}): {e}")) from None
    texts = [b.text for b in r.content if b.type == "text" and b.text.strip()]
    calls = [(b.id, b.name, b.input) for b in r.content if b.type == "tool_use"]
    return ({"role": "assistant", "content": r.content}, texts, calls,
            r.stop_reason, (r.usage.input_tokens, r.usage.output_tokens, 0))


def anthropic_results(results):
    """Wrap [(call_id, tool_name, text, is_error), ...] as the user message that returns tool results to Claude."""
    return {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": i, "content": t, "is_error": e} for i, _, t, e in results]}

# =================== END LLM PROVIDER (Anthropic) ===================


# ===================== LLM PROVIDER (Gemini) =====================
# Google Gemini via the google-genai SDK (AI Studio key). How our pieces map:
#   * Tool definitions: ours are {name, description, input_schema}. Gemini wants
#     one Tool holding a list of FunctionDeclaration {name, description,
#     parameters}. The schema body is the same JSON Schema, so input_schema is
#     passed through as parameters_json_schema. If Gemini rejects the bare
#     {"type": "object"} schemas for `order` and `payment`, only the copy built
#     here changes (GEMINI_SCHEMA_PATCH below), never agent/tools.py.
#   * History: the user's text is Content(role="user"); the model's reply is
#     stored exactly as Gemini returned it (role="model"), because Gemini 3
#     models need their "thought signature" sent back with a function call.
#   * Tool call out: a "function_call" part with name and args. Gemini gives no
#     call id, so we number them (g1, g2, ...) for our own logging.
#   * Tool result back: a "function_response" part {name, response} in a
#     role="user" Content. response must be a dict, so the text goes in as
#     {"result": text}, or {"error": text} for a failed call (is_error). Text
#     is never altered, so a MySQL error reaches the model verbatim.
#   * Stop reason: finish_reason STOP -> "end_turn"; MAX_TOKENS -> "max_tokens".
#   * We switch off the SDK's own automatic function calling so this loop,
#     tools.call and the transcript stay in charge.
#   * Thinking is left at the model default. A model listed in
#     GEMINI_DEFAULT_THINKING gets the level Google's docs state for it; any
#     other model gets "default level not documented" and NO level is claimed.
#     Thought tokens count against the output cap, and are logged per call.
#   * Retries, in gemini_generate(): HTTP 503 once after 30s; HTTP 429 once
#     after the server's suggested delay + 2s (20s if the server gives none;
#     at most 90s), but never for a daily-quota 429. Any other error, or a
#     second failure, stops the run.
#   * Pacing, in gemini_pace(): the free tier allows 5 requests a minute, so a
#     request never starts less than 13s after the previous one started
#     (process-wide, across tool loops and scenarios; no wait before the first).

# Default thinking level exactly as Google's thinking docs state it, only for models the docs list.
GEMINI_DEFAULT_THINKING = {"gemini-3.8-flash": "On (medium)", "gemini-3.6-flash": "On (medium)"}
# The whole header line, after "# ".
THINKING_NOTE_GEMINI = (
    f"Thinking: thinking not configured; API default for {MODEL} per Google docs: "
    f"{GEMINI_DEFAULT_THINKING[MODEL]}; thought tokens count against the output cap"
    if MODEL in GEMINI_DEFAULT_THINKING else
    "thinking: default level not documented for this model; observed thought tokens are logged per call")
RETRY_NOTE_GEMINI = "503 retry: once, 30s; 429 retry: once (per-minute limit only, wait = server delay + 2s, max 90s)"
PACE_SECONDS = 13
PACING_NOTE_GEMINI = (f"min {PACE_SECONDS}s between model calls (conservative; chosen for the strictest "
                      "free-tier limit seen, 5 requests/min)")
_clock = time.monotonic  # swapped for a fake clock by the offline tests
_last_start = None       # when the previous Gemini request started
GEMINI_SCHEMA_PATCH = {}  # tool name -> replacement input_schema for Gemini only; empty = use ours unchanged
_gemini_client = None
_gemini_call_count = 0


def gemini_result_payload(text, is_error):
    """Put a tool result's text into the dict Gemini expects, unchanged."""
    return {"error": text} if is_error else {"result": text}


def gemini_tools():
    """Build Gemini's Tool object from our tool definitions."""
    from google.genai import types
    decls = [types.FunctionDeclaration(name=s["name"], description=s["description"],
                                       parameters_json_schema=GEMINI_SCHEMA_PATCH.get(s["name"], s["input_schema"]))
             for s in tools.schemas(PROMPT_VERSION)]
    return [types.Tool(function_declarations=decls)]


def gemini_contents(messages):
    """Turn our history into Gemini Content objects (plain user text becomes a user Content)."""
    from google.genai import types
    return [m if isinstance(m, types.Content)
            else types.Content(role="user", parts=[types.Part(text=m["content"])]) for m in messages]


def gemini_pace(log):
    """Wait, if needed, so this request starts at least PACE_SECONDS after the previous one started."""
    global _last_start
    if _last_start is not None:
        wait = PACE_SECONDS - (_clock() - _last_start)
        if wait > 0:
            log(f"[pacing: waiting {wait:.1f}s (free tier: 5 requests/min)]")
            _sleep(wait)
    _last_start = _clock()


def gemini_retry_delay(e):
    """Seconds the server asks us to wait after a 429, or None. Reads the text 'retry in 59.39s' in the
    message first (more precise); otherwise the error's RetryInfo 'retryDelay' field (like '59s')."""
    def find(obj):
        if isinstance(obj, dict):
            if "retryDelay" in obj:
                return obj["retryDelay"]
            obj = list(obj.values())
        if isinstance(obj, list):
            for item in obj:
                found = find(item)
                if found is not None:
                    return found
        return None
    m = re.search(r"retry in ([0-9.]+)\s*s", str(e.message), re.I)
    if not m:
        field = find(e.details)
        m = re.fullmatch(r"\s*([0-9.]+)s\s*", str(field)) if field is not None else None
    return float(m.group(1)) if m else None


def gemini_generate(contents, config, log):
    """Send one request (paced); on a 503 or a per-minute 429 wait and send the same request once more."""
    from google.genai import errors
    try:
        gemini_pace(log)
        return _gemini_client.models.generate_content(model=MODEL, contents=contents, config=config)
    except errors.APIError as e:
        if e.code == 503:
            log("[503 UNAVAILABLE, waiting 30s, retrying once]")
            wait = 30
        elif e.code == 429:
            text = str(e)
            full = redact(text)
            log(f"[429 full text ({min(len(full), 4000)} of {len(full)} chars): {full[:4000]}]")
            names = sorted(set(re.findall(r"(?:quotaMetric|quotaId|metric)\W{1,5}([A-Za-z0-9_./-]{6,})", full)))
            log(f"[429 quota names found in the text: {', '.join(names) if names else 'none'}]")
            daily = re.search(r"per\s*day|PerDay", text, re.I)
            if daily:
                log(f"[429 classified as DAILY quota: matched {daily.group(0)!r}; stopping, no retry]")
                raise LLMError(redact("Gemini daily quota exhausted (HTTP 429); stopping, no retry. " + text[:300])) from None
            log("[429 classified as per-minute: neither 'per day' nor 'PerDay' appears in the text]")
            server = gemini_retry_delay(e)
            wait = min(server + 2, 90) if server is not None else 20
            log(f"[rate limited (HTTP 429); server asks {server}s; waiting {wait:.1f}s, then retrying once]"
                if server is not None else
                f"[rate limited (HTTP 429); waiting {wait}s, then retrying once]")
        else:
            raise
    _sleep(wait)
    gemini_pace(log)
    return _gemini_client.models.generate_content(model=MODEL, contents=contents, config=config)


def call_gemini(messages, log):
    """Ask Gemini for its next step; return (model_message, texts, tool_calls, stop_reason, (in, out, thoughts))."""
    global _gemini_client, _gemini_call_count
    from google import genai
    from google.genai import errors, types
    try:
        if _gemini_client is None:
            _gemini_client = genai.Client()
        config = types.GenerateContentConfig(
            system_instruction=SYSTEM, tools=gemini_tools(), max_output_tokens=MAX_TOKENS,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True))
        r = gemini_generate(gemini_contents(messages), config, log)
    except LLMError:
        raise
    except errors.APIError as e:
        raise LLMError(redact(f"Gemini request failed (HTTP {e.code}): {e.message}")) from None
    except Exception as e:
        raise LLMError(redact(f"Gemini request failed ({type(e).__name__}): {e}")) from None
    if not r.candidates or r.candidates[0].content is None:
        reason = r.candidates[0].finish_reason if r.candidates else r.prompt_feedback
        raise LLMError(redact(f"Gemini returned no content ({reason})"))
    message = r.candidates[0].content
    texts = [p.text for p in message.parts if p.text and not p.thought and p.text.strip()]
    calls = []
    for p in message.parts:
        if p.function_call:
            _gemini_call_count += 1
            calls.append((f"g{_gemini_call_count}", p.function_call.name, dict(p.function_call.args or {})))
    finish = getattr(r.candidates[0].finish_reason, "name", str(r.candidates[0].finish_reason))
    stop = "end_turn" if finish == "STOP" else ("max_tokens" if finish == "MAX_TOKENS" else finish)
    u = r.usage_metadata
    return (message, texts, calls, stop,
            (u.prompt_token_count or 0, u.candidates_token_count or 0, u.thoughts_token_count or 0))


def gemini_results(results):
    """Wrap [(call_id, tool_name, text, is_error), ...] as the user Content that returns tool results to Gemini."""
    from google.genai import types
    return types.Content(role="user", parts=[
        types.Part.from_function_response(name=n, response=gemini_result_payload(t, e)) for _, n, t, e in results])

# =================== END LLM PROVIDER (Gemini) ===================


PROVIDERS = {"anthropic": (call_anthropic, anthropic_results, THINKING_NOTE_ANTHROPIC, RETRY_NOTE_ANTHROPIC, "none"),
             "gemini": (call_gemini, gemini_results, THINKING_NOTE_GEMINI, RETRY_NOTE_GEMINI, PACING_NOTE_GEMINI)}
PROVIDER = os.environ.get("AGENT_PROVIDER", "")
if PROVIDER not in PROVIDERS:
    sys.exit(f"AGENT_PROVIDER must be one of {', '.join(PROVIDERS)} (got: {PROVIDER or 'not set'}).")
if not MODEL:
    sys.exit("AGENT_MODEL is not set; there is no default model.")
call_llm, tool_results_message, THINKING_NOTE, RETRY_NOTE, PACING_NOTE = PROVIDERS[PROVIDER]


def log(text):
    """Print a line and append it to the transcript file."""
    print(text)
    with TRANSCRIPT.open("a", encoding="utf-8") as f:
        f.write(text + "\n")


def answer(messages, log=log):
    """Let the model respond to the latest user message, running tools until it replies in text; return total (in, out, thoughts) tokens."""
    total = [0, 0, 0]
    for _ in range(MAX_TURNS):
        message, texts, calls, stop, usage = call_llm(messages, log)
        total = [a + b for a, b in zip(total, usage)]
        messages.append(message)
        for t in texts:
            log(f"\nASSISTANT: {t}")
        log(f"[tokens this call: {usage[0]} in, {usage[1]} out, {usage[2]} thinking]")
        if stop == "max_tokens":
            log(f"\n[stopped: output cap of {MAX_TOKENS} tokens reached; the reply may be cut off]")
            raise LLMError(f"Output cap of {MAX_TOKENS} tokens reached; stopped without running any tool.")
        if not calls:
            if stop not in ("end_turn", "stop_sequence"):
                log(f"\n[stopped: {stop}]")
            break
        results = []
        for call_id, name, args in calls:
            log(f"\nTOOL CALL {name}: {json.dumps(args, ensure_ascii=False)}")
            text, is_error = tools.call(name, args)
            log(f"TOOL {'ERROR' if is_error else 'RESULT'}: {text}")
            results.append((call_id, name, text, is_error))
        messages.append(tool_results_message(results))
    else:
        log(f"\n[stopped: turn limit of {MAX_TURNS} reached]")
    log(f"[tokens this message: {total[0]} in, {total[1]} out, {total[2]} thinking]")
    return tuple(total)


def read_line():
    """Show the 'You: ' prompt (only at a real terminal) and return the next input line; '' means end of input."""
    if sys.stdin.isatty():  # True only when a person is typing; False for piped or scripted input
        print("You: ", end="", flush=True)  # the prompt; no newline so the cursor stays beside it
    return sys.stdin.readline()  # one line; an empty string only when the input has ended


def main():
    """Run the chat until an empty line, 'quit', 'exit', end of input, or Ctrl+C."""
    TRANSCRIPT.parent.mkdir(exist_ok=True)
    TRANSCRIPT.write_text(f"# Billing assistant transcript -- provider {PROVIDER}, model {MODEL}\n"
                          f"# Prompt/tool-description version: {PROMPT_VERSION}\n"
                          f"# {THINKING_NOTE}\n"
                          f"# Retries: {RETRY_NOTE}\n# Pacing: {PACING_NOTE}\n", encoding="utf-8")
    # The banner uses print (not log), so it appears on the screen only and never in the transcript file.
    print(f"Billing assistant -- provider {PROVIDER}, model {MODEL}, prompt version {PROMPT_VERSION}")  # no keys or passwords
    print("Type your request and press Enter. Type quit (or exit) to leave.")  # how to leave
    messages = []
    try:
        while True:  # keep asking until a break below
            line = read_line()  # prompt (terminal only) and read one line
            text = line.strip()  # same trimming as before
            if not text or text.lower() in ("quit", "exit"):  # empty line, end of input, "quit" or "exit" (any case)
                break  # leave the chat
            log(f"\nUSER: {text}")
            messages.append({"role": "user", "content": text})
            answer(messages)
    except LLMError as e:
        sys.exit(f"Stopped: {e}")
    except KeyboardInterrupt:  # Ctrl+C pressed
        print("\nStopped.")  # one screen-only line; the transcript keeps what was logged; no traceback


if __name__ == "__main__":
    main()
