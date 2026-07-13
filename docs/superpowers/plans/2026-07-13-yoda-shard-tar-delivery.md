# Yoda Shard-Tar Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **AMENDED 2026-07-13** after live experiments (`.superpowers/sdd/yoda-experiments-2026-07-13.md`): plain uncompressed tars (no gzip — `-D tar` is the verified server-side extraction format), and `push-transcripts` now also extracts changed shards server-side via `gocmd bun -x` (default-on, `YODA_EXTRACT=0` to disable), producing a per-file browsable `<collection>/transcripts/` tree.

**Goal:** Replace per-file transcript delivery to Yoda with byte-reproducible per-shard tar archives plus server-side extraction, so milestone syncs take minutes-to-tens-of-minutes (bounded remote ops) instead of days, while researchers keep a per-file browsable tree.

**Architecture:** All logic lands in `scripts/yoda-sync.sh` (installed to `$HOME` by `roles/workspace_layout`; the generated `sync-to-storage.sh` / `restore-from-storage.sh` wrappers keep calling `push` / `pull-resume` / `pull-inbox` unchanged). A `stage-transcripts` verb builds reproducible `shard-NN.tar` archives in a staging dir; `push-transcripts` = stage → changed-shard detection (md5 manifest) → one `gocmd sync` → `gocmd bun -x` per changed shard into `<collection>/transcripts/`; `pull-resume` restores from the tars (never the projection) and falls back to a legacy plain tree. A hermetic test harness fakes `gocmd` (including `bun`) via a PATH shim so everything except the live Yoda round-trip runs offline.

**Tech Stack:** Bash (strict mode), GNU tar (no compression, no new package dependencies), GoCommands (`gocmd`) for iRODS transfer + server-side extraction.

**Spec:** `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md` (approved 2026-07-13, amended same day).

## Global Constraints

