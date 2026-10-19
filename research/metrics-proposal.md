# Richer Claude Code metrics — beyond Grafana dashboard 25052

The community Grafana dashboard (25052) is driven entirely by Claude Code's
**native OTel aggregate metrics** (`claude_code.cost.usage`, `.token.usage`,
`.session.count`, `.lines_of_code.count`, `.commit.count`, `.code_edit_tool.decision.count`,
`active_time`, api request/error counts), broken down by **model / tool / user / day**.

Confirmed live on the test tenant — those native metrics exist:
`claude_code.cost.usage` ≈ 4.24 → 17.38 USD/h · `claude_code.token.usage` up to 46M/h ·
`claude_code.session.count` · `claude_code.lines_of_code.count` (494/222).

**What Grafana cannot show** (it has no access to the span stream): per-conversation
cost, per-tool latency, cache efficiency, request-outcome mix, decode throughput.
Those are precisely what OneAgent-grade agentic monitoring needs — and they are all
**derivable from the Claude Code span stream** (which carries `trace.id`,
`span.parent_id`, `duration_ms`, `cache_*_tokens`, `stop_reason`,
`gen_ai.response.finish_reasons`, `gen_ai.conversation.id`).

## Proposed metric catalog (what the agent should collect)

### 1. Cost, attributed (closes Grafana's #1 gap)
Native `claude_code.cost.usage` is a flat aggregate. We derive cost per span and
attribute it:
| Metric | Type | Dimensions | Why it beats Grafana |
|--------|------|-----------|----------------------|
| `gen_ai.client.cost` | sum (USD) | `conversation.id`, `request.model`, `stop_reason` | cost **per session** and per request outcome, not just per model/day |
| `gen_ai.session.cost_burn` | gauge (USD/min) | `conversation.id` | live burn-rate per active session |

### 2. Cache efficiency (OneAgent signature; Grafana absent)
`input_tokens=2` vs `cache_read=114k` — cache is the real story.
| Metric | Type | Derivation |
|--------|------|-----------|
| `dt.genai.cache_read_ratio` | gauge (0–1) | `cache_read / (input + cache_read + cache_creation)` per request |
| `gen_ai.client.token.usage{type=cacheRead\|cacheCreation}` | sum | already added in the agent config |

### 3. Latency & throughput (Grafana shows none per-tool)
| Metric | Type | Derivation |
|--------|------|-----------|
| `gen_ai.client.operation.duration` | histogram (s) | `duration_ms/1000`, by `request.model` → p50/p95/p99 |
| `gen_ai.execute_tool.duration` | histogram (s) | `duration_ms/1000`, by `tool.name` → slowest tools |
| `gen_ai.throughput.output_tokens_per_second` | histogram | `output_tokens / (duration_ms/1000)` — decode speed, approximates the OTel `server.time_per_output_token` we otherwise can't fill |

### 4. Agentic shape (what the agent is *doing* — Grafana can't)
| Metric | Type | Derivation |
|--------|------|-----------|
| `gen_ai.agent.tool_calls` | sum | count of `execute_tool` spans by `conversation.id`, `tool.name` → tools-per-session |
| `gen_ai.request.count` | sum | by `stop_reason` (`tool_use` vs `end_turn` vs `max_tokens`) → how often the loop tool-calls vs finishes; `max_tokens` spikes = truncation problems |
| `gen_ai.agent.turn_depth` | histogram | llm_request spans per `trace.id` (parent interaction) → agentic loop depth |

### 5. Reliability
| Metric | Type | Derivation |
|--------|------|-----------|
| `gen_ai.client.operation.duration{error.type}` | histogram dim | failures as a dimension (spec-correct), not a separate counter |
| `gen_ai.request.count{stop_reason=max_tokens}` | sum | truncation rate as a quality signal |

### 6. Session analytics from the event stream (Datadog AI Agents Console parity)
Added 2026-10-18 after comparing with Datadog (research/datadog-comparison.md). All
from Claude Code **log events**, which carry what spans don't.
| Metric | Type | Derivation | Datadog equivalent |
|--------|------|-----------|--------------------|
| `gen_ai.client.cost` | sum (USD) | **`api_request.cost_usd` — authoritative**, dims conversation, model, `cc.query_source.class` (main/subagent/auxiliary/compact), effort, speed | spend by user/agent |
| `dt.genai.cost.estimated` | sum (USD) | the former span rate-card figure, kept for reconciliation | — |
| `gen_ai.server.time_to_first_token` | histogram (s) | `api_request.ttft_ms / 1000` | — (closes G8) |
| `claude_code.turns` | count | `user_prompt` per conversation, by `command_source` | avg turns / session |
| `claude_code.tool.results` | count | by tool, `success`, `error_type`, `cc.bash.class` | retry loops, skipped checks |
| `claude_code.tool.result_bytes` | sum (By) | `tool_result_size_bytes` by tool | file rereads (context burn) |
| `claude_code.tool.decisions` | count | `tool_decision` by decision/source | permission friction |
| `claude_code.hook.executions` | count | by `hook_event`, `cc.hook.blocked` | Fix Library (hooks) effect |
| `claude_code.permission_mode.changes` | count | by from/to/trigger (`auto_gate_denied`) | — |
| `claude_code.api.errors` / `.refusals` / `.requests` | count | by status/attempt · category · spender class | reliability |
| `claude_code.compactions`, `.compaction.tokens_reclaimed` | count / sum | `pre_tokens - post_tokens` | — |
| `claude_code.subagent.duration`, `.subagents` | histogram / count | `subagent_completed` by `agent_type` | — |

Log-record enrichment that makes the stateful DQL patterns possible: `gen_ai.conversation.id`
(join key to spans), `cc.tool.file_path`, `cc.tool.input_hash` (SHA256 of the call),
`cc.bash.class`, `cc.query_source.class`, real severities on failures.

## Status against the agent config
Implemented in `processor/claude-code-agent.yaml`: §1 cost (+conversation dim; now
authoritative from events, §6), §2 cache tokens + ratio attr, §3 all three + TTFT, §4
tool_calls + request.count, §5 error dim, §6 all rows.
`turn_depth`, `session.cost_burn`, file-reread and skipped-check detection need stateful
aggregation → dashboard DQL (datadog-comparison.md §4).
