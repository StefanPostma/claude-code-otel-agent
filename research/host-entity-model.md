# The missing link: OneAgent's host-entity model vs OTel

Derived from Dynatrace docs and live/local inspection (2026-10-17).
This is the piece OTel genuinely lacks — not a *signal*, but an *identity and
topology model*. Our Claude Code agent can borrow it.

## 1. The gap in one sentence
OpenTelemetry gives you **resource attributes** — `host.name="my-box"` is just a
string, re-asserted independently by every exporter, with no identity resolution,
no dedup, and no relationships. Dynatrace gives you **entities** — `HOST-6E56EE455C84E232`
is a stable managed object with a computed ID, deduplicated across every signal,
and wired into a topology graph (`PROCESS_GROUP_INSTANCE —runs_on→ HOST`,
`SERVICE —runs_on→ PGI`, `PGI —belongs_to→ PROCESS_GROUP`). Claude Code's OTel
stream today has `service.name=claude-code` and nothing else — it floats, unattached
to any host, process, or user topology. That is what we fix.

## 2. How OneAgent manufactures host identity
- At startup OneAgent computes a **host unique identifier** from a configurable
  source: `oneagentctl --set-host-id-source=<auto|ip-addresses|mac-addresses|fqdn>`
  (default `auto`), with an optional namespace for multi-environment disambiguation.
- That identifier is hashed/registered server-side into the Smartscape entity id
  **`HOST-xxxxxxxxxxxxxxxx`** (16 uppercase hex) — the id you see in a Host page URL.
- It is **persisted locally** and readable with `oneagentctl --get-host-id`, so the
  *same* host keeps the *same* entity id across restarts, IP changes, etc. (depending
  on the chosen source). This stability is the whole point: it is what lets Dynatrace
  merge metrics, traces, logs, events and processes onto one host object.

## 3. How that identity is handed to *other* telemetry — the enrichment files
OneAgent exposes the resolved entity identity through **enrichment files** so that
any process on the box (including an OTel SDK/Collector) can stamp its data with the
right Dynatrace entity ids:

| | Location | Scope | Nature |
|---|----------|-------|--------|
| **Host metadata** | `/var/lib/dynatrace/enrichment/dt_host_metadata.{json,properties}` (Unix) · `%ProgramData%\dynatrace\enrichment\…` (Windows) | host-level, all processes | **real files on disk** |
| **Virtual per-process** | `dt_metadata_e617c525669e072eebe3d0f08212e8f2.{json,properties}` | the *instrumented process* (process-group-instance) | **not on disk** — the magic-hash filename is intercepted by the OneAgent code module and served from memory for the calling process |

Contents (host file): host-level resource attributes incl. **`dt.entity.host`**,
`host.name`, **`dt.smartscape.host`**, plus any tags/properties set via `oneagentctl`.
The virtual per-process file additionally resolves the **process** identity:
`dt.entity.process_group_instance`, `dt.entity.process_group`, back to `dt.entity.host`.

The virtual-file trick is the clever bit: an app reads a fixed, bogus-looking
filename; if OneAgent is injected, the code module returns live entity ids; if not,
the read simply fails and the app degrades gracefully.

## 4. The OTel bridge (what we add to the agent)
The OTel Collector's `resource_detection` processor with the **`dynatrace` detector**
reads the host enrichment file and attaches the entity ids to every span/metric/log:

```yaml
processors:
  resource_detection/dynatrace:
    detectors: [dynatrace, system]   # dynatrace = OneAgent enrichment file; system = fallback
    override: false                  # never clobber ids the source already set
```

It adds `dt.entity.host`, `host.name`, `dt.smartscape.host`. With these present,
Claude Code's spans land **on the actual HOST entity** in Smartscape, and its process
can be resolved to a `PROCESS_GROUP_INSTANCE` that `runs_on` that host — so agent
cost/tokens/latency sit next to the host's CPU, memory, and the other processes it runs.

