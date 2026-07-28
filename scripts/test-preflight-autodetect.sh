#!/usr/bin/env bash
# test-preflight-autodetect.sh — hermetic tests for preflight's storage-volume
# auto-detection (no SRC needed). Runs the real preflight role via a scratch
# play, injecting fake mount tables (storage_mounts_source) and a temp data
# root (storage_data_root) so every case runs offline as the current user.
# Contract under test: preflight resolves the storage_path INPUT (an SRC
# extra-var, which set_fact cannot override) into the storage_root FACT that
# all consumers use; exactly-one mounted volume is adopted automatically.
set -uo pipefail   # no -e: failures are counted and reported

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PLAYBOOK="${REPO}/.venv/bin/ansible-playbook"
[ -x "${PLAYBOOK}" ] || { echo "missing ${PLAYBOOK} — set up the repo .venv first" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FAIL=0
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok: ${desc}"; else echo "FAIL: ${desc}"; FAIL=$((FAIL+1)); fi; }

DATA="${TMP}/data"
ME="$(id -un)"

cat > "${TMP}/scratch.yaml" <<'PLAY'
---
- name: Preflight auto-detect scratch harness
  hosts: 127.0.0.1
  connection: local
  gather_facts: false
  roles:
    - role: preflight
  tasks:
    - name: Report resolved facts
      ansible.builtin.debug:
        msg: "RESOLVED storage_root=[{{ storage_root | default('') }}] tiered=[{{ tiered_storage | default('') }}]"
PLAY

mounts() { # mounts <dir...> -> full -e JSON dict (key=value -e args arrive as
  local out first=1 d  # strings; only the '{...}' form yields a real list)
  out='{"storage_mounts_source": ['
  for d in "$@"; do
    [ "${first}" -eq 1 ] || out+=","
    out+="{\"mount\": \"${d}\"}"
    first=0
  done
  printf '%s]}' "${out}"
}

run() { # run <case-log> <extra -e args...>
  local log="$1"; shift
  ANSIBLE_ROLES_PATH="${REPO}/roles" "${PLAYBOOK}" "${TMP}/scratch.yaml" \
    -e "pipeline_user=${ME}" -e "storage_data_root=${DATA}" "$@" \
    > "${TMP}/${log}" 2>&1
}

# ---- 1. mount backend, one volume attached, no storage_path ----------------
rm -rf "${DATA}"; mkdir -p "${DATA}/vol1"
run c1.log -e storage_backend=src-volume -e "$(mounts "${DATA}/vol1")"
check "one volume: play succeeds"            bash -c "! grep -q 'failed=1' '${TMP}/c1.log'"
check "one volume: adopted as storage_root"  grep -qF "RESOLVED storage_root=[${DATA}/vol1]" "${TMP}/c1.log"

# ---- 2. mount backend, no volume, no storage_path --------------------------
rm -rf "${DATA}"; mkdir -p "${DATA}"
run c2.log -e storage_backend=src-volume -e '{"storage_mounts_source": []}'
check "no volume: play fails"                grep -q 'failed=1' "${TMP}/c2.log"
check "no volume: actionable message"        grep -qi 'attach a volume' "${TMP}/c2.log"

# ---- 3. mount backend, two volumes, no storage_path ------------------------
rm -rf "${DATA}"; mkdir -p "${DATA}/vol1" "${DATA}/vol2"
run c3.log -e storage_backend=src-volume -e "$(mounts "${DATA}/vol1" "${DATA}/vol2")"
check "two volumes: play fails"              grep -q 'failed=1' "${TMP}/c3.log"
check "two volumes: ambiguity named"         grep -qi 'set storage_path explicitly' "${TMP}/c3.log"

# ---- 4. yoda backend, one volume -> tiered on ------------------------------
rm -rf "${DATA}"; mkdir -p "${DATA}/vol1"
run c4.log -e storage_backend=yoda -e "$(mounts "${DATA}/vol1")" \
  -e yoda_collection=/zone/home/x -e yoda_user=u@x -e yoda_data_access_password=p
check "yoda+volume: play succeeds"           bash -c "! grep -q 'failed=1' '${TMP}/c4.log'"
check "yoda+volume: tiered activates"        grep -qF "tiered=[True]" "${TMP}/c4.log"

# ---- 5. yoda backend, no volume -> plain yoda ------------------------------
rm -rf "${DATA}"; mkdir -p "${DATA}"
run c5.log -e storage_backend=yoda -e '{"storage_mounts_source": []}' \
  -e yoda_collection=/zone/home/x -e yoda_user=u@x -e yoda_data_access_password=p
check "yoda no volume: play succeeds"        bash -c "! grep -q 'failed=1' '${TMP}/c5.log'"
check "yoda no volume: tiered stays off"     grep -qF "tiered=[False]" "${TMP}/c5.log"

# ---- 6. explicit storage_path wins over detection --------------------------
rm -rf "${DATA}"; mkdir -p "${DATA}/vol1" "${TMP}/explicit"
run c6.log -e storage_backend=src-volume -e "$(mounts "${DATA}/vol1")" \
  -e "storage_path=${TMP}/explicit"
check "explicit path: play succeeds"         bash -c "! grep -q 'failed=1' '${TMP}/c6.log'"
check "explicit path: respected verbatim"    grep -qF "RESOLVED storage_root=[${TMP}/explicit]" "${TMP}/c6.log"

# ---- 7. unedited placeholder counts as unset -> detection runs -------------
rm -rf "${DATA}"; mkdir -p "${DATA}/vol1"
run c7.log -e storage_backend=src-volume -e "$(mounts "${DATA}/vol1")" \
  -e 'storage_path=/home/<username>/data/<volume-name>'
check "placeholder: play succeeds"           bash -c "! grep -q 'failed=1' '${TMP}/c7.log'"
check "placeholder: detection supersedes"    grep -qF "RESOLVED storage_root=[${DATA}/vol1]" "${TMP}/c7.log"

# ---- 8. symlink flavor: ~/data/<vol> -> shared mount elsewhere -------------
# SRC (per operator report) may mount volumes once at a shared path and give
# each user a symlink under ~/data; detection must follow the link and match
# its TARGET against the mount table, adopting the ~/data-side path.
rm -rf "${DATA}"; mkdir -p "${DATA}" "${TMP}/shared/vol1"
ln -s "${TMP}/shared/vol1" "${DATA}/vol1"
run c8.log -e storage_backend=src-volume -e "$(mounts "${TMP}/shared/vol1")"
check "symlinked volume: play succeeds"      bash -c "! grep -q 'failed=1' '${TMP}/c8.log'"
check "symlinked volume: adopted via link"   grep -qF "RESOLVED storage_root=[${DATA}/vol1]" "${TMP}/c8.log"

# ---- 9. stray plain dir (not a mount, not a link to one) is rejected -------
rm -rf "${DATA}"; mkdir -p "${DATA}/not-a-volume"
run c9.log -e storage_backend=src-volume -e '{"storage_mounts_source": []}'
check "stray dir: play fails (no volume)"    grep -q 'failed=1' "${TMP}/c9.log"

# ---- 10. the data dir ITSELF is a symlink to a shared mount root -----------
# Live-observed flavor (2026-07-28 launch failure): ~/data -> /data (shared),
# volumes are real dirs under the target and the mount table lists the REAL
# paths. Detection must resolve the root symlink before walking.
rm -rf "${DATA}"; mkdir -p "${TMP}/sharedroot/vol1"
ln -s "${TMP}/sharedroot" "${DATA}"
run c10.log -e storage_backend=src-volume -e "$(mounts "${TMP}/sharedroot/vol1")"
check "symlinked data root: play succeeds"   bash -c "! grep -q 'failed=1' '${TMP}/c10.log'"
check "symlinked data root: volume adopted"  grep -qF "RESOLVED storage_root=[${TMP}/sharedroot/vol1]" "${TMP}/c10.log"

echo; [ "${FAIL}" -eq 0 ] && echo "ALL PASS" || { echo "${FAIL} FAILURES"; exit 1; }
