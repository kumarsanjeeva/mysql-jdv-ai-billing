# Billing agent system prompt

_Written in Phase 4._

Will instruct the agent: it is a bakery billing assistant; it may only act
through its tools (never invent data or bypass them); it must confirm order
totals with the customer before calling `create_order`; and it must never
invent prices — every price comes from `search_catalog`.
