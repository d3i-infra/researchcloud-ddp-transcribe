#!/usr/bin/env bash
# Tier 2 verification: run the playbook's CPU path twice inside a clean
# ubuntu:24.04 container. Run 1 includes the gated smoke test; run 2 runs
# without it and must report changed=0 (idempotency).
#
# Usage: scripts/tier2-docker.sh [git-ref] [cpus]
#   git-ref  pipeline_git_ref to build (default: the playbook default)
#   cpus     docker CPU cap (default 4; keep low on thermally-limited hosts)
set -euo pipefail

REF="${1:-}"
CPUS="${2:-4}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REF_ARG=""
if [[ -n "$REF" ]]; then REF_ARG="-e pipeline_git_ref=$REF"; fi

docker run --rm --cpus="$CPUS" -v "$REPO_DIR":/component:ro ubuntu:24.04 bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -yq python3-pip python3-venv sudo git >/dev/null
python3 -m venv /opt/ansible
/opt/ansible/bin/pip install -q 'ansible==9.1.0'
useradd -m -s /bin/bash pipeline
mkdir -p /home/pipeline/storage && chown pipeline:pipeline /home/pipeline/storage

run_playbook() {
  /opt/ansible/bin/ansible-playbook /component/deploy-ddp-transcribe.yaml \
    -e storage_path=/home/pipeline/storage \
    -e pipeline_user=pipeline \
    -e model_large_v3_turbo=false \
    -e model_tiny_en=true \
    -e run_smoke_test=\$1 \
    $REF_ARG
}

echo '=== TIER 2 RUN 1 (cold, with smoke test) ==='
run_playbook true | tee /tmp/run1.log
echo '=== TIER 2 RUN 2 (idempotency, no smoke test) ==='
run_playbook false | tee /tmp/run2.log

recap=\$(grep -A2 'PLAY RECAP' /tmp/run2.log | tail -1)
echo \"run 2 recap: \$recap\"
changed=\$(echo \"\$recap\" | sed -n 's/.*changed=\\([0-9]*\\).*/\\1/p')
if [[ \"\$changed\" -eq 0 ]]; then
  echo 'TIER 2 PASS (run-2 changed=0)'
else
  echo \"TIER 2 FAIL (run-2 changed=\$changed — non-idempotent tasks present)\"
  exit 1
fi
"
