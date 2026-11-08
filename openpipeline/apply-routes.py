#!/usr/bin/env python3
"""
Create the OpenPipeline dynamic routes that turn OTel host telemetry into an OTEL_HOST
Smartscape entity, using dtctl (https://github.com/dynatrace-oss/dtctl) and the active
dtctl context.

Prerequisites
  * dtctl installed and logged in (`dtctl doctor` green) against the target tenant
  * the "OpenTelemetry Host Monitoring" Hub extension (com.dynatrace.extension.opentelemetry)
    installed - it ships the three pipelines this script routes to

What it does (idempotent - re-running changes nothing once applied)
  1. metrics  : creates the routing object if the tenant has none, otherwise appends the route
  2. logs     : appends the route to the existing routing object (last position)
  3. spans    : appends the route to the existing routing object (last position)
  4. optional --link-claude-code : copies the extension's Smartscape node/edge extraction
     stages (pure id computation, extractNode=false) into the custom "Claude Code GenAI"
     pipelines, so Claude Code spans/logs that the specialised route captures still get
     dt.smartscape.otel_host and the service->host runs_on edge.

Why 2/3 append LAST: OpenPipeline routing is first-match. Putting the host route first
would steal Claude Code signals from the GenAI enrichment pipeline.

Usage
  ./openpipeline/apply-routes.py --dry-run           # show what would change
  ./openpipeline/apply-routes.py                     # apply routes
  ./openpipeline/apply-routes.py --link-claude-code  # routes + Claude Code pipeline linking
Verify afterwards (allow a few minutes):
  smartscapeNodes OTEL_HOST | fields id, name, host.id
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

HERE = os.path.dirname(os.path.abspath(__file__))
ROUTES = json.load(open(os.path.join(HERE, "routes.json")))
SIGNALS = ("metrics", "logs", "spans")
from apply_routes_lib import EXT_PIPELINE_SCHEMA  # noqa: E402
CC_PIPELINE_PREFIX = "pipeline_Claude_Code_GenAI"


from apply_routes_lib import dtctl, settings_list, write_tmp, apply_object, create_object, resolve_pipeline  # noqa: E402


def ensure_route(sig, dry_run):
    spec = ROUTES[sig]
    pipeline = resolve_pipeline(sig, spec["pipelineCustomId"])
    entry = dict(spec["entry"], pipelineId=pipeline["objectId"])
    print(f"\n[{sig}] target pipeline: {pipeline['value'].get('displayName')} ({pipeline['objectId'][-12:]})")
    routing = settings_list(spec["schema"])
    if not routing:
        print(f"[{sig}] no routing object yet -> create with 1 route")
        return create_object(spec["schema"], {"routingEntries": [entry]}, dry_run)
    obj = routing[0]
    entries = obj["value"].setdefault("routingEntries", [])
    if any(e.get("pipelineId") == entry["pipelineId"] and e.get("matcher") == entry["matcher"] for e in entries):
        print(f"[{sig}] route already present ({len(entries)} routes) -> nothing to do")
        return
    entries.append(entry)
    print(f"[{sig}] append route as #{len(entries)} (after {len(entries) - 1} existing)")
    apply_object(obj, dry_run)


def link_claude_code(dry_run):
    """Copy the extension's Smartscape extraction stages into the Claude Code GenAI pipelines."""
    for sig in ("spans", "logs"):
        ext = resolve_pipeline(sig, ROUTES[sig]["pipelineCustomId"])["value"]
        stages = {k: v for k, v in ext.items() if k in ("smartscapeNodeExtraction", "smartscapeEdgeExtraction")}
        for o in settings_list(EXT_PIPELINE_SCHEMA.format(sig=sig)):
            v = o.get("value", {})
            if not str(v.get("customId", "")).startswith(CC_PIPELINE_PREFIX):
                continue
            changed = False
            for stage, body in stages.items():
                have = {p.get("id") for p in v.get(stage, {}).get("processors", [])}
                for p in body.get("processors", []):
                    if p.get("id") not in have:
                        v.setdefault(stage, {"processors": []})["processors"].append(p)
                        changed = True
            print(f"\n[{sig}] Claude Code pipeline '{v.get('displayName')}': "
                  f"{'add Smartscape linking stages' if changed else 'already linked -> nothing to do'}")
            if changed:
                apply_object(o, dry_run)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--link-claude-code", action="store_true")
    a = ap.parse_args()
    ctx = dtctl("config", "current-context")
    print(f"dtctl context: {ctx if isinstance(ctx, str) else json.dumps(ctx)}  {'(DRY RUN)' if a.dry_run else ''}")
    for sig in SIGNALS:
        ensure_route(sig, a.dry_run)
    if a.link_claude_code:
        link_claude_code(a.dry_run)
    print("\nVerify in a few minutes:  smartscapeNodes OTEL_HOST | fields id, name, host.id")


if __name__ == "__main__":
    main()
