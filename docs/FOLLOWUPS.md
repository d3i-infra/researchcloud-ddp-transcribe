# researchcloud-ddp-transcribe — follow-ups

Deployment-side open items. (Pipeline-code follow-ups live in the ddp-transcribe
repo's `docs/FOLLOWUPS.md`.)

## Open

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
  for GPU flavors.

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

- **DAP lifecycle guidance belongs in the catalog-item docs.** Data-access
  passwords appear permanently invalidated after failed-attempt bursts (fresh
  ones work immediately; mechanism unconfirmed, asked of FSW). Researcher
  instruction: generate a fresh DAP right before provisioning; if provisioning
  fails auth, regenerate — don't retry the old one. See `yoda-operations.md`.

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