- **Claude never runs `git commit` or `git push`** (d3i CLAUDE.md scope policy). Every commit step: stage with `git add`, then report the exact `git commit` command for Danielle to run. Do not proceed past a commit step until she confirms.
- Reproducible tar recipe, verbatim (NO compression): `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --format=gnu --exclude='.*' -C <transcripts> NN`.
- The staging dir basename MUST be `transcripts-tars` (gocmd's basename-append rule: `sync SRC DEST` creates `DEST/basename(SRC)` when DEST exists).
- Transfer thread count: default `--thread_num 10`, never exceed 15 (30 threads saturated the server for all users, measured 2026-07-06).
- Extraction: `gocmd bun -x -f -D tar --timeout ${YODA_BUN_TIMEOUT:-1200}`, per changed shard only, default-on (`YODA_EXTRACT` ≠ 0). `-f` is required for re-delivery (bare re-extract fails `SYS_COPY_ALREADY_IN_RESC`).
- Changed-shard manifest: `$(dirname <stage>)/.transcripts-tars-pushed.md5`, rewritten only after sync + extraction fully succeed.
- Nothing auto-deletes remote data; a legacy plain `transcripts/` tree is simply overwritten into currency by `bun -x -f`.
- ASCII-only, no spaces, no quotes in anything created on Yoda.
- `YODA_BULK` / `--bulk_upload` is deleted, not deprecated. The word "bulk" must not appear in `scripts/yoda-sync.sh` at all (a harness test greps for it).
- Conventional Commits messages; branch `feature/yoda-shard-tar-delivery`.

## Prerequisites (operator, before execution)

1. In-flight changes on `fix/yoda-irods-env-keys` committed (DONE 2026-07-13: `f3ce35a`, `64249ed`); `test-yoda.yaml` stays untracked by its own declaration.
2. Work branch `feature/yoda-shard-tar-delivery` cut from it (DONE).
3. Task 5 (live verification) additionally needs a cached gocmd auth token on this machine (`gocmd init` with a fresh DAP) and a scratch sub-collection under the real collection. Tasks 1–4 need no network.

## File Structure

- `scripts/yoda-sync.sh` — modified: `stage-transcripts` verb + `tar_stage_dir` guard (Task 1); tar-by-default `push-transcripts` with manifest + server-side extraction, `push-transcripts-plain`, `YODA_BULK` removed (Task 2); `pull-resume` tar path + legacy fallback (Task 3).
- `scripts/test-yoda-sync.sh` — created: hermetic test harness (fake `gocmd` incl. `bun`, fixture tree, pass/fail summary). Grows with Tasks 1–3.
- `docs/FOLLOWUPS.md`, `docs/storage-backends.md`, `docs/yoda-operations.md`, `docs/catalog-item.md` — modified (Task 4; source material: `.superpowers/sdd/yoda-experiments-2026-07-13.md`); perf numbers refreshed in Task 5.

No changes to `roles/workspace_layout` templates or `roles/yoda` — the wrapper contract (`push`/`pull-resume`/`pull-inbox`, env vars `YODA_COLLECTION`, `YODA_TRANSCRIPTS_LOCAL`, `YODA_STATE_SNAPSHOT`, `YODA_INBOX_LOCAL`) is unchanged. The staging default `$(dirname $YODA_TRANSCRIPTS_LOCAL)/transcripts-tars` resolves to `{{ work_dir }}/transcripts-tars` on a workspace (boot disk) with no template edits.

---

### Task 1: Reproducible per-shard tar staging (`stage-transcripts`)

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Create: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Produces: `tar_stage_dir()` — echoes the staging dir path (`${YODA_TAR_STAGE:-$(dirname "$YODA_TRANSCRIPTS_LOCAL")/transcripts-tars}`), exits 2 if its basename ≠ `transcripts-tars`. `stage_transcripts()` — wipes/rebuilds the staging dir with one **plain, uncompressed** `shard-NN.tar` per populated 2-digit shard dir; hidden entries excluded. Verb `stage-transcripts` dispatches to it. Tasks 2–3 call both functions.

- [ ] **Step 1: Create the test harness with the staging tests**

Create `scripts/test-yoda-sync.sh` (mode 0755) with exactly:

```bash
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
```

- [ ] **Step 2: Run it to verify the new tests fail**

Run: `bash scripts/test-yoda-sync.sh`
Expected: FAIL lines for the staging tests (yoda-sync.sh exits 2 with `usage: …` because `stage-transcripts` is not a verb yet), non-zero exit.

- [ ] **Step 3: Implement staging in `scripts/yoda-sync.sh`**

Insert after the existing `irods()` helper:

```bash
# Staging dir for shard tars. Its basename MUST be `transcripts-tars`:
# `gocmd sync SRC DEST` lands SRC as DEST/basename(SRC) when DEST exists,
# which is exactly how the tars end up at <collection>/transcripts-tars.
tar_stage_dir() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  local stage="${YODA_TAR_STAGE:-$(dirname "${YODA_TRANSCRIPTS_LOCAL}")/transcripts-tars}"
  if [ "$(basename "${stage}")" != "transcripts-tars" ]; then
    echo "[yoda-sync] YODA_TAR_STAGE must end in /transcripts-tars (gocmd sync lands DEST/basename(SRC))" >&2
    exit 2
  fi
  printf '%s' "${stage}"
}

# Build one byte-REPRODUCIBLE plain shard-NN.tar per populated 2-digit shard
# dir. Reproducible (--sort/--owner/--group/--numeric-owner/--mtime/--format)
# so unchanged shards produce identical bytes and `gocmd sync`'s checksum
# diff skips them — incremental delivery with zero sync-side bookkeeping.
# Plain uncompressed tar: `-D tar` is the verified format for server-side
# extraction (gocmd bun -x, see docs/yoda-operations.md), and upload is
# bandwidth-bound (~85 MB/s measured) so compression buys nothing that
# matters. Hidden entries are excluded (the .work/ leak, FOLLOWUPS).
stage_transcripts() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  local stage; stage="$(tar_stage_dir)"
  rm -rf "${stage}"
  mkdir -p "${stage}"
  local built=0 shard name
  for shard in "${YODA_TRANSCRIPTS_LOCAL}"/[0-9][0-9]/; do
    [ -d "${shard}" ] || continue    # glob matched nothing
    name="$(basename "${shard}")"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        --format=gnu --exclude='.*' \
        -C "${YODA_TRANSCRIPTS_LOCAL}" -cf "${stage}/shard-${name}.tar" "${name}"
    built=$((built + 1))
  done
  echo "[yoda-sync] staged ${built} shard tar(s) in ${stage}"
}
```

Add the verb to the `case` dispatch and update the usage string:

```bash
  stage-transcripts) stage_transcripts ;;
```

```bash
    echo "usage: yoda-sync.sh {stage-transcripts|push-transcripts|push-state|push|pull-inbox|pull-resume}" >&2
```

- [ ] **Step 4: Run the harness to verify it passes**

Run: `bash scripts/test-yoda-sync.sh`
Expected: all `ok:` lines, `failed: 0`, exit 0.

- [ ] **Step 5: Stage and hand the commit to Danielle**

```bash
git add scripts/yoda-sync.sh scripts/test-yoda-sync.sh
```

Report for Danielle to run:

```bash
git commit -m "feat(yoda): add reproducible per-shard tar staging to yoda-sync.sh"
```

---

### Task 2: Tar-by-default push with server-side extraction; plain escape hatch; delete `YODA_BULK`

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Modify: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Consumes: `tar_stage_dir()`, `stage_transcripts()` from Task 1.
- Produces: `push_transcripts()` — stage → changed-shard set (md5 manifest at `$(dirname <stage>)/.transcripts-tars-pushed.md5`) → single `gocmd sync` (`--thread_num ${YODA_THREADS:-10}`) → per-changed-shard `gocmd bun -x -f -D tar --timeout ${YODA_BUN_TIMEOUT:-1200}` into `<collection>/transcripts` unless `YODA_EXTRACT=0` → manifest rewrite. `push_transcripts_plain()` + verb `push-transcripts-plain`. `push` still means tar push + state push. No `YODA_BULK` anywhere.

- [ ] **Step 1: Add the push tests to the harness**

Insert into `scripts/test-yoda-sync.sh` immediately before the `# ---- summary` block:

```bash
# ---- Task 2: push -------------------------------------------------------------
echo "— push-transcripts (tars + server-side extraction)"
fresh_workdir
"${SYNC}" push-transcripts
check "shard tars landed under transcripts-tars/" '[ -f "${R}/transcripts-tars/shard-00.tar" ] && [ -f "${R}/transcripts-tars/shard-17.tar" ]'
check "sync used --thread_num 10"                 'grep -q -- "--thread_num 10" "${FAKE_GOCMD_LOG}"'
check "extraction produced per-file tree"         '[ -f "${R}/transcripts/00/100.json" ] && [ -f "${R}/transcripts/17/217.json" ]'
check "one bun call per shard, right flags"       '[ "$(grep -c "^gocmd bun " "${FAKE_GOCMD_LOG}")" -eq 2 ] && grep -q -- "-x -f -D tar --timeout 1200" "${FAKE_GOCMD_LOG}"'
check "manifest written"                          '[ -f "${WORK}/.transcripts-tars-pushed.md5" ]'

echo "— idempotent second push extracts nothing"
: > "${FAKE_GOCMD_LOG}"
"${SYNC}" push-transcripts
check "no bun calls when nothing changed"         '! grep -q "^gocmd bun " "${FAKE_GOCMD_LOG}"'

echo "— single-shard change extracts exactly that shard"
echo 'more' >> "${WORK}/transcripts/17/217.json"
: > "${FAKE_GOCMD_LOG}"
"${SYNC}" push-transcripts
check "exactly one bun call"                      '[ "$(grep -c "^gocmd bun " "${FAKE_GOCMD_LOG}")" -eq 1 ]'
check "it targeted shard-17"                      'grep "^gocmd bun " "${FAKE_GOCMD_LOG}" | grep -q "shard-17.tar"'
check "updated content reached the projection"    'grep -q more "${R}/transcripts/17/217.json"'

echo "— YODA_EXTRACT=0 skips extraction"
fresh_workdir
YODA_EXTRACT=0 "${SYNC}" push-transcripts
check "tars pushed"                               '[ -f "${R}/transcripts-tars/shard-00.tar" ]'
check "no extraction happened"                    '[ ! -d "${R}/transcripts" ] && ! grep -q "^gocmd bun " "${FAKE_GOCMD_LOG}"'

echo "— push (tars + state)"
fresh_workdir
echo 'sqlite-bytes' > "${YODA_STATE_SNAPSHOT}"
"${SYNC}" push
check "shard tars landed"      '[ -f "${R}/transcripts-tars/shard-00.tar" ]'
check "state snapshot landed"  '[ -f "${R}/state-snapshot.sqlite" ]'

echo "— push-transcripts-plain (escape hatch)"
fresh_workdir
"${SYNC}" push-transcripts-plain
check "plain tree landed as transcripts/" '[ -f "${R}/transcripts/00/100.json" ]'

echo "— bulk upload removed"
check "no bulk_upload/YODA_BULK left in yoda-sync.sh" '! grep -qi "bulk" "${SYNC}"'
```

- [ ] **Step 2: Run it to verify the new tests fail**

Run: `bash scripts/test-yoda-sync.sh`
Expected: the extraction/manifest/`--thread_num` checks fail (current push syncs the plain tree, no `bun`, no manifest); `push-transcripts-plain` fails (unknown verb — with `set -uo pipefail` in the harness the run continues); the "bulk" grep fails. Task 1 tests still pass.

- [ ] **Step 3: Rewrite the push functions in `scripts/yoda-sync.sh`**

Replace the entire existing `push_transcripts()` (the one calling `gocmd sync ${YODA_BULK:+--bulk_upload} …`) with:

```bash
push_transcripts() {
  local stage; stage="$(tar_stage_dir)"
  local manifest; manifest="$(dirname "${stage}")/.transcripts-tars-pushed.md5"
  stage_transcripts
  # Changed-shard set: md5 of each staged (reproducible) tar vs the manifest
  # recorded by the last successful push. No manifest = everything changed.
  # The sync itself needs no bookkeeping (checksum diff), but the extraction
  # step must know WHICH shards to extract; deleting the manifest forces
  # re-extraction of all shards (harmless: bun -x -f is idempotent).
  local changed=() t name
  for t in "${stage}"/shard-*.tar; do
    [ -f "${t}" ] || continue
    name="$(basename "${t}")"
    if [ ! -f "${manifest}" ] \
       || ! grep -qxF "$(md5sum "${t}" | cut -d' ' -f1)  ${name}" "${manifest}"; then
      changed+=("${name}")
    fi
  done
  echo "[yoda-sync] push shard tars: ${stage} -> ${YODA_COLLECTION}/transcripts-tars (${#changed[@]} changed)"
  # Sync the staging dir at the collection base: gocmd's basename-append rule
  # lands it as <collection>/transcripts-tars. Unchanged shards are byte-
  # identical (reproducible tars) so the checksum diff skips them. Threads
  # capped <=15: 30 saturated the server for all users (2026-07-06).
  gocmd sync --thread_num "${YODA_THREADS:-10}" "${stage}" "$(irods "${YODA_COLLECTION}")"
  if [ "${YODA_EXTRACT:-1}" != "0" ] && [ "${#changed[@]}" -gt 0 ]; then
    # Server-side extraction into the browsable per-file projection
    # (~13-14 files/s server-side, measured 2026-07-13). -f is required for
    # re-delivery (bare re-extract fails SYS_COPY_ALREADY_IN_RESC); the
    # raised --timeout covers ~10k-file shards (gocmd default 300s is short).
    for name in "${changed[@]}"; do
      echo "[yoda-sync] server-side extract: ${name} -> ${YODA_COLLECTION}/transcripts"
      gocmd bun -x -f -D tar --timeout "${YODA_BUN_TIMEOUT:-1200}" \
        "$(irods "${YODA_COLLECTION}/transcripts-tars/${name}")" \
        "$(irods "${YODA_COLLECTION}/transcripts")"
    done
  fi
  # Record delivered state only after sync + extraction succeed; a failed
  # milestone re-syncs (checksum no-op) and re-extracts (-f) next run.
  if compgen -G "${stage}/shard-*.tar" > /dev/null; then
    ( cd "${stage}" && md5sum shard-*.tar > "${manifest}" )
  fi
}

# Per-file delivery for small pilots (<= ~10k files). At campaign scale this
# is ~1.5 files/s — days — which is why tar delivery is the default
# (docs/storage-backends.md).
push_transcripts_plain() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  echo "[yoda-sync] push transcripts (plain per-file): ${YODA_TRANSCRIPTS_LOCAL} -> ${YODA_COLLECTION}/$(basename "${YODA_TRANSCRIPTS_LOCAL}")"
  gocmd sync --thread_num "${YODA_THREADS:-10}" "${YODA_TRANSCRIPTS_LOCAL}" "$(irods "${YODA_COLLECTION}")"
}
```

Add the verb (keep `push) push_transcripts; push_state ;;` as is):

```bash
  push-transcripts-plain) push_transcripts_plain ;;
```

Update the usage string to:

```bash
    echo "usage: yoda-sync.sh {stage-transcripts|push-transcripts|push-transcripts-plain|push-state|push|pull-inbox|pull-resume}" >&2
```

Header maintenance, all in the top comment block:
- Under `Config via environment:` add:

```bash
#   YODA_TAR_STAGE         staging dir for shard tars (basename must be
#                          `transcripts-tars`; default: sibling of the
#                          transcripts dir)
#   YODA_THREADS           gocmd transfer threads (default 10; keep <=15 —
#                          30 saturated the server for all users)
#   YODA_EXTRACT           set 0 to skip server-side extraction of changed
#                          shards into <collection>/transcripts (default on)
#   YODA_BUN_TIMEOUT       gocmd bun -x client timeout in seconds
#                          (default 1200; gocmd's own default 300 is too
#                          short for ~10k-file shards)
```

- In `Usage:` describe `push-transcripts` as "shard tars + server-side extraction (default delivery)" and add `stage-transcripts` and `push-transcripts-plain` lines.
- Replace the paragraph saying "per-shard tar bundling is the documented scale path (docs/FOLLOWUPS.md) and is not needed for pilot-scale delivery" with:

```bash
# Transcripts are delivered as byte-reproducible per-shard plain tars
# (shard-NN.tar) plus server-side extraction (gocmd bun -x) into a browsable
# per-file tree — at ~1.5 files/s of server-side per-op latency, client-side
# per-file delivery cannot finish a campaign-scale sync
# (docs/storage-backends.md). `push-transcripts-plain` keeps the per-file
# path for small pilots.
```

Verify: `grep -ni bulk scripts/yoda-sync.sh` prints nothing.

- [ ] **Step 4: Run the harness to verify it passes**

Run: `bash scripts/test-yoda-sync.sh`
Expected: all `ok:`, `failed: 0`, exit 0.

- [ ] **Step 5: Stage and hand the commit to Danielle**

```bash
git add scripts/yoda-sync.sh scripts/test-yoda-sync.sh
```

Report for Danielle to run:

```bash
git commit -m "feat(yoda): shard-tar push with server-side extraction; drop dead bulk_upload"
```

---

### Task 3: Restore from shard tars with legacy plain fallback (`pull-resume`)

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Modify: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Consumes: `tar_stage_dir()` (Task 1), `irods()` (existing).
- Produces: `pull_transcript_tars()` — pulls `<collection>/transcripts-tars` into the staging dir, extracts every `shard-*.tar` into `YODA_TRANSCRIPTS_LOCAL`. `pull_resume()` probes `gocmd ls <collection>/transcripts-tars`: tar path when it exists (the tars are the record — never restore from the extracted projection, that is the ~1.5 files/s wall), else the plain sync fallback.

- [ ] **Step 1: Add the restore tests to the harness**

Insert into `scripts/test-yoda-sync.sh` immediately before the `# ---- summary` block (after the Task 2 tests):

```bash
# ---- Task 3: pull-resume --------------------------------------------------------
echo "— pull-resume (tar path)"
fresh_workdir
echo 'sqlite-bytes' > "${YODA_STATE_SNAPSHOT}"
"${SYNC}" push
EXPECTED_TREE="${TMP}/expected-tree"
rm -rf "${EXPECTED_TREE}"; cp -r "${WORK}/transcripts" "${EXPECTED_TREE}"
WORK2="${TMP}/work2-${RANDOM}"; mkdir -p "${WORK2}"
export YODA_TRANSCRIPTS_LOCAL="${WORK2}/transcripts"
export YODA_STATE_SNAPSHOT="${WORK2}/state.sqlite"
"${SYNC}" pull-resume
check "state snapshot restored"                     '[ -f "${WORK2}/state.sqlite" ]'
check "restore pulled tars, not the projection"     'grep -q "^gocmd get .*transcripts-tars" "${FAKE_GOCMD_LOG}"'
check "extracted tree matches source (sans hidden)" 'diff -r --exclude=".*" "${EXPECTED_TREE}" "${WORK2}/transcripts" >/dev/null'
check "hidden entries were never restored"          '[ ! -e "${WORK2}/transcripts/17/.hidden" ] && [ ! -d "${WORK2}/transcripts/.work" ]'

echo "— pull-resume (legacy plain fallback)"
fresh_workdir
mkdir -p "${R}/transcripts/42"
echo 'legacy' > "${R}/transcripts/42/4242.txt"
echo 'sqlite-bytes' > "${R}/state-snapshot.sqlite"
WORK3="${TMP}/work3-${RANDOM}"; mkdir -p "${WORK3}"
export YODA_TRANSCRIPTS_LOCAL="${WORK3}/transcripts"
export YODA_STATE_SNAPSHOT="${WORK3}/state.sqlite"
"${SYNC}" pull-resume
check "legacy plain tree pulled"   '[ -f "${WORK3}/transcripts/42/4242.txt" ]'
check "state snapshot restored"    '[ -f "${WORK3}/state.sqlite" ]'
```

- [ ] **Step 2: Run it to verify the new tests fail**

Run: `bash scripts/test-yoda-sync.sh`
Expected: the tar-path tests fail — the current `pull_resume` plain-syncs `<collection>/transcripts`; with extraction default-on that projection EXISTS remotely, so the tree may even restore, but "restore pulled tars" fails (no `gocmd get …transcripts-tars` in the log). The legacy-fallback tests pass already (they pin current behavior against regression). Tasks 1–2 tests still pass.

- [ ] **Step 3: Implement the tar restore path in `scripts/yoda-sync.sh`**

Add after `stage_transcripts()`:

```bash
# Pull <collection>/transcripts-tars into the staging dir and extract into
# the transcripts tree. The tars are the durable record and the ONLY sane
# restore path — pulling the extracted per-file projection would be the
# ~1.5 files/s per-op wall all over again. Members are `NN/...` (tarred with
# -C <transcripts> NN), so extraction is order-independent and lands in place.
pull_transcript_tars() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  local stage; stage="$(tar_stage_dir)"
  rm -rf "${stage}"
  mkdir -p "$(dirname "${stage}")"
  echo "[yoda-sync] pull shard tars: ${YODA_COLLECTION}/transcripts-tars -> ${stage}"
  # `gocmd get` of a collection lands it as <dest>/<collection-basename>,
  # i.e. exactly ${stage} when dest is its parent.
  gocmd get -f "$(irods "${YODA_COLLECTION}/transcripts-tars")" "$(dirname "${stage}")"
  mkdir -p "${YODA_TRANSCRIPTS_LOCAL}"
  local t n=0
  for t in "${stage}"/shard-*.tar; do
    [ -f "${t}" ] || continue
    tar -xf "${t}" -C "${YODA_TRANSCRIPTS_LOCAL}"
    n=$((n + 1))
  done
  echo "[yoda-sync] extracted ${n} shard tar(s) into ${YODA_TRANSCRIPTS_LOCAL}"
}
```

Replace the transcripts branch of `pull_resume()` (the `if [ -n "${YODA_TRANSCRIPTS_LOCAL:-}" ]; then … fi` block) with:

```bash
  if [ -n "${YODA_TRANSCRIPTS_LOCAL:-}" ]; then
    if gocmd ls "$(irods "${YODA_COLLECTION}/transcripts-tars")" >/dev/null 2>&1; then
      pull_transcript_tars
    else
      # Legacy plain tree from pre-tar pilots. Same basename-append rule:
      # sync INTO the parent so it lands as <parent>/transcripts.
      local parent; parent="$(dirname "${YODA_TRANSCRIPTS_LOCAL}")"
      mkdir -p "${parent}"
      echo "[yoda-sync] pull transcripts (legacy plain) -> ${YODA_TRANSCRIPTS_LOCAL}"
      gocmd sync "$(irods "${YODA_COLLECTION}/transcripts")" "${parent}" \
        || echo "[yoda-sync] no transcripts in collection yet"
    fi
  fi
```

(The state-snapshot half of `pull_resume()` is unchanged. Note `pull_resume` must be a function using `local` — it already is.)

- [ ] **Step 4: Run the harness to verify it passes**

Run: `bash scripts/test-yoda-sync.sh`
Expected: all `ok:`, `failed: 0`, exit 0.

- [ ] **Step 5: Stage and hand the commit to Danielle**

```bash
git add scripts/yoda-sync.sh scripts/test-yoda-sync.sh
```

Report for Danielle to run:

```bash
git commit -m "feat(yoda): restore from shard tars with legacy plain fallback"
```

---

### Task 4: Documentation updates

**Files:**
- Modify: `docs/FOLLOWUPS.md`
- Modify: `docs/storage-backends.md`
- Modify: `docs/yoda-operations.md`
- Modify: `docs/catalog-item.md`
- Read (source material): `.superpowers/sdd/yoda-experiments-2026-07-13.md` — the 2026-07-13 live experiment log (bun -x rates, ticket verification); its content must be *captured* in `yoda-operations.md`, the scratch copy is volatile.

**Interfaces:**
- Consumes: shipped behavior from Tasks 1–3 (verbs, defaults, layouts) — descriptions must match exactly.
- Produces: nothing consumed by other tasks (Task 5 appends measurements).

- [ ] **Step 1: `docs/FOLLOWUPS.md` — close three items, open two**

Replace the entire open item beginning `- **1M-file scale: bulk_upload is DEAD on Yoda — a delivery redesign is needed.**` with:

```markdown
- **RESOLVED 2026-07-13 — 1M-file scale: shard-tar delivery + server-side
  extraction shipped.** `yoda-sync.sh push-transcripts` builds
  byte-reproducible plain per-shard archives
  (`transcripts-tars/shard-NN.tar`), syncs them (unchanged shards
  checksum-skipped), and extracts changed shards server-side
  (`gocmd bun -x -f -D tar`, ~13–14 files/s, ~9× the client-side per-file
  rate) into a browsable `transcripts/` tree. `YODA_EXTRACT=0` gives an
  archive-only sink; `push-transcripts-plain` keeps per-file delivery for
  small pilots; `YODA_BULK`/`--bulk_upload` is deleted. NOTE the 2026-07-06
  "server-side extraction likely blocked by policy" hypothesis was WRONG —
  that failure was `bput`'s client-side staging guardrail; the server's
  native extraction works fine. Design:
  `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md`.
```

Replace the entire open item beginning `- **\`yoda-sync.sh\` uploads hidden files/dirs.**` with:

```markdown
- **RESOLVED 2026-07-13 — hidden files no longer uploaded; threads capped.**
  Shard-tar staging excludes hidden entries at tar time (the `.work/` leak),
  and transfer calls in `yoda-sync.sh` default to `--thread_num 10`
  (override via `YODA_THREADS`; keep ≤15 — 30 saturated the server for all
  users, 2026-07-06).
```

Add these three entries at the end of the Open section:

```markdown
- **RESOLVED 2026-07-13 — researcher hand-off via anonymous read tickets is
  verified.** The iRODS `anonymous` user is enabled on fsw.data.uu.nl;
  `gocmd mkticket -t read` + a 12-line credential-free config + a gocmd
  binary gives a researcher `ls`/`get` on a collection with no UU account,
  no DAP, no CO membership (three-way control test; denial presents as
  "not found"). HYGIENE: default tickets have unlimited uses and NO expiry —
  set one via `modticket` on any real hand-off; `rmticket` revokes;
  `lsticket` audits. See `yoda-operations.md`.

- **Does `bun -x -f` re-extraction mint a Yoda revision per overwritten
  object?** Invisible to gocmd; storage-relevant at scale (every milestone
  rewrites every file in changed shards). Asked of FSW (pending thread). If
  costly, flip the `YODA_EXTRACT` default to 0 — one env var, no structural
  change.

- **Does the server finish or abandon a `bun -x` extraction if the client
  disconnects at `--timeout`?** Untested (deliberately — server-load
  politeness). Also for the FSW thread. Until known, size
  `YODA_BUN_TIMEOUT` generously (default 1200 s covers ~10k-file shards).
```

- [ ] **Step 2: `docs/storage-backends.md` — correct the iCommands bullet, rewrite Scale**

Replace the bullet beginning `- **iCommands** — native iRODS, integrity-checked, but needs an apt install` with:

```markdown
- **iCommands** — native iRODS, integrity-checked, and pre-installed on
  SURF's SRC Ubuntu image (so install cost is *not* an argument against it
  there). Not chosen for delivery because the role pins its own client
  version (the baked-in iCommands drifts with SURF's image), `yoda-sync.sh`
  also runs from operator dev machines where iCommands has no easy install,
  and all validated auth behavior (DAP handling, headless init, token
  probing) is gocmd-specific. Useful as a diagnostic sidearm on a workspace
  (`ils -A`, `iquest`, `iticket`).
```

Replace the entire `## Scale` section (heading included) with:

```markdown
## Scale

Transcripts shard on the last two digits of the video id (ddp-transcribe
ADR 0004) → ~100 shards, ~10k files/shard at 1M videos.

Client-side per-file delivery cannot reach that scale: measured throughput
is ~1.5 files/s (server-side per-operation latency — Yoda 2.0.4 policy
rules fire on every data-object write — not bandwidth). A 100k-file sync
did not complete in 24 h of continuous running. gocmd's `--bulk_upload` is
also unusable here, but for a *client-side* reason: its staging-path
safety check rejects research group collections and `nluu10p` users have
no personal home collection to redirect staging to.

The problem is op count, not bytes (~85 MB/s measured for large objects),
so `yoda-sync.sh` sends **byte-reproducible plain per-shard tars**
(`transcripts-tars/shard-NN.tar`, pinned tar metadata, no compression) and
then has the **server** unpack changed shards
(`gocmd bun -x -f -D tar`, verified working 2026-07-13 at ~13–14 files/s —
~9× the client-side rate, client idle) into a browsable per-file
`transcripts/` tree. A milestone push is one checksum-skipping sync plus
one extraction per changed shard; restore is pull-tars + extract locally
(never the per-file projection). Researchers get both the durable archive
and per-file portal browsing; `YODA_EXTRACT=0` gives archive-only, and
`push-transcripts-plain` keeps per-file delivery for small pilots
(≤ ~10k files). Full measurements and the extraction/ticket verification
log: `yoda-operations.md`. Design:
`docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md`.
```

- [ ] **Step 3: `docs/yoda-operations.md` — capture the 2026-07-13 experiments**

3a. Update the intro paragraph (starts `Everything below was established by live testing on 2026-07-06`) to say testing happened on 2026-07-06 **and 2026-07-13**.

3b. Append two rows to the `## Performance envelope` table:

```markdown
| Server-side tar extraction (`gocmd bun -x`) | **~13–14 files/s**, steady 300 → 2,000 files (23.6 s / 2 m 22 s); `-f` re-extract of an unchanged/1-changed 300-file shard ~5.6–5.8 s |
| Large single object (`gocmd put`, 1 GB) | 12.0 s ≈ 85 MB/s, bandwidth-bound at default threads |
```

3c. In `## Transfer recipes`, replace the bullet beginning `- **Tarball pattern** for many small files` with:

```markdown
- **Shard-tar delivery (the default).** `yoda-sync.sh push-transcripts`
  builds one byte-reproducible PLAIN archive per shard —
  `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0
  --format=gnu --exclude='.*' -C <transcripts> NN` (no compression: `-D tar`
  is the verified server-side extraction format and transfer is
  bandwidth-bound anyway) — into a staging dir whose basename MUST be
  `transcripts-tars` (basename-append rule), then one
  `gocmd sync --thread_num 10`, then `gocmd bun -x -f -D tar
  --timeout 1200` per *changed* shard into `<collection>/transcripts`
  (changed set via a local md5 manifest). Unchanged shards are
  byte-identical, so the sync checksum-skips them and no extraction fires.
  Restore: `pull-resume` fetches the TARS and extracts locally — never the
  per-file projection. Legacy plain `transcripts/` collections still
  restore via the old sync path.
```

3d. Add a new section after `## Transfer recipes`, sourced from
`.superpowers/sdd/yoda-experiments-2026-07-13.md` (do not paraphrase away
the numbers; carry them over):

```markdown
## Server-side extraction (`gocmd bun -x`) — verified 2026-07-13

The 2026-07-06 hypothesis that server-side extraction is policy-blocked was
wrong: what failed was `bput`'s client-side staging guardrail. The server's
native extraction works on stock gocmd:

```
gocmd put shard.tar i:<collection>/transcripts-tars/   # one network op
gocmd bun -x -f -D tar --timeout 1200 \
  i:<collection>/transcripts-tars/shard-NN.tar i:<collection>/transcripts
```

- Measured: put 310 KB/300-file tar 5.1 s; extract 300 files 23.6 s, 2,000
  files 2 m 22 s (**steady ~13–14 files/s**, no amortization — per-file
  policy cost moved server-side, client `user` time ~0.04 s); `-f`
  re-extract of a mostly-unchanged 300-file shard ~5.6–5.8 s.
- **`-f` is required for re-delivery**: bare re-extract fails fast with
  `SYS_COPY_ALREADY_IN_RESC` (-46000). Updated content propagates; new
  files materialize.
- **Raise `--timeout`**: gocmd's default 300 s is too short for a
  ~10k-file campaign shard (~12 min at ~14 files/s); `yoda-sync.sh` uses
  1200 s (`YODA_BUN_TIMEOUT`).
- Campaign arithmetic: ~2M files ≈ ~40 h total server-side extraction,
  amortized per changed shard across milestones (vs 2+ weeks client-side).
- Open questions (FSW thread): revision-store cost of `-f` overwrites;
  server behavior on client timeout mid-extraction.

## Researcher hand-off via anonymous read tickets — verified 2026-07-13

gocmd v0.12.2 has full ticket support (`mkticket`/`lsticket`/`modticket`/
`rmticket`, `-T` on `ls`/`get`), and the iRODS `anonymous` user is enabled
on fsw.data.uu.nl. Three-way control verified: anonymous env (12-line
credential-free config, `irods_authentication_scheme: native`) + no ticket
→ "not found" (existence not leaked); + read ticket → full `ls` and
byte-correct `get`. Flow: mint a read ticket on the collection, hand over
ticket string + anon config + a gocmd binary — no UU account, no DAP, no
CO membership. HYGIENE: defaults are permissive (`USES LIMIT 0`,
`EXPIRY TIME none`) — always `modticket` an expiry on real hand-offs;
`rmticket` revokes; `lsticket` audits.
```

3e. In `## Diagnosis playbook (short)`, append:

```markdown
5. iCommands are pre-installed on SURF's SRC Ubuntu image — an independent
   client for cross-checking gocmd behavior (`ils -A` for ACLs, `iquest`
   for metadata queries, `iticket` for share tickets). Same DAP credential.
```

- [ ] **Step 4: `docs/catalog-item.md` — delivery note**

In the Step A parameters table, replace the `yoda_collection` description cell text `**yoda only.** iRODS collection base path, e.g. \`/nluu10p/home/research-foo\`; holds inbox, transcripts, state snapshot.` with:

```
**yoda only.** iRODS collection base path, e.g. `/nluu10p/home/research-foo`; holds inbox, the transcript shard archives (`transcripts-tars/`) plus their server-side-extracted per-file tree (`transcripts/`), and the state snapshot.
```

- [ ] **Step 5: Verify docs consistency**

Run: `grep -rn "YODA_BULK\|bulk_upload" docs/ scripts/ roles/ | grep -v superpowers`
Expected: only historical/RESOLVED mentions in `FOLLOWUPS.md`, `storage-backends.md` (the client-side-reason explanation), and `yoda-operations.md` (measurement records); no live instructions. Run `grep -n "transcripts-tars" docs/*.md scripts/yoda-sync.sh` and confirm identical spelling everywhere; `grep -n "tar.gz" docs/*.md scripts/*.sh` must return nothing (plain tar everywhere).

- [ ] **Step 6: Stage and hand the commit to Danielle**

```bash
git add docs/FOLLOWUPS.md docs/storage-backends.md docs/yoda-operations.md docs/catalog-item.md
```

Report for Danielle to run:

```bash
git commit -m "docs(yoda): document shard-tar delivery with server-side extraction and ticket hand-off"
```

---

### Task 5: Live Yoda round-trip verification (operator-assisted)

**Files:**
- Modify: `docs/yoda-operations.md` (performance table)
- Modify: `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md` (validation note)

**Interfaces:**
- Consumes: the shipped `yoda-sync.sh` verbs from Tasks 1–3.
- Produces: measured wallclock numbers; confirmation (or correction) of two live assumptions the fake can't test: `gocmd get` of a collection lands as `<dest>/transcripts-tars`, and `bun -x` accepts our reproducible-tar output (the 2026-07-13 experiments used ad-hoc tars, not this recipe's).

