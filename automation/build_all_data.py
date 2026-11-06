#!/usr/bin/env python3
"""Data-only validation for build_all.sh; never evaluates result contents."""
import os
import json
import re
import sys
from pathlib import Path


def target_project(path, environment):
    """Resolve only literal metadata in JSON or the repository's branch grammar.

    This is deliberately not a Go template interpreter. Unknown control flow,
    nested branches, duplicate keys and computed project values fail closed.
    """
    if environment not in ("test", "prod"):
        raise ValueError("unsupported target environment")
    text = re.sub(r"{{/\*.*?\*/}}", "", Path(path).read_text(), flags=re.S)
    tag = r"{{-?\s*(.*?)\s*-?}}"
    tokens = list(re.finditer(tag, text, re.S))
    controls = [(m, m.group(1).strip().rstrip("-").strip()) for m in tokens
                if not m.group(1).strip().startswith("$")]
    if controls:
        expected = ['if eq .environment "test"', 'else if eq .environment "prod"',
                    'else if eq .environment "autopush"', 'else', 'end']
        if [value for _, value in controls] != expected:
            raise ValueError("unsupported publisher environment branch layout")
        start, stop = (0, 1) if environment == "test" else (1, 2)
        selected = text[controls[start][0].end():controls[stop][0].start()]
        text = text[:controls[0][0].start()] + selected + text[controls[-1][0].end():]
    project_values = []
    for key in re.finditer(r'("(?:\\.|[^"\\])*")\s*:\s*', text):
        if json.loads(key.group(1)) == "PublishProject":
            value, _ = json.JSONDecoder().raw_decode(text[key.end():])
            project_values.append(value)
    if (len(project_values) != 1 or not isinstance(project_values[0], str)
            or not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project_values[0])):
        raise ValueError("publisher requires a single static PublishProject")
    # Only the repository's metadata declarations/references are understood.
    def replace(match):
        value = match.group(1).strip().rstrip("-").strip()
        if re.fullmatch(r"\$(work_project|endpoint|delete_after|guest_features|time)\s*:=\s*[^{}]+", value):
            return ""
        if value in ("$work_project", "$endpoint", "$delete_after", "$guest_features"):
            return "null"
        if value == "$time":
            return ""
        raise ValueError("unsupported publisher template expression")
    text = re.sub(tag, replace, text, flags=re.S)
    if "{{" in text or "}}" in text:
        raise ValueError("unresolved publisher template")
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError("duplicate publisher metadata key")
            obj[key] = value
        return obj
    obj = json.loads(text, object_pairs_hook=unique)
    project = obj.get("PublishProject") if isinstance(obj, dict) else None
    if project != project_values[0]:
        raise ValueError("publisher project changed during metadata validation")
    return project


def read_result(path):
    fields = {}
    for line in Path(path).read_text().splitlines():
        key, sep, value = line.partition("=")
        if not sep or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in fields:
            raise ValueError("malformed or duplicate result field")
        fields[key] = value
    return fields


def source(path):
    fields = read_result(path)
    if fields.get("BUILD_STATUS") not in ("PASS", "SKIPPED"):
        raise ValueError("source BUILD_STATUS must be PASS or SKIPPED")
    version = fields.get("BUILD_VERSION", "")
    if not re.fullmatch(r"v[0-9]+", version):
        raise ValueError("source BUILD_VERSION must match v[0-9]+")
    return version


def verify(path, project, name, tarball):
    image = json.loads(Path(path).read_text())
    if not isinstance(image, dict):
        raise ValueError("image readback must contain a JSON object")
    link = f"https://www.googleapis.com/compute/v1/projects/{project}/global/images/{name}"
    # Identity/state must be returned by the API, not inferred from podman exit.
    if (image.get("name") != name or image.get("selfLink") != link
            or image.get("status") != "READY"
            or not re.fullmatch(r"[0-9]+", str(image.get("id", "")))):
        raise ValueError("image readback identity/status mismatch")
    raw_disk = image.get("rawDisk", {})
    if not isinstance(raw_disk, dict):
        raise ValueError("image readback rawDisk must contain a JSON object")
    raw_source = raw_disk.get("source")
    if raw_source is not None and raw_source not in (
            tarball, tarball.replace("gs://", "https://storage.googleapis.com/", 1)):
        raise ValueError("image readback source mismatch")
    return [{"selfLink": image["selfLink"], "id": str(image["id"]),
             "status": image["status"], "source": raw_source,
             "source_verified": raw_source is not None}]


