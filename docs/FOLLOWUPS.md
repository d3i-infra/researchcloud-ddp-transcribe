# researchcloud-ddp-transcribe — follow-ups

Deployment-side open items. (Pipeline-code follow-ups live in the ddp-transcribe
repo's `docs/FOLLOWUPS.md`.)

## Open

- **gocmd connection-pool cap (S18, 2026-07-31).** `push-to-yoda.sh` (default
  `--thread_num 10`) died mid-`push-transcripts` with "Failed to establish a
  new connection to iRODS server as connection pool is full (occupied: 3,
  max: 3)" — not in any doc; docs were verified against gocmd v0.12.2, so a
  newer gocmd is the suspected cause. Diagnostics pending from the operator:
  `gocmd --version` and `gocmd sync --help | grep -i 'conn\|thread'`; if
  confirmed, the fix is a pool-size flag/config or a version pin.
  `YODA_THREADS` default dropped to 2 meanwhile (threads must fit the pool
  with headroom; upload is bandwidth-bound so low counts cost ~nothing), and
  collection `gocmd get` in `pull_transcript_tars` runs `--single_threaded`
  (v0.12.x intermittently sizes the pool at 1 for collection gets). Retry is
  safe/idempotent; a pool failure in `push-transcripts` skips `push-state`
  under `set -e` — the rerun does both halves.

- **Campaign-VM one-time cleanup: 279,212 leftover `.work/ytdlp-*` dirs**
  (2026-07-31). v0.3.0 leaves per-attempt dirs behind by design; v0.4.0
  removes them per-attempt and sweeps at startup, so this is a one-off on the
  pinned VM. Age-gated cleanup is safe live:
  `find <work_dir>/transcripts/.work -mindepth 1 -maxdepth 1 -type d -name 'ytdlp-*' -mtime +1 -exec rm -rf {} +`.

- **Stale loose `transcripts/` tree on the campaign collection** — frozen at
  Jul-29 content while extraction is policy-blocked; misled a downstream
  consumer 2026-07-31. Operator action on Yoda: delete it or README-mark it
  until extraction is enabled and a push back-fills it. Delivery contract
  documented in `yoda-operations.md`.

- **RESOLVED 2026-07-31 — `sync-to-storage.sh` (tiered/mount branch) shipped
  stale state snapshots on rsync exit 24.** Observed live twice, 2026-07-29:
  a mid-run sync hits `file has vanished: …/transcripts/.work/ytdlp-*/…`
  (in-flight yt-dlp transients live inside the synced tree), rsync exits 24,
  and under `set -euo pipefail` the script dies at the rsync line — **before**
  the `sqlite3 .backup` — so the staged `state-snapshot.sqlite` silently keeps
  its old content while gaining a fresh mtime. Fixed in
  `roles/workspace_layout/templates/sync-to-storage.sh.j2` (mount/tiered
  branch; yoda-direct already backed up first): `.backup` moved **above** the
  rsync, `--exclude='.work'` + `--exclude='*.tmp-*'`, and
  `rsync … || [ $? -eq 24 ]`. Backup-first is more than the exit-24 fix — it
  yields the invariant *volume artifacts ⊇ volume snapshot's succeeded set*,
  making offline verification of the volume copy sound
  (`ddp-transcribe --state-db <snapshot> --transcripts <volume>/transcripts
  status --verify`). Field-validated in production form as the campaign VM's
  `~/checkpoint-sync.sh` (see the cron stopgap in `yoda-operations.md`); this
  also unblocks the checkpoint hook, now wired in `run-pipeline.sh.j2`.
  **INCIDENT this caused (hop-1 transcript gap, Jul 29–31, resolved):** the
  operator had stopped running `sync-to-storage.sh` because it "breaks"
  (this bug) and substituted a DB-only one-liner (`flock … sqlite3 .backup`),
  so the volume had fresh snapshots but **frozen transcripts** — the loose
  tree stuck at 39,972 files (Jul 29 06:56 state) while the DB recorded
  213,528 succeeded: ~173k transcript pairs singly-homed on the volatile boot
  disk for ~2 days (transcripts are not reconstructable from the DB).
  Surfaced by a researcher-side Yoda pull ("metadata ≈ processed count,
  transcripts missing" — Yoda's loose tree and `transcripts-tars` both
  derived from the frozen volume state). Resolved by a manual protective
  rsync: volume current again, ≥216k `.txt` verified, count symmetry +
  dry-run checks pass.

- **CUDA version is not pinned on SRC.** SRC's CUDA component does `apt install
  cuda` off the dynamic keyring, pulling NVIDIA's *current* release (13.3 +
  driver 610 as provisioned at Tier 5; builds cleanly). Our `cuda` role defers
  to it (skips its pinned 13.2 when nvcc is present), so the build CUDA floats
  with whatever NVIDIA ships. A future release could break the whisper.cpp
  build. If it does: force our pinned toolkit (install even when nvcc present),
  or pin the version via the CUDA component. Low likelihood, high blast radius.

- **`download_workers=3` is likely too low for the 1M campaign.** At ~2 s/video
  on 2 GPUs (~1 video/s) the downloader, not transcription, is the probable
  bottleneck over a multi-week pull — and the main TikTok rate-limiting exposure.
  Tune per-machine once live throughput is observed; consider a higher default
  for GPU flavors. 2026-07-28: made Interactive at the catalog item — set
  per-launch, tune from observed throughput (see `catalog-item.md`).

- **`pipeline_user` could be dropped via a user-agnostic redesign.** Today the
  pipeline installs a per-user toolchain (rustup, pipx yt-dlp) and lays out its
  run dirs in `$HOME`, so it must ask for the username. A system-path layout
  (`/opt`) owned by the CO group, with system-wide rust/yt-dlp, would remove the
  parameter and match how no-prompt SRC items work. Multi-role change; only worth
  it if workspaces become genuinely multi-user.

- **`timeout=7200` is very conservative.** Observed total provision (SRC-OS →
  ready, incl. CUDA component + reboot + CUDA build + ~1 GB models) was ~11 min
  at Tier 5. Can dial the catalog-item `timeout` override down (e.g. 2400–3600)
  once a couple more provisions confirm the ceiling.

- **`scripts/tier2-docker.sh` "run 2 recap:" echo prints empty.** Cosmetic; the
  changed-count extraction still works. Fix when next touching the script.

- **RESOLVED 2026-07-06 — Yoda runtime confirmations (see `yoda-operations.md`).**
  Both remaining VERIFYs cleared by a live isolated-role run on the SRC
  workspace: (1) `IRODS_USER_PASSWORD` completes `gocmd init` non-interactively
  under Ansible — but **only with `-c`**; without it init interrogates stdin
  and submits an empty password (this was a real defect, fixed in the role).
  (2) Yoda accepts `--ttl 720`. The `creates:` sentinel is gone: the role now
  probes token validity by `gocmd ls` exit code and re-inits on a stale token,
  so an expired token refreshes on re-run.

- **Yoda push requires the collection base to pre-exist.** `gocmd sync SRC DEST`
  is dual-mode: if DEST exists it creates `DEST/basename(SRC)`; if DEST does
  *not* exist it creates DEST and syncs the contents in (DEST becomes SRC). The
  script relies on `yoda_collection` (the researcher's group root) existing — it
  always does in production. If a future flow targets a fresh sub-collection,
  `gocmd mkdir` it first.

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

- **RESOLVED 2026-07-13 — hidden files no longer uploaded; threads capped.**
  Shard-tar staging excludes hidden entries at tar time (the `.work/` leak),
  and the push-side sync calls in `yoda-sync.sh` default to `--thread_num 10`
  (override via `YODA_THREADS`; keep ≤15 — 30 saturated the server for all
  users, 2026-07-06).

- **RESOLVED 2026-07-28 — DAP lifecycle guidance belongs in the catalog-item
  docs.** Data-access passwords appear permanently invalidated after
  failed-attempt bursts (fresh ones work immediately; mechanism unconfirmed,
  asked of FSW). Moved to `catalog-item.md`'s pre-launch CO setup section:
  generate a fresh DAP right before provisioning; if provisioning fails auth,
  regenerate — don't retry the old one. See `yoda-operations.md` for the
  underlying evidence.

- **Mid-campaign PAM token renewal is manual** (`yoda-operations.md` §Mid-campaign
  token renewal); revisit only if renewals get missed in practice.

- **`research-drive` backend is a reserved stub.** The selector accepts it but
  `preflight` hard-fails with guidance (mount + use `src-volume`, or use `yoda`).
  Wiring it means a WebDAV mount (davfs/rclone) → the existing rsync path, and it
  carries the same no-checksum corruption caveat as Yoda-over-WebDAV at 1M files.

- **Tier-1 `ansible-lint` cannot run in the committed `.venv` under Python 3.14.**
  `ansible==9.1.0` (ansible-core 2.16.18, matched to SRC-External) is rejected by
  `ansible-compat` on Python 3.14 (needs core ≥ 2.20). `yamllint` and
  `ansible-playbook --syntax-check` still run. Rebuild the venv with Python
  ≤ 3.12 for the full Tier-1 lint, or run lint in the Tier-2 container.

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

- **Server-side extraction is policy-blocked on the campaign collection
  (2026-07-28).** `gocmd bun -x` returns iRODS `-1110000
  MSI_OPERATION_NOT_ALLOWED` on `/nluu10p/home/research-tiktok-crime-policing`
  — although extraction worked on fsw.data.uu.nl during the 2026-07-13/14
  live validation (different collection). Asked of FSW (pending thread): is
  the microservice policy per-group/category, and can it be enabled here?
  Until then the campaign runs with `YODA_EXTRACT=0` (archive-only sink,
  the designed fallback); pending-extraction tracking means one ordinary
  `push-to-yoda.sh` back-fills the browsable `transcripts/` tree once
  allowed. NOTE the inspector data-plane contract promises that extracted
  tree — if the ban stands, the inspector must pull + extract tars instead.

- **A Co-Secret in the parameter set censors the ENTIRE component log (S17).**
  SRC-External's "Run Ansible plugin" wrapper task `no_log`s its result when
  the command line carries a Co-Secret, so every fail_msg we write is
  invisible in the portal on yoda launches (observed 2026-07-28: a preflight
  assert failure surfaced only as "censored"). Nothing fixable client-side;
  debugging path is input-side elimination + local preflight replay
  (`scripts/test-preflight-autodetect.sh` pattern). Consider asking SURF
  whether per-task output can be preserved with secrets masked.

- **`yoda-sync.sh` masks local filesystem errors as "remote missing"
  (2026-07-29).** A `gocmd get` that failed because the LOCAL parent dir
  didn't exist printed "no state snapshot in collection — fresh batch". On a
  restore that mask could silently start a fresh batch despite a present
  snapshot. Fix: distinguish remote not-found from local errors; fail loudly
  on the latter. Verify at the same time whether the pull path overwrites an
  existing local snapshot or silently keeps the stale file (suspected on the
  2026-07-29 local mirror pull).

- **RESOLVED 2026-07-31 — continuous (uncapped) runs never triggered hop 1.**
  The batch-end auto-sync only fires when a `process` invocation exits; an
  uncapped campaign runner grinds for weeks, so the volume (and thus any
  hop-2 push and the Yoda snapshot) went stale unless hop 1 was run by hand
  (observed live 2026-07-29; escalated into the transcript-gap incident
  above). Now: `run-pipeline.sh.j2` passes
  `--checkpoint-cmd ~/sync-to-storage.sh --checkpoint-every 4h` to `process`
  (pipeline ≥ v0.3.2; playbook default is v0.4.0). The v0.3.0 campaign VM
  runs an operator-installed cron stopgap instead; hop 2 remains
  operator-driven — both documented in `yoda-operations.md`.

- **`yoda-sync.sh` could derive its paths from a single `YODA_LOCAL_ROOT`.**
  Operators mirroring a collection locally must export three env vars per
  invocation; the collection layout is a contract, so one root would do.
  Quality-of-life; came up during the 2026-07-29 researcher-mirror setup.

- **Ingest consumed 141 of 142 inbox entries (2026-07-28).** One inbox file
  was skipped without a named reason in the summary line. Identify the odd
  file out (likely a non-DDP artifact) and make ingest name skipped files.
  (If it IS a donor DDP that failed to parse, that's a pipeline-repo bug.)
