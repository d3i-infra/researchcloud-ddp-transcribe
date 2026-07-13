# Yoda Shard-Tar Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-file transcript delivery to Yoda with byte-reproducible per-shard tar archives so milestone syncs take minutes (≤ ~100 remote ops) instead of days.

**Architecture:** All logic lands in `scripts/yoda-sync.sh` (installed to `$HOME` by `roles/workspace_layout`; the generated `sync-to-storage.sh` / `restore-from-storage.sh` wrappers keep calling `push` / `pull-resume` / `pull-inbox` unchanged). A new `stage-transcripts` verb builds reproducible `shard-NN.tar.gz` archives in a staging dir; `push-transcripts` becomes stage + one `gocmd sync`; `pull-resume` prefers remote tars and falls back to the legacy plain tree. A hermetic test harness fakes `gocmd` via a PATH shim so everything except the live Yoda round-trip runs offline.

**Tech Stack:** Bash (strict mode), GNU tar + gzip (no new package dependencies), GoCommands (`gocmd`) for iRODS transfer.

**Spec:** `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md` (approved 2026-07-13).

## Global Constraints

- **Claude never runs `git commit` or `git push`** (d3i CLAUDE.md scope policy). Every commit step: stage with `git add`, then report the exact `git commit` command for Danielle to run. Do not proceed past a commit step until she confirms.
- Reproducible tar recipe, verbatim: `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --format=gnu --exclude='.*' -C <transcripts> NN | gzip -n` — `gzip -n` is load-bearing (omits the embedded timestamp).
- The staging dir basename MUST be `transcripts-tars` (gocmd's basename-append rule: `sync SRC DEST` creates `DEST/basename(SRC)` when DEST exists).
- Transfer thread count: default `--thread_num 10`, never exceed 15 (30 threads saturated the server for all users, measured 2026-07-06).
- Nothing auto-deletes remote data; legacy plain `transcripts/` collections are left for manual operator cleanup.
- ASCII-only, no spaces, no quotes in anything created on Yoda (server naming bugs — `yoda-operations.md`).
- `YODA_BULK` / `--bulk_upload` is deleted, not deprecated (proven dead on Yoda 2026-07-06).
- Conventional Commits messages; branch per d3i-infra standards.

## Prerequisites (operator, before execution)

1. The working tree on `fix/yoda-irods-env-keys` has uncommitted changes to `docs/FOLLOWUPS.md`, `docs/storage-backends.md`, `roles/yoda/tasks/main.yaml`, plus the still-untracked `docs/yoda-operations.md` (and `test-yoda.yaml`, whose fate is Danielle's call) — **Danielle commits those first** (they are that branch's own fix). The doc-edit anchors in Task 4 match that post-commit content.
2. Cut the work branch from it: `git switch -c feature/yoda-shard-tar-delivery fix/yoda-irods-env-keys` (or execute in a worktree per `superpowers:using-git-worktrees`).
3. Task 5 (live verification) additionally needs a cached gocmd auth token on this machine (`gocmd init` with a fresh DAP) and a scratch area under the real collection. Tasks 1–4 need no network.

## File Structure

- `scripts/yoda-sync.sh` — modified: new `stage-transcripts` verb + `tar_stage_dir` guard (Task 1); `push-transcripts` tar-by-default, `push-transcripts-plain`, `YODA_BULK` removed (Task 2); `pull-resume` tar path + legacy fallback (Task 3).
- `scripts/test-yoda-sync.sh` — created: hermetic test harness (fake `gocmd`, fixture tree, pass/fail summary). Grows with Tasks 1–3.
- `docs/FOLLOWUPS.md`, `docs/storage-backends.md`, `docs/yoda-operations.md`, `docs/catalog-item.md` — modified (Task 4); perf numbers refreshed in Task 5.

No changes to `roles/workspace_layout` templates or `roles/yoda` — the wrapper contract (`push`/`pull-resume`/`pull-inbox`, env vars `YODA_COLLECTION`, `YODA_TRANSCRIPTS_LOCAL`, `YODA_STATE_SNAPSHOT`, `YODA_INBOX_LOCAL`) is unchanged. The staging default `$(dirname $YODA_TRANSCRIPTS_LOCAL)/transcripts-tars` resolves to `{{ work_dir }}/transcripts-tars` on a workspace (boot disk) with no template edits.

---

### Task 1: Reproducible per-shard tar staging (`stage-transcripts`)

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Create: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Produces: `tar_stage_dir()` — echoes the staging dir path (`${YODA_TAR_STAGE:-$(dirname "$YODA_TRANSCRIPTS_LOCAL")/transcripts-tars}`), exits 2 if its basename ≠ `transcripts-tars`. `stage_transcripts()` — wipes/rebuilds the staging dir with one `shard-NN.tar.gz` per populated 2-digit shard dir; hidden entries excluded. Verb `stage-transcripts` dispatches to it. Tasks 2–3 call both functions.

- [ ] **Step 1: Create the test harness with the staging tests**

Create `scripts/test-yoda-sync.sh` (mode 0755) with exactly:

```bash
#!/usr/bin/env bash
# test-yoda-sync.sh — hermetic tests for scripts/yoda-sync.sh (no Yoda needed).
# A fake `gocmd` on PATH maps i:<path> onto a local "remote" dir, so staging,
# reproducibility, push/pull logic, and the legacy fallback all run offline.
# The live-Yoda round trip is a separate operator step (see the plan/spec).
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
    --thread_num) shift 2 ;;
    -f|--*)       shift ;;
    *)            args+=("$1"); shift ;;
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
check "one tar per numeric shard, nothing else" '[ -f "${STAGE}/shard-00.tar.gz" ] && [ -f "${STAGE}/shard-17.tar.gz" ] && [ "$(ls "${STAGE}" | wc -l)" -eq 2 ]'
check "no tar for hidden .work dir"            '! ls "${STAGE}" | grep -q work'
check "in-shard dotfile excluded"              '! tar -tzf "${STAGE}/shard-17.tar.gz" | grep -q hidden'
check "members rooted at NN/"                  'tar -tzf "${STAGE}/shard-00.tar.gz" | grep -qx "00/100.json"'

echo "— reproducibility"
sum1="$(md5sum "${STAGE}/shard-00.tar.gz" | cut -d" " -f1)"
touch "${WORK}/transcripts/00/100.json"        # mtime-only change
"${SYNC}" stage-transcripts
sum2="$(md5sum "${STAGE}/shard-00.tar.gz" | cut -d" " -f1)"
check "mtime-only change -> identical tar"     '[ "${sum1}" = "${sum2}" ]'
echo 'changed' >> "${WORK}/transcripts/00/100.txt"
"${SYNC}" stage-transcripts
sum3="$(md5sum "${STAGE}/shard-00.tar.gz" | cut -d" " -f1)"
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
Expected: FAIL lines for the staging tests (yoda-sync.sh exits 2 with `usage: … {push-transcripts|…}` because `stage-transcripts` is not a verb yet), non-zero exit.

- [ ] **Step 3: Implement staging in `scripts/yoda-sync.sh`**

Insert after the existing `irods()` helper (line 33):

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

# Build one byte-REPRODUCIBLE shard-NN.tar.gz per populated 2-digit shard dir.
# Reproducible (--sort/--owner/--group/--numeric-owner/--mtime/--format + gzip -n,
# which omits gzip's embedded timestamp) so unchanged shards produce identical
# bytes and `gocmd sync`'s checksum diff skips them — incremental delivery with
# zero bookkeeping. Hidden entries are excluded (the .work/ leak, FOLLOWUPS).
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
        -C "${YODA_TRANSCRIPTS_LOCAL}" -cf - "${name}" \
      | gzip -n > "${stage}/shard-${name}.tar.gz"
    built=$((built + 1))
  done
  echo "[yoda-sync] staged ${built} shard tar(s) in ${stage}"
}
```

Add the verb to the `case` dispatch and usage line:

```bash
  stage-transcripts) stage_transcripts ;;
```

and change the usage string to:

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

### Task 2: Tar-by-default push (`push-transcripts`), plain escape hatch, delete `YODA_BULK`

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Modify: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Consumes: `tar_stage_dir()`, `stage_transcripts()` from Task 1.
- Produces: `push_transcripts()` (stage + single `gocmd sync` of the staging dir, `--thread_num ${YODA_THREADS:-10}`), `push_transcripts_plain()` (the old per-file sync, now with `--thread_num`), verbs `push-transcripts-plain`; `push` still means tar push + state push. No `YODA_BULK` anywhere.

- [ ] **Step 1: Add the push tests to the harness**

Insert into `scripts/test-yoda-sync.sh` immediately before the `# ---- summary` block:

```bash
# ---- Task 2: push -------------------------------------------------------------
echo "— push-transcripts (tar default)"
fresh_workdir
"${SYNC}" push-transcripts
check "shard tars landed under transcripts-tars/" '[ -f "${R}/transcripts-tars/shard-00.tar.gz" ] && [ -f "${R}/transcripts-tars/shard-17.tar.gz" ]'
check "sync used --thread_num 10"                 'grep -q -- "--thread_num 10" "${FAKE_GOCMD_LOG}"'
check "no plain per-file tree pushed"             '[ ! -d "${R}/transcripts" ]'

echo "— push (tars + state)"
fresh_workdir
echo 'sqlite-bytes' > "${YODA_STATE_SNAPSHOT}"
"${SYNC}" push
check "shard tars landed"      '[ -f "${R}/transcripts-tars/shard-00.tar.gz" ]'
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
Expected: "push-transcripts (tar default)" fails (`transcripts-tars/` absent remotely — current push syncs the plain tree; `--thread_num 10` absent from the log), "push-transcripts-plain" fails (unknown verb, script exits 2 — with `set -uo pipefail` in the harness the run continues), "bulk" grep fails. Task 1 tests still pass.

- [ ] **Step 3: Rewrite the push functions in `scripts/yoda-sync.sh`**

Replace the entire existing `push_transcripts()` (the one calling `gocmd sync ${YODA_BULK:+--bulk_upload} …`) with:

```bash
push_transcripts() {
  local stage; stage="$(tar_stage_dir)"
  stage_transcripts
  echo "[yoda-sync] push shard tars: ${stage} -> ${YODA_COLLECTION}/transcripts-tars"
  # Sync the staging dir at the collection base: gocmd's basename-append rule
  # lands it as <collection>/transcripts-tars. Unchanged shards are byte-
  # identical (reproducible tars) so the checksum diff skips them. Threads
  # capped ≤15: 30 saturated the server for all users (2026-07-06).
  gocmd sync --thread_num "${YODA_THREADS:-10}" "${stage}" "$(irods "${YODA_COLLECTION}")"
}

# Per-file delivery for small pilots (≤ ~10k files) where per-file portal
# browsing genuinely works. At campaign scale this is ~1.5 files/s — days —
# which is why tar delivery is the default (docs/storage-backends.md).
push_transcripts_plain() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  echo "[yoda-sync] push transcripts (plain per-file): ${YODA_TRANSCRIPTS_LOCAL} -> ${YODA_COLLECTION}/$(basename "${YODA_TRANSCRIPTS_LOCAL}")"
  gocmd sync --thread_num "${YODA_THREADS:-10}" "${YODA_TRANSCRIPTS_LOCAL}" "$(irods "${YODA_COLLECTION}")"
}
```

Add the verb to the dispatch (keep `push) push_transcripts; push_state ;;` as is):

```bash
  push-transcripts-plain) push_transcripts_plain ;;
