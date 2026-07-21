#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline_file="$repo_dir/UPSTREAM_BASELINE.json"
api_url="https://api.github.com/repos/BeipDev/BeipMU/commits/master"
archive_root="https://github.com/BeipDev/BeipMU/archive"
upstream_checkout=$(CDPATH= cd -- "$repo_dir/../BeipMU-win" && pwd)
temporary_dir=$(mktemp -d)
trap 'rm -r "$temporary_dir"' EXIT HUP INT TERM

case "$temporary_dir/" in
  "$upstream_checkout/"*)
    echo "Refusing audit: temporary output resolved inside the Windows checkout" >&2
    exit 1
    ;;
esac

baseline_sha=$(python3 - "$baseline_file" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not data.get("upstreamCheckoutIsReadOnly"):
    raise SystemExit("Refusing audit: read-only upstream policy is not enabled")
print(data["auditedCommit"])
PY
)
echo "Audited baseline: $baseline_sha"

curl --fail --silent --show-error --location "$api_url" --output "$temporary_dir/commit.json"
remote_sha=$(python3 - "$temporary_dir/commit.json" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["sha"])
PY
)
echo "Remote master:    $remote_sha"

# Audits use disposable GitHub archives and never run git against the supplied
# Windows checkout. Keeping the archive outside Git also prevents accidental
# redistribution of reference source or binaries.
curl --fail --silent --show-error --location \
  "$archive_root/$remote_sha.tar.gz" --output "$temporary_dir/upstream.tar.gz"
tar -tzf "$temporary_dir/upstream.tar.gz" >/dev/null
archive_sha=$(shasum -a 256 "$temporary_dir/upstream.tar.gz" | awk '{print $1}')
echo "Archive SHA-256:  $archive_sha"

python3 - "$baseline_file" "$temporary_dir/commit.json" "$archive_sha" <<'PY'
import json, pathlib, sys
baseline = json.loads(pathlib.Path(sys.argv[1]).read_text())
remote = json.loads(pathlib.Path(sys.argv[2]).read_text())
sha = remote["sha"]
if sha == baseline["auditedCommit"]:
    expected_archive = baseline.get("sourceArchiveSHA256")
    if expected_archive and expected_archive != sys.argv[3]:
        raise SystemExit("The source archive checksum does not match UPSTREAM_BASELINE.json")
    print("Parity audit is current.")
else:
    print("Upstream changed. Update the parity matrix before changing the audited baseline.")
    raise SystemExit(2)
PY
