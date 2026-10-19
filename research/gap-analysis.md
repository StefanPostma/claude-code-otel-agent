# Gap analysis — OneAgent GenAI vs OTel semconv vs PR #353

Target: **Dynatrace OneAgent GenAI instrumentation**, analysed from what it actually
emits — Dynatrace docs plus the AI Observability field inventory. The OneAgent binaries
themselves are not needed to build an OTel processor and were not examined.

Goal: an OTel Collector processor ("the OneAgent" we build) that fills the signals
left uncovered by **(a)** the OTel GenAI semantic conventions and **(b)** the
Claude Code mappings in PR #353.

## Three inventories

### A. What Dynatrace OneAgent emits natively (source of truth for "what matters")
Spans: `gen_ai.provider`, `gen_ai.model`, `gen_ai.usage.input_tokens`,
`gen_ai.usage.output_tokens`, `gen_ai.operation.kind` ∈ {workflow, task, agent,
tool, retrieval}, prompt/response content (opt-in).
Metrics: `gen_ai.client.token.usage`, `gen_ai.client.operation.duration`.
Advanced: full agentic/pipeline span hierarchies (RAG, agentic loops, tool calls,
retrieval), W3C trace-context propagation, **AWS Bedrock Guardrails** (activations,
filter hits by type PII/topic/word/content, direction, latency), **prompt-cache**
read/write token counts.

### B. OTel GenAI semconv (the standard — all Development status)
Operations (`gen_ai.operation.name`): `create_agent`, `invoke_agent`,
`invoke_workflow`, `plan`, `execute_tool`, `chat`.
Attrs: `gen_ai.agent.{id,name,description,version}`, `gen_ai.conversation.id`,
`gen_ai.request.*`, `gen_ai.{input,output}.messages`, `gen_ai.usage.{input,output}_tokens`,
`gen_ai.usage.cache_read.input_tokens`, `gen_ai.tool.*`, `gen_ai.workflow.name`.
Metrics: `gen_ai.client.operation.duration`, `gen_ai.client.token.usage`,
`gen_ai.server.{request.duration,time_to_first_token,time_per_output_token}`,
`gen_ai.invoke_agent.{duration,inference_calls,tool_calls}`,
`gen_ai.invoke_workflow.duration`, `gen_ai.execute_tool.duration`.
**No cost metric. No guardrail convention. No cache-write/creation token.**

### C. PR #353 (your Claude Code mappings)
Maps `claude_code.*` spans/logs → `gen_ai.*` via OTTL; derives
`gen_ai.client.token.usage` (4 token types), `gen_ai.client.inference.usage.*`,
`gen_ai.client.operation.duration`. Claude-Code-specific; anthropic hard-coded.

## The gaps (B ∪ C do not cover; A or AI Observability need)

| # | Gap | In OneAgent? | In OTel std? | In PR #353? | Processor fills it by |
|---|-----|:--:|:--:|:--:|---|
| G1 | **Cost** (`Overall cost` tile) | yes (tile) | **no** | no | generic: tokens × editable rate card → estimate. **Claude Code: use the authoritative `cost_usd` on the `api_request` log event** → `gen_ai.client.cost`; rate card demoted to `dt.genai.cost.estimated` (a flat rate misses long-context tiers by up to 55 %, see datadog-comparison.md §2.1) |
| G2 | **`operation.kind` → `operation.name`** normalization | emits `kind` | uses `name` | n/a (claude only) | translate kind∈{workflow,task,agent,tool,retrieval} → name, provider-agnostic |
| G3 | **Agent/tool roll-up metrics** (`invoke_agent.duration`, `execute_tool.duration`) | no | defined | no | derive histograms from the enriched spans via `signal_to_metrics` |
| G4 | **`invoke_agent.tool_calls` / `inference_calls`** counters | no | defined | no | approximate via `count` connector grouped by `conversation.id` (documented caveat) |
| G5 | **cache-write / creation tokens** | yes | **no std key** | ad-hoc key | normalize to `gen_ai.usage.cache_write.input_tokens` consistently for any provider |
| G6 | **Guardrails** (activations, filter hits, direction) | yes (Bedrock) | **no** | no | map to `gen_ai.guardrail.*` + `gen_ai.guardrail.activations` counter |
| G7 | `total_tokens` coalesce + `error.type` on failures, provider-agnostic | partial | partial | claude only | generic OTTL on `gen_ai.*` |
| G8 | **server inference timing** (`time_to_first_token`, `time_per_output_token`) | no | defined | no | **closed for Claude Code (2026-10-18):** `ttft_ms` is on every `api_request` log event → `gen_ai.server.time_to_first_token` histogram. `time_per_output_token` approximated by `gen_ai.throughput.output_tokens_per_second`. Still open for the generic config |
| G9 | **Session analytics** (turns/session, retry loops, file rereads, skipped checks, permission friction) — what Datadog's AI Agents Console sells | no | no | no | events layer `transform/cc_events` + log→metric connectors; stateful patterns as DQL (datadog-comparison.md §3–4) |

## Design decision
The processor operates on the **normalised `gen_ai.*` namespace**, not on
`claude_code.*`. That makes it a drop-in downstream stage for *any* GenAI source —
OneAgent-exported OTLP, an OTel GenAI SDK, or PR #353's output — rather than a
second Claude-Code-specific config. Claude/anthropic ships as the worked rate-card
example (matching PR #353), fully editable.
