# Datadog "Agent Observability" for Claude — what it is, and what we took from it

Researched 2026-10-18 from the claude.com marketplace listing, Datadog docs/blog, and the
Datadog documentation PR that adds Claude Code to the AI Agents Console. Then verified
against the live Claude Code log stream on the test tenant.

## 1. The listing bundles two different products

| | Datadog Claude Code Monitoring (AI Agents Console) | Datadog LLM Observability (Agent Observability SDK) |
|---|---|---|
| Source | Claude Code's **native** OTel export, **logs + metrics only** (no traces exporter in their setup) | `ddtrace` auto-instrumentation inside **your own** Python/Node app (`claude_agent_sdk`, `anthropic` integrations) |
| Transport | `settings.json` env → Datadog OTLP intake (`dd-api-key` header) **or** a local Datadog Agent with `otlp_config` receiver on gRPC 4317 | Datadog Agent (default) or agentless (`DD_LLMOBS_AGENTLESS_ENABLED=true`) |
| Monitors the Claude Code CLI itself | yes | **no** — needs code you own |
| Span kinds llm / agent / tool / workflow / task / retrieval / embedding | no | yes (same inventory as OneAgent's `gen_ai.operation.kind`) |
| Tokens incl. cache read / write | aggregate metric only | yes, per span |
| Cost per request | no (aggregate `claude_code.cost.usage`) | estimated per span |
| Host entity / host metrics | only if a Datadog Agent runs | only if a Datadog Agent runs |
| Console analytics: spend per user/team, turns/session, time-to-merge, AI-assisted commit/PR share, "Detected Problems" (skipped checks, retry loops, file rereads) + Fix Library (PreToolUse hooks, skills) | **yes — this is the product** | no |
| Evaluations, Patterns clustering, prompt-injection / sensitive-data detection | no | yes |

The separately listed Datadog **plugin** for Claude Code (`/plugin install datadog@claude-plugins-official`,
`/ddsetup`) is the *reverse* direction: an MCP server (OAuth, HTTP) so Claude can query Datadog.
It sends nothing about Claude Code to Datadog.

**Conclusion.** Datadog's Claude Code product is console work on the same raw stream Grafana
25052 uses; the enrichment our collector does (cache→gen_ai, cost on spans, host entity) has no
counterpart there. What *is* worth borrowing is the console-side **session analytics**, and
those derive from Claude Code's **log/event stream** — which we were forwarding but not using.

## 2. What the Claude Code event stream really contains (the test tenant, 7 days)

| event.name | count | what it carries that matters |
|---|---:|---|
| `api_request` | 4315 | **`cost_usd` (authoritative)**, `cost_usd_micros`, `ttft_ms`, all 4 token kinds, `duration_ms`, `model`, `effort`, `speed`, `query_source` (`repl_main_thread` / `agent…` / `generate_session_title` / `compact`…), `request_id`, `prompt.id` |
| `tool_decision` | 3828 | `decision` accept/reject, `source` config/hook/user_*, `tool_name`, `tool_source` |
| `tool_result` | 3792 | `tool_name`, `success`, `error_type`, `duration_ms`, **`tool_input` (JSON string)**, `tool_input_size_bytes`, `tool_result_size_bytes`, `decision_source` |
| `assistant_response` | 2022 | text (opt-in), `model`, `request_id` |
| `hook_execution_complete/start` | 1169 each | `hook_event`, `hook_name`, `num_hooks`, `num_blocking` |
| `user_prompt` | 383 | one per turn; `prompt_length`, `command_name/source` |
| `subagent_completed` | 54 | `agent_type`, `model`, `duration_ms` |
| `compaction` | 9 | `trigger` manual/auto, `pre_tokens`, `post_tokens`, `duration_ms` |
| `api_refusal` | 10 | `model`, `attempt`, `has_category`, `category` |
| `permission_mode_changed` | 4 | `from_mode`, `to_mode`, `trigger` (incl. `auto_gate_denied`) |
| `api_error` | — (none in window) | `status_code`, `attempt`, `error`, `model` |

Every event carries `session.id`, `prompt.id`, `trace_id`/`span_id` (when traces are on),
`user.*`, `organization.id`, `terminal.type`, `service.version`. Claude Code emits all of
them at SeverityNumber 0 / "INFO" — so failures show as `loglevel: NONE` in Dynatrace.

### 2.1 Cost: the rate card cannot be made exact
Least-squares fit of per-1M-token rates over 80 `claude-fable-5-1` requests
(`research/fit-fable-rates.js`, run with `node research/fit-fable-rates.js`):

| | input | output | cache read | cache write |
|---|---:|---:|---:|---:|
| fitted USD / 1M | 9.06 | 46.42 | 0.26 | 19.58 |

Mean relative error **10.8 %**, max **55 %**. The residual structure matches long-context
pricing tiers (many samples sit at 250–330k cached tokens). A flat rate card is therefore an
*estimate*; the exact number is `api_request.cost_usd`, computed by Claude Code itself.

### 2.2 TTFT exists — on the log, not reliably on the span
`ttft_ms` and `first_content_ms` are present on `api_request` events (and on some
`llm_request` spans). That closes gap **G8** (`gen_ai.server.time_to_first_token`) which the
gap analysis had marked "known limitation".

## 3. What we added (processor/claude-code-agent.yaml → `transform/cc_events` + connectors)

| Datadog console signal | Our implementation | Signal |
|---|---|---|
| Spend by user / team / agent | `gen_ai.client.cost` **from `cost_usd`** (authoritative), dims `gen_ai.conversation.id`, `gen_ai.request.model`, `cc.query_source.class` (main/subagent/auxiliary/compact), `effort`, `speed`. User/org come from resource attrs already on the stream. Span rate-card figure demoted to `dt.genai.cost.estimated` + `dt.genai.cost.source` | metric |
| Average turns per session | `claude_code.turns` (count of `user_prompt` by conversation) | metric |
| Retry loops | `claude_code.tool.results{success,error_type}`, `claude_code.api.errors{status_code,attempt}`; `cc.tool.input_hash` = SHA256(tool_input) → "same call repeated N×" in DQL without exposing the input | metric + log attr |
| File rereads | `cc.tool.file_path` extracted from `tool_input` → DQL `count() by session, file_path \| filter > 1`; `claude_code.tool.result_bytes` by tool shows the context they burn | log attr + metric |
| Skipped checks | `cc.bash.class` ∈ {test, lint, build, package_manager, vcs_commit, vcs_push, vcs_pr, vcs_other, other} → session with `vcs_commit` and no earlier `test` | log attr + `claude_code.tool.results{cc.bash.class}` |
| AI-assisted commits / PRs | Claude Code's native `claude_code.commit.count` / `pull_request.count` pass through; `cc.bash.class=vcs_commit/vcs_pr` gives the same from events | native + derived |
| Permission friction (Fix Library motivation) | `claude_code.tool.decisions{decision,source}`, `claude_code.hook.executions{hook_event,cc.hook.blocked}`, `claude_code.permission_mode.changes{trigger}` | metric |
| — (not in Datadog) TTFT | `gen_ai.server.time_to_first_token` histogram from `ttft_ms` | metric |
| — (not in Datadog) context hygiene | `claude_code.compaction.tokens_reclaimed`, `claude_code.compactions`, `claude_code.subagent.duration{agent_type}` | metric |
| Proper severities | `api_error`/`internal_error`/failed `tool_result` → ERROR; refusals and rejected tools → WARN | log field |

Not reproduced (needs Datadog's SCM integration, not telemetry): median time-to-merge, change
lead time, PR review time. Those come from GitHub/GitLab webhooks, not from Claude Code.

## 4. DQL for the stateful patterns (collector stays stateless)

```sql
-- file rereads per session
fetch logs | filter event.name == "tool_result" and gen_ai.tool.name == "Read"
| summarize reads = count(), by:{gen_ai.conversation.id, cc.tool.file_path}
| filter reads > 1 | sort reads desc

-- identical tool call repeated (retry loop)
fetch logs | filter event.name == "tool_result"
| summarize n = count(), failures = countIf(success == "false"), by:{gen_ai.conversation.id, gen_ai.tool.name, cc.tool.input_hash}
| filter n >= 3

-- skipped checks: commits in sessions that never ran tests
fetch logs | filter event.name == "tool_result" and isNotNull(cc.bash.class)
| summarize commits = countIf(cc.bash.class == "vcs_commit"), tests = countIf(cc.bash.class == "test"), by:{gen_ai.conversation.id}
| filter commits > 0 and tests == 0

-- spend by who spent it
timeseries cost = sum(gen_ai.client.cost), by:{cc.query_source.class, gen_ai.request.model}

-- estimate vs truth (how wrong is the rate card today?)
timeseries { est = sum(dt.genai.cost.estimated), real = sum(gen_ai.client.cost) }
```
