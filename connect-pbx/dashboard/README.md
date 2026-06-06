# Connect PBX Dashboard

This is a lightweight local deployment dashboard for the `connect-pbx` repo.

It does not implement a separate deployment engine. Instead, it wraps the
existing repo contracts:

- `modules/dependency-order.json`
- `environments/<env>/deployment-manifest.json`
- `scripts/tf-run.sh`

## What it does

- lets you choose an environment
- shows manifest-enabled modules
- lets you select one or more modules to deploy
- auto-adds required dependencies
- shows execution order before anything runs
- runs `plan` or `apply` sequentially through `tf-run.sh`

## What it does not do

- it does not edit manifests
- it does not bypass dependency checks
- it does not replace the teardown/redeploy scripts
- it keeps PRD-10 and PRD-11 retained by default, but can run an explicitly approved operator destroy for them

## Run it

From `connect-pbx`:

```bash
python dashboard/app.py
```

Then open:

```text
http://127.0.0.1:8765
```

Optional flags:

```bash
python dashboard/app.py --host 127.0.0.1 --port 8765
```

## Notes

- The backend expects Git Bash to be installed because it shells into
  `scripts/tf-run.sh`.
- The dashboard sets `CONNECT_PBX_NONINTERACTIVE=1` for its own runs so the
  existing runner can execute without prompt loops.
- Manual CLI usage of `tf-run.sh` is unchanged.
