# agent/db.py -- opens the database connection the billing agent uses.
#
# Why it is separate: the agent must connect ONLY as AGENT_DB_USER, the
# least-privilege account created in sql/00_setup.sql, which can touch the
# JSON Duality Views and nothing else. Keeping the connection in one place
# makes that impossible to get wrong elsewhere. Planned.

raise NotImplementedError("agent/db.py is not implemented yet")
