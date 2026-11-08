"""dtctl helpers shared by apply-routes.py and apply-macos-security.py."""
import json, os, subprocess, sys, tempfile

EXT_PIPELINE_SCHEMA = "builtin:openpipeline.{sig}.pipelines"


def dtctl(*args, input_file=None):
    cmd = ["dtctl", *args, "--plain", "-o", "json"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout.strip()
    try:
        env = json.loads(out)
    except json.JSONDecodeError:
        if r.returncode != 0:
            sys.exit(f"dtctl {' '.join(args)} failed:\n{out}\n{r.stderr}")
        return out
    if isinstance(env, dict) and env.get("ok") is False:
        sys.exit(f"dtctl {' '.join(args)} failed: {json.dumps(env.get('error'))}")
    return env.get("result", env) if isinstance(env, dict) else env


def settings_list(schema):
    res = dtctl("get", "settings", "--schema", schema, "--scope", "environment")
    return res if isinstance(res, list) else [res]


def write_tmp(obj):
    fd, path = tempfile.mkstemp(suffix=".json", prefix="op-route-")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1)
    return path


def apply_object(obj, dry_run):
    keep = {k: obj[k] for k in ("objectId", "schemaId", "schemaVersion", "scope", "value") if k in obj}
    path = write_tmp(keep)
    args = ["apply", "-f", path] + (["--dry-run"] if dry_run else [])
    print("   ", "dtctl", *args)
    print("   ", json.dumps(dtctl(*args))[:300])


def create_object(schema, value, dry_run):
    path = write_tmp(value)
    args = ["create", "settings", "-f", path, "--schema", schema, "--scope", "environment"]
    args += ["--dry-run"] if dry_run else []
    print("   ", "dtctl", *args)
    print("   ", json.dumps(dtctl(*args))[:300])


def resolve_pipeline(sig, custom_id):
    for o in settings_list(EXT_PIPELINE_SCHEMA.format(sig=sig)):
        if o.get("value", {}).get("customId") == custom_id:
            return o
    sys.exit(f"[{sig}] pipeline with customId={custom_id} not found - is the OpenTelemetry Host "
             f"Monitoring extension installed? (dtctl get extensions | grep opentelemetry)")


