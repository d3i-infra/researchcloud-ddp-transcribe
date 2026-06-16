# researchcloud-ddp-transcribe

SURF Research Cloud (SRC) component that provisions a
[ddp-transcribe](https://github.com/daniellemccool/ddp-transcribe) workspace:
a video-transcription pipeline for data-donation studies (TikTok is the
currently supported source). The component is consumed by the
**DDP Transcribe** catalog item (see `docs/catalog-item.md`) and run by
SRC-External on the workspace itself.

## What it provisions

- System packages (cmake, clang + `libclang-18-dev`, ffmpeg, sqlite3, jq, …)
- CUDA toolkit — detect-else-install (pinned **13.2** fallback); never kernel
  drivers. The driver + CUDA **12.6** come from SRC's own **CUDA** component
  (`plugin-cuda`), which must precede ddp-transcribe in the catalog item
  (`SRC-OS → SRC-CO → SRC-External → CUDA → ddp-transcribe`): the stock
  `ubuntu-24.04-rsc` image ships no driver, so without it the cuda role
  hard-fails. When CUDA has run, nvcc is present and this step skips — the
  build links against SRC's 12.6 (the version proven on the A10 in Tier 3)
- Rust stable (rustup, per-user) and `yt-dlp` (`pipx install
  'yt-dlp[default,curl-cffi]'` — never `pipx inject`)
- The `ddp-transcribe` release binary, built from a pinned git ref with
  `--features cuda` when a GPU is present, installed to `/usr/local/bin`
  (build tree removed afterwards — the boot disk is 15 GB)
- The whisper models selected at workspace creation, downloaded to the boot
  disk (`~/ddp-work/models/`) — see the storage layout below
- Storage layout (per [ADR 0032](https://github.com/daniellemccool/ddp-transcribe/blob/main/docs/decisions/0032-transcription-hot-path-on-boot-disk-storage-volume-is-seed-at-provision-and-sink-at-downtime.md)): the transcription hot path runs off the
  **boot disk** — whisper model (`~/ddp-work/models`), live transcripts
  (`~/ddp-work/transcripts`, the sharded `NN/` tree), and `~/ddp-state/state.sqlite`
  (SQLite WAL needs POSIX fsync — never the NFS-like mount). The **storage
  volume** is seed + sink: `<storage_path>/{inbox,transcripts,archive}` plus a
  `state-snapshot.sqlite`. One generated `~/run-pipeline-gpuN.sh` per GPU
  (`CUDA_VISIBLE_DEVICES`-pinned) or a single `~/run-pipeline.sh` on CPU flavors,
  plus `~/sync-to-storage.sh` and `~/restore-from-storage.sh`

Runs are **operator-driven** — there is no systemd unit. SSH in and use the
run scripts (`init`, `ingest`, `process [--max-videos N]`; exit 3 from
`process` means "zero videos claimed", not an error). After each `process`
run the script **auto-syncs** the boot-disk transcripts and a state snapshot
to the volume; chunk long runs with `--max-videos` to bound the unsynced
window. A rebuilt workspace resumes a batch via `~/restore-from-storage.sh`.

## Parameters

| Parameter | Default | Catalog action | Meaning |
|---|---|---|---|
| `storage_path` | *(required)* | interactive | Mount point of the attached storage volume, e.g. `/home/<user>/data/<volume>` |
| `pipeline_user` | *(required)* | interactive | Workspace user that owns run scripts, source tree, and state dir |
| `pipeline_git_ref` | `v0.2.0-rc1` | keep (overwrite to upgrade) | Pinned tag/ref of ddp-transcribe to build |
| `model_large_v3_turbo` | `true` | interactive | Download `ggml-large-v3-turbo-q5_0.bin` (~573 MB; production model) |
| `model_tiny_en` | `false` | interactive | Download `ggml-tiny.en.bin` (~75 MB; smoke/dev) |
| `model_small` | `false` | interactive | Download `ggml-small.bin` (~466 MB; multilingual fallback) |
| `download_workers` | `3` | keep | Parallel fetch workers baked into run scripts |
| `compute_lang_probs` | `false` | keep | Per-language probability pass (~1.5–2× slower per video) |
| `run_smoke_test` | `false` | keep | Provision-time init+ingest against a bundled fixture |
| `force_cpu_build` | `false` | keep | Build without the `cuda` feature even on a GPU flavor; also bypasses the GPU-without-driver hard-fail (debug aid, and used by the Tier 2 container test where the host GPU leaks into `lspci`) |

Booleans may arrive from SRC as strings; the playbook coerces with `| bool`.

## Developing / verifying without SRC

```sh
# Tier 1 — static (pin Ansible to SRC-External's version):
python -m venv .venv && .venv/bin/pip install 'ansible==9.1.0' ansible-lint yamllint
.venv/bin/yamllint .
.venv/bin/ansible-lint
.venv/bin/ansible-playbook --syntax-check deploy-ddp-transcribe.yaml

# Tier 2 — CPU-path double-run in a container (second run asserted changed=0):
scripts/tier2-docker.sh              # build the playbook-default ref
scripts/tier2-docker.sh feat/foo 6   # build a branch, allow 6 CPUs
```

The `cuda` role is only truly testable on an SRC GPU workspace (see the
deployment plan's Tier 3/4).

## Conventions

- Entry playbook at repo root; SRC-External is configured with
  `deploy-ddp-transcribe.yaml`.
- `ansible.builtin` modules only — SRC-External runs stock Ansible 9.1.0.
- Every role is idempotent; a re-run on a provisioned workspace must report
  zero changes.
- CUDA toolkit version is pinned (`cuda_toolkit_package`); bump it only
  together with a verified whisper-rs/driver combination (see
  ddp-transcribe `docs/SRC-BAKE-NOTES.md` for the evidence trail).