**Needs from Danielle:** a cached gocmd auth token on this machine (fresh DAP → `gocmd init`; never retry a failing DAP) and the collection path, with a scratch sub-collection allowed (e.g. `<collection>/tar-verify`). All fixture content ASCII, digit-named.

- [ ] **Step 1: Build a live fixture (local)**

```bash
FIX="$(mktemp -d)/ddp-work"
mkdir -p "${FIX}/transcripts"/{03,41,88} "${FIX}/transcripts/.work"
for s in 03 41 88; do
  for i in $(seq 1 150); do
    printf '{"video_id":"%s%03d","text":"fixture transcript %d"}\n' "$s" "$i" "$i" > "${FIX}/transcripts/${s}/${i}${s}.json"
  done
done
echo scratch > "${FIX}/transcripts/.work/tmp.bin"
printf 'not-a-real-db' > "${FIX}/state-snapshot.sqlite"
export YODA_COLLECTION="<collection>/tar-verify"          # Danielle supplies
export YODA_TRANSCRIPTS_LOCAL="${FIX}/transcripts"
export YODA_STATE_SNAPSHOT="${FIX}/state-snapshot.sqlite"
gocmd mkdir "i:${YODA_COLLECTION}" 2>/dev/null || true    # base must pre-exist
```

- [ ] **Step 2: First push — layout, extraction, timing**

