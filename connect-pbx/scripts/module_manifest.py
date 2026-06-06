#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

ALLOWED_CLASSIFICATIONS = {
    "core-required",
    "optional-feature",
    "migration-only",
    "conditional-foundation",
}

REQUIRED_MODULE_KEYS = [
    "path",
    "prd",
    "layer",
    "classification",
    "capability_packs",
    "dependencies",
    "state_key",
    "domain_tfvars",
    "workspace_scoped",
    "supports_destroy",
]


def load_json(path_str):
    path = Path(path_str)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"File not found: {path}")


def ordered_modules(catalog):
    return catalog.get("modules", [])


def module_map(catalog):
    return {module["path"]: module for module in ordered_modules(catalog)}


def capability_pack_map(catalog):
    return {pack["id"]: pack for pack in catalog.get("capability_packs", [])}


def discover_module_directories(catalog_path):
    modules_root = Path(catalog_path).resolve().parent
    discovered = []
    for entry in sorted(modules_root.iterdir(), key=lambda item: item.name):
        if not entry.is_dir():
            continue
        if entry.name.startswith("."):
            continue
        if not any(child.suffix == ".tf" for child in entry.iterdir() if child.is_file()):
            continue
        discovered.append(f"modules/{entry.name}")
    return discovered


def resolve_enabled_module_paths(catalog, manifest):
    modules = ordered_modules(catalog)
    modules_by_path = module_map(catalog)
    packs_by_id = capability_pack_map(catalog)

    enabled = set()

    for pack_id in manifest.get("enabled_capability_packs", []):
        if pack_id not in packs_by_id:
            raise SystemExit(f"Unknown capability pack in manifest: {pack_id}")
        for module in modules:
            if pack_id in module.get("capability_packs", []):
                enabled.add(module["path"])

    for module_path in manifest.get("enabled_modules", []):
        if module_path not in modules_by_path:
            raise SystemExit(f"Unknown enabled module in manifest: {module_path}")
        enabled.add(module_path)

    for module_path in manifest.get("disabled_modules", []):
        if module_path not in modules_by_path:
            raise SystemExit(f"Unknown disabled module in manifest: {module_path}")
        if modules_by_path[module_path]["classification"] == "core-required":
            raise SystemExit(f"Manifest cannot disable core-required module: {module_path}")
        enabled.discard(module_path)

    for module in modules:
        path = module["path"]
        if path not in enabled:
            continue
        for dependency in module.get("dependencies", []):
            if dependency not in modules_by_path:
                raise SystemExit(f"Module {path} depends on unknown module {dependency}")
            if dependency not in enabled:
                raise SystemExit(f"Enabled module {path} requires disabled dependency {dependency}")

    return [module["path"] for module in modules if module["path"] in enabled]


