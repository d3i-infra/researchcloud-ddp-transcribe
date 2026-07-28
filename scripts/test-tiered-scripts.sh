#!/usr/bin/env bash
# test-tiered-scripts.sh — hermetic tests for the tiered-mode generated
# scripts (no Yoda, no SRC needed). Renders the workspace_layout templates
# with tiered vars via ansible's template module, then executes them against
# temp dirs and a fake `gocmd` PATH shim (same approach as test-yoda-sync.sh).
set -uo pipefail   # no -e: failures are counted and reported

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
ANSIBLE="${REPO}/.venv/bin/ansible"
TPL="${REPO}/roles/workspace_layout/templates"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FAIL=0
check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok: ${desc}"; else echo "FAIL: ${desc}"; FAIL=$((FAIL+1)); fi
}

# ---- layout: boot (hot), volume (interim), fake remote (yoda) --------------
BOOT="${TMP}/boot";   mkdir -p "${BOOT}/ddp-work/inbox" "${BOOT}/ddp-work/transcripts" "${BOOT}/ddp-state"
VOL="${TMP}/volume";  mkdir -p "${VOL}/inbox" "${VOL}/transcripts"
export FAKE_REMOTE="${TMP}/remote"; mkdir -p "${FAKE_REMOTE}/coll/inbox"
export FAKE_GOCMD_LOG="${TMP}/gocmd.log"; : > "${FAKE_GOCMD_LOG}"

# fake gocmd: reuse test-yoda-sync.sh's shim verbatim by extracting it is
# overkill — a minimal sync/get/ls/bun subset suffices for these paths.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gocmd" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "gocmd $*" >> "${FAKE_GOCMD_LOG}"
resolve() { case "$1" in i:*) printf '%s' "${FAKE_REMOTE}${1#i:}";; *) printf '%s' "$1";; esac; }
cmd="$1"; shift
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --thread_num|--timeout|-D) shift 2 ;;
    -*)                        shift ;;
    *)                         args+=("$1"); shift ;;
  esac
done
case "${cmd}" in
  ls)   p="$(resolve "${args[0]}")"; [ -e "${p}" ] || { echo "not found" >&2; exit 1; }; ls "${p}" ;;
  sync) s="$(resolve "${args[0]}")"; d="$(resolve "${args[1]}")"
        if [ -d "${d}" ]; then cp -r "${s}" "${d}/"; else mkdir -p "${d}"; cp -r "${s}/." "${d}/"; fi ;;
  get)  s="$(resolve "${args[0]}")"; d="${args[1]}"; cp -r "${s}" "${d}" ;;
  put)  s="${args[0]}"; d="$(resolve "${args[1]}")"; mkdir -p "$(dirname "${d}")"; cp "${s}" "${d}" ;;
  bun)  a="$(resolve "${args[0]}")"; out="$(resolve "${args[1]}")"; mkdir -p "${out}"; tar -xf "${a}" -C "${out}" ;;
  mkdir) mkdir -p "$(resolve "${args[0]}")" ;;
  *)    exit 0 ;;
esac
FAKE
chmod +x "${TMP}/bin/gocmd"
export PATH="${TMP}/bin:${PATH}"

# pipeline_home hosts the real yoda-sync.sh, as on a workspace
PHOME="${TMP}/home"; mkdir -p "${PHOME}"
cp "${HERE}/yoda-sync.sh" "${PHOME}/yoda-sync.sh"; chmod +x "${PHOME}/yoda-sync.sh"

render() { # render <template> <dest> [tiered]
  local tpl="$1" dest="$2" tiered="${3:-true}"
  "${ANSIBLE}" localhost -c local -m ansible.builtin.template \
    -a "src=${TPL}/${tpl} dest=${dest} mode=0755" \
    -e "storage_backend=yoda" -e "tiered_storage=${tiered}" \
    -e "storage_root=${VOL}" -e "yoda_collection=/coll" \
    -e "work_dir=${BOOT}/ddp-work" -e "state_dir=${BOOT}/ddp-state" \
    -e "pipeline_home=${PHOME}" -e "cuda_build=false" \
    -e "download_workers=3" -e "compute_lang_probs=false" \
    >/dev/null
}

