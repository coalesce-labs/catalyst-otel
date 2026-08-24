# Codex (OpenAI) estimated cost — price table

**This file is the cited source for every "estimated cost" panel in
`dashboards/codex-usage.json` and `dashboards/ai-usage.json`.** Do not hardcode
a price in a panel query without updating this file first — panel queries
reference these numbers, this file is where they're justified.

## Why "estimated," never "real"

The laptop's Codex CLI (`codex exec`) authenticates via **ChatGPT subscription
auth (Plan Pro)**, confirmed from `~/.codex/auth.json`: `"auth_mode": "chatgpt"`,
`"OPENAI_API_KEY": ""` (present but empty — no API key configured at all).
Checked three possible cost sources, 2026-08-24, all negative:

1. **Rollout JSONLs** (`~/.codex/sessions/**/rollout-*.jsonl`) — every
   `token_count` event carries a `rate_limits.credits` block:
   `{"has_credits": false, "unlimited": false, "balance": "0"}` and
   `"plan_type": "pro"`, on every session checked (multiple 40MB+ files from
   today's relay activity). No `cost`/`dollar`/`usd`/`price` field exists
   anywhere in any rollout JSONL (`grep -oiE '"[a-z_]*(cost|dollar|usd|price)[a-z_]*"' `
   over several full files: zero matches).
2. **The OTLP feed** (Loki `codex_exec` structured metadata) — enumerated
   every distinct metadata key across `codex_exec` streams in a 6h window
   (74 keys total): no `cost`/`dollar`/`usd`/`price`/`credit`/`balance`/`spend`
   key exists.
3. **OpenAI platform Costs/Usage API** — not reachable from this environment.
   Requires an API key with org-admin scope; `~/.codex/auth.json` has none
   (empty string). Not "reports zero" — genuinely uncallable without
   provisioning a separate API credential this box doesn't have.

So: **subscription usage has no true marginal dollar cost**, and there is no
reported number to surface. Every panel using the table below must say
"estimated @ API list price" in its title or description.

## Price table (OpenAI published API pricing, short-context tier)

Source: https://developers.openai.com/api/docs/pricing (fetched 2026-08-24;
redirects from the legacy `platform.openai.com/docs/pricing`). Model-specific
context threshold confirmed via https://developers.openai.com/api/docs/models/gpt-5.6-sol
(fetched 2026-08-24): **"Prompts with >272K input tokens are priced at 2x
input and 1.5x output for the full request."**

| Model | Input $/1M | Cached input $/1M | Output $/1M | Long-context (>272K in) |
|---|---|---|---|---|
| `gpt-5.6-sol` | 4.00 | 0.40 | 20.00 | 2x input / 1.5x output ($8.00 / $0.80 / $30.00) |
| `gpt-5.6-terra` | 2.00 | 0.20 | 12.00 | 2x input / 1.5x output ($4.00 / $0.40 / $18.00) |
| `gpt-5.6-luna` | 0.20 | 0.02 | 1.20 | 2x input / 1.5x output ($0.40 / $0.04 / $1.80) |

`gpt-5.6-sol`'s promotional pricing is stated to hold "at least through
November 21, 2026" — re-verify against the source URL after that date, or
sooner if a price panel's numbers look implausible.

**Which tier applies to this fleet:** every `codex_exec` session observed
reports `model_context_window: 258400` (from rollout JSONL `token_count`
events) — below the 272K long-context threshold, so a single request on this
fleet's configuration can never cross into the long-context tier. **The
dashboard queries therefore use the short-context (base) price only.** If the
context-window configuration ever changes to allow >272K, this assumption
needs revisiting (the queries would need a per-event conditional, which LogQL
does not support cleanly — would likely require a small script/exporter
instead).

**Fleet's actual usage:** every sample checked across today's relay activity
used `gpt-5.6-sol` exclusively — `gpt-5.6-terra`/`gpt-5.6-luna` prices are
listed for completeness/future use but are not wired into any panel query
yet (no data to price). Add a target block per model, copy-pasting the
`gpt-5.6-sol` panel pattern with the new model's prices, if/when terra or
luna traffic appears.

## Token-field-to-price mapping (avoiding a real double-count bug)

Codex's `codex.sse_event` Loki structured metadata carries 5 numeric fields:
`input_token_count`, `cached_token_count`, `output_token_count`,
`reasoning_token_count`, `tool_token_count`. Verified their relationship from
10 consecutive same-conversation events (`linear_key=CTL-1463`, 2026-08-24):

- `tool_token_count == input_token_count + output_token_count` exactly, every
  row checked. It is a **running total**, not a separate billable category —
  **do not add it to a cost formula**, it would double the input+output cost.
- `reasoning_token_count < output_token_count` in every row — reasoning
  tokens are a **subset** of `output_token_count` (OpenAI bills reasoning as
  output tokens), matching the rollout JSONL's `total_token_usage` shape
  (`output_tokens` already includes `reasoning_output_tokens`). **Do not add
  it separately either.**
- `cached_token_count <= input_token_count` in every row — cached is a
  **subset** of input, priced at the cached rate; the remainder
  (`input_token_count - cached_token_count`) is priced at the base input rate.

**Correct per-event cost** (all in the *turn*, i.e. one `codex.sse_event`,
which is one real billed API call — conversation context growing turn-over-
turn means each turn IS a separate charge, so summing over events in a
window is correct, not a double-count):

```
cost = (input_token_count - cached_token_count) * input_price
     + cached_token_count * cached_price
     + output_token_count * output_price
```
(all `_price` values = $/1M ÷ 1,000,000; `tool_token_count` and
`reasoning_token_count` are NOT separately added.)
