#!/usr/bin/env bash
# yoda-sync.sh — seed/sink the ddp-transcribe working set to a Yoda (iRODS)
# collection via GoCommands (gocmd). Plain, standalone script with no Ansible
# templating: the component's generated sync-to-storage.sh / restore-from-
# storage.sh wrap it on a provisioned workspace, AND an operator can run it
# directly from a dev machine to deliver a researcher's transcripts (run
# `gocmd init` once locally first to cache auth).
#
# Config via environment:
#   YODA_COLLECTION        (required) iRODS collection base, e.g.
#                          /nluu10p/home/research-foo
#   YODA_TRANSCRIPTS_LOCAL local transcripts dir (the sharded NN/ tree)
#   YODA_INBOX_LOCAL       local inbox dir (DDP export JSONs)
#   YODA_STATE_SNAPSHOT    local path to the state snapshot file
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
#
# Usage:
#   yoda-sync.sh stage-transcripts       # build per-shard tars in staging dir
#   yoda-sync.sh push-transcripts        # shard tars + server-side extraction (default delivery)
#   yoda-sync.sh push-transcripts-plain  # per-file delivery (small pilots only)
#   yoda-sync.sh push-state              # state snapshot -> collection/state-snapshot.sqlite
#   yoda-sync.sh push                    # push-transcripts + push-state
#   yoda-sync.sh pull-inbox              # collection/inbox -> local inbox
#   yoda-sync.sh pull-resume             # collection state + transcripts -> local (rebuild)
#
# Transcripts are delivered as byte-reproducible per-shard plain tars
# (shard-NN.tar) plus server-side extraction (gocmd bun -x) into a browsable
# per-file tree — at ~1.5 files/s of server-side per-op latency, client-side
# per-file delivery cannot finish a campaign-scale sync
# (docs/storage-backends.md). `push-transcripts-plain` keeps the per-file
# path for small pilots.
set -euo pipefail

: "${YODA_COLLECTION:?set YODA_COLLECTION to the iRODS collection base path}"

# gocmd addresses iRODS paths with an `i:` prefix. VERIFY against the installed
# gocmd version (older builds used bare paths for some subcommands).
irods() { printf 'i:%s' "$1"; }

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
    # raised --timeout covers ~10k-file shards (gocmd default 300s is too
    # short).
    for name in "${changed[@]}"; do
      echo "[yoda-sync] server-side extract: ${name} -> ${YODA_COLLECTION}/transcripts"
      gocmd bun -x -f -D tar --timeout "${YODA_BUN_TIMEOUT:-1200}" \
        "$(irods "${YODA_COLLECTION}/transcripts-tars/${name}")" \
        "$(irods "${YODA_COLLECTION}/transcripts")"
    done
  fi
  # Record delivered state only after sync AND extraction succeed; a failed
  # milestone re-syncs (checksum no-op) and re-extracts (-f) next run. A push
  # with YODA_EXTRACT=0 deliberately does NOT advance the manifest — the next
  # extraction-enabled push must still extract those shards. The redirect sits
  # OUTSIDE the subshell so ${manifest} resolves against the caller's CWD even
  # if the stage path is relative.
  if [ "${YODA_EXTRACT:-1}" != "0" ] && compgen -G "${stage}/shard-*.tar" > /dev/null; then
    ( cd "${stage}" && md5sum shard-*.tar ) > "${manifest}"
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

push_state() {
  : "${YODA_STATE_SNAPSHOT:?set YODA_STATE_SNAPSHOT}"
  if [ -f "${YODA_STATE_SNAPSHOT}" ]; then
    echo "[yoda-sync] push state snapshot -> ${YODA_COLLECTION}/state-snapshot.sqlite"
    gocmd put -f "${YODA_STATE_SNAPSHOT}" "$(irods "${YODA_COLLECTION}/state-snapshot.sqlite")"
  else
    echo "[yoda-sync] no state snapshot at ${YODA_STATE_SNAPSHOT} — skipping"
  fi
}

pull_inbox() {
  : "${YODA_INBOX_LOCAL:?set YODA_INBOX_LOCAL}"
  # gocmd sync appends basename(SRC) to DEST, so sync the remote inbox INTO the
  # parent dir; it lands as <parent>/inbox == YODA_INBOX_LOCAL.
  local parent; parent="$(dirname "${YODA_INBOX_LOCAL}")"
  mkdir -p "${parent}"
  echo "[yoda-sync] pull inbox: ${YODA_COLLECTION}/inbox -> ${YODA_INBOX_LOCAL}"
  gocmd sync "$(irods "${YODA_COLLECTION}/inbox")" "${parent}"
}

pull_resume() {
  if [ -n "${YODA_STATE_SNAPSHOT:-}" ]; then
    echo "[yoda-sync] pull state snapshot -> ${YODA_STATE_SNAPSHOT}"
    gocmd get -f "$(irods "${YODA_COLLECTION}/state-snapshot.sqlite")" "${YODA_STATE_SNAPSHOT}" \
      || echo "[yoda-sync] no state snapshot in collection — fresh batch"
  fi
  if [ -n "${YODA_TRANSCRIPTS_LOCAL:-}" ]; then
    # Same basename-append rule: sync INTO the parent so it lands as
    # <parent>/transcripts == YODA_TRANSCRIPTS_LOCAL.
    local parent; parent="$(dirname "${YODA_TRANSCRIPTS_LOCAL}")"
    mkdir -p "${parent}"
    echo "[yoda-sync] pull transcripts -> ${YODA_TRANSCRIPTS_LOCAL}"
    gocmd sync "$(irods "${YODA_COLLECTION}/transcripts")" "${parent}" \
      || echo "[yoda-sync] no transcripts in collection yet"
  fi
}

cmd="${1:-}"
case "${cmd}" in
  stage-transcripts)       stage_transcripts ;;
  push-transcripts)        push_transcripts ;;
  push-transcripts-plain)  push_transcripts_plain ;;
  push-state)              push_state ;;
  push)                    push_transcripts; push_state ;;
  pull-inbox)              pull_inbox ;;
  pull-resume)             pull_resume ;;
  *)
    echo "usage: yoda-sync.sh {stage-transcripts|push-transcripts|push-transcripts-plain|push-state|push|pull-inbox|pull-resume}" >&2
    exit 2
    ;;
esac
