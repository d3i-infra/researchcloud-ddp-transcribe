#!/usr/bin/env bash
# test-yoda-sync.sh — hermetic tests for scripts/yoda-sync.sh (no Yoda needed).
# A fake `gocmd` on PATH maps i:<path> onto a local "remote" dir, so staging,
# reproducibility, push/pull logic, server-side extraction (bun -x), and the
# legacy fallback all run offline. The live-Yoda round trip is a separate
# operator step (see the plan/spec).
set -uo pipefail   # no -e: failures are counted and reported

HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="${HERE}/yoda-sync.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export FAKE_REMOTE="${TMP}/remote"
export FAKE_GOCMD_LOG="${TMP}/gocmd.log"

# ---- fake gocmd (PATH shim) ------------------------------------------------
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
  ls)
    p="$(resolve "${args[0]}")"
    [ -e "${p}" ] || { echo "not found: ${args[0]}" >&2; exit 1; }
    ls "${p}"
    ;;
  sync)   # gocmd rule: DEST exists -> DEST/basename(SRC); else DEST gets contents
    s="$(resolve "${args[0]}")"; d="$(resolve "${args[1]}")"
    if [ -d "${d}" ]; then cp -r "${s}" "${d}/"; else mkdir -p "${d}"; cp -r "${s}/." "${d}/"; fi
    ;;
  put)
    s="${args[0]}"; d="$(resolve "${args[1]}")"
    mkdir -p "$(dirname "${d}")"; cp "${s}" "${d}"
    ;;
  get)    # collection -> lands as <dest>/<collname>; data object -> plain copy
    s="$(resolve "${args[0]}")"; d="${args[1]}"
    [ -e "${s}" ] || { echo "not found: ${args[0]}" >&2; exit 1; }
    if [ -d "${s}" ]; then mkdir -p "${d}"; cp -r "${s}" "${d}/"; else mkdir -p "$(dirname "${d}")"; cp "${s}" "${d}"; fi
    ;;
  bun)    # server-side extraction: bun -x -f -D tar i:<tar> i:<dest-collection>
    s="$(resolve "${args[0]}")"; d="$(resolve "${args[1]}")"
    [ -e "${s}" ] || { echo "not found: ${args[0]}" >&2; exit 1; }
    mkdir -p "${d}"; tar -xf "${s}" -C "${d}"
    ;;
  *) echo "fake gocmd: unhandled subcommand ${cmd}" >&2; exit 9 ;;
esac
FAKE
chmod +x "${TMP}/bin/gocmd"
export PATH="${TMP}/bin:${PATH}"

# ---- helpers ----------------------------------------------------------------
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

fresh_workdir() {
  WORK="${TMP}/work-${RANDOM}"
  mkdir -p "${WORK}/transcripts/00" "${WORK}/transcripts/17" "${WORK}/transcripts/.work"
  echo '{"id":100}'      > "${WORK}/transcripts/00/100.json"
  echo 'transcript 100'  > "${WORK}/transcripts/00/100.txt"
  echo '{"id":217}'      > "${WORK}/transcripts/17/217.json"
  echo 'secret scratch'  > "${WORK}/transcripts/17/.hidden"
  echo 'big media'       > "${WORK}/transcripts/.work/media.mp4"
  export YODA_COLLECTION="/nluu10p/home/research-test"
  export YODA_TRANSCRIPTS_LOCAL="${WORK}/transcripts"
  export YODA_STATE_SNAPSHOT="${WORK}/state-snapshot.sqlite"
  unset YODA_TAR_STAGE 2>/dev/null || true
  unset YODA_EXTRACT 2>/dev/null || true
  R="${FAKE_REMOTE}${YODA_COLLECTION}"
  rm -rf "${FAKE_REMOTE}"; mkdir -p "${R}"
  : > "${FAKE_GOCMD_LOG}"
}

# ---- Task 1: staging ----------------------------------------------------------
echo "— stage-transcripts"
fresh_workdir
"${SYNC}" stage-transcripts
STAGE="${WORK}/transcripts-tars"
check "stage dir created next to transcripts"  '[ -d "${STAGE}" ]'
check "one tar per numeric shard, nothing else" '[ -f "${STAGE}/shard-00.tar" ] && [ -f "${STAGE}/shard-17.tar" ] && [ "$(ls "${STAGE}" | wc -l)" -eq 2 ]'
check "no tar for hidden .work dir"            '! ls "${STAGE}" | grep -q work'
check "in-shard dotfile excluded"              '! tar -tf "${STAGE}/shard-17.tar" | grep -q hidden'
check "members rooted at NN/"                  'tar -tf "${STAGE}/shard-00.tar" | grep -qx "00/100.json"'

echo "— reproducibility"
sum1="$(md5sum "${STAGE}/shard-00.tar" | cut -d" " -f1)"
touch "${WORK}/transcripts/00/100.json"        # mtime-only change
"${SYNC}" stage-transcripts
sum2="$(md5sum "${STAGE}/shard-00.tar" | cut -d" " -f1)"
check "mtime-only change -> identical tar"     '[ "${sum1}" = "${sum2}" ]'
echo 'changed' >> "${WORK}/transcripts/00/100.txt"
"${SYNC}" stage-transcripts
sum3="$(md5sum "${STAGE}/shard-00.tar" | cut -d" " -f1)"
check "content change -> different tar"        '[ "${sum1}" != "${sum3}" ]'

echo "— staging dir basename guard"
fresh_workdir
if YODA_TAR_STAGE="${TMP}/wrong-name" "${SYNC}" stage-transcripts 2>/dev/null; then
  bad "wrong YODA_TAR_STAGE basename accepted"
else
  ok "wrong YODA_TAR_STAGE basename rejected"
fi

# ---- summary ------------------------------------------------------------------
echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
