# agent/check_error_passthrough.py -- offline check, no database and no API call:
# a MySQL guard error must reach the model's tool-result message byte for byte,
# for both providers. It fakes one tool that raises the real GUARD 6 error
# (errno 1644, text copied from results/07_e28_item_price_guard.txt), sends it
# through tools.call, and compares what each provider would hand to the model.
#
# Usage:  AGENT_PROVIDER=gemini AGENT_MODEL=offline-check python -m agent.check_error_passthrough

import mysql.connector

from agent import agent, tools

GUARD = "GUARD 6: order_items.price does not match the current catalog price"


def fake_create_order(order):
    """Stand-in for create_order that raises the real GUARD 6 error."""
    raise mysql.connector.Error(msg=GUARD, errno=1644, sqlstate="45000")


def main():
    """Run the check and print what was compared."""
    tools.TOOLS["create_order"] = fake_create_order
    text, is_error = tools.call("create_order", {"order": {}})
    expected = f"MySQL error 1644: {GUARD}"
    print(f"tools.call text   : {text!r}")
    print(f"is_error          : {is_error}")
    assert text == expected and is_error, "tools.call changed the error"
    payload = agent.gemini_result_payload(text, is_error)
    print(f"gemini payload    : {payload!r}")
    assert payload == {"error": expected} and payload["error"].encode() == expected.encode()
    anthropic_msg = agent.anthropic_results([("c1", "create_order", text, is_error)])
    block = anthropic_msg["content"][0]
    print(f"anthropic block   : {block!r}")
    assert block["content"].encode() == expected.encode() and block["is_error"] is True
    # A non-MySQL failure (bad argument) must also come back as an error, not a crash.
    text2, is_error2 = tools.call("search_catalog", {"wrong_argument": 1})
    print(f"bad-argument case : {text2!r} (is_error={is_error2})")
    assert is_error2 and text2.startswith("Tool error (TypeError)")
    print("RESULT: byte-for-byte match for both providers; bad arguments returned as errors.")
    print("NOT covered here: the Gemini SDK's own Part object (needs google-genai; checked after install).")


if __name__ == "__main__":
    main()
