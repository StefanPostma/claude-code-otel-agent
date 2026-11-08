#!/usr/bin/env python3
"""
Apply the macOS security OpenPipeline rule set (openpipeline/macos-security.json) with dtctl.

  1. pipeline : create the custom logs pipeline `pipeline_macos_security`, or update it in
                place (matched by customId) so edits to the JSON are re-applied
  2. link     : copy the OpenTelemetry Host Monitoring extension's Smartscape stage into it,
                so records still get dt.smartscape.otel_host / otel_process (first-match
                routing means they no longer pass the extension pipeline)
  3. route    : insert the route BEFORE the extension's host route (or append if absent);
                idempotent — an existing route with the same matcher is updated, not duplicated

Usage
  ./openpipeline/apply-macos-security.py --dry-run
  ./openpipeline/apply-macos-security.py
Verify (after a few minutes of sidecar output):
  fetch logs | filter log.source == "macos:unified_log" | summarize count(), by:{event.category, event.outcome}
  fetch security.events | filter event.provider == "macos" | limit 10
"""
import argparse, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from apply_routes_lib import dtctl, settings_list, resolve_pipeline, apply_object, create_object  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(os.path.join(HERE, "macos-security.json")))
EXT_LOGS_CUSTOM_ID = "extension.opentelemetry-logs"


def ensure_pipeline(dry_run):
    want = SPEC["pipeline"]["value"]; schema = SPEC["pipeline"]["schema"]
    existing = [o for o in settings_list(schema) if o.get("value", {}).get("customId") == want["customId"]]
    # Smartscape linking stage from the extension pipeline (pure id computation, no side effects)
    try:
        ext = resolve_pipeline("logs", EXT_LOGS_CUSTOM_ID)["value"]
        for stage in ("smartscapeNodeExtraction", "smartscapeEdgeExtraction"):
            if stage in ext:
                want[stage] = ext[stage]
    except SystemExit:
        print("   (OpenTelemetry Host Monitoring extension not installed — pipeline created without Smartscape linking)")
    if existing:
        obj = existing[0]
        keep = {k: v for k, v in obj["value"].items() if k not in want}  # preserve stages we do not manage
        obj["value"] = {**keep, **want}
        print(f"[pipeline] update '{want['displayName']}' ({obj['objectId'][-12:]})")
        apply_object(obj, dry_run)
        return obj["objectId"]
    print(f"[pipeline] create '{want['displayName']}'")
    create_object(schema, want, dry_run)
    if dry_run:
        return None
    return next(o["objectId"] for o in settings_list(schema) if o.get("value", {}).get("customId") == want["customId"])


def ensure_route(pipeline_id, dry_run):
    r = SPEC["route"]; entry = dict(r["entry"], pipelineId=pipeline_id or "<new pipeline objectId>", pipelineType="custom")
    routing = settings_list(r["schema"])
    if not routing:
        print("[route] no logs routing object yet -> create with 1 route")
        return create_object(r["schema"], {"routingEntries": [entry]}, dry_run)
    obj = routing[0]; entries = obj["value"].setdefault("routingEntries", [])
    for i, e in enumerate(entries):
        if e.get("matcher") == entry["matcher"]:
            if e.get("pipelineId") == entry["pipelineId"] and e.get("description") == entry["description"]:
                print(f"[route] already present at #{i + 1} -> nothing to do"); return
            entries[i] = entry; print(f"[route] update existing route #{i + 1}"); return apply_object(obj, dry_run)
    try:
        ext_id = resolve_pipeline("logs", EXT_LOGS_CUSTOM_ID)["objectId"]
        pos = next((i for i, e in enumerate(entries) if e.get("pipelineId") == ext_id), len(entries))
    except SystemExit:
        pos = len(entries)
    entries.insert(pos, entry)
    print(f"[route] insert at #{pos + 1} of {len(entries)} (before the OpenTelemetry Host Monitoring route)")
    apply_object(obj, dry_run)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    ctx = dtctl("config", "current-context")
    print(f"dtctl context: {ctx if isinstance(ctx, str) else json.dumps(ctx)}  {'(DRY RUN)' if a.dry_run else ''}")
    pid = ensure_pipeline(a.dry_run)
    ensure_route(pid, a.dry_run)
    print("\nVerify:  fetch logs | filter log.source == \"macos:unified_log\" | summarize count(), by:{event.category, event.outcome}")


if __name__ == "__main__":
    main()
