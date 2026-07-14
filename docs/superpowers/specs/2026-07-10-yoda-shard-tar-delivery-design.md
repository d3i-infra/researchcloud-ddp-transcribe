# Yoda shard-tar delivery — design

**Date:** 2026-07-10, **amended 2026-07-13** (server-side extraction verified;
plain tar replaces gzip; extraction default-on)
**Status:** approved (brainstorming 2026-07-10; amendment approved 2026-07-13)
**Companion docs:** `docs/storage-backends.md` (backend rationale),
`docs/yoda-operations.md` (measured server behavior), `docs/FOLLOWUPS.md`
(the open items this design closes).

## Problem

Per-file transcript delivery to Yoda does not scale. Measured 2026-07-06
(`yoda-operations.md`): ~1.5 files/s at 15 threads, ~3 s per collection
create, cost dominated by server-side per-operation latency (Yoda 2.0.4
policy rules fire on every data-object write; documented `msiDataObjRepl`
deadlock issue). A 100k-file sync did not complete in 24 h of continuous
running — consistent with that baseline, not an incident. The 1M-video
campaign (~2M files) is infeasible as a plain sync.

The bottleneck is **op count, not bytes**: 2M transcripts total only a few
GB, and large single-file transfers to Yoda are bandwidth-bound and healthy
(~85 MB/s measured 2026-07-13). The fix is to send fewer, bigger objects.
No client change helps — iCommands (pre-installed on SURF's SRC Ubuntu
image), rclone/WebDAV, and iBridges all pay the same server-side per-write
cost (and WebDAV additionally lacks transfer integrity checks, which is
disqualifying for a durable sink). We stay on GoCommands: the role pins its
version, `yoda-sync.sh` also runs from operator dev machines, and all the
validated DAP/auth behavior (`init -c`, `--ttl 720`, token probing) is
gocmd-specific. The pre-installed iCommands remain useful as a diagnostic
sidearm (`ils -A`, `iquest`, `iticket`).

**Correction (2026-07-13 live experiments):** the 2026-07-06 conclusion that
server-side archive handling is blocked on Yoda was wrong. What failed then
was `--bulk_upload`'s *client-side* staging-path guardrail. The server's
native tar extraction — `gocmd bun -x` — **works on stock gocmd** against
`fsw.data.uu.nl`, measured at ~13–14 files/s server-side (vs ~1.5 files/s
client-side per-file push, ~9× faster, client idle while it runs). This
makes a per-file browsable tree on Yoda feasible after all, as a server-side
*projection* of the uploaded tars.

## Decisions driving the shape

1. **Yoda's role:** durable sink **plus browsable per-file projection**.
   Researchers want per-file browsing of inbox and transcripts. The tars are
   the durable record and the restore path; after each milestone push, the
   changed shards are additionally extracted **server-side** into
   `<collection>/transcripts/`, giving researchers the per-file tree at
   ~13–14 files/s of server time per changed shard without any client-side
   per-file transfer. The inbox (small file counts) stays per-file in both
   directions. (Amended 2026-07-13 — the original design offered shard-level
   browsing only, believing server-side extraction was blocked.)
2. **Sync cadence:** periodic milestones, operator-driven (run
   `~/sync-to-storage.sh` at checkpoints), not continuous auto-sync. The
   workspace disk holds the working copy between milestones.
3. **Approach:** per-shard **reproducible plain tars** delivered with
   `gocmd sync` (chosen over a single whole-tree snapshot tar and over
   append-only incremental batch tars). Byte-identical archives for
   unchanged shards let gocmd's checksum comparison skip them. **Plain
   uncompressed tar, not gzip** (amended 2026-07-13): `-D tar` is the
   verified `bun -x` extraction format, upload cost is trivial at measured
   bandwidth (whole campaign ≈ minutes), and reproducibility gets simpler
   (no gzip timestamp quirk).
4. **Extraction is default-on** (`YODA_EXTRACT=1`), per-changed-shard only.
   Set `YODA_EXTRACT=0` for an archive-only sink. Known open risk, asked of
   FSW: whether `-f` re-extraction mints a Yoda revision per overwritten
   object (storage-relevant at scale). If that comes back bad, the default
   flips to off — one env var, no structural change.

## Remote collection layout

