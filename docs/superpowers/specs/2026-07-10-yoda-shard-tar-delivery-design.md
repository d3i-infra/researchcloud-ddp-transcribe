# Yoda shard-tar delivery — design

**Date:** 2026-07-10
**Status:** approved (brainstorming session 2026-07-10)
**Companion docs:** `docs/storage-backends.md` (backend rationale),
`docs/yoda-operations.md` (measured server behavior), `docs/FOLLOWUPS.md`
(the open items this design closes).

## Problem

Per-file transcript delivery to Yoda does not scale. Measured 2026-07-06
(`yoda-operations.md`): ~1.5 files/s at 15 threads, ~3 s per collection
create, cost dominated by server-side per-operation latency (Yoda 2.0.4
policy rules fire on every data-object write; documented `msiDataObjRepl`
deadlock issue). A 100k-file sync did not complete in 24 h of continuous
running — consistent with that baseline, not an incident. gocmd's native
`--bulk_upload` is dead on Yoda (staging collection rejected on research
group collections; no personal home collection on `nluu10p` to redirect to).
The 1M-video campaign (~2M files) is infeasible as a plain sync.

The bottleneck is **op count, not bytes**: 2M transcripts total only a few
GB, and large single-file transfers to Yoda are bandwidth-bound and healthy.
The fix is to send fewer, bigger objects. No client change helps — iCommands
(pre-installed on SURF's SRC Ubuntu image), rclone/WebDAV, and iBridges all
pay the same server-side per-write cost (and WebDAV additionally lacks
transfer integrity checks, which is disqualifying for a durable sink). We
stay on GoCommands: the role pins its version (the baked-in iCommands drifts
with SURF's image), `yoda-sync.sh` also runs from operator dev machines where
iCommands has no easy install, and all the validated DAP/auth behavior
(`init -c`, `--ttl 720`, token probing) is gocmd-specific. The pre-installed
iCommands remain useful as a diagnostic sidearm (`ils -A`, `iquest`,
`iticket`) alongside gocmd.

## Decisions driving the shape

1. **Yoda's role:** durable sink. Researchers would *like* per-file browsing
   of inbox and transcripts, but at campaign scale it is doubly broken: the
   transfer takes weeks, and the portal (60–90 s per iRODS-heavy page load)
   cannot usefully browse ~100k files scattered across ~100 shards keyed on
   the *video id*, not the participant. Shard-level browsing (~100 tidy
   archive objects) is the honest offer; per-file human browsing is the DDP
   Inspector's job, on the workspace. The inbox (small file counts) stays
   per-file in both directions.
2. **Sync cadence:** periodic milestones, operator-driven (run
   `~/sync-to-storage.sh` at checkpoints), not continuous auto-sync. The
   workspace disk holds the working copy between milestones.
3. **Approach:** per-shard **reproducible** tars, delivered with `gocmd
   sync` (chosen over a single whole-tree snapshot tar and over append-only
   incremental batch tars). Byte-identical archives for unchanged shards let
   gocmd's checksum comparison skip them — incremental delivery with zero
   manifest/state bookkeeping, partial restore, and a bounded op count.

## Remote collection layout

```
<yoda_collection>/
  inbox/                        # per-file DDP exports (unchanged, researcher-managed)
  transcripts-tars/
    shard-NN.tar.gz             # one per populated local shard 00–99
  state-snapshot.sqlite         # unchanged (single gocmd put)
  transcripts/                  # LEGACY plain tree from pre-tar pilots, if any
```

A legacy plain `transcripts/` collection is left untouched; the operator may
`gocmd rm -r` it manually once shard tars are confirmed. Nothing in this repo
auto-deletes remote data.

## Push path — `yoda-sync.sh`

`push-transcripts` (and therefore `push`, which the generated
`sync-to-storage.sh` calls) switches to tar delivery **by default**:

1. Wipe and rebuild a local staging dir on the boot disk, **outside** the
   transcripts tree (a hidden dir inside it is exactly the `.work/` leak we
   are retiring): e.g. `${YODA_TAR_STAGE:-<workdir>/transcripts-tars}`.
2. For each populated shard dir `NN/` under the transcripts tree, build
   `shard-NN.tar.gz` with a byte-reproducible recipe:
   - GNU tar: `--sort=name --owner=0 --group=0 --numeric-owner --mtime=@0
     --format=gnu -C <transcripts> NN`
   - piped through `gzip -n` — `-n` is load-bearing: without it gzip embeds
     a timestamp and breaks reproducibility. No new package dependency
     (deliberately not zstd).
   - hidden files/dirs excluded at tar time (closes the dotfile-leak
     follow-up).
3. `gocmd sync <staging-dir> i:<yoda_collection>` with
   `--thread_num ${YODA_THREADS:-10}` (≤15 is the measured server-safe
   ceiling; 30 saturated the server for all users). Unchanged shards produce
   byte-identical tars, so sync's checksum diff skips them. The staging dir's
   basename MUST be `transcripts-tars`: gocmd's basename-append rule
   (`sync SRC DEST` creates `DEST/basename(SRC)` when DEST exists) is what
   lands it as `<collection>/transcripts-tars`.

Milestone cost: ~2 min local CPU to re-tar + upload of changed shards only;
≤ ~100 remote operations regardless of file count.

Also in this pass:

- **`push-transcripts-plain`** — the current per-file `gocmd sync` survives
  as an explicit escape hatch for small pilots (≤ ~10k files) where per-file
  portal browsing genuinely works.
- **`YODA_BULK` / `--bulk_upload` is deleted outright** (proven dead on
  Yoda 2026-07-06).
- Push order stays transcripts-then-state, so the state snapshot never
  claims transcripts that are not yet durably on Yoda.
- The `workspace_layout` wrappers (`sync-to-storage.sh`,
  `restore-from-storage.sh`) keep calling `push` / `pull-resume` /
  `pull-inbox` — no template changes required beyond any env plumbing.

## Restore path

`pull-resume`, after fetching the state snapshot:

- probe the remote: if `<collection>/transcripts-tars` exists, `gocmd get`
  the shard tars and extract each into the transcripts dir
  (`tar -xf … -C <transcripts>`; members are `NN/…`, order-independent);
- otherwise fall back to the current plain `gocmd sync` pull (legacy
  collections keep working).

`pull-inbox` is unchanged.

## Failure model

- **Interrupted push:** rerun; `gocmd sync` is checksummed and idempotent.
- **Tar determinism breaks** (e.g. differing GNU tar versions between a dev
  machine and the workspace): failure mode is spurious re-upload of
  unchanged shards — wasted bandwidth, never corruption.
- **Auth/DAP handling:** unchanged; the `yoda` role owns it (token probe by
  exit code, fresh-DAP guidance on failure).

## Testing (runnable now — no GPU workspace needed)

From a dev machine with `gocmd init` cached, against the real Yoda
collection (matches the script's documented operator-from-dev-machine use):

1. Fixture: ~3 shard dirs, a few hundred small files, plus a planted
   `.work/` dir with a dummy media file.
2. `push-transcripts` → shard tars appear under `transcripts-tars/`;
   dotfiles absent from the archives.
3. Immediate second push → zero objects transferred (checksum skip).
4. Touch one file in one shard → exactly one shard tar re-uploads.
5. `pull-resume` into a clean dir → extracted tree is byte-identical to the
   source (diff -r), state snapshot restored.
6. `push-transcripts-plain` still round-trips.
7. Record wallclock numbers; update the performance table in
   `yoda-operations.md`.

## Documentation updates

- `FOLLOWUPS.md`: close the 1M-scale delivery-redesign item (tar-mode chosen;
  FSW admin-side bulk ingest stays noted as a possible future upgrade — the
  question is still pending with FSW) and the hidden-files item. Optionally
  add an `iticket` note (share-by-ticket for handing researchers download
  access to shard tars without CO membership — unexplored).
- `storage-backends.md`: rewrite the Scale section around shard tars, and
  correct the iCommands bullet in the client rationale — iCommands is
  pre-installed on SURF's SRC Ubuntu image, so the apt/admin install-cost
  argument is false there; the real reasons for gocmd are version pinning by
  the role, identical availability on operator dev machines, and the
  gocmd-validated auth behavior.
- `yoda-operations.md`: add the tar recipe to Transfer recipes; refresh the
  performance table after testing; note the pre-installed iCommands as a
  diagnostic option alongside the WebDAV curl probe.
- `catalog-item.md`: one-line note that the yoda backend delivers
  transcripts as per-shard archives.

## Out of scope

Deliberately deferred, and not foreclosed by this design:

- the catalog item remake (portal re-registration, parameter changes);
- the DDP Inspector integration (separate design; the inspector is the
  per-file browsing answer);
- the `research-drive` backend stub;
- FSW admin-side bulk ingest (would slot in as an alternative delivery
  transport if FSW offers one).