Run: `time scripts/yoda-sync.sh push`
Then: `gocmd ls "i:${YODA_COLLECTION}/transcripts-tars"` and `gocmd ls "i:${YODA_COLLECTION}/transcripts/41"`
Expected: exactly `shard-03.tar shard-41.tar shard-88.tar` under `transcripts-tars/` (no `.work`); the per-file tree under `transcripts/41/` lists 150 objects; `state-snapshot.sqlite` at the base. Extraction of 3×150 files should take ~30–35 s at the measured rate. Record wallclock. **This validates `bun -x` against our reproducible-tar recipe.**

- [ ] **Step 3: Idempotent second push**

Run: `time scripts/yoda-sync.sh push-transcripts`
Expected: gocmd sync transfers nothing (checksum match), zero `bun` invocations ("0 changed"), wallclock a few seconds. If everything re-uploads, tar reproducibility broke across machines — compare `md5sum` of two consecutive `stage-transcripts` runs locally before proceeding.

- [ ] **Step 4: Single-shard change**

```bash
echo '{"video_id":"41999","text":"new"}' > "${FIX}/transcripts/41/99941.json"
time scripts/yoda-sync.sh push-transcripts
gocmd get "i:${YODA_COLLECTION}/transcripts/41/99941.json" /tmp/bun-check.json && cat /tmp/bun-check.json
```