```

Update the usage string to:

```bash
    echo "usage: yoda-sync.sh {stage-transcripts|push-transcripts|push-transcripts-plain|push-state|push|pull-inbox|pull-resume}" >&2
```

Update the header comment block: in the `Usage:` section describe `push-transcripts` as "shard tars (default delivery)" and add `push-transcripts-plain` and `stage-transcripts` lines; document the two new env vars under `Config via environment:`:

```bash
#   YODA_TAR_STAGE         staging dir for shard tars (basename must be
#                          `transcripts-tars`; default: sibling of the
#                          transcripts dir)
#   YODA_THREADS           gocmd transfer threads (default 10; keep <=15 —
#                          30 saturated the server for all users)
```

Finally, replace the header paragraph that still says "per-shard tar bundling is the documented scale path (docs/FOLLOWUPS.md) and is not needed for pilot-scale delivery" with:

```bash
# Transcripts are delivered as byte-reproducible per-shard tar archives
# (shard-NN.tar.gz) — at ~1.5 files/s of server-side per-op latency, per-file
# delivery cannot finish a campaign-scale sync (docs/storage-backends.md).
# `push-transcripts-plain` keeps the per-file path for small pilots.
```

Verify no other `YODA_BULK` / `bulk_upload` references remain: `grep -ni bulk scripts/yoda-sync.sh` must print nothing.

- [ ] **Step 4: Run the harness to verify it passes**

Run: `bash scripts/test-yoda-sync.sh`
Expected: all `ok:`, `failed: 0`, exit 0.

- [ ] **Step 5: Stage and hand the commit to Danielle**

```bash
git add scripts/yoda-sync.sh scripts/test-yoda-sync.sh
```

Report for Danielle to run:

```bash
git commit -m "feat(yoda): deliver transcripts as shard tars by default; drop dead bulk_upload"
```

---

### Task 3: Restore from shard tars with legacy plain fallback (`pull-resume`)

**Files:**
- Modify: `scripts/yoda-sync.sh`
- Modify: `scripts/test-yoda-sync.sh`

**Interfaces:**
- Consumes: `tar_stage_dir()` (Task 1), `irods()` (existing).
- Produces: `pull_transcript_tars()` (pull `<collection>/transcripts-tars` into the staging dir, extract every `shard-*.tar.gz` into `YODA_TRANSCRIPTS_LOCAL`); `pull_resume()` probes `gocmd ls <collection>/transcripts-tars` and takes the tar path when it exists, else the current plain sync.

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
check "state snapshot restored"                   '[ -f "${WORK2}/state.sqlite" ]'
check "extracted tree matches source (sans hidden)" 'diff -r --exclude=".*" "${EXPECTED_TREE}" "${WORK2}/transcripts" >/dev/null'
check "hidden entries were never restored"        '[ ! -e "${WORK2}/transcripts/17/.hidden" ] && [ ! -d "${WORK2}/transcripts/.work" ]'

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
Expected: "pull-resume (tar path)" fails — the current `pull_resume` plain-syncs `<collection>/transcripts`, which doesn't exist when only tars were pushed, so `WORK2/transcripts` never materializes. The legacy-fallback tests pass already (they exercise the current behavior — that is expected; they pin it against regression). Task 1–2 tests still pass.

- [ ] **Step 3: Implement the tar restore path in `scripts/yoda-sync.sh`**

Add after `stage_transcripts()`:

```bash
# Pull <collection>/transcripts-tars into the staging dir and extract into the
# transcripts tree. Members are `NN/...` (tarred with -C <transcripts> NN), so
# extraction is order-independent and lands directly in place.
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
  for t in "${stage}"/shard-*.tar.gz; do
    [ -f "${t}" ] || continue
    tar -xzf "${t}" -C "${YODA_TRANSCRIPTS_LOCAL}"
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

