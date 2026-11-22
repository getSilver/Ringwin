"""Validate signed bundle bytes without importing or executing their contents."""

from __future__ import annotations

import hashlib
import json
import re
import tarfile
import unicodedata
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping


MAX_BUNDLE_BYTES = 512 * 1024 * 1024
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_JSON_BYTES = 256 * 1024
LIMITS = {"max_private_state_bytes", "max_input_record_bytes", "max_output_frame_bytes",
          "max_output_frames_per_event", "max_callback_ns", "max_warmup_events",
          "max_warmup_ns", "max_memory_bytes"}
COMPATIBILITY = {"host_build", "python_abi", "host_protocol", "schema_registry",
                 "runtime_lock_sha256"}
MANIFEST = {"format_version", "definition_identity", "name", "runtime", "entrypoint",
            "strategy_api_version", "compatibility", "config_schema", "state_schema",
            "subscriptions", "output_kinds", "limits", "files", "evidence"}


class PackageError(ValueError):
    pass


def host_manifests(requests):
    """v1: domain-separated SHA-256 of identity-sorted canonical JSON arrays."""
    require(1 <= len(requests) <= 16, "Host instance capacity exceeded")
    ordered = sorted(requests, key=lambda r: r["binding"]["strategy_identity"])
    identities = [r["binding"]["strategy_identity"] for r in ordered]
    require(len(set(identities)) == len(identities), "duplicate Host member")
    strategies, checkpoints = [], []
    for request in ordered:
        binding, manifest = request["binding"], request["manifest"]
        strategies.append({k: binding[k] for k in ("strategy_identity", "definition_identity",
            "package_manifest_sha256", "config_version", "config_sha256")})
        checkpoints.append(dict(strategy_identity=binding["strategy_identity"],
            definition_identity=binding["definition_identity"], state_schema=manifest["state_schema"],
            config_version=binding["config_version"], checkpoint=request.get("checkpoint")))
    return (hashlib.sha256(b"RingWin/StrategyHost/strategies/v1\0" + canonical(strategies)).hexdigest(),
            hashlib.sha256(b"RingWin/StrategyHost/checkpoints/v1\0" + canonical(checkpoints)).hexdigest())


def require(condition, reason):
    if not condition:
        raise PackageError(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("utf-8")


def parse_json(data):
    require(len(data) <= MAX_JSON_BYTES, "JSON capacity exceeded")

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result

    def no_float(value):
        raise PackageError("floating point JSON is forbidden")

    def integer(value):
        require(len(value.lstrip("-")) <= 20, "JSON integer capacity exceeded")
        return int(value)

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs,
                           parse_float=no_float, parse_constant=no_float, parse_int=integer)
        require(canonical(value) == data, "JSON is not canonical")
        return value
    except (UnicodeError, ValueError, RecursionError) as error:
        raise PackageError(f"invalid canonical JSON: {error}") from error


def fields(value, expected):
    require(type(value) is dict and value.keys() == expected, "unexpected or missing fields")


def uint(value, bits=64, positive=True):
    require(type(value) is int and (1 if positive else 0) <= value < 2 ** bits,
            "invalid unsigned integer")


def identity(value):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{32}", value) is not None
            and int(value, 16) != 0, "invalid definition or schema identity")


def digest(value):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
            "invalid SHA-256")


def path(value):
    require(type(value) is str and 0 < len(value) <= 1024, "invalid path")
    require(not any(unicodedata.category(c).startswith("C") or c in "\\:" for c in value),
            "unsafe path")
    require(len(value.encode("utf-8")) <= 1024, "path capacity exceeded")
    for part in value.split("/"):
        require(part not in ("", ".", "..") and not part.endswith((".", " "))
                and len(part.encode("utf-8")) <= 255
                and not any(c in '<>"|?*' for c in part), "unsafe path")
        require(re.fullmatch(r"(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])",
                             part.split(".")[0]) is None, "device path is forbidden")
    return value


