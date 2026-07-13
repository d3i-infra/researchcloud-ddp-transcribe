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

- **1M-file scale: bulk_upload is DEAD on Yoda — a delivery redesign is needed.**
  Disproven 2026-07-06: `--bulk_upload` (exposed as `YODA_BULK=1`) fails on
  Yoda — its `.gocmd_staging` collection is rejected by gocommands' staging
  safety check on research group collections, and `nluu10p` users have no
  personal home collection to redirect `--irods_temp` to. Remove or rewrite
  the `YODA_BULK` option. Measured file-per-file throughput is ~1.5 files/s at
  15 threads (server per-op latency ~3 s; collection create ~3 s), so the
  campaign (~2M files) is infeasible as a plain sync (~weeks). Options:
  (a) tar-mode in `yoda-sync.sh` (per-shard/per-batch archives; changes restore
  semantics); (b) FSW admin-side bulk ingest (server-side extraction of an
  uploaded archive) — question pending with FSW tech support. Pilot scale
  (≤~10k files) is tolerable as-is. See `yoda-operations.md`.

- **`yoda-sync.sh` uploads hidden files/dirs.** `gocmd sync` copies dotfiles;
  a `.work/` scratch tree inside `transcripts/` (ytdlp temp dirs, can hold
  large media) went to Yoda in live testing before being caught. Exclude
  hidden entries (check the installed gocmd for `--exclude_hidden_files`; else
  stage via glob). Same pass: default `--thread_num` to ~10 — 30 threads
  saturated the server and made the portal unusable for all users (2026-07-06).

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