```
<yoda_collection>/
  inbox/                        # per-file DDP exports (unchanged, researcher-managed)
  transcripts-tars/
    shard-NN.tar                # durable record: one plain tar per populated shard 00–99
  transcripts/                  # browsable per-file projection, extracted server-side
    NN/...                      # (same path a legacy plain-mode tree used — they converge)
  state-snapshot.sqlite         # unchanged (single gocmd put)
```

A legacy plain `transcripts/` tree from pre-tar pilots simply becomes the
extraction target — `bun -x -f` overwrites it into currency. Nothing in this
repo auto-deletes remote data.

## Push path — `yoda-sync.sh`

`push-transcripts` (and therefore `push`, which the generated
`sync-to-storage.sh` calls):

1. Wipe and rebuild a local staging dir on the boot disk, **outside** the
   transcripts tree: `${YODA_TAR_STAGE:-$(dirname $YODA_TRANSCRIPTS_LOCAL)/transcripts-tars}`.
   The basename MUST be `transcripts-tars` (gocmd's basename-append rule
   lands it as `<collection>/transcripts-tars`); the script guards this.
2. For each populated 2-digit shard dir `NN/`, build `shard-NN.tar` with a
   byte-reproducible recipe: GNU tar
   `--sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --format=gnu
   --exclude='.*' -C <transcripts> NN`. No compression. Hidden entries are
   excluded (closes the dotfile-leak follow-up).
3. Compute the changed-shard set: md5 of each staged tar vs the manifest
   file recorded by the last successful push
   (`$(dirname <stage>)/.transcripts-tars-pushed.md5`); no manifest = all
   shards changed. (The *sync* needs no bookkeeping — reproducible bytes +
   checksum diff — but the extraction step must know which shards to
   extract, and parsing gocmd output would be fragile.)
4. `gocmd sync <staging-dir> i:<collection>` with
   `--thread_num ${YODA_THREADS:-10}` (≤15 measured server-safe ceiling; 30
   saturated the server for all users). Unchanged shards are checksum-skipped.
5. If `YODA_EXTRACT` ≠ 0: for each changed shard,
   `gocmd bun -x -f -D tar --timeout ${YODA_BUN_TIMEOUT:-1200}
   i:<collection>/transcripts-tars/shard-NN.tar i:<collection>/transcripts`.
   `-f` is required for re-delivery (bare re-extract fails
   `SYS_COPY_ALREADY_IN_RESC`); the raised `--timeout` covers ~10k-file
   shards (~12 min at ~14 files/s; gocmd default 300 s is too short).
6. Rewrite the manifest only after sync + extraction succeed; a failed
   milestone re-syncs (checksum no-op) and re-extracts (`-f`, idempotent)
   on the next run. A push with `YODA_EXTRACT=0` does NOT advance the
   manifest, so a later extraction-enabled push still extracts those
   shards. Deleting the manifest forces re-extraction of everything.

Milestone cost: ~2 min local CPU to re-tar + bandwidth for changed shards +
server-side extraction of changed shards only.

Also in this pass:

- **`push-transcripts-plain`** — the per-file `gocmd sync` survives as an
  explicit escape hatch for small pilots.
- **`YODA_BULK` / `--bulk_upload` is deleted outright** (its client-side
  staging check is what actually failed on 2026-07-06).
- Push order stays transcripts-then-state.
- The `workspace_layout` wrappers keep calling `push` / `pull-resume` /
  `pull-inbox` — no template changes.

## Restore path

`pull-resume`, after fetching the state snapshot:

- probe the remote: if `<collection>/transcripts-tars` exists, `gocmd get`
  the shard tars and extract each into the transcripts dir
  (`tar -xf … -C`; members are `NN/…`, order-independent). The tars are the
  restore path — never the extracted projection (client-side per-file pull
  is the ~1.5 files/s wall all over again);
- otherwise fall back to the plain `gocmd sync` pull (legacy collections
  keep working).

`pull-inbox` is unchanged.

## Failure model

- **Interrupted push:** rerun; `gocmd sync` is checksummed and idempotent,
  `bun -x -f` overwrites idempotently, and the manifest only advances on
  full success.
- **Tar determinism breaks** (differing GNU tar versions): spurious
  re-upload + re-extraction of unchanged shards — wasted time, never
  corruption.
