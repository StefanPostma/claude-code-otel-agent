# Decision log

Architecture and project decisions behind the Claude Code OTel agent, with the reason for each
and the alternative that was rejected. Entries are grouped by theme, not by date. Each entry
names the file where the decision is implemented.

## 1. Scope and positioning

### D1. Build a collector-side agent, not a change to Claude Code
Claude Code already emits OTLP traces, metrics and logs. Everything missing (cost, cache
accounting, host identity, derived metrics, security logs) can be added in an OpenTelemetry
Collector between Claude Code and Dynatrace. Changing Claude Code itself would need an upstream
release cycle and would not help existing installs.
Implemented in `processor/claude-code-agent.yaml`.

### D2. Keep this repo separate from dynatrace-oss PR #353
PR #353 (the Claude Code to Dynatrace GenAI mapping) is still open and unreviewed. Folding a
much larger agent into it would stall both. This repo builds on the PR #353 mapping, keeps a
snapshot of it in `research/pr353-baseline/`, and will send small follow-up PRs upstream later
(authoritative cost from the api_request event, host recipe docs).

### D3. Target OneAgent-grade coverage, measured against a gap analysis
The reference point is what Dynatrace OneAgent provides for agentic AI workloads. The gap
analysis in `research/gap-analysis.md` lists what the native Claude Code stream lacks; the
metrics proposal in `research/metrics-proposal.md` defines what the agent adds. Features that do
not close a listed gap are out of scope.

### D4. Compare with Datadog's AI Agents Console before designing the events layer
`research/datadog-comparison.md` was written to check whether a competitor shows something the
native stream could also provide. The comparison showed that the Claude Code log stream is
richer than the span stream, which led to D9 and D10.

## 2. Collector configuration

### D5. Use otelcol-contrib with snake_case component names
The installed contrib build uses `host_metrics`, `resource_detection`, `otlp_http`,
`signal_to_metrics`. Legacy camelCase names only work through aliases, so the config uses the
snake_case names throughout to validate cleanly.

### D6. Stable host.id fallback where OneAgent is absent
Dynatrace needs a stable `host.id` to build a host entity. The `dynatrace` resource detector
wins when OneAgent is present. Without OneAgent, `host-identity/compute-host-id.sh` (and the
PowerShell twin) derives a cached 16-hex id from the machine id. The hostmetrics receiver
supplies the infrastructure layer only in that case, so a OneAgent host is never double-reported.

### D7. OTTL conditions as block lists, not flow lists
YAML flow style `[ attributes["x"] ]` breaks because the inner bracket opens a nested sequence.
All OTTL conditions and flow mappings that reference `attributes["x"]` are quoted or written
as block lists.

### D8. Shape host metrics for the OpenTelemetry Host Monitoring extension
Dynatrace silently drops cumulative counters, so `cumulative_to_delta` converts them. Per-process
resource attributes are stripped from system metrics to cut cardinality (hundreds of series per
metric before). `host.ip` is scalarised and the cpu idle state filtered. This mirrors the
Dynatrace reference host-metrics configuration rather than inventing a new shape.

## 3. Cost, tokens and the events layer

### D9. Authoritative cost comes from the api_request log event, not from a rate card
A flat per-token rate card cannot reproduce Claude's billing: the fit for the current model had an
11% mean and 55% maximum error because of long-context pricing tiers (`research/fit-fable-rates.js`).
The `api_request` event carries `cost_usd` and `ttft_ms`, which spans do not. So
`gen_ai.client.cost` is taken from logs, and the span-side estimate is kept under a separate
name, `dt.genai.cost.estimated`, so nobody mistakes it for the real figure.

### D10. Classify tool activity in the events layer
`tool_result` events carry the tool input, so `transform/cc_events` adds the file path, a SHA256
hash of the input, a bash command class (test, lint, build, vcs commit and so on) and a query
source class (main, subagent, auxiliary, compact). Hashing instead of storing the raw input keeps
prompts and file contents out of Dynatrace while still allowing grouping.