## 5. When OneAgent is NOT on the host (e.g. this macOS dev box)
There is no enrichment file, so the `dynatrace` detector finds nothing — confirmed
here: `/var/lib/dynatrace/enrichment` does not exist. Two degraded options:
1. **`system` detector fallback** — emit OTel-standard `host.name`, `host.id`,
   `os.type`. Dynatrace's **OTel-native entity model** then builds a host entity from
   those semantic-convention attributes (weaker than OneAgent: no deep process/service
   topology, identity only as stable as `host.id`).
2. **Mirror OneAgent's host-id-source** — derive a stable `host.id` yourself from the
   machine-id / primary MAC / FQDN (the same inputs OneAgent's `--set-host-id-source`
   uses), so the OTel-built host entity stays stable across restarts.

> Bottom line: for *true* Smartscape membership (host + process-group topology), the
> host needs OneAgent and the agent just reads its enrichment file. Without OneAgent,
> we can still give Claude Code a stable host entity via `host.id`/`host.name`, but the
> rich `runs_on`/`belongs_to` topology is OneAgent's to provide — that is exactly the
> link OTel alone cannot manufacture.

## 6. The stable fallback — implemented, cross-platform
`host-identity/compute-host-id.sh` (Linux/macOS) and `host-identity/Compute-HostId.ps1`
(Windows) reproduce OneAgent's `--set-host-id-source` locally:
- source ∈ `machine-id` (default) · `mac` · `fqdn` · `ip`, with optional `HOST_ID_NAMESPACE`
  - machine-id: `/etc/machine-id` → `IOPlatformUUID` (macOS) → `HKLM\…\Cryptography\MachineGuid` (Windows)
- SHA-256 → first **16 hex, uppercase** (OneAgent HOST-xxxx style), **cached** so the id
  is stable across restarts (`~/.dynatrace-otel/host-id` · `%ProgramData%\dynatrace-otel\host-id`).

Verified on macOS: machine-id → a 16-hex id (identical across runs); `mac` and
`fqdn`+namespace yield distinct, each-stable ids.

`start-collector.{sh,ps1}` derive+export `STABLE_HOST_ID`/`STABLE_HOST_NAME`, then launch
the collector. In `claude-code-agent.yaml` the `resource/host_identity` processor injects
them with `action: insert` — so OneAgent's `dynatrace` detector always wins when present,
and the stable id fills in only on a OneAgent-less host. Windows OneAgent enrichment
(`%ProgramData%\dynatrace\enrichment`) is read by the same `dynatrace` detector — no
config change needed per-OS.

## 7. Infra layer on a OneAgent-less host (host_metrics receiver)
When OneAgent is absent, the entity we create is empty of infrastructure data. The
`host_metrics` receiver fills that: it scrapes `system.cpu.*`, `system.memory.*`,
`system.disk.*`, `system.filesystem.*`, `system.network.*`, `system.paging.*`,
`system.processes.*`, `system.uptime`, and per-`process.*` metrics, which flow through
the **same** `resource_detection` + `resource/host_identity` processors — so they bind to
the same `host.id`/`host.name` as the Claude Code telemetry. The host then appears in
Dynatrace with real infra charts, and the agent runs "on" it.

**Honest scope — this is NOT true full-stack OneAgent.** It reproduces OneAgent's
*infrastructure* layer (host + process resource metrics) only. It does **not** provide:
deep-code auto-instrumentation, automatic service/PGI discovery and the Smartscape
`runs_on`/`calls`/`belongs_to` topology graph, log auto-discovery, PurePath/code-level
tracing, or RUM. Those remain OneAgent-exclusive. Enable `host_metrics` **only** where
OneAgent is not installed — running both double-reports host metrics.

## 8. Why the metrics arrived but no host appeared in Smartscape (2026-10-18, live)
First live run through the launchd collector: `system.*` metrics with `host.id`/`host.name`/
`os.type` were on the test tenant within minutes — yet Infrastructure & Operations › Hosts showed nothing
and `smartscapeNodes OTEL_HOST` returned zero rows. Three independent causes, all verified:

| # | Cause | Evidence | Fix |
|---|---|---|---|
| 1 | **Cumulative counters are dropped silently.** Dynatrace ingests delta sums only; the collector logs no warning. | `fetch metric.series` showed only gauges (utilization, usage, load, counts). `system.cpu.time`, `system.network.io`, `system.disk.io`, `system.paging.operations`, `process.cpu.time` were absent. | `cumulative_to_delta/host_metrics` (scoped to `^system\.`/`^process\.`) — as in Dynatrace's reference `host-metrics.yaml`. |
| 2 | **Metrics never create an entity by themselves.** The `otel:host` (Smartscape `OTEL_HOST`) entity is minted by the **OpenTelemetry Host Monitoring extension** from `host.id` + `host.name` (+ `os.type`). | Docs: "Without the extension no host entity is created." | Activate the extension from Dynatrace Hub (a current version with Smartscape-on-Grail support). Tenant-side; cannot be done from the collector. |
| 3 | **Smartscape needs routing.** The extension only sees data routed to its pipeline. | `OTEL_HOST` requires three OpenPipeline dynamic routes. | Settings › Process and contextualize › OpenPipeline, target pipeline **OpenTelemetry Host Monitoring**: <br>• Metrics: `matchesValue(metric.key, {"system.*", "process.*"}) AND isNotNull(host.id)` <br>• Logs: `isNotNull(host.id) and isNotNull(host.name) and matchesValue(dt.openpipeline.source, "/api/v2/otlp/v1/logs")` <br>• Spans: `isNotNull(host.id) and isNotNull(host.name) and matchesValue(telemetry.sdk.name, {"opentelemetry", "odin", "otel"})` |

Also aligned with the reference config: cpu `idle` state filtered, `process.*` resource
identity reduced to `process.executable.name` (pid/command_line/args/owner/path dropped — the
first run produced 936 series per process metric), `host.ip` scalarised, extra system-detector
facts (`host.arch`, `host.ip`, `host.mac`, `host.cpu.model.name`, `os.name`, `os.version`,
`os.build.id`) so the extension can fill the entity's properties.

**What this means for the "missing link".** On a OneAgent-less host the entity is not
produced by the collector but by the tenant-side extension, from the identity the collector
supplies. Our stable `host.id` is therefore the *key*; the extension is the *lock*. With both
in place the Claude Code spans/logs (which carry the same `host.id`) attach to the `OTEL_HOST`
node — the OneAgent-style "agent runs on this host" view.

Verification once the extension and routes are active:
```sql
smartscapeNodes OTEL_HOST | fields id, name, host.id, os.type
```
(`fetch dt.entity.otel:host` is **not** accepted by the DQL parser on the test tenant — the colon breaks the
parameter name; use `smartscapeNodes OTEL_HOST`.)

## 9. What the extension actually installs (read live via dtctl, 2026-10-18)
The **com.dynatrace.extension.opentelemetry** extension was installed on the test tenant. It does not add
processors to existing pipelines; it installs three *custom* pipelines as Settings 2.0 objects
(`builtin:openpipeline.{metrics,logs,spans}.pipelines`, `customId` =
`extension.opentelemetry-{metrics,logs,spans}`, displayName "OpenTelemetry Host Monitoring"),
and **no routes**. Their content explains the three-route requirement precisely:

| Pipeline | Stage | Processor | Effect |
|---|---|---|---|
| metrics | smartscapeNodeExtraction | `OTEL_HOST_host_metrics_extraction` — matcher `matchesValue(metric.key, {"system.*", "process.*"}) AND isNotNull(host.id)` | **`extractNode: true`** → this is the only place the `OTEL_HOST` node is *created*; id components `host.id`+`host.name`, properties from `os.*`, `host.arch`, cloud ids, `dt.host_group.id` |
| metrics | smartscapeNodeExtraction | `OTEL_PROCESS_process_extraction` — `process.*` AND `process.executable.name` AND `host.id` | creates `OTEL_PROCESS` nodes (one per executable name — hence our pid/command_line stripping) |
| metrics | smartscapeNodeExtraction | AWS_EC2 / AZURE_VM / GCP id computation | `extractNode: false`; only computes the cloud-VM id for correlation |
| logs | smartscapeNodeExtraction | `OTEL_HOST_logs_enrichment`, `OTEL_PROCESS_logs_enrichment` | `extractNode: false` → only writes `dt.smartscape.otel_host` / `dt.smartscape.otel_process` onto the record (linking) |
| spans | smartscapeNodeExtraction | `OTEL_HOST_spans_enrichment`, `OTEL_PROCESS_spans_enrichment` | same linking fields on spans |
| spans | smartscapeEdgeExtraction | `OTEL_HOST_service_linking`, `OTEL_PROCESS_service_linking` | `runs_on` edge SERVICE → OTEL_HOST / OTEL_PROCESS when `dt.smartscape.service` is set |