Expected: exactly one tar uploads and one `bun -x` runs (shard-41); the new file is present and byte-correct in the extracted projection.

- [ ] **Step 5: Restore round-trip**

```bash
FRESH="$(mktemp -d)/ddp-work"; mkdir -p "${FRESH}"
YODA_TRANSCRIPTS_LOCAL="${FRESH}/transcripts" \
YODA_STATE_SNAPSHOT="${FRESH}/state.sqlite" \
  time scripts/yoda-sync.sh pull-resume
diff -r --exclude='.*' "${FIX}/transcripts" "${FRESH}/transcripts" && echo TREE-IDENTICAL
ls "${FRESH}/state.sqlite"
```

Expected: `TREE-IDENTICAL`; state file present; no dotfiles in `${FRESH}`. **This validates the `gocmd get` collection-landing assumption** — if the tars land elsewhere (e.g. contents splatted into dest), fix `pull_transcript_tars()` and re-run the harness + this step.

- [ ] **Step 6: Plain escape hatch still round-trips**

Run: `YODA_COLLECTION="${YODA_COLLECTION}/plain-check" sh -c 'gocmd mkdir "i:${YODA_COLLECTION}" 2>/dev/null; scripts/yoda-sync.sh push-transcripts-plain' && gocmd ls "i:${YODA_COLLECTION}/plain-check/transcripts"`
Expected: per-file `03/ 41/ 88/` tree appears (dotfiles WILL be included on this path — plain mode never excluded them; acceptable for the escape hatch, documented).