### D11. Map cache tokens to gen_ai.usage.cache_*
Claude Code reports `cache_read_tokens` and `cache_creation_tokens`, which are the real volume
(`input_tokens` is often tiny). They are mapped to the GenAI semantic attributes so cache ratio
and throughput can be derived per span.

### D12. Derive GenAI metrics in the collector with signal_to_metrics
Claude Code's native metrics are coarse aggregates disconnected from spans. The collector derives
per-conversation cost, per-tool latency, cache ratio, request outcome by stop reason and
session analytics from spans and logs, so dashboards do not depend on a separate pipeline.

## 4. Host entity and Smartscape

### D13. Metrics alone never create a host entity
The OpenTelemetry Host Monitoring extension from the Hub mints the OTEL_HOST entity from
`host.id` plus `host.name`. The extension installs three pipelines (metrics, logs, spans) but no
routes. Explained in `research/host-entity-model.md`.

### D14. Three OpenPipeline dynamic routes, appended after existing routes
Routing is first-match. Putting the host routes first would steal Claude Code signals from the
GenAI enrichment pipeline. So `openpipeline/apply-routes.py` appends the logs and spans routes
last and creates the metrics routing object if none exists.

### D15. Copy the extension's Smartscape stages into the Claude Code pipelines
Signals that the GenAI route captures never reach the extension pipeline, so they would not link
to the host. The `--link-claude-code` option copies the extension's node and edge extraction
stages (id computation only) into those pipelines instead of reordering routes.

### D16. Resolve pipelines by customId, never by object id
Settings object ids differ per tenant. `routes.json` names pipelines by customId and the apply
script resolves them at run time, so the files are tenant-agnostic and safe to publish.

### D17. Insert telemetry.sdk.name on Claude Code signals
Claude Code spans do not carry `telemetry.sdk.name`, which the extension's span matcher
requires. The collector inserts `telemetry.sdk.name=opentelemetry` in `resource/host_identity`
so spans link to the host and the service gets a runs_on edge.

### D18. Insert process.executable.name on traces and logs only
`resource/cc_process` sets `process.executable.name=claude` so spans and logs link to the
OTEL_PROCESS node and the service gets a runs_on edge to the process. It is deliberately not
applied to metrics, because that would tag every system metric as the claude process.

### D19. Enable the reference per-process metric set, without the low-memory filter
`process.cpu.utilization` is off by default in hostmetrics, and without it the host page
Processes tab shows only a count. The agent enables the same per-process set as the Dynatrace
reference (cpu utilization, cpu time, memory usage, memory virtual, disk io). The reference's
filter that hides processes below 1 MiB was rejected: the user wants the complete process list.

## 5. Always-on monitoring kit

### D20. Redirect Claude Code's settings only after the collector is verified reachable
`auto-monitoring/install.sh` points `~/.claude/settings.json` at the local collector only after
a health check succeeds. Otherwise a failed collector would silently stop all telemetry.

### D21. Move the Dynatrace token out of settings into a gitignored, mode-600 env file
Claude Code's settings held the API token in plaintext in an OTLP header. The kit moves it into
`auto-monitoring/collector.env`, which is gitignored and readable only by the user. The example
file ships without a token.

### D22. Service PATH includes /usr/sbin
launchd's default PATH lacks `/usr/sbin`, so the system resource detector could not run `ioreg`
and the collector failed on first start. The plist template, `start-collector.sh` and the host id
script use the full path.

### D23. Collector self-metrics on 127.0.0.1:18888
Other collectors on the machine may hold the default 8888 port. The agent pins its own telemetry
to a loopback port that nothing else uses.

### D24. Installer and settings changes are run by the user, not by the agent
Changing persistence (launchd services) and the user's own Claude settings is a user action. The
scripts exist so the step is one command; the agent only prepares and verifies.

## 6. Testing

### D25. Smoke test runs the real collector with the debug exporter on private ports
`test/smoke-test.sh` starts otelcol-contrib on its own ports (14317, 14318, 28888) with the debug
exporter instead of Dynatrace, replays the sample traces and logs and asserts on the output.
Nothing is sent to a tenant. Running on the live ports would hit the running collector and fail
every assertion silently.

