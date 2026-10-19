# Cost rate card (G1)

> **Estimate only — for Claude Code the authoritative cost is `cost_usd` on the
> `api_request` log event**, which `claude-code-agent.yaml` turns into
> `gen_ai.client.cost`. The span-side rate-card figure is exported separately as
> `dt.genai.cost.estimated` (span attr `dt.genai.cost.source = rate_card_estimate`).
> Why: a flat per-token rate cannot reproduce long-context pricing tiers. A least-squares
> fit over 80 live `claude-fable-5-1` requests gave in 9.06 / out 46.42 / cache-read 0.26 /
> cache-write 19.58 USD per 1M with **10.8 % mean, 55 % max error**
> (research/datadog-comparison.md §2.1). Use the rate card where no `cost_usd` exists
> (other providers, OneAgent-exported spans, the generic `config.yaml`).

`transform/genai_cost` in `config.yaml` computes `gen_ai.usage.cost` (USD) from
token counts × these per-1M-token rates. **Edit both this file and the OTTL
`set(attributes["tmp.rate.*"], …)` lines together — they are the same numbers.**

Rates are matched by case-insensitive regex on `gen_ai.request.model`, most
specific last (Haiku/Opus override the Sonnet default).

| Tier (regex)   | input | output | cache read | cache write |
|----------------|------:|-------:|-----------:|------------:|
| default/Sonnet | 3.00  | 15.00  | 0.30       | 3.75        |
| `.*opus.*`     | 15.00 | 75.00  | 1.50       | 18.75       |
| `.*haiku.*`    | 0.80  | 4.00   | 0.08       | 1.00        |
| `.*fable.*` (fitted, not in OTTL yet — see note above; ±11 %) | 9.06 | 46.42 | 0.26 | 19.58 |

Formula per span:
```
cost = input/1e6·in + output/1e6·out + cache_read/1e6·cr + cache_write/1e6·cw
```

Notes
- Cost is **not** an OTel-spec signal — it is a vendor extension that fills the
  gap (OTel defines no GenAI cost metric). Treat figures as estimates.
- Add a provider: append a new `tmp.rate.*` override block keyed on that
  provider's model regex, and a matching row here.
- For non-Anthropic providers, replace the default tier or gate the whole stage
  on `gen_ai.provider.name`.
- Confirm current public prices before trusting absolute numbers; the point of
  the processor is the *mechanism*, not the specific cents.
