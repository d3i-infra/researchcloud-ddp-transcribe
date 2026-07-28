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

## Tiered mode (yoda + interim volume)

For a campaign at 1M+ videos, an SRC volume sits between the boot disk and
Yoda as a fast interim tier — Yoda stays the inbox origin and the durable
final sink, but hop 2 (below) runs at operator cadence instead of every batch:

```
HOT (boot disk)                INTERIM (SRC volume)              DURABLE (Yoda)
~/ddp-work/{inbox,transcripts} <storage_path>/{inbox,transcripts, yoda_collection/{inbox,
~/ddp-state/state.sqlite        transcripts-tars/,                transcripts-tars/, transcripts/,
                                state-snapshot.sqlite}            state-snapshot.sqlite}

── hop 1: fast, AUTOMATIC, end of every batch ──►
   sync-to-storage.sh — rsync transcripts + sqlite .backup snapshot → volume
   (today's mount-backend branch, verbatim; no gocmd in the hot path)

                               ── hop 2: slow, OPERATOR-DRIVEN (~daily) ──►
                                  push-to-yoda.sh — shard-tar build + gocmd push
                                  + server-side extract, sourced from the VOLUME
                                  (yoda-sync.sh unchanged; env points at
                                   <storage_path>/transcripts + snapshot)

◄── restore: fast, volume → boot ──  ◄── seed once / refresh: yoda → volume ──
   restore-from-storage.sh              pull-from-yoda.sh (inbox + resume state)
```

**Activation:** tiered mode is `storage_backend: yoda` **and** a resolved
storage volume. Preflight resolves the volume automatically: SRC mounts
attached volumes at `/home/<user>/data/<volume-name>`, and exactly one mount
there is adopted with no parameter needed (multiple mounts fail loudly and
ask for an explicit `storage_path`; an unedited `<...>` placeholder counts as
unset). The resolved path lives in the `storage_root` fact — SRC parameters
arrive as extra-vars, which `set_fact` cannot override, so the raw
`storage_path` input and the resolved fact are deliberately distinct names.
Plain `yoda` (no volume attached) and `src-volume` behavior are unchanged.

**Scripts:**

- `sync-to-storage.sh` (hop 1) — fast rsync + `.backup` snapshot, boot disk →
  volume, run automatically at the end of every batch (both GPUs serialize
  through the existing flock).
- `push-to-yoda.sh` (hop 2) — shard-tar build + `gocmd` push + server-side
  extraction, sourced from the volume; operator-driven, ~daily. Hop 2 stages
  the shard tars on the volume itself (`<storage_path>/transcripts-tars/`, plus
  a `.transcripts-tars-pushed.md5` manifest at the volume root) — a near-duplicate
  of the transcript tree that persists between pushes, so size the volume for ~2×
  the transcript tree. Takes the sync lock only to capture a stable copy of the
  state snapshot, then pushes lock-free — a slow push never blocks a batch-end
  sync.
- `pull-from-yoda.sh` — seeds or refreshes the volume's inbox from Yoda (and,
  on a fresh volume with no `state-snapshot.sqlite`, prior transcripts + resume
  state too). Run once before the first batch, and again to pick up newly
  arrived donor DDPs.
- `restore-from-storage.sh` — volume → boot, including inbox hydration. On a
  rebuilt workspace: if the volume itself is empty (no state snapshot **and**
  an empty inbox), it fails loudly with instructions to run
  `pull-from-yoda.sh` first, rather than silently starting a fresh batch.

**Order on a rebuilt workspace:** volume first — `pull-from-yoda.sh` only if
the volume is fresh/empty, then `restore-from-storage.sh`.

**Durability:** losing the volume costs only the delta since the last hop-2
push — everything before that is already on Yoda, and ADR 0008 (pipeline
repo) makes re-attempts idempotent, so a restart never double-processes.
State DB never leaves the boot disk; only its `.backup` snapshots travel.

## Data-plane contract (DDP Inspector interop)

The DDP Inspector is a **separate catalog item**, on its own workspace; an SRC
volume attaches to one workspace only, so Yoda is the shared data plane
between this component and the inspector. This component never serves web
traffic and stays SSH-only — interop is entirely through what it guarantees
lives under `yoda_collection`:

- `inbox/` — donor DDP JSONs.
- `transcripts/` — server-side-extracted sharded tree, `NN/<id>.txt|.json`
  (ADR 0004 sharding) — exactly the inspector's expected `transcripts_dir`
  layout.
- `transcripts-tars/` — the byte-reproducible per-shard archives.
- `state-snapshot.sqlite` — the latest pushed state snapshot.
- No hidden files (shard-tar staging excludes dotfiles at tar time).

**Freshness:** the Yoda tree lags the running pipeline by the hop-2 cadence
(~daily, operator-driven — not automatic, not cron'd). The inspector's
"not transcribed yet" state is expected to cover that gap.

**Access:** an anonymous read ticket (`gocmd mkticket -t read` on the
collection) — read-only, no DAP, no CO membership required on the inspector
side (verified 2026-07-13). Hygiene: set an expiry with `modticket` on any
real hand-off (defaults are permissive — unlimited uses, no expiry);
`rmticket` revokes; `lsticket` audits. See `yoda-operations.md` for the full
verification log.
