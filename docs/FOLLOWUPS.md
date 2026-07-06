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

- **Yoda backend: two small runtime confirmations remain (most VERIFYs cleared).**
  A live round-trip against UU Yoda (`fsw.data.uu.nl`, gocmd v0.12.2) confirmed:
  the asset `gocmd-<ver>-linux-amd64.tar.gz` extracts a top-level `gocmd`; auth
  works over `pam_password` with a data-access password; `gocmd ls`/`sync`/`put`
  behave as the role/script assume; and the full `push`→`pull` round-trip is
  byte-identical. Still to confirm at Tier 3 (needs the Co-Secret path, not just
  a dev box): (1) the **env-var** auth (`IRODS_USER_PASSWORD`) completes
  `gocmd init` **non-interactively** under Ansible (verified via the binary's
  embedded `envconfig` tag + `--help`, not yet run headless), and (2) Yoda
  accepts the requested `--ttl` (see next item).

- **Yoda PAM token TTL — now a lever, verify the server cap.** `gocmd init --ttl
  <hours>` sets the token lifetime; the role passes `yoda_auth_ttl_hours` (default
  720). Confirm at Tier 3 that Yoda's server does not cap it lower (if it errors,
  lower the value). The `creates: ~/.irods/.irodsA` sentinel means an expired
  token won't refresh on a plain re-run — operator re-runs `gocmd init` if a batch
  outlives the token.

- **Yoda push requires the collection base to pre-exist.** `gocmd sync SRC DEST`
  is dual-mode: if DEST exists it creates `DEST/basename(SRC)`; if DEST does
  *not* exist it creates DEST and syncs the contents in (DEST becomes SRC). The
  script relies on `yoda_collection` (the researcher's group root) existing — it
  always does in production. If a future flow targets a fresh sub-collection,
  `gocmd mkdir` it first.

- **1M-file scale: use gocmd's native bundling, not hand-rolled tar.** `gocmd
  sync` has built-in `--bulk_upload` (`--max_bundle_size` / `--max_file_num`);
  `yoda-sync.sh` exposes it via `YODA_BULK=1`. For the 1M-transcript / ~100-shard
  campaign, enable it and tune the bundle knobs once real throughput is measured
  (pilot-scale delivery is fine without it).

- **`research-drive` backend is a reserved stub.** The selector accepts it but
  `preflight` hard-fails with guidance (mount + use `src-volume`, or use `yoda`).
  Wiring it means a WebDAV mount (davfs/rclone) → the existing rsync path, and it
  carries the same no-checksum corruption caveat as Yoda-over-WebDAV at 1M files.

- **Tier-1 `ansible-lint` cannot run in the committed `.venv` under Python 3.14.**
  `ansible==9.1.0` (ansible-core 2.16.18, matched to SRC-External) is rejected by
  `ansible-compat` on Python 3.14 (needs core ≥ 2.20). `yamllint` and
  `ansible-playbook --syntax-check` still run. Rebuild the venv with Python
  ≤ 3.12 for the full Tier-1 lint, or run lint in the Tier-2 container.