(The state-snapshot half of `pull_resume()` is unchanged.)

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

**Interfaces:**
- Consumes: the shipped behavior from Tasks 1–3 (verbs, defaults, layouts) — descriptions must match it exactly.
- Produces: nothing consumed by other tasks (Task 5 appends measurements).

Anchors below assume the in-flight edits on `fix/yoda-irods-env-keys` are committed (see Prerequisites); if an anchor doesn't match, find the item by its bold lead-in and adapt minimally.

- [ ] **Step 1: `docs/FOLLOWUPS.md` — close the two items, add the iticket note**

Replace the entire open item beginning `- **1M-file scale: bulk_upload is DEAD on Yoda — a delivery redesign is needed.**` with:

```markdown
- **RESOLVED 2026-07-13 — 1M-file scale: shard-tar delivery shipped.**
  `yoda-sync.sh push-transcripts` now builds byte-reproducible per-shard
  archives (`transcripts-tars/shard-NN.tar.gz`) and syncs those: ≤ ~100
  remote ops per milestone instead of one per file, with unchanged shards
  checksum-skipped for free. `push-transcripts-plain` keeps the per-file
  path for small pilots. The dead `YODA_BULK`/`--bulk_upload` path is
  deleted. Design: `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md`.
  FSW admin-side bulk ingest remains a possible future upgrade (question
  still pending with FSW tech support).
```

