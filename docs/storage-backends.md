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
- **iCommands** — native iRODS, integrity-checked, but needs an apt install with
  admin and version-pinning to the server (4.3.4).
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
ADR 0004) → ~100 shards, ~10k files/shard at 1M videos. `yoda-sync.sh` uses
`gocmd sync` (checksummed, symmetric), which is right for pilot-scale delivery.
For the full campaign, gocmd's **native** `--bulk_upload` (exposed as
`YODA_BULK=1`) bundles many small files per transfer — no hand-rolled `tar`
needed; tune `--max_bundle_size` / `--max_file_num` once real throughput is
measured.