Consequences:
- **Only the metrics route creates the host.** Logs/spans routes are about *linking* and the
  service→host edge. So the Smartscape Hosts view appears as soon as the metrics route is active.
- **Routing is first-match.** the test tenant already routes `service.name == "claude-code"` spans and
  `assistant_response`/`user_prompt` logs to the custom "Claude Code GenAI" pipelines. Putting
  the host route *before* them would strip Claude Code of its GenAI enrichment; putting it
  *after* means Claude Code signals never reach the extension pipeline and get no
  `dt.smartscape.otel_host`. The fix that keeps both is to copy the extension's two Smartscape
  stages (pure id computation, no side effects) into the Claude Code pipelines —
  `openpipeline/apply-routes.py --link-claude-code` does exactly that.
- the test tenant state before applying: metrics routing object **absent** (0 routes), logs routing 13 routes
  (OCSF/syslog project + Claude Code GenAI logs), spans routing 1 route (Claude Code GenAI).

**Result (2026-10-19, user ran `apply-routes.py --link-claude-code`).** Within minutes:
an `OTEL_HOST-…` node named after the Mac (host.id = the 16-hex machine-id derivative, darwin/arm64,
macOS 26.6.2) plus ~90 `OTEL_PROCESS` nodes; host-metric series carry
`dt.smartscape.otel_host` from the first 10-minute bucket after the apply. Claude Code **logs**
link immediately (`dt.smartscape.otel_host` set in both the extension pipeline and the Claude
Code GenAI logs pipeline). Claude Code **spans did not link**: the extension's span matcher
also requires `telemetry.sdk.name ∈ {opentelemetry, odin, otel}`, and Claude Code's spans reach
Grail without any `telemetry.sdk.*` attribute. Fix in the collector, not the tenant:
`resource/host_identity` now *inserts* `telemetry.sdk.name = opentelemetry` when absent. The
spans already carry `dt.smartscape.service`, so the `runs_on` SERVICE → OTEL_HOST edge follows.

**No regression for the GenAI app.** The Claude Code GenAI pipelines' `processing` and
`metricExtraction` stages are byte-identical before/after the linking update (only the two
Smartscape stages were added), and every `claude_code.llm_request` span of the last 26 h has
`gen_ai.provider.name`, `gen_ai.system`, `gen_ai.operation.name`, `gen_ai.request.model`,
`gen_ai.response.model` and token counts (100 % per hour). A "no data" view in the GenAI
Observability app on 2026-10-19 coincided with a 5-hour gap without any Claude Code activity
(12:48–17:46 UTC), not with the routing change.

**Tooling.** The Dynatrace MCP (remote gateway) exposes no OpenPipeline or
Settings tool, and the collector's API token has no `settings:*` scope. `dtctl` (logged in to the test tenant) can read and write the settings objects;
`dtctl create settings --validate-only` accepted the metrics route (the server validates the
matcher). `dtctl verify openpipeline-matcher` needs `openpipeline:configurations:read`, which the
OAuth session lacks — the settings validation covers it. Writing the routes from an agent session
was blocked by Claude Code's auto-mode policy ("Protected-Scope IaC Apply"), so the apply is a
user-run step: `./openpipeline/apply-routes.py` (idempotent; `--dry-run` first).
