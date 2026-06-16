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
