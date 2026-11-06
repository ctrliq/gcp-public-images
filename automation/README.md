# Parallel Rocky image builds

`build_all.sh` runs **every selected workflow in parallel**, with independent build
and publish retry loops. There is intentionally no concurrency-limit option.
Production promotion policy and test-evidence gates belong in the calling pipeline,
not in this build script.

```bash
# Plan only; no cloud calls, credential reads, or persistent output.
./automation/build_all.sh --dry-run

# Build without publishing.
./automation/build_all.sh --versions 8,9 --skip-publish

# Retry publication from completed builds (including earlier publish failures).
./automation/build_all.sh --versions 9 --source-results /path/to/run/results

# Noninteractive production publication requires explicit approval.
./automation/build_all.sh --versions 9 --source-version v1774034849 \
  --environment prod --yes
```

Use `--help` for all options. Versions are limited to `8,9,10`; workflow names
must exist in the selected versions. Empty selections and missing option values
are errors. `--retries N` means N retries **after** the initial attempt, independently
for building and publishing; decimal integers from 0 through 999999 are accepted.
A source version must literally match `v[0-9]+` and is never normalized (including
leading zeroes). Source flags are mutually exclusive, and cannot be combined with
`--skip-publish`.

Production requires source artifacts, forbids `--if-image-exists delete`, and
prompts on a terminal unless `--yes` is supplied. Without a terminal, missing
`--yes` fails **before cloud access**. Dry-run never prompts. Each workflow's target
project is resolved from its publisher template's literal `PublishProject` for the
selected environment, before approval or cloud access. Current templates use
`gce-ciq-images` for test; production uses `rocky-linux-cloud` for ordinary images
and `rocky-linux-accelerator-cloud` for NVIDIA images. There is no filename-based
project policy in the script. Dry-run and production approval show each target.
Missing, computed, duplicate, or unsupported metadata fails closed. The local
resolver supports plain JSON with an explicit project and the repository's explicit
test/prod/autopush/else Go branch shape, not arbitrary Go template execution.

## Dependencies and credentials

Real runs require Bash 4.4+, Python 3 (standard library only), gcloud, and ordinary
GNU command-line utilities. Building additionally requires Daisy; publishing
additionally requires Podman. Build-only runs do not require Podman, and source
publication does not require Daisy. `--help` needs neither Python nor cloud tools.
Dry-runs require Python for local publisher metadata validation (and source-result
validation when selected), but need no cloud tools or credentials and make no
cloud calls or writes.

Configure the host gcloud identity/configuration explicitly, using
`CLOUDSDK_CONFIG` when not using `$HOME/.config/gcloud`. Host gcloud commands use
that configuration and the normal gcloud authentication arrangement. The script
does **not** run `gcloud auth login` or modify account configuration. In CI, set up
the host gcloud WIF identity before invoking the script; ADC alone is not a
substitute for configuring host gcloud authentication.

Daisy and the publisher use the file specified by
`GOOGLE_APPLICATION_CREDENTIALS`. When unset, the script selects
`$CLOUDSDK_CONFIG/application_default_credentials.json` (or the same file under
`$HOME/.config/gcloud`). The selected file must be readable and use an absolute
path. Service-account and authorized-user ADC are supported. External-account
(WIF) ADC is supported for **file-based** `credential_source.file`: both the ADC
and its subject-token file must exist at absolute paths. The publisher mounts
these exact paths read-only, preserving references inside WIF configuration.
Executable/URL-sourced WIF and other credential types are rejected explicitly;
no publisher authentication flags are invented. Keep credential and token files
available while Daisy/publisher are using them. Known redaction values are
snapshotted privately in shell memory before execution, so removing an ephemeral
credential file afterward does not prevent final redaction or summary generation.
Final redaction also includes rotated values when the files are still readable.

Publisher credential mounts are not printed. Results and summary options never
include credential paths or contents. At completion the script also redacts known
credential paths, ADC secret values, and WIF subject-token contents from logs.
Treat in-progress logs as sensitive; redaction is defense in depth, not a license
to enable credential-debug output or archive the host gcloud directory. Use an
isolated CI credential directory and restrict artifact permissions/access.

## Results and verification

Set `LOG_DIR` to select a run directory; otherwise a timestamped directory is
created under `automation/tmp`. Always use a fresh results directory: a preexisting
`LOG_DIR/results` is rejected rather than mixing runs. No persistent result or
JSON summary is created by dry-run.

