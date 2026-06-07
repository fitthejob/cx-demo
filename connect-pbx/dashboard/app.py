#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socket import error as SocketError
from typing import Any
from urllib.parse import parse_qs, urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
DASHBOARD_ROOT = Path(__file__).resolve().parent
STATIC_ROOT = DASHBOARD_ROOT / "static"
CATALOG_PATH = REPO_ROOT / "modules" / "dependency-order.json"
ENVIRONMENTS_ROOT = REPO_ROOT / "environments"
TF_RUNNER = REPO_ROOT / "scripts" / "tf-run.sh"
BOOTSTRAP_MODULE_PATH = "modules/bootstrap"
BOOTSTRAP_TFVARS_PATH = REPO_ROOT / "modules" / "bootstrap" / "bootstrap.tfvars"
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
OUTPUT_BLOCK_RE = re.compile(r'^\s*output\s+"([^"]+)"', re.MULTILINE)
TFVARS_STRING_RE = r'^\s*{key}\s*=\s*"([^"]*)"\s*$'


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def ordered_modules(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    return catalog.get("modules", [])


def module_map(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {module["path"]: module for module in ordered_modules(catalog)}


def capability_pack_map(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {pack["id"]: pack for pack in catalog.get("capability_packs", [])}


def reverse_dependency_map(catalog: dict[str, Any]) -> dict[str, list[str]]:
    reverse: dict[str, list[str]] = {module["path"]: [] for module in ordered_modules(catalog)}
    for module in ordered_modules(catalog):
        for dependency in module.get("dependencies", []):
            reverse.setdefault(dependency, []).append(module["path"])
    return reverse


def supports_operator_destroy(module: dict[str, Any]) -> bool:
    return bool(module.get("supports_operator_destroy", False))


def dashboard_destroyable(module: dict[str, Any]) -> bool:
    return bool(module.get("supports_destroy", False) or supports_operator_destroy(module))


def resolve_enabled_module_paths(catalog: dict[str, Any], manifest: dict[str, Any]) -> list[str]:
    modules = ordered_modules(catalog)
    modules_by_path = module_map(catalog)
    packs_by_id = capability_pack_map(catalog)
    enabled: set[str] = set()

    for pack_id in manifest.get("enabled_capability_packs", []):
        if pack_id not in packs_by_id:
            raise ValueError(f"Unknown capability pack in manifest: {pack_id}")
        for module in modules:
            if pack_id in module.get("capability_packs", []):
                enabled.add(module["path"])

    for module_path in manifest.get("enabled_modules", []):
        if module_path not in modules_by_path:
            raise ValueError(f"Unknown enabled module in manifest: {module_path}")
        enabled.add(module_path)

    for module_path in manifest.get("disabled_modules", []):
        if module_path not in modules_by_path:
            raise ValueError(f"Unknown disabled module in manifest: {module_path}")
        if modules_by_path[module_path]["classification"] == "core-required":
            raise ValueError(f"Manifest cannot disable core-required module: {module_path}")
        enabled.discard(module_path)

    for module in modules:
        path = module["path"]
        if path not in enabled:
            continue
        for dependency in module.get("dependencies", []):
            if dependency not in modules_by_path:
                raise ValueError(f"Module {path} depends on unknown module {dependency}")
            if dependency not in enabled:
                raise ValueError(f"Enabled module {path} requires disabled dependency {dependency}")

    return [module["path"] for module in modules if module["path"] in enabled]


def available_environments() -> list[str]:
    preferred = ["dev", "staging", "prod"]
    discovered = [
        path.name
        for path in ENVIRONMENTS_ROOT.iterdir()
        if path.is_dir() and (path / "deployment-manifest.json").exists()
    ]
    ordered = [env for env in preferred if env in discovered]
    ordered.extend(sorted(env for env in discovered if env not in ordered))
    return ordered


def environment_manifest_path(environment: str) -> Path:
    return ENVIRONMENTS_ROOT / environment / "deployment-manifest.json"


def read_tfvar_string(path: Path, key: str) -> str | None:
    if not path.exists():
        return None

    pattern = re.compile(TFVARS_STRING_RE.format(key=re.escape(key)), re.MULTILINE)
    match = pattern.search(path.read_text(encoding="utf-8"))
    if match is None:
        return None
    return match.group(1)


def bootstrap_repo_name() -> str:
    github_repo = read_tfvar_string(BOOTSTRAP_TFVARS_PATH, "github_repo")
    if github_repo:
        return github_repo

    raise FileNotFoundError(
        f"github_repo is not set in {BOOTSTRAP_TFVARS_PATH}. "
        "Update modules/bootstrap/bootstrap.tfvars or set CONNECT_PBX_BOOTSTRAP_DIR explicitly."
    )


def bootstrap_github_org() -> str:
    github_org = read_tfvar_string(BOOTSTRAP_TFVARS_PATH, "github_org")
    if github_org:
        return github_org

    raise FileNotFoundError(
        f"github_org is not set in {BOOTSTRAP_TFVARS_PATH}. "
        "Update modules/bootstrap/bootstrap.tfvars."
    )


def bootstrap_repo_slug() -> str:
    return f"{bootstrap_github_org()}/{bootstrap_repo_name()}"


def bootstrap_artifact_dir() -> Path:
    if os.environ.get("CONNECT_PBX_BOOTSTRAP_DIR"):
        return Path(os.environ["CONNECT_PBX_BOOTSTRAP_DIR"])
    github_repo = bootstrap_repo_name()
    if os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "connect-pbx" / github_repo / "bootstrap"
    return Path.home() / ".connect-pbx" / github_repo / "bootstrap"


def backend_config_path() -> Path:
    profile_name = os.environ.get("AWS_PROFILE", "default")
    return bootstrap_artifact_dir() / f"backend-{profile_name}.hcl"


def parse_backend_config(path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    if not path.exists():
        return config

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip()] = value.strip().strip('"')
    return config


def collect_github_status(environment: str) -> dict[str, Any]:
    repo_slug = bootstrap_repo_slug()
    gh = shutil.which("gh")
    status: dict[str, Any] = {
        "repo": repo_slug,
        "gh_cli_available": gh is not None,
        "gh_authenticated": False,
        "environment_status": "unknown",
        "bootstrap_secrets_status": "unknown",
        "prd02_secret_status": "unknown",
        "cicd_readiness": "unknown",
        "detail": "",
    }

    if gh is None:
        status["detail"] = "GitHub CLI not found in PATH."
        return status

    auth = subprocess.run([gh, "auth", "status"], capture_output=True, text=True, check=False)
    if auth.returncode != 0:
        stderr = (auth.stderr or "").strip()
        stdout = (auth.stdout or "").strip()
        status["detail"] = stderr or stdout or "GitHub CLI is not authenticated."
        return status

    status["gh_authenticated"] = True

    environment_lookup = subprocess.run(
        [gh, "api", f"repos/{repo_slug}/environments/{environment}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if environment_lookup.returncode != 0:
        stderr = (environment_lookup.stderr or "").strip()
        if "404" in stderr or "Not Found" in stderr:
            status["environment_status"] = "missing"
            status["bootstrap_secrets_status"] = "missing"
            status["prd02_secret_status"] = "missing"
            status["cicd_readiness"] = "missing"
            return status

        status["detail"] = stderr or "Unable to query GitHub environment state."
        return status

    status["environment_status"] = "present"

    secrets_lookup = subprocess.run(
        [gh, "api", f"repos/{repo_slug}/environments/{environment}/secrets"],
        capture_output=True,
        text=True,
        check=False,
    )
    if secrets_lookup.returncode != 0:
        stderr = (secrets_lookup.stderr or "").strip()
        status["detail"] = stderr or "Unable to query GitHub environment secrets."
        return status

    try:
        secrets_doc = json.loads(secrets_lookup.stdout or "{}")
    except json.JSONDecodeError:
        status["detail"] = "GitHub environment secrets response was not valid JSON."
        return status

    secret_names = {secret.get("name", "") for secret in secrets_doc.get("secrets", []) if secret.get("name")}
    required_bootstrap_secrets = {"AWS_ACCOUNT_ID", "AWS_REGION", "STATE_BUCKET", "LOCK_TABLE", "TF_EXEC_ROLE_ARN"}
    present_bootstrap_count = len(required_bootstrap_secrets & secret_names)

    if present_bootstrap_count == len(required_bootstrap_secrets):
        status["bootstrap_secrets_status"] = "complete"
    elif present_bootstrap_count == 0:
        status["bootstrap_secrets_status"] = "missing"
    else:
        status["bootstrap_secrets_status"] = "partial"

    if "ENV_KMS_KEY_ARN" in secret_names:
        status["prd02_secret_status"] = "present"
    else:
        status["prd02_secret_status"] = "missing"

    if status["bootstrap_secrets_status"] == "complete" and status["prd02_secret_status"] == "present":
        status["cicd_readiness"] = "ready"
    elif status["bootstrap_secrets_status"] in {"complete", "partial"}:
        status["cicd_readiness"] = "partial"
    else:
        status["cicd_readiness"] = "missing"

    return status


def current_aws_account_id() -> str | None:
    aws = shutil.which("aws")
    if not aws:
        return None

    result = subprocess.run(
        [aws, "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None

    account_id = (result.stdout or "").strip()
    return account_id or None


def backend_scope_note() -> str:
    return "Account-scoped bootstrap backend"


def account_scope_notice(environments: list[str], account_id: str | None) -> str:
    if not account_id or len(environments) <= 1:
        return ""

    return (
        f"All dashboard environments currently resolve through AWS account {account_id} via one account-scoped bootstrap backend. "
        "This is normal for a single-account dev or demo setup. In a future multi-account model, each target account should get its own bootstrap."
    )


def state_object_key(module: dict[str, Any], environment: str) -> str:
    state_key = module["state_key"]
    if module.get("workspace_scoped", True):
        return f"env:/{environment}/{state_key}"
    return state_key


def is_dashboard_selectable(module_path: str) -> bool:
    return module_path != BOOTSTRAP_MODULE_PATH


def state_has_managed_resources(state_doc: dict[str, Any]) -> bool:
    raw_resources = state_doc.get("resources", [])
    if raw_resources:
        for resource in raw_resources:
            if resource.get("mode", "managed") != "managed":
                continue
            instances = resource.get("instances", [])
            if instances:
                return True
        return False

    values = state_doc.get("values") or {}
    root_module = values.get("root_module") or {}
    stack = [root_module]

    while stack:
        current = stack.pop()
        for resource in current.get("resources", []):
            if resource.get("mode", "managed") == "managed":
                return True
        stack.extend(current.get("child_modules", []))

    return False


def expected_module_outputs(module: dict[str, Any]) -> list[str]:
    module_root = REPO_ROOT / module["path"]
    if not module_root.exists():
        return []

    outputs: set[str] = set()
    for tf_path in module_root.glob("*.tf"):
        try:
            content = tf_path.read_text(encoding="utf-8")
        except OSError:
            continue
        outputs.update(OUTPUT_BLOCK_RE.findall(content))
    return sorted(outputs)


def missing_state_outputs(module: dict[str, Any], state_doc: dict[str, Any]) -> list[str]:
    expected_outputs = expected_module_outputs(module)
    if not expected_outputs:
        return []

    state_outputs = state_doc.get("outputs") or {}
    missing: list[str] = []
    for output_name in expected_outputs:
        if output_name not in state_outputs:
            missing.append(output_name)
            continue
        output_value = state_outputs[output_name]
        if isinstance(output_value, dict) and output_value.get("value") is None:
            missing.append(output_name)
    return missing


def detect_module_state_status(module: dict[str, Any], environment: str, backend: dict[str, str]) -> tuple[str, str]:
    bucket = backend.get("bucket")
    region = backend.get("region", "us-east-1")
    if not bucket:
        return ("unknown", "Backend bucket is unavailable. Launch the dashboard from an environment with bootstrap artifacts.")

    aws = shutil.which("aws")
    if not aws:
        return ("unknown", "AWS CLI not found in PATH.")

    key = state_object_key(module, environment)
    command = [aws, "s3api", "head-object", "--bucket", bucket, "--key", key, "--region", region]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode == 0:
        fetch = subprocess.run(
            [aws, "s3", "cp", f"s3://{bucket}/{key}", "-", "--region", region],
            capture_output=True,
            text=True,
            check=False,
        )
        if fetch.returncode != 0:
            stderr = (fetch.stderr or "").strip()
            return ("unknown", stderr or f"State object exists at s3://{bucket}/{key}, but the dashboard could not read it.")

        try:
            state_doc = json.loads(fetch.stdout)
        except json.JSONDecodeError:
            return ("unknown", f"State object exists at s3://{bucket}/{key}, but it is not valid JSON.")

        if state_has_managed_resources(state_doc):
            missing_outputs = missing_state_outputs(module, state_doc)
            if missing_outputs:
                return (
                    "partial",
                    f"Managed resources found in state at s3://{bucket}/{key}, but required outputs are still missing: {', '.join(missing_outputs)}",
                )
            return ("deployed", f"Managed resources found in state at s3://{bucket}/{key}")

        return ("no-state", f"State object exists at s3://{bucket}/{key}, but it contains no managed resources.")

    stderr = (result.stderr or "").strip()
    lower_stderr = stderr.lower()
    if any(token in lower_stderr for token in ["404", "not found", "key does not exist", "not exist"]):
        return ("no-state", f"No state object found at s3://{bucket}/{key}")

    return ("unknown", stderr or "State lookup failed.")


def collect_module_state_statuses(
    modules: list[dict[str, Any]],
    environment: str,
    backend: dict[str, str],
) -> dict[str, tuple[str, str]]:
    if not modules:
        return {}

    bucket = backend.get("bucket")
    if not bucket:
        message = "Backend bucket is unavailable. Launch the dashboard from an environment with bootstrap artifacts."
        return {module["path"]: ("unknown", message) for module in modules}

    aws = shutil.which("aws")
    if not aws:
        message = "AWS CLI not found in PATH."
        return {module["path"]: ("unknown", message) for module in modules}

    max_workers = min(8, len(modules))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(lambda module: (module["path"], detect_module_state_status(module, environment, backend)), modules)
        return dict(results)


def bootstrap_status(environment: str) -> tuple[str, str]:
    catalog = load_json(CATALOG_PATH)
    bootstrap_module = module_map(catalog).get(BOOTSTRAP_MODULE_PATH)
    if bootstrap_module is None:
        return ("unknown", "Bootstrap module is missing from the module catalog.")

    backend = parse_backend_config(backend_config_path())
    return detect_module_state_status(bootstrap_module, environment, backend)


def relevant_destroy_paths(
    selected_modules: list[str],
    enabled_set: set[str],
    reverse_dependencies: dict[str, list[str]],
) -> set[str]:
    relevant = set(selected_modules)
    stack = list(selected_modules)

    while stack:
        current = stack.pop()
        for dependent in reverse_dependencies.get(current, []):
            if dependent not in enabled_set or dependent in relevant:
                continue
            relevant.add(dependent)
            stack.append(dependent)

    return relevant


def load_environment_state(environment: str, include_deployment_status: bool = True) -> dict[str, Any]:
    catalog = load_json(CATALOG_PATH)
    manifest = load_json(environment_manifest_path(environment))
    environments = available_environments()
    enabled = resolve_enabled_module_paths(catalog, manifest)
    enabled_set = set(enabled)
    pack_names = {pack["id"]: pack["name"] for pack in catalog.get("capability_packs", [])}
    backend_path = backend_config_path()
    backend = parse_backend_config(backend_path) if include_deployment_status else {}
    github_status = collect_github_status(environment)
    aws_account_id = current_aws_account_id()
    status_by_path: dict[str, tuple[str, str]] = {}

    if include_deployment_status:
        enabled_modules = [module for module in ordered_modules(catalog) if module["path"] in enabled_set]
        status_by_path = collect_module_state_statuses(enabled_modules, environment, backend)

    modules = []
    for module in ordered_modules(catalog):
        deployment_status = "unknown"
        deployment_detail = "State detection skipped."
        if include_deployment_status and module["path"] in enabled_set:
            deployment_status, deployment_detail = status_by_path.get(
                module["path"],
                ("unknown", "State lookup failed."),
            )

        modules.append(
            {
                "path": module["path"],
                "prd": module["prd"],
                "layer": module["layer"],
                "classification": module["classification"],
                "capability_packs": module.get("capability_packs", []),
                "capability_pack_names": [pack_names.get(pack_id, pack_id) for pack_id in module.get("capability_packs", [])],
                "dependencies": module.get("dependencies", []),
                "state_key": module.get("state_key"),
                "domain_tfvars": module.get("domain_tfvars"),
                "workspace_scoped": module.get("workspace_scoped", True),
                "supports_destroy": module.get("supports_destroy", False),
                "supports_operator_destroy": module.get("supports_operator_destroy", False),
                "enabled_in_manifest": module["path"] in enabled_set,
                "dashboard_selectable": is_dashboard_selectable(module["path"]),
                "deployment_status": deployment_status,
                "deployment_detail": deployment_detail,
            }
        )

    return {
        "environment": environment,
        "manifest": manifest,
        "enabled_module_paths": enabled,
        "modules": modules,
        "capability_packs": catalog.get("capability_packs", []),
        "bash_available": find_bash() is not None,
        "backend_config_path": str(backend_path),
        "backend_config_present": backend_path.exists(),
        "aws_profile": os.environ.get("AWS_PROFILE", "default"),
        "aws_account_id": aws_account_id,
        "github_repo_slug": bootstrap_repo_slug(),
        "github_environment": environment,
        "backend_scope": backend_scope_note(),
        "account_scope_notice": account_scope_notice(environments, aws_account_id),
        "github_status": github_status,
    }


def selected_scope_paths(selected_modules: list[str], enabled_order: list[str]) -> list[str]:
    selected_set = set(selected_modules)
    return [path for path in enabled_order if path in selected_set]


def initial_satisfied_paths(modules_by_path: dict[str, dict[str, Any]]) -> set[str]:
    return {
        path
        for path, module in modules_by_path.items()
        if module.get("deployment_status") == "deployed"
    }


def runnable_scope_paths(
    execution_order: list[str],
    selected_modules: list[str],
    modules_by_path: dict[str, dict[str, Any]],
) -> list[str]:
    selected_set = set(selected_modules)
    runnable: list[str] = []
    for path in execution_order:
        if path in selected_set or modules_by_path[path].get("deployment_status") != "deployed":
            runnable.append(path)
    return runnable


def unresolved_dependencies_for_path(
    path: str,
    modules_by_path: dict[str, dict[str, Any]],
    satisfied_paths: set[str],
) -> list[str]:
    blockers: list[str] = []
    for dependency in modules_by_path[path].get("dependencies", []):
        if dependency == BOOTSTRAP_MODULE_PATH:
            continue
        if dependency not in satisfied_paths:
            blockers.append(dependency)
    return blockers


def build_deployment_waves(
    pending_paths: list[str],
    modules_by_path: dict[str, dict[str, Any]],
) -> tuple[list[list[str]], list[str]]:
    remaining = list(pending_paths)
    waves: list[list[str]] = []
    satisfied_paths = initial_satisfied_paths(modules_by_path)

    while remaining:
        wave = [
            path
            for path in remaining
            if not unresolved_dependencies_for_path(path, modules_by_path, satisfied_paths)
        ]
        if not wave:
            break

        waves.append(wave)
        satisfied_paths.update(wave)
        remaining = [path for path in remaining if path not in wave]

    return waves, remaining


def resolve_apply_selection(
    action: str,
    environment: str,
    selected_modules: list[str],
    enabled_order: list[str],
    enabled_set: set[str],
    modules_by_path: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    resolved: set[str] = set()
    bootstrap_state: tuple[str, str] | None = None

    def include(path: str) -> None:
        if path in resolved:
            return
        module = modules_by_path[path]
        for dependency in module.get("dependencies", []):
            if dependency not in enabled_set:
                raise ValueError(f"{path} requires dependency {dependency}, which is disabled in the manifest.")
            if dependency == BOOTSTRAP_MODULE_PATH:
                nonlocal bootstrap_state
                if bootstrap_state is None:
                    bootstrap_state = bootstrap_status(environment)
                if bootstrap_state[0] != "deployed":
                    raise ValueError(
                        "Bootstrap is a one-time operator prerequisite and is not deployed through the dashboard. "
                        f"Current bootstrap status: {bootstrap_state[1]} "
                        "Run modules/bootstrap/scripts/bootstrap.sh first, then reload the dashboard."
                    )
                continue
            include(dependency)
        resolved.add(path)

    for path in selected_modules:
        include(path)

    execution_order = [path for path in enabled_order if path in resolved]
    selected_scope = selected_scope_paths(selected_modules, enabled_order)
    runnable_scope = runnable_scope_paths(execution_order, selected_modules, modules_by_path)
    waves, unresolved_paths = build_deployment_waves(runnable_scope, modules_by_path)
    ready_wave = waves[0] if waves else []
    auto_added_dependencies = [path for path in ready_wave if path not in selected_modules]
    warnings = []
    deferred_modules: list[dict[str, Any]] = []

    satisfied_before_wave = initial_satisfied_paths(modules_by_path)
    for path in runnable_scope:
        if path in ready_wave:
            continue

        blocked_by = unresolved_dependencies_for_path(path, modules_by_path, satisfied_before_wave)
        reason = "Dependency not yet deployed to remote state."
        if not blocked_by:
            reason = "Module is waiting for an earlier wave to complete before its dependencies can be satisfied."

        deferred_modules.append(
            {
                "path": path,
                "blocked_by": blocked_by,
                "reason": reason,
            }
        )

    for path in unresolved_paths:
        module = modules_by_path[path]
        deferred_modules.append(
            {
                "path": path,
                "blocked_by": [dep for dep in module.get("dependencies", []) if dep != BOOTSTRAP_MODULE_PATH],
                "reason": "Unable to place this module into a deployment wave because dependency state could not be resolved.",
            }
        )

    if deferred_modules:
        warnings.append(
            "This selection deploys incrementally in dependency waves. Only the ready wave can run in this pass; deferred modules unlock after earlier waves are applied."
        )
        warnings.append(
            f"{len(deferred_modules)} module(s) are deferred in this pass. See the Blocked column for exact dependency gates."
        )

    execution_order = ready_wave

    if any(path == "modules/l0-audit-pipeline" for path in execution_order):
        warnings.append("PRD-03 is included. Applying it will manage AWS Config, CloudTrail, Security Hub, and the audit bucket.")

    if any(path == "modules/l1-phone-numbers" for path in execution_order):
        warnings.append("PRD-11 is stateful. Phone numbers are retained infrastructure and should be changed deliberately.")

    return {
        "environment": environment,
        "action": action,
        "requested_modules": selected_modules,
        "selected_scope": selected_scope,
        "auto_added_dependencies": auto_added_dependencies,
        "execution_order": execution_order,
        "warnings": warnings,
        "ready_wave": ready_wave,
        "deferred_modules": deferred_modules,
        "waves": waves,
        "current_wave_index": 0 if ready_wave else -1,
        "total_waves": len(waves),
    }


def resolve_destroy_selection(
    environment: str,
    selected_modules: list[str],
    enabled_order: list[str],
    enabled_set: set[str],
    modules_by_path: dict[str, dict[str, Any]],
    reverse_dependencies: dict[str, list[str]],
) -> dict[str, Any]:
    def is_active_destroy_status(status: str | None) -> bool:
        return status in {"deployed", "partial"}

    destroy_set = set(selected_modules)
    auto_added_reverse_dependents: set[str] = set()
    blockers: list[str] = []
    warnings: list[str] = []
    inspected: set[str] = set()
    stack = list(selected_modules)

    for path in selected_modules:
        module = modules_by_path[path]
        if path != BOOTSTRAP_MODULE_PATH and not dashboard_destroyable(module):
            blockers.append(f"{path} is not marked destroyable for either standard or operator-gated dashboard destroy.")
        status = module.get("deployment_status")
        if status == "unknown":
            blockers.append(f"{path} has unknown deployment status, so the dashboard cannot safely determine destroy scope.")
        if status == "no-state":
            blockers.append(f"{path} is not currently deployed, so it is not a valid destroy target.")

    while stack:
        current = stack.pop()
        if current in inspected:
            continue
        inspected.add(current)

        for dependent in reverse_dependencies.get(current, []):
            if dependent not in enabled_set:
                continue

            stack.append(dependent)
            dependent_module = modules_by_path[dependent]
            dependent_status = dependent_module.get("deployment_status")

            if dependent_status == "unknown":
                blockers.append(
                    f"{dependent} depends on {current}, but its deployment status is unknown. Resolve state detection before using dashboard destroy."
                )
                continue

            if not is_active_destroy_status(dependent_status):
                continue

            if dependent != BOOTSTRAP_MODULE_PATH and not dashboard_destroyable(dependent_module):
                blockers.append(
                    f"{dependent} is currently deployed and depends on {current}, but it is not marked destroyable for dashboard teardown."
                )
                continue

            if dependent not in destroy_set:
                destroy_set.add(dependent)
                auto_added_reverse_dependents.add(dependent)

    if blockers:
        raise ValueError("Destroy cannot proceed safely:\n- " + "\n- ".join(blockers))

    execution_order = [path for path in reversed(enabled_order) if path in destroy_set and path != BOOTSTRAP_MODULE_PATH]
    auto_added_dependencies = [path for path in execution_order if path in auto_added_reverse_dependents]

    if auto_added_dependencies:
        warnings.append(
            "Destroy will also remove deployed reverse dependents so no deployed module is left depending on a removed prerequisite."
        )

    if BOOTSTRAP_MODULE_PATH in destroy_set:
        warnings.append(
            "Bootstrap is selected. The dashboard will destroy other selected modules first and then stop. "
            "Complete the final bootstrap teardown manually using docs/DEPLOY-00-bootstrapping-guide.md Scenario E."
        )

    if any(path == "modules/l0-audit-pipeline" for path in execution_order):
        warnings.append("Destroying PRD-03 will remove AWS Config, CloudTrail, Security Hub, and the audit bucket for this environment.")

    return {
        "environment": environment,
        "action": "destroy",
        "requested_modules": selected_modules,
        "auto_added_dependencies": auto_added_dependencies,
        "execution_order": execution_order,
        "warnings": warnings,
    }


def resolve_module_selection(environment: str, selected_modules: list[str], action: str = "apply") -> dict[str, Any]:
    if action not in {"plan", "apply", "destroy"}:
        raise ValueError(f"Unsupported action: {action}")

    state = load_environment_state(environment, include_deployment_status=(action in {"plan", "apply"}))
    enabled_order = state["enabled_module_paths"]
    enabled_set = set(enabled_order)
    modules_by_path = {module["path"]: module for module in state["modules"]}
    catalog = load_json(CATALOG_PATH)
    reverse_dependencies = reverse_dependency_map(catalog)

    if not selected_modules:
        raise ValueError("Select at least one module.")

    if BOOTSTRAP_MODULE_PATH in selected_modules and action != "destroy":
        raise ValueError(
            "modules/bootstrap is a one-time operator prerequisite and is not run from the dashboard. "
            "Use modules/bootstrap/scripts/bootstrap.sh for first-time bootstrap or backend recovery."
        )

    invalid = [module for module in selected_modules if module not in enabled_set]
    if invalid:
        raise ValueError("These modules are not enabled by the current manifest: " + ", ".join(invalid))

    if action == "destroy":
        backend = parse_backend_config(backend_config_path())
        status_paths = relevant_destroy_paths(selected_modules, enabled_set, reverse_dependencies)
        status_modules = [modules_by_path[path] for path in enabled_order if path in status_paths]
        status_by_path = collect_module_state_statuses(status_modules, environment, backend)
        modules_by_path = {
            path: {
                **module,
                "deployment_status": status_by_path.get(path, ("unknown", "State lookup failed."))[0],
                "deployment_detail": status_by_path.get(path, ("unknown", "State lookup failed."))[1],
            }
            for path, module in modules_by_path.items()
        }
        return resolve_destroy_selection(
            environment=environment,
            selected_modules=selected_modules,
            enabled_order=enabled_order,
            enabled_set=enabled_set,
            modules_by_path=modules_by_path,
            reverse_dependencies=reverse_dependencies,
        )

    return resolve_apply_selection(
        action=action,
        environment=environment,
        selected_modules=selected_modules,
        enabled_order=enabled_order,
        enabled_set=enabled_set,
        modules_by_path=modules_by_path,
    )


def find_bash() -> str | None:
    candidates = [
        Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe",
        Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "usr" / "bin" / "bash.exe",
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)

    discovered = shutil.which("bash")
    if discovered:
        discovered_path = Path(discovered)
        # Ignore the WSL launcher on Windows. The dashboard needs Git Bash
        # to run repo shell scripts directly.
        if discovered_path.name.lower() == "bash.exe" and "system32" in str(discovered_path).lower():
            return None
        return discovered
    return None


@dataclass
class RunTask:
    task_id: str
    action: str
    environment: str
    requested_modules: list[str]
    execution_order: list[str]
    auto_added_dependencies: list[str]
    allow_operator_destroy: bool = False
    status: str = "queued"
    started_at: float | None = None
    finished_at: float | None = None
    active_module: str | None = None
    logs: list[str] = field(default_factory=list)
    error: str | None = None
    return_code: int | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "action": self.action,
            "environment": self.environment,
            "requested_modules": self.requested_modules,
            "execution_order": self.execution_order,
            "auto_added_dependencies": self.auto_added_dependencies,
            "allow_operator_destroy": self.allow_operator_destroy,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "active_module": self.active_module,
            "logs": self.logs,
            "error": self.error,
            "return_code": self.return_code,
        }


class ActiveRunConflict(Exception):
    def __init__(self, task: RunTask) -> None:
        super().__init__("Another dashboard run is already active.")
        self.task = task


class RunManager:
    def __init__(self) -> None:
        self._tasks: dict[str, RunTask] = {}
        self._lock = threading.Lock()

    def list_tasks(self) -> list[dict[str, Any]]:
        with self._lock:
            tasks = list(self._tasks.values())
        tasks.sort(key=lambda task: task.started_at or 0, reverse=True)
        return [task.as_dict() for task in tasks]

    def get_task(self, task_id: str) -> RunTask | None:
        with self._lock:
            return self._tasks.get(task_id)

    def active_task(self) -> RunTask | None:
        with self._lock:
            active_tasks = [task for task in self._tasks.values() if task.status in {"queued", "running"}]
        if not active_tasks:
            return None
        active_tasks.sort(key=lambda task: task.started_at or 0, reverse=True)
        return active_tasks[0]

    def create_task(self, action: str, environment: str, requested_modules: list[str], allow_operator_destroy: bool = False) -> RunTask:
        with self._lock:
            active_task = next((task for task in self._tasks.values() if task.status in {"queued", "running"}), None)
            if active_task is not None:
                raise ActiveRunConflict(active_task)

            task = RunTask(
                task_id=str(uuid.uuid4()),
                action=action,
                environment=environment,
                requested_modules=requested_modules,
                execution_order=[],
                auto_added_dependencies=[],
                allow_operator_destroy=allow_operator_destroy,
            )
            self._tasks[task.task_id] = task
        thread = threading.Thread(target=self._run_task, args=(task.task_id,), daemon=True)
        thread.start()
        return task

    def _append_log(self, task: RunTask, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        clean_message = ANSI_ESCAPE_RE.sub("", message)
        if clean_message and all(char == "─" for char in clean_message):
            clean_message = "-" * min(len(clean_message), 48)
        with self._lock:
            task.logs.append(f"[{timestamp}] {clean_message}")

    def _run_task(self, task_id: str) -> None:
        task = self.get_task(task_id)
        if task is None:
            return

        bash = find_bash()
        if bash is None:
            with self._lock:
                task.status = "failed"
                task.error = "Git Bash was not found in PATH or the default Git installation paths."
                task.finished_at = time.time()
                task.return_code = 1
            return

        with self._lock:
            task.status = "running"
            task.started_at = time.time()

        try:
            self._append_log(task, f"Resolving {task.action} scope for selected modules...")
            resolution = resolve_module_selection(task.environment, task.requested_modules, task.action)
            with self._lock:
                task.execution_order = resolution["execution_order"]
                task.auto_added_dependencies = resolution["auto_added_dependencies"]

            if task.auto_added_dependencies:
                joined = ", ".join(task.auto_added_dependencies)
                self._append_log(task, f"Auto-added modules for this run: {joined}")

            for warning in resolution.get("warnings", []):
                self._append_log(task, f"Warning: {warning}")

            if not task.execution_order:
                self._append_log(task, "No dashboard-executable modules were queued for this run.")

            for module_path in task.execution_order:
                with self._lock:
                    task.active_module = module_path
                self._append_log(task, f"Starting {task.action} for {module_path}")

                resolved_backend_path = backend_config_path()
                if module_path != BOOTSTRAP_MODULE_PATH and not resolved_backend_path.exists():
                    with self._lock:
                        task.status = "failed"
                        task.error = f"Backend config file not found: {resolved_backend_path}"
                        task.finished_at = time.time()
                        task.return_code = 1
                        task.active_module = module_path
                    self._append_log(
                        task,
                        f"Run stopped because the backend config file is missing: {resolved_backend_path}",
                    )
                    return

                command = [
                    bash,
                    str(TF_RUNNER),
                    task.action,
                    task.environment,
                    module_path,
                    str(resolved_backend_path),
                ]
                self._append_log(task, f"Using backend config: {resolved_backend_path}")
                env = os.environ.copy()
                env["CONNECT_PBX_NONINTERACTIVE"] = "1"
                if task.allow_operator_destroy and task.action == "destroy":
                    env["CONNECT_PBX_ALLOW_OPERATOR_DESTROY"] = "1"

                process = subprocess.Popen(
                    command,
                    cwd=str(REPO_ROOT),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,
                    env=env,
                )

                assert process.stdout is not None
                for line in process.stdout:
                    self._append_log(task, line.rstrip())

                return_code = process.wait()
                if return_code != 0:
                    with self._lock:
                        task.status = "failed"
                        task.error = f"{task.action} failed for {module_path}"
                        task.finished_at = time.time()
                        task.return_code = return_code
                        task.active_module = module_path
                    self._append_log(task, f"Run stopped because {module_path} exited with code {return_code}")
                    return

                self._append_log(task, f"Completed {task.action} for {module_path}")

            with self._lock:
                task.status = "succeeded"
                task.finished_at = time.time()
                task.return_code = 0
                task.active_module = None
            if BOOTSTRAP_MODULE_PATH in task.requested_modules:
                self._append_log(
                    task,
                    "Dashboard destroy phase is complete. Bootstrap still requires the manual local-state teardown from docs/DEPLOY-00-bootstrapping-guide.md Scenario E.",
                )
            self._append_log(task, f"{task.action.capitalize()} run completed successfully.")
        except Exception as exc:
            with self._lock:
                task.status = "failed"
                task.error = str(exc)
                task.finished_at = time.time()
                task.return_code = 1
                task.active_module = None
            self._append_log(task, f"Unexpected error: {exc}")


RUN_MANAGER = RunManager()


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "ConnectPBXDashboard/0.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._serve_static("index.html", "text/html; charset=utf-8")
            return
        if parsed.path == "/app.js":
            self._serve_static("app.js", "application/javascript; charset=utf-8")
            return
        if parsed.path == "/styles.css":
            self._serve_static("styles.css", "text/css; charset=utf-8")
            return
        if parsed.path == "/api/state":
            query = parse_qs(parsed.query)
            environment = query.get("env", [available_environments()[0]])[0]
            self._handle_api_state(environment)
            return
        if parsed.path == "/api/runs":
            self._write_json(HTTPStatus.OK, {"runs": RUN_MANAGER.list_tasks()})
            return
        if parsed.path.startswith("/api/runs/"):
            task_id = parsed.path.split("/")[-1]
            task = RUN_MANAGER.get_task(task_id)
            if task is None:
                self._write_json(HTTPStatus.NOT_FOUND, {"error": "Run not found."})
                return
            self._write_json(HTTPStatus.OK, task.as_dict())
            return

        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found."})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        body = self._read_json_body()
        if parsed.path == "/api/resolve":
            self._handle_api_resolve(body)
            return
        if parsed.path == "/api/run":
            self._handle_api_run(body)
            return

        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found."})

    def _read_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(content_length) if content_length > 0 else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _serve_static(self, filename: str, content_type: str) -> None:
        path = STATIC_ROOT / filename
        if not path.exists():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError, SocketError):
            return

    def _handle_api_state(self, environment: str) -> None:
        try:
            state = load_environment_state(environment)
        except Exception as exc:
            self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return

        self._write_json(HTTPStatus.OK, {"available_environments": available_environments(), **state})

    def _handle_api_resolve(self, body: dict[str, Any]) -> None:
        environment = body.get("environment")
        selected_modules = body.get("selected_modules", [])
        action = body.get("action", "apply")
        try:
            result = resolve_module_selection(environment, selected_modules, action)
        except Exception as exc:
            self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        self._write_json(HTTPStatus.OK, result)

    def _handle_api_run(self, body: dict[str, Any]) -> None:
        action = body.get("action")
        environment = body.get("environment")
        selected_modules = body.get("selected_modules", [])
        allow_operator_destroy = bool(body.get("allow_operator_destroy", False))

        if action not in {"plan", "apply", "destroy"}:
            self._write_json(HTTPStatus.BAD_REQUEST, {"error": "Unsupported action. Use plan, apply, or destroy."})
            return

        try:
            task = RUN_MANAGER.create_task(
                action=action,
                environment=environment,
                requested_modules=selected_modules,
                allow_operator_destroy=allow_operator_destroy,
            )
        except ActiveRunConflict as exc:
            self._write_json(
                HTTPStatus.CONFLICT,
                {
                    "error": "Another dashboard run is already queued or running. Reattach to the active run before starting a new one.",
                    "active_task": exc.task.as_dict(),
                },
            )
            return
        self._write_json(HTTPStatus.ACCEPTED, task.as_dict())

    def _write_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError, SocketError):
            return


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local deployment dashboard for Connect PBX.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server = ThreadingHTTPServer((args.host, args.port), DashboardHandler)
    print(f"Connect PBX dashboard listening on http://{args.host}:{args.port}")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