Replace the entire open item beginning `- **\`yoda-sync.sh\` uploads hidden files/dirs.**` with:

```markdown
- **RESOLVED 2026-07-13 — hidden files no longer uploaded; threads capped.**
  Shard-tar staging excludes hidden entries at tar time (the `.work/` leak),
  and all `gocmd sync` calls in `yoda-sync.sh` now default to
  `--thread_num 10` (override via `YODA_THREADS`; keep ≤15 — 30 saturated
  the server for all users, 2026-07-06).
```

Add a new open item at the end of the Open section:

```markdown
- **`iticket` (iRODS tickets) unexplored for researcher hand-off.** Tickets
  could give a researcher download access to the shard tars without CO
  membership (`iticket create read <collection>`; iCommands are pre-installed
  on SURF's SRC image). Worth a look when a researcher who isn't in the CO
  needs the deliverables.
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

Per-file delivery cannot reach that scale: measured throughput is
~1.5 files/s (server-side per-operation latency — Yoda 2.0.4 policy rules
fire on every data-object write — not bandwidth), gocmd's native
`--bulk_upload` is rejected on research group collections, and `nluu10p`
users have no personal home collection to redirect its staging to
(details in `yoda-operations.md`). A 100k-file sync did not complete in
24 h of continuous running.

The problem is op count, not bytes, so `yoda-sync.sh` delivers transcripts
as **byte-reproducible per-shard tar archives**
(`transcripts-tars/shard-NN.tar.gz`, built with pinned tar metadata and
`gzip -n`): a milestone push is ≤ ~100 remote operations, unchanged shards
are byte-identical and checksum-skipped by `gocmd sync`, and restore is
pull + extract. Researchers browse Yoda at shard granularity; per-file
browsing of donations is the DDP Inspector's job, on the workspace.
`push-transcripts-plain` keeps per-file delivery for small pilots
(≤ ~10k files). Design:
`docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md`.
```

