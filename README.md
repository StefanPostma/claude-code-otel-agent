# claude-code-otel-agent

**OneAgent-grade observability for Claude Code — on OpenTelemetry.**

An OTel Collector–based "first agent" that lifts Claude Code's native OTel stream to the
agentic-AI coverage Dynatrace OneAgent provides: **cost attributed per session**, **cache
tokens → real token volume**, **derived GenAI metrics**, a **stable host entity** (with or
without OneAgent), **host metrics** on OneAgent-less machines, and **zero-touch auto-monitoring**
of every `claude` session on the box.

Based on the OTel GenAI semantic conventions and
[dynatrace-oss PR #353](https://github.com/dynatrace-oss/dynatrace-ai-agent-instrumentation-examples/pull/353),
verified against live data. Background notes live in [`research/`](research/).

## Status — verified, not just reviewed

| Check | Result |
|---|---|
| `otelcol-contrib validate` (0.163.1) — `processor/claude-code-agent.yaml` | ✅ valid |
| `otelcol-contrib validate` (0.163.1) — `processor/config.yaml` (generic) | ✅ valid |
| End-to-end smoke test (`test/smoke-test.sh`, real collector, debug exporter) | ✅ 46/46: span layer (cache→`gen_ai.usage.cache_*`, effective input, ratio, throughput, rate-card estimate), **events layer** (authoritative `cost_usd` → `gen_ai.client.cost`, TTFT, tool file/bash-class extraction, severities, 13 session-analytics metrics), stable `host.id`, host_metrics; 0 collector errors |
| Stable host-id derivation (`host-identity/compute-host-id.sh`, macOS) | ✅ 16-hex id, identical across runs; distinct per source |
| Windows scripts (`*.ps1`) | ⚠ syntax-reviewed, **not executed** (no Windows host here) |
| Live Dynatrace ingest through the collector (launchd service) | ✅ 2026-10-18: host metrics (gauges **and**, after `cumulative_to_delta`, counters) from the stable `host.id`; Claude Code events with authoritative cost/TTFT and spans with cache mapping from the first redirected session |
| `otel:host` entity in Smartscape (Infrastructure & Operations › Hosts) | ✅ 2026-10-19: `OTEL_HOST` node for the Mac (darwin/arm64, macOS 26.6.2) + 90 `OTEL_PROCESS` nodes, minutes after `./openpipeline/apply-routes.py --link-claude-code` — `research/host-entity-model.md` §8–9 |

## What it is

```
                 ┌──────────────── claude-code-agent.yaml (otelcol-contrib) ────────────────┐
 Claude Code ───▶│ resource_detection[dynatrace,system] → resource/host_identity (stable id) │
 spans           │ → transform/cc_enrich (cache→gen_ai, cost estimate, ratio, throughput)   │
 Claude Code ───▶│ → transform/cc_events (authoritative cost, TTFT, tool file/bash class,   │──▶ Dynatrace
 events (logs)   │     spender class, input hash, severities)                               │
                 │ → signal_to_metrics + count (GenAI + session-analytics metrics)          │
 host_metrics ──▶│   (CPU/mem/disk/net/process — only when OneAgent is absent)              │
                 └──────────────────────────────────────────────────────────────────────────┘
```

**Two sources, two truths.** Spans give the agentic *shape* (interaction → llm_request →
tool) and cache accounting. The **event stream** gives what spans never carry: Claude Code's
own `cost_usd` per request, `ttft_ms`, the tool's input, permission decisions, hooks,
compactions, subagents. The agent uses both and joins them on `gen_ai.conversation.id`.

**Why the native stream is "not enough"** (verified live): spans carry `cache_read_tokens`
= 114k while `input_tokens` = 2, and **no cost**; cost exists only as a flat aggregate metric
disconnected from spans. OneAgent-style monitoring needs cost *attributed* and cache
*accounted*.

**What it adds beyond the Grafana Claude Code dashboard (25052)** — per-conversation cost,
per-tool latency, cache-hit ratio, decode throughput, request-outcome by `stop_reason`:
[`research/metrics-proposal.md`](research/metrics-proposal.md).

**What it adds beyond Datadog's AI Agents Console for Claude Code** — Datadog renders the same
raw stream in a console (spend per user, turns/session, retry loops, file rereads, skipped
checks). We derive those as metrics and log attributes *and* keep the enrichment Datadog lacks
(cache→gen_ai, cost on spans, host entity, TTFT). Cost is **authoritative** (`cost_usd`), not a
rate-card guess — a flat rate misses long-context tiers by up to 55 %.
[`research/datadog-comparison.md`](research/datadog-comparison.md).

**The missing link OTel lacks — entity identity.** OneAgent mints a stable `HOST-xxxx` and
hands it to other telemetry via enrichment files; the `dynatrace` resource-detection detector
reads them. Where OneAgent is absent, we derive a stable `host.id` the same way OneAgent does
(`--set-host-id-source` semantics: machine-id | mac | fqdn | ip, cached) and supply the infra
layer with `host_metrics`. Honest ceiling: that reproduces OneAgent's *infrastructure* layer,
not deep-code/service topology. [`research/host-entity-model.md`](research/host-entity-model.md).

## Layout

| Path | Purpose |
|---|---|
| `processor/claude-code-agent.yaml` | **The agent.** Claude-Code-scoped collector config (entity bridge, stable host.id, host_metrics, span enrichment, **events layer**, derived metrics) |
| `processor/config.yaml` | Provider-agnostic gap filler on normalised `gen_ai.*` (any GenAI source) |
| `processor/rate-card.md` | Cost rates — keep in sync with the OTTL `tmp.rate.*` lines |
| `host-identity/compute-host-id.sh` · `Compute-HostId.ps1` | Stable host.id fallback (Linux/macOS · Windows) |
| `start-collector.sh` · `.ps1` | Derive host id, load `collector.env`, run the collector |
| `start-monitored-session.sh` | Launch one Claude Code session pointed at the collector (manual alternative to auto-monitoring) |
| `auto-monitoring/` | Install once → every `claude` session monitored: launchd / systemd / Scheduled Task + `settings.json` redirect; `install.sh`, `install.ps1`, `uninstall.sh` |
| `openpipeline/` | Tenant side of the entity bridge: `routes.json` (3 dynamic routes → OpenTelemetry Host Monitoring pipelines) + `apply-routes.py` (idempotent, via `dtctl`; `--link-claude-code` adds the Smartscape linking stages to the Claude Code GenAI pipelines) |
| `test/smoke-test.sh` + `sample-claude-code-{trace,logs}.json` + `smoke-override.yaml` | End-to-end verification (46 assertions), nothing sent to Dynatrace; `sample-trace.json` is a generic `gen_ai.*` input for `processor/config.yaml` |
| `research/` | gap-analysis · metrics-proposal · host-entity-model · **datadog-comparison** (incl. DQL for rereads / retry loops / skipped checks) · fit-fable-rates.js · `pr353-baseline/` (the upstream mapping this builds on) |

## Run

```bash
# otelcol-contrib: NO brew formula exists — install the GitHub release binary
# (https://github.com/open-telemetry/opentelemetry-collector-releases), e.g. into /opt/homebrew/bin

./test/smoke-test.sh                 # prove it works locally first (no Dynatrace traffic)

# Auto-monitoring (recommended): always-on collector + every claude session routed through it.
# Safe order: redirects settings.json ONLY after the collector is verified reachable.
./auto-monitoring/install.sh         # macOS / Linux     (Windows: auto-monitoring\install.ps1)
./auto-monitoring/uninstall.sh       # full rollback (restores settings.json backup)

# Tenant side (once per environment): host entity in Smartscape.
# 1) Dynatrace Hub → install "OpenTelemetry Host Monitoring"
# 2) with dtctl logged in to the tenant:
./openpipeline/apply-routes.py --dry-run
./openpipeline/apply-routes.py --link-claude-code
```

Then in Dynatrace:
```sql
fetch spans | filter isNotNull(gen_ai.usage.cost) | limit 5                       -- span layer
fetch logs  | filter event.name == "api_request" | fields gen_ai.usage.cost, gen_ai.server.time_to_first_token, cc.query_source.class | limit 5
timeseries cost = sum(gen_ai.client.cost), by:{cc.query_source.class}            -- who spends it
```
More (file rereads, retry loops, skipped checks): `research/datadog-comparison.md` §4.

**Event-layer prerequisites:** `tool_input` (→ `cc.tool.file_path`, `cc.bash.class`) only exists
with `OTEL_LOG_TOOL_DETAILS=1` (already on in this setup). Without it the tool metrics still
work, only the file/bash classification is absent.

## Dynatrace setup — OpenPipeline and the host entity

The collector supplies the *identity*; the tenant turns it into an *entity*. Three things have
to be in place on the Dynatrace side, once per environment. Nothing here is specific to a tenant;
the script resolves every ID at run time.

### 1. Install the OpenTelemetry Host Monitoring extension
Dynatrace Hub → **OpenTelemetry Host Monitoring** (`com.dynatrace.extension.opentelemetry`,
a current version with Smartscape-on-Grail support). It installs three *custom* OpenPipeline
pipelines named "OpenTelemetry Host Monitoring" — one each for metrics, logs and spans — and
**no routes**. Without routes the pipelines never see data and no host appears.

| Pipeline | What it does |
|---|---|
| metrics | **Creates** the `OTEL_HOST` node from `host.id` + `host.name` (properties from `os.*`, `host.arch`, cloud ids) and one `OTEL_PROCESS` per `process.executable.name`. This is the only stage that creates the host. |
| logs | Links records to the host: sets `dt.smartscape.otel_host` / `dt.smartscape.otel_process`. |
| spans | Links spans to the host and adds the `runs_on` edge SERVICE → OTEL_HOST. Requires `telemetry.sdk.name` ∈ {`opentelemetry`, `odin`, `otel`} — Claude Code does not send it, so the collector inserts it. |

### 2. Create the three dynamic routes
Settings → Process and contextualize → OpenPipeline → *Metrics / Logs / Spans* → **Dynamic
routing**, target pipeline **OpenTelemetry Host Monitoring**:

| Signal | Matcher |
|---|---|
| Metrics | `matchesValue(metric.key, {"system.*", "process.*"}) and isNotNull(host.id)` |
| Logs | `isNotNull(host.id) and isNotNull(host.name) and matchesValue(dt.openpipeline.source, "/api/v2/otlp/v1/logs")` |
| Spans | `isNotNull(host.id) and isNotNull(host.name) and matchesValue(telemetry.sdk.name, {"opentelemetry", "odin", "otel"})` |

**Order matters — routing is first-match.** If you already route Claude Code spans or logs to a
GenAI enrichment pipeline (for example the one from
[dynatrace-oss PR #353](https://github.com/dynatrace-oss/dynatrace-ai-agent-instrumentation-examples/pull/353)),
add the host routes *after* it. Otherwise Claude Code loses its GenAI mapping. The flip side is
that Claude Code signals then never reach the extension pipeline and are not linked to the host.
The fix that keeps both: copy the extension's two Smartscape stages (`smartscapeNodeExtraction`,
`smartscapeEdgeExtraction`; pure id computation, `extractNode: false`, no side effects) into
your Claude Code pipelines.

Or let the script do all of it, idempotently, with [`dtctl`](https://github.com/dynatrace-oss/dtctl)
logged in to the tenant:
```bash
./openpipeline/apply-routes.py --dry-run             # shows the 3 routes (+ 2 pipeline updates)
./openpipeline/apply-routes.py --link-claude-code    # applies; routes are appended, never reordered
```
`openpipeline/routes.json` holds the three routes; pipeline IDs are resolved by `customId`
(`extension.opentelemetry-{metrics,logs,spans}`), so the same file works on any tenant.

### 3. Verify
```sql
smartscapeNodes OTEL_HOST | fields id, name, host.id, os.type              -- the host exists
smartscapeNodes OTEL_PROCESS | summarize count()                            -- its processes
fetch spans | filter service.name == "claude-code" and isNotNull(host.id)
| summarize n = count(), linked = countIf(isNotNull(dt.smartscape.otel_host))   -- spans attached
```
`fetch dt.entity.otel:host` is not valid DQL (the colon breaks the parameter name); use
`smartscapeNodes`. Expect the host within minutes of the first routed metric batch. Two collector
prerequisites are already in the config: counters go out as **delta** (`cumulative_to_delta`;
Dynatrace drops cumulative monotonic sums silently) and `process.*` metrics are keyed by
executable name only (pid/command line stripped), otherwise cardinality explodes.
Background and evidence: [`research/host-entity-model.md`](research/host-entity-model.md) §8–9.

## Relationship to dynatrace-oss PR #353

[PR #353](https://github.com/dynatrace-oss/dynatrace-ai-agent-instrumentation-examples/pull/353)
contributes the Claude Code → GenAI semconv mapping (spans, response logs, metric extraction) to
Dynatrace's instrumentation-examples repository, as an OpenPipeline variant and a collector
variant. This repository starts from that mapping (`transform/cc_enrich` re-implements it; a
snapshot is in `research/pr353-baseline/`) and adds what an *agent* needs beyond an *example*:
stable host identity and host metrics without OneAgent, the Smartscape host entity, the event
stream with authoritative cost and TTFT, session-analytics metrics, and zero-touch
auto-monitoring. Once #353 is merged the base mapping should come from upstream rather than be
duplicated here; the pieces that generalise (authoritative cost from `api_request`, the host
recipe above) are intended as small follow-up PRs.

## Operational notes
- **Component names** in otelcol-contrib ≥ 0.16x are snake_case: `host_metrics`,
  `resource_detection`, `otlp_http`, `signal_to_metrics` (legacy spellings work only via alias).
- **Collector self-metrics** are pinned to `127.0.0.1:18888` (default `:8888` is often taken).
  If another collector already binds `4317/4318`, change the OTLP receiver ports.
- **OneAgent present?** Remove the `host_metrics` receiver (double-reporting) and leave the rest —
  the `dynatrace` detector then supplies the real `dt.entity.host`.
- **No host entity in Smartscape?** Three things must hold. (1) Dynatrace drops cumulative
  counters silently — `cumulative_to_delta/host_metrics` is in the metrics pipeline for that
  (first live run: only gauges arrived). (2) The tenant needs the **OpenTelemetry Host
  Monitoring** extension (Hub) — it is what turns `host.id`/`host.name`/`os.type`
  into an `otel:host` / `OTEL_HOST` entity; the metrics alone never create one. (3) The
  extension installs three pipelines but **no routes**: the metrics route is what creates the
  node, the logs/spans routes only link records to it. `openpipeline/apply-routes.py` creates
  all three (appended *after* existing routes — routing is first-match, and the Claude Code
  GenAI routes must keep priority); `--link-claude-code` copies the extension's Smartscape
  stages into the Claude Code pipelines so those signals link to the host too. Details and the
  exact conditions: `research/host-entity-model.md` §8–9.
- **Spans not linked to the host (`dt.smartscape.otel_host` null) while logs are?** The
  extension's span matcher needs `telemetry.sdk.name`; Claude Code spans arrive without it.
  `resource/host_identity` inserts `telemetry.sdk.name = opentelemetry` when absent.
- **Windows:** drop the `processes` scraper (Linux/macOS only); `process` needs elevated rights.
- **Service PATH (macOS):** launchd's minimal PATH lacks `/usr/sbin`; the `system` resource
  detector shells out to `ioreg` and the collector aborts without it. The plist and
  `start-collector.sh` both add `/usr/sbin:/sbin`, and `compute-host-id.sh` calls
  `/usr/sbin/ioreg` by absolute path so a service start derives the same `host.id`.
- **Secrets:** the Dynatrace token lives only in `auto-monitoring/collector.env` (gitignored,
  mode 600) — never in `settings.json` or git. Rotate any token that was ever stored in cleartext.
- **OTTL in YAML:** write conditions as block lists — flow style `[ attributes["x"] ]` breaks
  because the inner `[` opens a nested sequence.
- **Verifying with the `process` scraper on:** `process.command_line` of the test runner itself
  shows up in debug output; `test/smoke-test.sh` filters it so assertions don't self-match.
