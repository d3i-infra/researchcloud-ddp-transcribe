# Storage backends — design note

Why this component (not the pipeline) owns storage, and why Yoda is reached over
iRODS/GoCommands rather than WebDAV. Companion to the ADR set in the
[ddp-transcribe](https://github.com/daniellemccool/ddp-transcribe) repo
(especially ADR 0031/0032); this note lives here because it is a
provisioning/linkage decision, not a pipeline decision.

## Ports-and-adapters boundary

`ddp-transcribe` (the pipeline) is the **core**: it reads local `--inbox`, writes
local `--transcripts` and `--state-db`, and knows nothing about mounts, WebDAV, or
iRODS. This component is the **environment adapter**: every storage system —
SRC-internal volume, SURF Research Drive, Yoda — is wired here, on the durable
seed/sink side that ADR 0032 already fenced off from the hot path.

The contract between the two is **the local working directory**, not an API:

- before a run, the adapter guarantees `~/ddp-work/inbox` is populated;
- after a run, it sinks `~/ddp-work/transcripts` + a `state.sqlite` snapshot to
  the chosen backend.

Consequence: adding a backend never touches the pipeline. The three backends
collapse to **two transports** — a *mount* path (`src-volume` and a mounted
Research Drive differ only by mount point; `rsync` + `sqlite3 .backup`) and an
*iRODS push/pull* path (`yoda`, via `gocmd`).

## Why GoCommands for Yoda (not WebDAV)

Yoda exposes several access methods. The relevant ones here:

- **Network Disk / WebDAV** — mounts as a folder, but Yoda's own docs warn it has
  *no automatic transfer checks* and *can silently corrupt* on larger or
  continuous transfers. For a sink of up to ~1M transcript JSONs that is
  disqualifying — it is the same weak-semantics hazard ADR 0032 kept off the
  state DB.
- **iCommands** — native iRODS, integrity-checked, and pre-installed on
  SURF's SRC Ubuntu image (so install cost is *not* an argument against it
  there). Not chosen for delivery because the role pins its own client
  version (the baked-in iCommands drifts with SURF's image), `yoda-sync.sh`
  also runs from operator dev machines where iCommands has no easy install,
  and all validated auth behavior (DAP handling, headless init, token
  probing) is gocmd-specific. Useful as a diagnostic sidearm on a workspace
  (`ils -A`, `iquest`, `iticket`).
- **GoCommands (`gocmd`)** — native iRODS protocol, checksummed transfers, and a
  single **downloaded static binary** (no apt/admin). Easiest to bake into a
  provisioning image; chosen.

Requires SRC egress to the Yoda host on iRODS ports **1247/1248/20000–20199**
(confirmed open for the pilot). The `yoda` role verifies reachability with
`gocmd ls` at provision time so a blocked port or bad password fails fast.

Note this is a deliberate divergence from `mono`'s Yoda storage backend, which
uses **WebDAV** — appropriate there because mono writes one bundle per donation
(a small, occasional write), a different flow from a bulk transcript sink.

## Scale

Transcripts shard on the last two digits of the video id (ddp-transcribe
ADR 0004) → ~100 shards, ~10k files/shard at 1M videos.

Client-side per-file delivery cannot reach that scale: measured throughput
is ~1.5 files/s (server-side per-operation latency — Yoda 2.0.4 policy
rules fire on every data-object write — not bandwidth). A 100k-file sync
did not complete in 24 h of continuous running (the ~1.5 files/s baseline
plus sync-restart re-listing overhead as the remote tree grows). gocmd's
`--bulk_upload` is also unusable here, but for a *client-side* reason: its
staging-path safety check rejects research group collections and `nluu10p`
users have no personal home collection to redirect staging to.

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