- **Extraction fails or times out mid-shard:** manifest doesn't advance;
  next milestone re-extracts. Whether the server finishes an extraction
  after client `--timeout` disconnect is untested (deliberately — server-load
  politeness); flagged to FSW.
- **Revision-store risk (open):** `-f` re-extraction may create a Yoda
  revision per overwritten object. Asked of FSW; if confirmed costly, flip
  `YODA_EXTRACT` default to 0.
- **Auth/DAP handling:** unchanged; the `yoda` role owns it.

## Testing (hermetic + live)

Hermetic harness (`scripts/test-yoda-sync.sh`, fake `gocmd` PATH shim):
staging reproducibility, hidden-entry exclusion, changed-shard detection,
extraction calls (count, flags, targets), `YODA_EXTRACT=0`, restore
round-trip, legacy fallback.

Live, from a dev machine with cached gocmd auth (matches the script's
operator-from-dev-machine use):

1. Fixture: ~3 shard dirs, a few hundred small files, planted `.work/` dir.
2. `push` → shard tars under `transcripts-tars/`, per-file tree under
   `transcripts/`, state snapshot at base; dotfiles absent everywhere.
3. Immediate second push → zero objects transferred, zero extractions.
4. Touch one file in one shard → exactly one tar re-uploads, exactly one
   `bun -x` runs, updated content visible in the extracted tree.
5. `pull-resume` into a clean dir → tree byte-identical (tars, not the
   projection), state restored.
6. `push-transcripts-plain` still round-trips.
7. Record wallclock; update `yoda-operations.md`'s performance table
   (2026-07-13 experiment numbers are the baseline: put 310 KB/300-file tar
   5.1 s; `bun -x` 300 files 23.6 s; 2,000 files 2 m 22 s; `-f` re-extract
   ~5.6–5.8 s).

**Validated live 2026-07-14** (dev machine → `fsw.data.uu.nl`, scratch
sub-collection, 450-file/3-shard fixture): all checks passed — first
`push` 54 s (tars + 3 extractions + state; dotfiles excluded), no-op push
7.2 s / 0 changed, single-shard delta 10.8 s / exactly one re-upload +
one extraction with byte-correct content in the projection, `pull-resume`
6.8 s with `diff -r` byte-identical tree (confirming the `gocmd get`
landing rule and never touching the projection), and
`push-transcripts-plain` round-tripped the same content in 6 m 18 s
(~1.2 files/s — the per-file baseline this design exists to avoid).
Timings recorded in `yoda-operations.md`.

## Documentation updates

- `FOLLOWUPS.md`: close the 1M-scale delivery-redesign item (shard tars +
  server-side extraction; the "extraction blocked by policy" hypothesis is
  corrected) and the hidden-files item. Close the `iticket` question — the
  anonymous read-ticket hand-off is **verified working** (2026-07-13,
  three-way control; the iRODS `anonymous` user is enabled on
  fsw.data.uu.nl) with hygiene caveat: default tickets have unlimited uses
  and no expiry — always `modticket` an expiry on real hand-offs. Add open
  items: the revision-store question and the client-timeout-mid-extraction
  question (both for the pending FSW thread).
- `storage-backends.md`: rewrite the Scale section around shard tars +
  server-side extraction; correct the iCommands bullet (pre-installed on
  SRC; the real gocmd rationale is version pinning, dev-machine
  availability, validated auth).
- `yoda-operations.md`: new sections for `bun -x` (verified behavior,
  measured rates, `-f`/timeout semantics) and ticket hand-off (flow +
  hygiene), sourced from the 2026-07-13 experiment log; shard-tar recipe in
  Transfer recipes; performance table refresh.
- `catalog-item.md`: note that the yoda backend delivers transcripts as
  per-shard archives plus a server-side-extracted per-file tree.

## Out of scope

Deliberately deferred, and not foreclosed by this design:

- the catalog item remake (portal re-registration, parameter changes);
- the DDP Inspector integration (separate design);
- the `research-drive` backend stub;
- FSW admin-side bulk ingest (superseded in practice by `bun -x`, but their
  answer may still improve the story);
- `ibun -c` server-side *re-bundling* via iCommands (would let restore read
  a fresh server-side bundle of the projection; only relevant if the
  tars-as-record model ever changes).