def credentials():
    """Return mount paths privately to the shell, never to run artifacts."""
    adc = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not adc:
        config = os.environ.get("CLOUDSDK_CONFIG", str(Path.home() / ".config/gcloud"))
        adc = str(Path(config) / "application_default_credentials.json")
    path = Path(adc)
    try:
        obj = json.loads(path.read_text())
        if not isinstance(obj, dict):
            raise ValueError("credentials must contain a JSON object")
        paths = [path]
        kind = obj.get("type")
        if kind == "external_account":
            source = obj.get("credential_source", {})
            if (not isinstance(source, dict)
                    or set(source) - {"file", "format"}
                    or not isinstance(source.get("file"), str)):
                raise ValueError("unsupported credential arrangement: WIF requires a mounted credential_source.file")
            paths.append(Path(source["file"]))
        elif kind not in ("authorized_user", "service_account"):
            raise ValueError("unsupported credential arrangement: credential type")
        for item in paths:
            if not item.is_absolute() or any(c in str(item) for c in "\n\r:") or not item.is_file():
                raise ValueError("unsupported credential arrangement: readable absolute file paths required")
            with item.open("rb"):
                pass
        return "\n".join(str(p) for p in paths)
    except (OSError, json.JSONDecodeError, TypeError, KeyError):
        raise ValueError("credentials unavailable or malformed; set GOOGLE_APPLICATION_CREDENTIALS or CLOUDSDK_CONFIG") from None


def summary(log_dir, environment, retries, skip, exists, publish_version,
            commit, source_mode, source_version, versions, yes, cancelled, *names):
    workflows = []
    for name in names:
        r = read_result(Path(log_dir) / "results" / f"{name}.result")
        workflows.append({
            "name": name,
            "target_project": r["TARGET_PROJECT"],
            "source_tarball": r.get("SOURCE_TARBALL") or None,
            "worker_exit_status": int(r.get("WORKER_EXIT_STATUS", "0")),
            "build": {"status": r["BUILD_STATUS"], "attempts": int(r["BUILD_ATTEMPTS"]),
                      "reason": r["BUILD_REASON"], "version": r["BUILD_VERSION"] or None},
            "publish": {"status": r["PUBLISH_STATUS"], "attempts": int(r["PUBLISH_ATTEMPTS"]),
                        "reason": r["PUBLISH_REASON"], "images": json.loads(r["PUBLISHED_IMAGES"])}
        })
    projects = sorted({w["target_project"] for w in workflows})
    obj = {"schema_version": 1, "dry_run": False, "cancelled": cancelled == "true",
           "repo_commit": commit or None,
           "options": {"environment": environment,
                       "target_project": projects[0] if len(projects) == 1 else None,
                       "target_projects": projects,
                       "retries": int(retries), "skip_publish": skip == "true",
                       "if_image_exists": exists, "publish_version": publish_version,
                       "source_mode": source_mode, "source_version": source_version or None,
                       "versions": [int(v) for v in versions.split(",")], "yes": yes == "true",
                       "workflows": list(names)}, "workflows": workflows}
    target = Path(log_dir) / "summary.json"
    tmp = target.with_name(f".summary.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(obj, indent=2) + "\n")
    os.replace(tmp, target)


def redaction_rules():
    """Snapshot known secrets privately before ephemeral credentials disappear."""
    paths = credentials().splitlines()
    replacements = set(paths)
    secret_keys = {"private_key", "private_key_id", "client_secret", "refresh_token",
                   "access_token", "id_token", "subject_token"}
    def collect(obj):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key in secret_keys and isinstance(value, str) and value:
                    replacements.add(value)
                    replacements.add(json.dumps(value)[1:-1])
                collect(value)
        elif isinstance(obj, list):
            for value in obj:
                collect(value)
    for index, path in enumerate(paths):
        raw = Path(path).read_text()
        if index and raw.strip():
            replacements.add(raw.strip())
        try:
            collect(json.loads(raw))
        except json.JSONDecodeError:
            pass
    return sorted(replacements)


def redact(log_dir):
    # Snapshot arrives over stdin, never argv, exported environment, or artifacts.
    replacements = set(json.load(sys.stdin))
    try:
        # Include newly rotated credentials too when they are still available.
        replacements.update(redaction_rules())
    except (ValueError, OSError):
        pass
    for path in Path(log_dir).rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        original = path.read_bytes()
        redacted = original
        for value in sorted(replacements, key=len, reverse=True):
            redacted = redacted.replace(value.encode(), b"[REDACTED]")
        if original != redacted:
            path.write_bytes(redacted)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "target-project":
            print(target_project(*sys.argv[2:]))
        elif sys.argv[1] == "source":
            print(source(sys.argv[2]))
        elif sys.argv[1] == "redaction-rules":
            print(json.dumps(redaction_rules()))
        elif sys.argv[1] == "redact":
            redact(sys.argv[2])
        elif sys.argv[1] == "summary":
            summary(*sys.argv[2:])
        elif sys.argv[1] == "credentials":
            print(credentials())
        elif sys.argv[1] == "verify":
            print(json.dumps(verify(*sys.argv[2:])))
        else:
            raise ValueError("unknown data operation")
    except (ValueError, OSError) as exc:
        print(f"ERROR: data validation failed: {exc}", file=sys.stderr)
        sys.exit(1)