- [ ] **Step 3: `docs/yoda-operations.md` — transfer recipes + diagnostics**

In `## Transfer recipes`, replace the bullet beginning `- **Tarball pattern** for many small files` with:

```markdown
- **Shard-tar delivery (the default).** `yoda-sync.sh push-transcripts`
  builds one byte-reproducible archive per shard —
  `tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0
  --format=gnu --exclude='.*' -C <transcripts> NN | gzip -n` — into a
  staging dir whose basename MUST be `transcripts-tars` (the basename-append
  rule lands it as `<collection>/transcripts-tars`), then one
  `gocmd sync --thread_num 10`. Unchanged shards are byte-identical, so the
  checksum diff skips them: incremental delivery with zero bookkeeping.
  `gzip -n` is load-bearing (gzip otherwise embeds a timestamp and every
  tar looks changed). Restore: `pull-resume` fetches the tars and extracts;
  legacy plain `transcripts/` collections still restore via the old sync
  path.
```

In `## Diagnosis playbook (short)`, append a new numbered step:

```markdown
5. iCommands are pre-installed on SURF's SRC Ubuntu image — an independent
   client for cross-checking gocmd behavior (`ils -A` for ACLs, `iquest`
   for metadata queries, `iticket` for share tickets). Same DAP credential.
```

- [ ] **Step 4: `docs/catalog-item.md` — one-line delivery note**

In the Step A parameters table, replace the `yoda_collection` description cell text `**yoda only.** iRODS collection base path, e.g. \`/nluu10p/home/research-foo\`; holds inbox, transcripts, state snapshot.` with:

```
**yoda only.** iRODS collection base path, e.g. `/nluu10p/home/research-foo`; holds inbox, transcripts (delivered as per-shard tar archives under `transcripts-tars/`), state snapshot.
```

- [ ] **Step 5: Verify docs consistency**

Run: `grep -rn "YODA_BULK\|bulk_upload" docs/ scripts/ roles/ | grep -v superpowers`
Expected: only historical/RESOLVED mentions in `FOLLOWUPS.md` and `yoda-operations.md` (measurement records); no live instructions referencing it. Run `grep -n "transcripts-tars" docs/*.md scripts/yoda-sync.sh` and confirm the name is spelled identically everywhere.

- [ ] **Step 6: Stage and hand the commit to Danielle**

```bash
git add docs/FOLLOWUPS.md docs/storage-backends.md docs/yoda-operations.md docs/catalog-item.md
```

Report for Danielle to run:

```bash
git commit -m "docs(yoda): document shard-tar delivery; correct iCommands rationale"
```

---

### Task 5: Live Yoda round-trip verification (operator-assisted)

**Files:**
- Modify: `docs/yoda-operations.md` (performance table)
- Modify: `docs/superpowers/specs/2026-07-10-yoda-shard-tar-delivery-design.md` (validation note)

**Interfaces:**
- Consumes: the shipped `yoda-sync.sh` verbs from Tasks 1–3.
- Produces: measured wallclock numbers; confirmation (or correction) of the live `gocmd get` collection-landing assumption in `pull_transcript_tars()`.

**Needs from Danielle:** a cached gocmd auth token on this machine (fresh DAP → `gocmd init`; never retry a failing DAP) and the collection path to use, with a scratch sub-collection allowed (e.g. `<collection>/tar-verify`). All fixture content ASCII, digit-named.

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