### D26. Assertions live in a file and filter process.command_line
The hostmetrics process scraper dumps multi-line command lines into the debug output. An inline
test script would match its own assertion strings. Tests therefore live in a file and filter the
command line attribute before matching.

## 7. macOS security events and logs

### D27. Poll the unified log with `log show`, ship as NDJSON through filelog
macOS has no syslog socket for security events. `macos-security/macos-security-log.sh` polls
`/usr/bin/log show --style ndjson` with a cursor, writes daily NDJSON files, and the collector's
`filelog/macos_security` receiver parses them with a checkpointed `file_storage` extension. The
full path is used because `log` is a zsh builtin.

### D28. Predicates define categories; noisy sources are disabled by default
`macos-security/predicates.json` selects authentication, authorization, privilege escalation,
account management, security policy, privacy (TCC), software changes, firewall and launch
persistence. TCC grants are disabled because of volume. sudo debug chatter and XPC lines were
excluded after the first live run produced false positives.

### D29. Endpoint Security via eslogger as an optional root tier
Apple's `eslogger` gives process, file and login events but needs root and Full Disk Access, so
`macos-security/eslogger-sidecar.sh` is optional and not started automatically. Red Canary's Mac
Monitor was evaluated and rejected because it is GUI-only and does not stream.

### D30. Sidecar lifecycle owned by start-collector.sh
`start-collector.sh` no longer `exec`s the collector. It starts the poller in the background,
runs the collector, traps TERM and INT, stops both and waits, so launchd restarts keep the pair
in sync. `MACOS_SECURITY_LOGS=0` disables the feature.

### D31. OpenPipeline rule set maps to the Semantic Dictionary and emits security events
`openpipeline/macos-security.json` follows the same convention as the user's Windows event log
and auditd pipelines: `event.provider`, `event.category`, `event.type`, `event.outcome`,
`user.name`, `source.ip`, `process.*`. A securityEvent data extraction fires only for
authentication failures, IAM, malware and persistence, so routine successes stay as logs.

### D32. The macOS route is inserted before the extension route
Unlike the host routes (D14), the macOS route must win over the generic OTel logs route, so
`apply-macos-security.py` inserts it directly before the extension's logs route.

### D33. Matchers use matchesValue, processors use DQL functions
OpenPipeline matchers cannot use `contains()`, so matchers use `matchesValue(content, "* : *")`.
DQL processor scripts can use `contains`, `startsWith` and `parse`. DPL has no PATH pattern, so
paths are parsed with LD. `dtctl create settings --validate-only` validates DQL server-side.

### D34. Shared dtctl helpers in a library module
`openpipeline/apply_routes_lib.py` holds the dtctl, settings list, create and update helpers so
`apply-routes.py` and `apply-macos-security.py` behave the same and stay idempotent.

## 8. Publishing and repository rules

### D35. Tenant-agnostic, personal-detail-free public repo
No tenant names, hostnames, host ids, entity ids, session ids or tool context names appear in
the repo or its history. Configs resolve tenant-specific ids at run time (D16). A publish guard
scans every push.

### D36. No Dynatrace extension or app version numbers in docs
Version numbers go stale and invite support questions. Docs describe behaviour, not versions.

### D37. Research notes are undated technical notes, not a troubleshooting diary
The host entity model was condensed to prerequisites, what the extension installs and why three
routes are needed. Dated first-run narratives and tenant state were removed, and a separate
runtime findings note was deleted from the repo and its history.

### D38. Describe analysis as derived from documentation and live inspection
OneAgent behaviour was analysed from what it emits and from Dynatrace documentation, with live
DQL against a test tenant. No binary analysis was done, and the repo uses that wording.

### D39. Apply scripts support --dry-run and are run by the user
`dtctl create` and `apply` change tenant configuration. The scripts print a dry run first; the
user runs the real apply.

### D40. Git attribution and publish guard
Commits use the GitHub noreply author, carry co-author trailers, and the publish guard runs
before every push to the public remote. History rewrites use a root rebase with a scrub script
and a force push with lease.