def compatibility(value, with_lock=True):
    fields(value, COMPATIBILITY if with_lock else COMPATIBILITY - {"runtime_lock_sha256"})
    identity(value["host_build"])
    identity(value["schema_registry"])
    uint(value["python_abi"], 32)
    uint(value["host_protocol"], 16)
    if with_lock:
        digest(value["runtime_lock_sha256"])


def subscriptions(value):
    require(type(value) is list and len(value) <= 256, "subscription capacity exceeded")
    ordered = []
    for item in value:
        fields(item, {"event_type", "schema_version"})
        uint(item["event_type"], 16)
        uint(item["schema_version"], 16)
        ordered.append((item["event_type"], item["schema_version"]))
    require(ordered == sorted(set(ordered)), "subscriptions must be sorted and unique")


def declared_files(value, files, prefix="", total_limit=256 * 1024 * 1024):
    require(type(value) is list and 0 < len(value) <= 4096, "file count capacity exceeded")
    names, folded, total = [], set(), 0
    for item in value:
        fields(item, {"path", "size_bytes", "sha256"})
        name = path(item["path"])
        require(name.casefold() not in folded, "duplicate or case-colliding file path")
        folded.add(name.casefold())
        names.append(name)
        uint(item["size_bytes"], positive=False)
        require(item["size_bytes"] <= MAX_FILE_BYTES, "file size capacity exceeded")
        total += item["size_bytes"]
        require(total <= total_limit, "total file capacity exceeded")
        digest(item["sha256"])
        data = files.get(prefix + name)
        require(data is not None, "declared file is missing")
        require(len(data) == item["size_bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"],
                "declared file size or digest mismatch")
    require(names == sorted(names), "files must be sorted")
    return set(names)


def schema(value, names, state=False):
    fields(value, {"identity", "version", "path", "encoding"} if state else
           {"identity", "version", "path"})
    identity(value["identity"])
    uint(value["version"], 32)
    require(path(value["path"]) in names, "schema file is not declared")
    if state:
        require(value["encoding"] == "portable_json_v1", "unsupported private state encoding")


def validate_qualification(report):
    fields(report, {"package_manifest_sha256", "compatibility", "scope", "qualified"})
    digest(report["package_manifest_sha256"])
    if type(report["compatibility"]) is dict and "native_api" in report["compatibility"]:
        native_compatibility(report["compatibility"])
    else:
        compatibility(report["compatibility"])
    require(type(report["qualified"]) is bool, "qualification verdict must be boolean")
    scope = report["scope"]
    fields(scope, {"platform", "os_build", "node_identity", "environment", "mode",
                   "config_sha256", "venues", "exchange_accounts", "instruments",
                   "products", "capabilities"})
    require(scope["platform"] in ("linux", "windows"), "unsupported qualification platform")
    require(scope["environment"] in ("offline", "demo", "testnet", "production"),
            "unsupported qualification environment")
    identity(scope["node_identity"])
    digest(scope["config_sha256"])
    for key in ("os_build", "mode"):
        require(type(scope[key]) is str and 0 < len(scope[key]) <= 128
                and not any(ord(c) < 32 for c in scope[key]), "invalid qualification scope")
    for key in ("venues", "exchange_accounts", "instruments", "products", "capabilities"):
        values = scope[key]
        require(type(values) is list and 0 < len(values) <= 256
                and all(type(v) is str and 0 < len(v) <= 128 for v in values),
                "invalid qualification scope inventory")
        require(values == sorted(set(values)), "qualification scope must be sorted and unique")
        if key in ("venues", "exchange_accounts", "instruments"):
            for value in values:
                identity(value)


@dataclass(frozen=True)
class Bundle:
    files: Mapping[str, bytes]
    packages: tuple[dict, ...]
    executable_paths: tuple[str, ...]


