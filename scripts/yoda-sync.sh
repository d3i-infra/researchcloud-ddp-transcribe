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
#
# Usage:
#   yoda-sync.sh push-transcripts   # local transcripts -> collection/transcripts
#   yoda-sync.sh push-state         # state snapshot     -> collection/state-snapshot.sqlite
#   yoda-sync.sh push               # push-transcripts + push-state
#   yoda-sync.sh pull-inbox         # collection/inbox   -> local inbox
#   yoda-sync.sh pull-resume        # collection state + transcripts -> local (rebuild)
#
# Transfers use `gocmd sync` (hash-checksummed, idempotent) — the integrity
# guarantee WebDAV/Network-Disk cannot give. At ~1M transcripts the per-file
# listing cost grows; per-shard tar bundling is the documented scale path
# (docs/FOLLOWUPS.md) and is not needed for pilot-scale delivery.
set -euo pipefail

: "${YODA_COLLECTION:?set YODA_COLLECTION to the iRODS collection base path}"

# gocmd addresses iRODS paths with an `i:` prefix. VERIFY against the installed
# gocmd version (older builds used bare paths for some subcommands).
irods() { printf 'i:%s' "$1"; }

push_transcripts() {
  : "${YODA_TRANSCRIPTS_LOCAL:?set YODA_TRANSCRIPTS_LOCAL}"
  echo "[yoda-sync] push transcripts: ${YODA_TRANSCRIPTS_LOCAL} -> ${YODA_COLLECTION}/$(basename "${YODA_TRANSCRIPTS_LOCAL}")"
  # `gocmd sync SRC DEST` creates DEST/basename(SRC) (it appends the source dir
  # name and ignores a trailing slash), and creates the target itself — so
  # target the collection base, not <base>/transcripts, or you get a doubled
  # transcripts/transcripts path. Set YODA_BULK=1 to enable gocmd's native
  # bundling (--bulk_upload) for the 1M-file campaign.
  gocmd sync ${YODA_BULK:+--bulk_upload} "${YODA_TRANSCRIPTS_LOCAL}" "$(irods "${YODA_COLLECTION}")"
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
  push-transcripts) push_transcripts ;;
  push-state)       push_state ;;
  push)             push_transcripts; push_state ;;
  pull-inbox)       pull_inbox ;;
  pull-resume)      pull_resume ;;
  *)
    echo "usage: yoda-sync.sh {push-transcripts|push-state|push|pull-inbox|pull-resume}" >&2
    exit 2
    ;;
esac
