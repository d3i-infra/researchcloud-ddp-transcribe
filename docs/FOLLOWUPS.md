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

- **Yoda backend: verify gocmd version, asset name, and non-interactive auth on
  a real workspace.** The `yoda` role pins `gocmd_version` and assumes the
  release asset `gocmd-<ver>-linux-amd64.tar.gz` extracts `gocmd` at top level,
  and that `gocmd init` reads the data-access password from stdin. All three are
  marked `VERIFY` in `roles/yoda/tasks/main.yaml` — none could be exercised here
  (no gocmd binary / iRODS reachability in the dev env). Confirm at Tier 3/4 on
  an SRC workspace with a real data-access password; adjust the `-p`/env-var
  auth form or `--strip-components` if needed.

- **Yoda data-access-password (PAM) token TTL vs. multi-day batches.** The `yoda`
  role caches auth once (`creates: ~/.irods/.irodsA`) so re-provisioning is
  idempotent — but a Yoda data-access password / PAM token expires. A batch that
  outlives the token will fail its next `sync-to-storage.sh`. Confirm the TTL and,
  if short relative to batch length, add a re-auth step (or `gocmd` auto-refresh)
  to the run scripts. Until then: operator re-runs `gocmd init` when a push fails.

- **Per-shard bundling for the 1M-file campaign.** `yoda-sync.sh` uses `gocmd
  sync` (checksummed, symmetric) which is right for pilot-scale delivery. At ~1M
  transcripts / ~100 shards (~10k files/shard) the per-file listing/transfer cost
  grows and iRODS collection cardinality gets large. Add a per-shard `tar` bundle
  path (bundle on push, untar on pull) gated behind an env flag once real
  throughput is measured; decide bundle-vs-`gocmd sync --diff` by measurement.

- **`research-drive` backend is a reserved stub.** The selector accepts it but
  `preflight` hard-fails with guidance (mount + use `src-volume`, or use `yoda`).
  Wiring it means a WebDAV mount (davfs/rclone) → the existing rsync path, and it
  carries the same no-checksum corruption caveat as Yoda-over-WebDAV at 1M files.

- **Tier-1 `ansible-lint` cannot run in the committed `.venv` under Python 3.14.**
  `ansible==9.1.0` (ansible-core 2.16.18, matched to SRC-External) is rejected by
  `ansible-compat` on Python 3.14 (needs core ≥ 2.20). `yamllint` and
  `ansible-playbook --syntax-check` still run. Rebuild the venv with Python
  ≤ 3.12 for the full Tier-1 lint, or run lint in the Tier-2 container.
