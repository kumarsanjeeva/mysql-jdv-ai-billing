# agent/scenarios.py -- a scripted, repeatable run of the billing story that
# calls agent/tools.py directly, so it works without an Anthropic API key.
#
# Why it exists: the blog needs output anyone can reproduce. The story:
# create an order with items and an advance payment, race it against a
# counter-staff status update to show the stale-etag retry, then show the
# final document. Comparing the document with the relational rows is done
# by a SQL query (as in sql/03_dml_demos.sql H03), not in Python.
#
# Usage:
#     python -m agent.scenarios
#
# Output is saved to results/agent_scenarios.txt. Planned.

raise NotImplementedError("agent/scenarios.py is not implemented yet")
