# agent/agent.py -- the chat loop between a person at the bakery counter and
# Claude. Claude answers in plain language and, when it needs data, calls
# the tools in agent/tools.py; this file only passes messages and tool
# results back and forth. It holds no business rules -- those are in MySQL.
#
# The whole conversation (messages, every tool call with its input, every
# tool result) is printed and also saved to results/agent_transcript.txt.
#
# Usage:
#     python -m agent.agent
# Type a message and press Enter; an empty line or "quit" ends the chat.
# Needs ANTHROPIC_API_KEY and ANTHROPIC_MODEL in .env (or the environment).

import json
import os
import sys
from pathlib import Path

import anthropic
from dotenv import load_dotenv

from agent import tools

load_dotenv()
MODEL = os.environ["ANTHROPIC_MODEL"]
TRANSCRIPT = Path(__file__).resolve().parent.parent / "results" / "agent_transcript.txt"

SYSTEM = f"""You are the billing assistant at the counter of Sunrise Bakers, MG Road outlet (outlet id 1).
You help staff take and manage customer orders. You can only act through your tools.

- Never invent a price, product, customer or order. Prices and GST rates come from search_catalog;
  customers from get_customer; orders from get_order.
- Before create_order, show the customer the items, subtotal, GST and total, and wait for them to agree.
- For GST-exclusive items: item gst_value = price x qty x gst_rate / 100; subtotal = sum of price x qty;
  total = subtotal - discount_value + gst_value. The database rejects a total that does not add up.
- Generate a new unique request_id for every create_order and every add_payment (for example
  "ord-" or "pay-" followed by random letters and digits). If you retry the same action, reuse its request_id.
- If a tool returns a MySQL error, tell the staff member what it means in plain words; do not work around it.
- Payments cannot be edited. A mistaken payment is corrected with a refund payment.
Business id {tools.BUSINESS_ID}. Today is {os.environ.get("AGENT_TODAY", "2026-09-26")}."""


def log(text):
    """Print a line and append it to the transcript file."""
    print(text)
    with TRANSCRIPT.open("a", encoding="utf-8") as f:
        f.write(text + "\n")


def answer(client, messages):
    """Let Claude respond to the latest user message, running tools until it replies in text."""
    while True:
        response = client.messages.create(model=MODEL, max_tokens=16000, system=SYSTEM,
                                          tools=tools.SCHEMAS, messages=messages)
        messages.append({"role": "assistant", "content": response.content})
        for block in response.content:
            if block.type == "text" and block.text.strip():
                log(f"\nASSISTANT: {block.text}")
        if response.stop_reason != "tool_use":
            if response.stop_reason not in ("end_turn", "stop_sequence"):
                log(f"\n[stopped: {response.stop_reason}]")
            return
        results = []
        for block in response.content:
            if block.type == "tool_use":
                log(f"\nTOOL CALL {block.name}: {json.dumps(block.input, ensure_ascii=False)}")
                text, is_error = tools.call(block.name, block.input)
                log(f"TOOL {'ERROR' if is_error else 'RESULT'}: {text}")
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": text, "is_error": is_error})
        messages.append({"role": "user", "content": results})


def main():
    """Run the chat until an empty line, 'quit', or end of input."""
    TRANSCRIPT.parent.mkdir(exist_ok=True)
    TRANSCRIPT.write_text(f"# Billing assistant transcript -- model {MODEL}\n", encoding="utf-8")
    client = anthropic.Anthropic()
    messages = []
    for line in sys.stdin:
        text = line.strip()
        if not text or text.lower() == "quit":
            break
        log(f"\nUSER: {text}")
        messages.append({"role": "user", "content": text})
        answer(client, messages)


if __name__ == "__main__":
    main()