- [ ] **Step 2: First push — verify layout and timing**

Run: `time scripts/yoda-sync.sh push`
Then: `gocmd ls "i:${YODA_COLLECTION}/transcripts-tars"`
Expected: exactly `shard-03.tar.gz  shard-41.tar.gz  shard-88.tar.gz` (no `.work`, no plain tree); `state-snapshot.sqlite` present at the collection base; wallclock well under a minute. Record the time.

- [ ] **Step 3: Idempotent second push — verify checksum skip**

Run: `time scripts/yoda-sync.sh push-transcripts`
Expected: gocmd reports no files transferred (checksum match); wallclock a few seconds. If it re-uploads everything, tar reproducibility is broken across this machine's tar/gzip versions — investigate before proceeding (compare `md5sum` of two consecutive `stage-transcripts` runs locally).

- [ ] **Step 4: Single-shard change — verify minimal upload**

```bash
echo '{"video_id":"41999","text":"new"}' > "${FIX}/transcripts/41/99941.json"
time scripts/yoda-sync.sh push-transcripts
```

Expected: exactly one object transferred (`shard-41.tar.gz`).

- [ ] **Step 5: Restore round-trip — verify `gocmd get` landing + extraction**

```bash
FRESH="$(mktemp -d)/ddp-work"; mkdir -p "${FRESH}"
YODA_TRANSCRIPTS_LOCAL="${FRESH}/transcripts" \
YODA_STATE_SNAPSHOT="${FRESH}/state.sqlite" \
  time scripts/yoda-sync.sh pull-resume
diff -r --exclude='.*' "${FIX}/transcripts" "${FRESH}/transcripts" && echo TREE-IDENTICAL
ls "${FRESH}/state.sqlite"
```

Expected: `TREE-IDENTICAL`; state file present; no `.work`/dotfiles in `${FRESH}`. **This step also validates the assumption that `gocmd get` of a collection lands as `<dest>/transcripts-tars`** — if it lands differently (e.g. contents splatted into dest), fix `pull_transcript_tars()` accordingly and re-run the harness + this step.

- [ ] **Step 6: Plain escape hatch still round-trips**

Run: `scripts/yoda-sync.sh push-transcripts-plain` then `gocmd ls "i:${YODA_COLLECTION}/transcripts"`
Expected: per-file `03/ 41/ 88/` tree appears (dotfiles WILL be included on this path — plain mode never excluded them; acceptable for the escape hatch, documented).

- [ ] **Step 7: Clean up the scratch collection (Danielle runs)**

Report for Danielle: `gocmd rm -r "i:${YODA_COLLECTION}"` (the `tar-verify` scratch only — never the real collection).

- [ ] **Step 8: Record the measurements**

Add rows to the performance table in `docs/yoda-operations.md` with the measured times, e.g.:

```markdown
| Shard-tar milestone push (450 files / 3 shards, first) | measured 2026-07-13: <X s> |
| Shard-tar no-op push (checksum skip) | measured 2026-07-13: <X s> |
| Shard-tar restore (pull + extract, 3 shards) | measured 2026-07-13: <X s> |
```

Append to the spec's Testing section: `**Validated live 2026-07-13** — all seven checks passed; timings recorded in yoda-operations.md.` (Adjust date/wording to reality; report failures honestly instead if any step failed.)

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

- **Spec coverage:** remote layout (T2 push landing + T4 docs), reproducible recipe (T1), thread cap (T2), plain escape hatch (T2), `YODA_BULK` deletion (T2), tar-preferred restore + legacy fallback (T3), no auto-delete of remote data (nowhere deletes; T5 cleanup is operator-run on scratch only), staging-basename guard (T1), wrapper contract untouched (no role/template tasks), docs updates incl. iCommands correction and `iticket` note (T4), live test plan + perf table refresh (T5). No gaps found.
- **Placeholder scan:** `<collection>` and `<X s>` in Task 5 are operator-supplied runtime values, flagged as such; no TBDs.
- **Type consistency:** `tar_stage_dir` / `stage_transcripts` / `pull_transcript_tars` names and the env contract (`YODA_TAR_STAGE`, `YODA_THREADS`) are identical across Tasks 1–3 and the harness; `transcripts-tars` and `shard-NN.tar.gz` spelled identically throughout (T4 Step 5 re-checks mechanically).