def validate_bundle(data, policy, version=1):
    require(policy is not None, "approved strategy runtime policy is required")
    if version == 1:
        fields(policy, {"compatibility", "limits", "subscriptions"})
        compatibility(policy["compatibility"])
        fields(policy["limits"], LIMITS)
        for maximum in policy["limits"].values():
            uint(maximum)
        subscriptions(policy["subscriptions"])
    else:
        require(version == 2, "unsupported bundle version")
        fields(policy, {"native_build"})
    require(len(data) <= MAX_BUNDLE_BYTES, "bundle capacity exceeded")
    files, folded, total = {}, set(), 0
    try:
        offset = 0
        while True:
            require(offset + 512 <= len(data), "truncated archive header")
            header = data[offset:offset + 512]
            if not any(header):
                require(len(data) - offset >= 1024 and not any(data[offset:]),
                        "archive trailing content is forbidden")
                break
            # Inspect headers before tarfile can expand GNU/PAX metadata.
            member = tarfile.TarInfo.frombuf(header, "utf-8", "strict")
            name = path(member.name)
            require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not member.linkname,
                    "archive links and non-regular entries are forbidden")
            require(name.casefold() not in folded, "duplicate or case-colliding archive path")
            folded.add(name.casefold())
            file_limit = 256 * 1024 * 1024 if version == 2 and name in ("bin/ringwin", "bin/ringwin.exe") else MAX_FILE_BYTES
            require(len(files) < 16384 and 0 <= member.size <= file_limit,
                    "archive capacity exceeded")
            total += member.size
            require(total <= MAX_BUNDLE_BYTES, "expanded archive capacity exceeded")
            start, end = offset + 512, offset + 512 + member.size
            offset = start + ((member.size + 511) // 512) * 512
            require(offset <= len(data) and not any(data[end:offset]), "truncated or invalid archive padding")
            files[name] = data[start:end]
    except (tarfile.TarError, OSError) as error:
        raise PackageError(f"invalid strategy archive: {error}") from error
    for name in files:
        pieces = name.split("/")
        require(not any("/".join(pieces[:n]).casefold() in folded
                        for n in range(1, len(pieces))), "file and directory path conflict")

    if version == 2:
        return validate_native_bundle(files, policy)
    require("runtime-lock.json" in files and "strategy-index.json" in files,
            "bundle runtime lock or strategy index missing")
    lock_bytes = files["runtime-lock.json"]
    lock = parse_json(lock_bytes)
    fields(lock, {"format_version", "compatibility", "python_path", "host_path", "files"})
    require(type(lock["format_version"]) is int and lock["format_version"] == 1,
            "unsupported runtime lock format")
    compatibility(lock["compatibility"], with_lock=False)
    actual = dict(lock["compatibility"], runtime_lock_sha256=hashlib.sha256(lock_bytes).hexdigest())
    require(actual == policy["compatibility"], "runtime compatibility mismatch")
    runtime_names = declared_files(lock["files"], files, total_limit=MAX_BUNDLE_BYTES)
    require("ringwin" in runtime_names and all(p == "ringwin" or p.startswith("runtime/")
                                             for p in runtime_names), "invalid runtime inventory")
    for key in ("python_path", "host_path"):
        require(type(lock[key]) is str and lock[key].startswith("runtime/")
                and lock[key] in runtime_names, "runtime entrypoint is not locked")
    require(lock["python_path"] != lock["host_path"], "runtime entrypoints must be distinct")
    expected = runtime_names | {"runtime-lock.json", "strategy-index.json"}
    index = parse_json(files["strategy-index.json"])
    fields(index, {"format_version", "strategies"})
    require(type(index["format_version"]) is int and index["format_version"] == 1,
            "unsupported strategy index format")
    require(type(index["strategies"]) is list and len(index["strategies"]) <= 1024,
            "strategy index capacity exceeded")
    identifiers, packages = [], []
    for entry in index["strategies"]:
        fields(entry, {"definition_identity", "manifest_path", "package_manifest_sha256"})
        identity(entry["definition_identity"])
        identifiers.append(entry["definition_identity"])
        prefix = f"strategies/{entry['definition_identity']}/"
        manifest_path = prefix + "manifest.json"
        require(entry["manifest_path"] == manifest_path, "index manifest path mismatch")
        digest(entry["package_manifest_sha256"])
        require(manifest_path in files, "strategy manifest missing")
        manifest_bytes = files[manifest_path]
        require(hashlib.sha256(manifest_bytes).hexdigest() == entry["package_manifest_sha256"],
                "strategy manifest digest mismatch")
        manifest = parse_json(manifest_bytes)
        fields(manifest, MANIFEST)
        require(type(manifest["format_version"]) is int and manifest["format_version"] == 1
                and type(manifest["strategy_api_version"]) is int
                and manifest["strategy_api_version"] == 1, "unsupported strategy API or format")
        require(manifest["definition_identity"] == entry["definition_identity"],
                "index definition identity mismatch")
        require(type(manifest["name"]) is str and 1 <= len(manifest["name"]) <= 64
                and not any(ord(c) < 32 for c in manifest["name"]), "invalid strategy name")
        require(manifest["runtime"] == "python", "unsupported strategy runtime")
        compatibility(manifest["compatibility"])
        require(manifest["compatibility"] == actual, "strategy compatibility mismatch")
        names = declared_files(manifest["files"], files, prefix)
        require("manifest.json" not in names, "manifest cannot declare itself")
        require(all("__pycache__" not in name.split("/")
                    and not re.search(r"(?i)\.(pyc|pyo|pyd|dll|dylib|so)(\.[0-9]+)*$", name)
                    for name in names), "compiled dependencies must belong to the locked runtime")
        schema(manifest["config_schema"], names)
        schema(manifest["state_schema"], names, state=True)
        entrypoint = manifest["entrypoint"]
        require(type(entrypoint) is str and re.fullmatch(
            r"[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)*:create", entrypoint),
            "invalid strategy entrypoint")
        module = entrypoint[:-7].replace(".", "/")
        require("code/" + module + ".py" in names or "code/" + module + "/__init__.py" in names,
                "strategy entrypoint file missing")
        subscriptions(manifest["subscriptions"])
        require(all(s in policy["subscriptions"] for s in manifest["subscriptions"]),
                "unsupported subscription schema")
        outputs = manifest["output_kinds"]
        require(type(outputs) is list and all(o in ("order_intent", "intent_group", "order_query", "order_cancel", "maker_intent") for o in outputs)
                and outputs == sorted(set(outputs)), "unsupported or duplicate output kinds")
        fields(manifest["limits"], LIMITS)
        for key, limit in manifest["limits"].items():
            uint(limit)
            require(limit <= policy["limits"][key], "strategy resource limit exceeds deployment policy")
        for key, ceiling in (("max_private_state_bytes", 8 * 1024 * 1024),
                             ("max_input_record_bytes", 1048576 - 128 - 64),
                             ("max_output_frame_bytes", 262144),
                             ("max_output_frames_per_event", 64)):
            require(manifest["limits"][key] <= ceiling, "strategy resource limit exceeds codec capacity")
        evidence = manifest["evidence"]
        require(type(evidence) is list and len(evidence) <= len(names), "invalid build evidence")
        evidence_keys = []
        for report in evidence:
            fields(report, {"kind", "path"})
            require(report["kind"] in ("offline", "economic", "operational")
                    and path(report["path"]) in names, "build evidence file is not declared")
            evidence_keys.append((report["kind"], report["path"]))
        require(evidence_keys == sorted(set(evidence_keys)), "build evidence must be sorted and unique")
        expected.add(manifest_path)
        expected.update(prefix + name for name in names)
        record = {k: manifest[k] for k in ("definition_identity", "name", "runtime", "entrypoint",
                  "compatibility", "config_schema", "state_schema", "subscriptions", "output_kinds", "limits")}
        record.update(manifest_path=manifest_path, package_manifest_sha256=entry["package_manifest_sha256"],
                      validation="passed", trading_authorized=False, qualifications=[])
        for kind in ("config_schema", "state_schema"):
            record[kind + "_sha256"] = hashlib.sha256(files[prefix + manifest[kind]["path"]]).hexdigest()
        packages.append(record)
    require(identifiers == sorted(set(identifiers)), "index identities must be sorted and unique")
    require(set(files) == expected, "undeclared bundle file")
    executables = ("ringwin", lock["python_path"])
    for candidate in ("runtime/ringwin-strategy-candidate", "runtime/ringwin-strategy-candidate.exe"):
        if candidate in files:
            executables += (candidate,)
    return Bundle(MappingProxyType(files), tuple(packages), executables)


def native_compatibility(value):
    fields(value, {"native_api", "canonical_schema", "schema_registry", "journal_schema", "core_state_schema"})
    for v in value.values():
        uint(v, 64)
    require(value["native_api"] == 1, "unsupported native API")


def validate_native_bundle(files, policy):
    inventory = "share/ringwin/native-strategies.json"
    require(inventory in files and "strategy-index.json" in files, "native build inventory or index missing")
    build = parse_json(files[inventory])
    fields(build, {"format_version", "runtime", "zig_version", "target", "optimize", "binary_path", "definitions"})
    require(type(build["format_version"]) is int and build["format_version"] == 1
            and build["runtime"] == "native_static", "unsupported native build format")
    require(build == policy["native_build"], "native approved build mismatch")
    for key in ("zig_version", "target", "optimize"):
        require(type(build[key]) is str and 0 < len(build[key]) <= 128, "invalid native build identity")
    binary = path(build["binary_path"])
    require(binary in ("bin/ringwin", "bin/ringwin.exe") and binary in files and files[binary],
            "native binary missing")
    definitions = build["definitions"]
    require(type(definitions) is list and 0 < len(definitions) <= 1024, "invalid native definition inventory")
    index = parse_json(files["strategy-index.json"])
    fields(index, {"format_version", "strategies"})
    require(type(index["format_version"]) is int and index["format_version"] == 2,
            "unsupported native strategy index format")
    require(type(index["strategies"]) is list and len(index["strategies"]) == len(definitions), "native index mismatch")
    expected, identifiers, records = {inventory, binary, "strategy-index.json"}, [], []
    for definition, entry in zip(definitions, index["strategies"]):
        fields(definition, {"definition_identity", "name", "entrypoint", "algorithm_path", "algorithm_sha256",
                            "config_schema", "state_schema", "compatibility", "subscription", "output"})
        identity(definition["definition_identity"])
        identifiers.append(definition["definition_identity"])
        for key in ("name", "entrypoint"):
            require(type(definition[key]) is str and re.fullmatch(r"[a-zA-Z_][a-zA-Z_0-9]{0,63}", definition[key]),
                    "invalid native entrypoint or name")
        path(definition["algorithm_path"])
        digest(definition["algorithm_sha256"])
        native_compatibility(definition["compatibility"])
        require(definition["subscription"] == 19 and type(definition["subscription"]) is int
                and definition["output"] == "none", "unsupported native callback or output contract")
        for kind in ("config_schema", "state_schema"):
            contract = definition[kind]
            fields(contract, {"identity", "version", "path", "sha256"})
            identity(contract["identity"])
            uint(contract["version"], 32)
            name = path(contract["path"])
            require(name.startswith("share/ringwin/contracts/") and name in files, "native schema missing")
            digest(contract["sha256"])
            require(hashlib.sha256(files[name]).hexdigest() == contract["sha256"], "native schema digest mismatch")
            expected.add(name)
        descriptor = dict(build={k: v for k, v in build.items() if k != "definitions"}, definition=definition)
        manifest_hash = hashlib.sha256(canonical(descriptor)).hexdigest()
        fields(entry, {"definition_identity", "manifest_path", "package_manifest_sha256"})
        require(entry == dict(definition_identity=definition["definition_identity"], manifest_path=inventory,
                              package_manifest_sha256=manifest_hash), "native index identity or digest mismatch")
        record = dict(definition, runtime="native_static", manifest_path=inventory,
                      package_manifest_sha256=manifest_hash, validation="passed", trading_authorized=False,
                      qualifications=[], subscriptions=[dict(event_type=19, schema_version=1)], output_kinds=[])
        for kind in ("config_schema", "state_schema"):
            record[kind + "_sha256"] = definition[kind]["sha256"]
        records.append(record)
    require(identifiers == sorted(set(identifiers)), "native identities must be sorted and unique")
    require(set(files) == expected, "undeclared native bundle file")
    # The existing role service executes current/ringwin; both names use signed bytes.
    installed = dict(files, ringwin=files[binary])
    return Bundle(MappingProxyType(installed), tuple(records), (binary, "ringwin"))