def validate_catalog(catalog, catalog_path):
    modules = ordered_modules(catalog)
    modules_by_path = module_map(catalog)
    pack_ids = set(capability_pack_map(catalog).keys())

    errors = []

    if len(modules_by_path) != len(modules):
        errors.append("Catalog contains duplicate module paths.")

    discovered_module_paths = discover_module_directories(catalog_path)
    discovered_set = set(discovered_module_paths)
    catalog_set = set(modules_by_path.keys())

    missing_catalog_entries = sorted(discovered_set - catalog_set)
    if missing_catalog_entries:
        errors.append(
            "Module directories exist without catalog metadata: "
            + ", ".join(missing_catalog_entries)
        )

    missing_directories = sorted(catalog_set - discovered_set)
    if missing_directories:
        errors.append(
            "Catalog entries point to missing module directories: "
            + ", ".join(missing_directories)
        )

    for module in modules:
        path = module.get("path", "<unknown>")
        for key in REQUIRED_MODULE_KEYS:
            if key not in module:
                errors.append(f"Catalog entry {path} is missing required key: {key}")

        classification = module.get("classification")
        if classification not in ALLOWED_CLASSIFICATIONS:
            errors.append(
                f"Catalog entry {path} has invalid classification: {classification}"
            )

        capability_packs = module.get("capability_packs", [])
        if not isinstance(capability_packs, list):
            errors.append(f"Catalog entry {path} has non-list capability_packs.")
        else:
            unknown_packs = sorted(pack for pack in capability_packs if pack not in pack_ids)
            if unknown_packs:
                errors.append(
                    f"Catalog entry {path} references unknown capability packs: "
                    + ", ".join(unknown_packs)
                )

        dependencies = module.get("dependencies", [])
        if not isinstance(dependencies, list):
            errors.append(f"Catalog entry {path} has non-list dependencies.")
        else:
            unknown_dependencies = sorted(
                dependency for dependency in dependencies if dependency not in modules_by_path
            )
            if unknown_dependencies:
                errors.append(
                    f"Catalog entry {path} references unknown dependencies: "
                    + ", ".join(unknown_dependencies)
                )

        if not isinstance(module.get("workspace_scoped"), bool):
            errors.append(f"Catalog entry {path} must define workspace_scoped as a boolean.")

        if not isinstance(module.get("supports_destroy"), bool):
            errors.append(f"Catalog entry {path} must define supports_destroy as a boolean.")

        if "supports_operator_destroy" in module and not isinstance(module.get("supports_operator_destroy"), bool):
            errors.append(f"Catalog entry {path} must define supports_operator_destroy as a boolean when present.")

    if errors:
        raise SystemExit("\n".join(errors))


def cmd_validate(args):
    catalog = load_json(args.catalog)
    manifest = load_json(args.manifest)
    enabled = resolve_enabled_module_paths(catalog, manifest)
    print(f"Validated manifest: {args.manifest}")
    print(f"Enabled modules: {len(enabled)}")
    return 0


def cmd_validate_catalog(args):
    catalog = load_json(args.catalog)
    validate_catalog(catalog, args.catalog)
    print(f"Validated catalog: {args.catalog}")
    print(f"Catalog modules: {len(ordered_modules(catalog))}")
    return 0


def cmd_eligible_modules(args):
    catalog = load_json(args.catalog)
    manifest = load_json(args.manifest)
    enabled = resolve_enabled_module_paths(catalog, manifest)
    modules_by_path = module_map(catalog)

    if args.action == "destroy":
        enabled = [path for path in enabled if modules_by_path[path].get("supports_destroy", False)]

    for path in enabled:
        print(path)
    return 0


def cmd_module_field(args):
    catalog = load_json(args.catalog)
    modules_by_path = module_map(catalog)
    module = modules_by_path.get(args.module)
    if module is None:
        raise SystemExit(f"Unknown module path: {args.module}")

    value = module.get(args.field)
    if value is None:
        return 0
    if isinstance(value, bool):
        print(str(value).lower())
    elif isinstance(value, (list, dict)):
        print(json.dumps(value))
    else:
        print(value)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Resolve Connect PBX module catalog and deployment manifests.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_catalog_parser = subparsers.add_parser("validate-catalog")
    validate_catalog_parser.add_argument("--catalog", required=True)
    validate_catalog_parser.set_defaults(func=cmd_validate_catalog)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--catalog", required=True)
    validate.add_argument("--manifest", required=True)
    validate.set_defaults(func=cmd_validate)

    eligible = subparsers.add_parser("eligible-modules")
    eligible.add_argument("--catalog", required=True)
    eligible.add_argument("--manifest", required=True)
    eligible.add_argument("--action", choices=["plan", "apply", "audit", "destroy"], required=True)
    eligible.set_defaults(func=cmd_eligible_modules)

    field = subparsers.add_parser("module-field")
    field.add_argument("--catalog", required=True)
    field.add_argument("--module", required=True)
    field.add_argument("--field", required=True)
    field.set_defaults(func=cmd_module_field)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