# ---- 1. sync-to-storage.sh: tiered render is the rsync branch --------------
render sync-to-storage.sh.j2 "${TMP}/sync-to-storage.sh"
check "tiered sync renders rsync (hop 1)"      grep -q 'rsync -a' "${TMP}/sync-to-storage.sh"
check "tiered sync has no gocmd/yoda-sync"     bash -c "! grep -q 'yoda-sync.sh' '${TMP}/sync-to-storage.sh'"
render sync-to-storage.sh.j2 "${TMP}/sync-plain.sh" false
check "plain-yoda sync still uses yoda-sync"   grep -q 'yoda-sync.sh" push' "${TMP}/sync-plain.sh"

# hop 1 executes: transcript + snapshot land on the volume
mkdir -p "${BOOT}/ddp-work/transcripts/42"; echo t > "${BOOT}/ddp-work/transcripts/42/a.json"
command -v sqlite3 >/dev/null && sqlite3 "${BOOT}/ddp-state/state.sqlite" 'CREATE TABLE IF NOT EXISTS x(i);'
check "hop 1 runs"                             "${TMP}/sync-to-storage.sh"
check "hop 1 landed transcript on volume"      test -f "${VOL}/transcripts/42/a.json"
check "hop 1 landed snapshot on volume"        test -f "${VOL}/state-snapshot.sqlite"

# ---- 2. push-to-yoda.sh: hop 2 volume -> fake Yoda -------------------------
render push-to-yoda.sh.j2 "${TMP}/push-to-yoda.sh"
check "hop 2 runs"                             "${TMP}/push-to-yoda.sh"
check "hop 2 landed shard tar"                 test -f "${FAKE_REMOTE}/coll/transcripts-tars/shard-42.tar"
check "hop 2 pushed state snapshot"            test -f "${FAKE_REMOTE}/coll/state-snapshot.sqlite"
check "hop 2 cleaned stable snapshot copy"     bash -c "! ls '${VOL}'/.state-snapshot.hop2.sqlite 2>/dev/null"

# ---- 3. pull-from-yoda.sh: seed a fresh volume -----------------------------
VOL2="${TMP}/volume2"; mkdir -p "${VOL2}/inbox" "${VOL2}/transcripts"
echo '{}' > "${FAKE_REMOTE}/coll/inbox/donor1.json"
VOL="${VOL2}" render pull-from-yoda.sh.j2 "${TMP}/pull-from-yoda.sh"  # re-render against VOL2
check "pull-from-yoda runs"                    "${TMP}/pull-from-yoda.sh"
check "inbox seeded onto volume"               test -f "${VOL2}/inbox/donor1.json"

# ---- 4. restore-from-storage.sh: guard + hydrate ---------------------------
VOL3="${TMP}/volume3"; mkdir -p "${VOL3}/inbox" "${VOL3}/transcripts"
BOOT3="${TMP}/boot3"; mkdir -p "${BOOT3}/ddp-work/inbox" "${BOOT3}/ddp-work/transcripts" "${BOOT3}/ddp-state"
VOL="${VOL3}" BOOT="${BOOT3}" render restore-from-storage.sh.j2 "${TMP}/restore3.sh"
check "restore fails loudly on empty volume"   bash -c "! '${TMP}/restore3.sh'"
echo '{}' > "${VOL3}/inbox/d.json"
check "restore passes with inbox only (fresh campaign)" "${TMP}/restore3.sh"
check "restore hydrated boot inbox"            test -f "${BOOT3}/ddp-work/inbox/d.json"

echo; [ "${FAIL}" -eq 0 ] && echo "ALL PASS" || { echo "${FAIL} FAILURES"; exit 1; }