- [ ] **Step 7: Clean up the scratch collection (Danielle runs)**

Report for Danielle: `gocmd rm -r "i:${YODA_COLLECTION}"` (the `tar-verify` scratch only — never the real collection).

- [ ] **Step 8: Record the measurements**

Add rows to the performance table in `docs/yoda-operations.md`:

```markdown
| Shard-tar milestone push+extract (450 files / 3 shards, first) | measured 2026-07-XX: <X s> |
| Shard-tar no-op push (checksum skip, 0 extractions) | measured 2026-07-XX: <X s> |
| Shard-tar restore (pull tars + extract, 3 shards) | measured 2026-07-XX: <X s> |
```

Append to the spec's Testing section: `**Validated live 2026-07-XX** — all checks passed; timings in yoda-operations.md.` (Report failures honestly instead if any step failed.)

- [ ] **Step 9: Stage and hand the commit to Danielle**

```bash
git add docs/yoda-operations.md docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md
```

Report for Danielle to run:

```bash
git commit -m "docs(yoda): record live shard-tar round-trip measurements"
```

---

## Self-Review

- **Spec coverage (amended spec):** plain reproducible tars (T1), staging basename guard (T1), changed-shard manifest + single sync + default-on `bun -x` extraction with `-f`/`-D tar`/timeout (T2), `YODA_EXTRACT=0` archive-only (T2), plain escape hatch (T2), `YODA_BULK` deletion (T2), tars-as-record restore + legacy fallback (T3), no auto-delete of remote data (nowhere; T5 cleanup is operator-run scratch), wrapper contract untouched, docs incl. corrected extraction hypothesis, ticket verification, revision-store + timeout open questions (T4), live validation of the two untestable assumptions + perf capture (T5). No gaps found.
- **Placeholder scan:** `<collection>` / `<X s>` / `2026-07-XX` in Task 5 are operator-supplied runtime values, flagged as such; no TBDs.
- **Type consistency:** `tar_stage_dir` / `stage_transcripts` / `pull_transcript_tars` / `push_transcripts_plain` names, the env contract (`YODA_TAR_STAGE`, `YODA_THREADS`, `YODA_EXTRACT`, `YODA_BUN_TIMEOUT`), manifest path `.transcripts-tars-pushed.md5`, and `shard-NN.tar` naming are identical across Tasks 1–3, the harness, and Task 4's doc text (T4 Step 5 re-checks mechanically, including a no-`tar.gz` grep).
