# Baseline: dynatrace-oss PR #353

Snapshot of the Claude Code → GenAI semconv mapping this project builds on, taken from
[dynatrace-oss/dynatrace-ai-agent-instrumentation-examples PR #353](https://github.com/dynatrace-oss/dynatrace-ai-agent-instrumentation-examples/pull/353)
(`ai-coding-agents/claude-code/`). Kept here only as the reference point for the gap analysis;
the authoritative, maintained versions live upstream.

| File | Upstream path | Role |
|---|---|---|
| `spans-pipeline.json` | `openpipeline/spans-pipeline.json` | OpenPipeline variant: span mapping + GenAI metric extraction |
| `collector-config.yaml` | `collector/config.yaml` | Collector variant of the same mapping (`transform` + `signal_to_metrics`) |

`processor/claude-code-agent.yaml` in this repository re-implements the span mapping in
`transform/cc_enrich` and layers host identity, host metrics, the events layer and the
session-analytics metrics on top. Once PR #353 is merged, the plan is to reference the upstream
collector config for the base mapping instead of duplicating it.