Each workflow has an atomically replaced `results/<workflow>.result` file. Existing
fields are retained: `BUILD_STATUS`, `BUILD_ATTEMPTS`, `BUILD_REASON`,
`BUILD_VERSION`, `PUBLISH_STATUS`, `PUBLISH_ATTEMPTS`, `PUBLISH_REASON`. Additional
fields are `TARGET_PROJECT`, `SOURCE_TARBALL`, `PUBLISHED_IMAGES` (a JSON array), and
`WORKER_EXIT_STATUS`. Terminal states distinguish `PASS`, `FAIL`, `SKIPPED`,
`CANCELLED`, and `NOT_ATTEMPTED`. Completed builds survive publish failures and
cancellation. A worker crash is reconciled by the parent, not silently ignored.
A nonzero `WORKER_EXIT_STATUS` fails the run even if the worker completed its
build/publish stages before exiting; completed stage results are not rewritten.
If final redaction fails, the script still attempts summary generation, exits
nonzero, and warns not to archive the logs. Cancellation retains its signal exit
code; callers must treat failed redaction diagnostics as an artifact safety error.

`--source-results` parses files as data, never shell code. Every line must be a
unique `UPPERCASE_KEY=value` field. `BUILD_STATUS` must be `PASS` or `SKIPPED`, and
`BUILD_VERSION` must match `v[0-9]+`; prior `PUBLISH_STATUS=FAIL` is allowed.
Failed builds, duplicate keys, malformed lines, missing required fields, or
invalid versions fail before cloud access. Validated versions are snapshotted
before workers start.

`summary.json` is atomically written after workers finish, including failures and
handled cancellations. Schema version 1 includes safe effective options, selected
versions/workflows, repository commit (`null` if unavailable), source tarballs,
build/publish states and attempts, cancellation state, worker exit codes, and
verified published-image identifiers. It records `dry_run: false`; dry-runs are
plans, not successful executions.

Each summary workflow includes `target_project`. Effective options include sorted
`target_projects`; `target_project` retains the scalar for a single target and is
`null` for mixed-target runs. Results carry the resolved target even before a
worker launches or if it is cancelled.

One UTC `vYYYYMMDD` publication version is frozen at script startup and passed via
the publisher's `-publish_version` flag **instead of** `-date_version`. This keeps
existence checks, publication, and readback aligned across UTC day boundaries.
The publisher's successful exit is not sufficient for `PUBLISH_STATUS=PASS`:
gcloud must read back the exact target image with matching name/selfLink, numeric
ID, and `READY` status. Summary image identifiers/IDs come from that readback.
If the API returns `rawDisk.source`, it must match the expected source tarball;
otherwise the summary explicitly records `source_verified: false`. Identity
readback alone is not a provenance or promotion-policy guarantee. Readback failure
is terminal rather than blindly republishing an image that may already exist.

`--if-image-exists skip` is explicitly `existing-image-unverified`, not a verified
publication or promotion signal. Only a target-specific image-not-found response
allows publication after a failed existence lookup; permission, authentication,
and network errors fail closed. Delete failures are fatal, and successful deletes
require absence readback before continuing. A serial-log fetch failure is an
infrastructure failure: it never deletes a tarball or rebuilds the workflow.

## Cancellation and cleanup limits

INT and TERM stop further launches, terminate each tracked worker process group,
escalate to KILL for resistant descendants, and wait/reconcile results. Exit status
is 130 for INT and 143 for TERM; ordinary failed workflows exit nonzero. Completed
logs/results and a cancelled summary remain available. Normal children and
grandchildren are covered; deliberately detached sessions/daemonized processes
can escape Unix process-group supervision and require runner/cgroup supervision.
SIGKILL, machine loss, and filesystem failures cannot guarantee final summaries.

Stopping local processes does **not** guarantee cleanup of GCE instances, disks,
images, publisher resources, or GCS objects already created remotely. Inspect
Daisy/publisher logs and apply your cloud cleanup policy. Cancellation never
attempts broad cloud deletion.

## Local tests (no cloud access)

```bash
bash -n automation/build_all.sh
shellcheck automation/build_all.sh
bats automation/tests/build_all.bats
```

Every test installs fail-closed Daisy, gcloud, and Podman stubs before execution;
specialized mocks replace those stubs as needed. Tests use scratch directories
under `$TMPDIR`, never real credentials or a cloud endpoint.
