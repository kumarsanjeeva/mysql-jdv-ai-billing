# agent/check_gemini_sdk.py -- offline checks of the Gemini section of agent/agent.py
# against the installed google-genai SDK. No network, no API call, no real key:
# it only builds the SDK's objects and reads their fields. Each check prints
# PASS or raises, so a failure stops the run with the reason.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_gemini_sdk

import os

from agent import agent, tools


def check(label, ok, detail=""):
    """Print PASS/FAIL for one check and stop if it failed."""
    print(f"{'PASS' if ok else 'FAIL'}  {label}  {detail}")
    assert ok, label


def main():
    """Run checks a to g."""
    import google.genai
    from google.genai import errors, types

    # a) import and version
    print(f"a) google-genai version: {google.genai.__version__}")

    # b) our tool declarations, including the bare {"type": "object"} schemas
    built = agent.gemini_tools()
    decls = built[0].function_declarations
    check("b) six declarations built", len(decls) == 6, [d.name for d in decls])
    bare = [s["name"] for s in tools.SCHEMAS
            if any(v == {"type": "object"} for v in s["input_schema"]["properties"].values())]
    print(f"   tools with a bare object parameter: {bare}")
    dumped = built[0].model_dump(exclude_none=True)
    create = [d for d in dumped["function_declarations"] if d["name"] == "create_order"][0]
    print(f"   create_order parameters as the SDK holds them: {create.get('parameters_json_schema')}")
    check("b) SDK accepted the schemas (validation only; the Gemini server may still reject them)",
          all(d.get("parameters_json_schema") for d in dumped["function_declarations"]))

    # c) generation config: output cap and automatic function calling off
    cfg = types.GenerateContentConfig(
        system_instruction=agent.SYSTEM, tools=built, max_output_tokens=agent.MAX_TOKENS,
        automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True))
    check("c) max_output_tokens is 2048", cfg.max_output_tokens == 2048, cfg.max_output_tokens)
    check("c) automatic function calling disabled", cfg.automatic_function_calling.disable is True)

    # d) function-response Part for the GUARD 6 error, byte for byte
    guard = "MySQL error 1644: GUARD 6: order_items.price does not match the current catalog price"
    content = agent.gemini_results([("g1", "create_order", guard, True)])
    part = content.parts[0]
    got = part.function_response.response["error"]
    check("d) role is user", content.role == "user", content.role)
    check("d) function name kept", part.function_response.name == "create_order")
    check("d) error string byte-for-byte", got.encode() == guard.encode(), repr(got))
    ok_part = agent.gemini_results([("g2", "get_order", "{}", False)]).parts[0]
    check("d) success result goes under 'result'", ok_part.function_response.response == {"result": "{}"})

    # e) fields the token logging and the reply parsing read
    usage_fields = types.GenerateContentResponseUsageMetadata.model_fields
    for f in ("prompt_token_count", "candidates_token_count", "thoughts_token_count"):
        check(f"e) usage metadata has {f}", f in usage_fields)
    for f in ("function_call", "thought", "text"):
        check(f"e) Part has {f}", f in types.Part.model_fields)
    check("e) FinishReason has STOP and MAX_TOKENS",
          {"STOP", "MAX_TOKENS"} <= set(types.FinishReason.__members__))

    # f) the API error class and what the 429 handling reads
    err = errors.APIError(429, {"error": {"code": 429, "message": "quota test", "status": "RESOURCE_EXHAUSTED"}})
    check("f) APIError.code is 429", err.code == 429, err.code)
    check("f) APIError.message is readable", "quota test" in err.message, err.message)
    check("f) str(error) contains the text the PerDay/retry matching reads", "quota test" in str(err), str(err))
    check("f) ClientError is an APIError", issubclass(errors.ClientError, errors.APIError))

    # g) redact() hides a fake key
    os.environ["GEMINI_API_KEY"] = "FAKE-KEY-1234567890-NOT-REAL"
    shown = agent.redact("request failed for key FAKE-KEY-1234567890-NOT-REAL at host")
    print(f"   redact output: {shown}")
    check("g) fake key not in output", "FAKE-KEY-1234567890-NOT-REAL" not in shown)
    check("g) [redacted] in output", "[redacted]" in shown)

    # history conversion used by call_gemini
    conv = agent.gemini_contents([{"role": "user", "content": "hello"}, content])
    check("history) plain text becomes a user Content; Content passes through unchanged",
          conv[0].role == "user" and conv[0].parts[0].text == "hello" and conv[1] is content)
    print("ALL OFFLINE CHECKS PASSED (no network used).")


if __name__ == "__main__":
    main()
