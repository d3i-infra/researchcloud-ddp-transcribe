# DDP Transcribe — catalog item record & registration runbook

This doc is two things: the **registration runbook** (concrete values for the
portal wizard — Phase 4 of the deployment plan) and the **item record** (filled
in once the item is live). General portal mechanics live in the SURF-distilled
`surf_research_cloud/runbooks/create-catalog-item.md`; this page only carries
the ddp-transcribe-specific values and the decisions you must make at the portal.

## Decisions to make before you start the wizard

These are portal facts I can't see; settle them first.

- [ ] **Owner CO** — *permanent, cannot be changed later.* The existing
  "Next for data donation" item is owned by **D3I data donation**; using the same
  CO is the obvious default unless you want this item maintained separately.
- [ ] **Exact flavour names** — confirm the SURF HPC Cloud GPU flavour names and,
  critically, that a **2×A10** flavour exists (the two-instance design needs two
  physical GPUs in one workspace). If SURF only offers 1×A10, the 2-GPU path is
  blocked and we ship CPU + 1×A10 only.
- [ ] **Developer rights** in the owner CO (`src_co_developer` SRAM group) — without
  these the **Development** tab won't appear.

## Step A — Register the component (Development → Components → +)

The component is created **before** the catalog item (a non-SURF component can't
be added to an item until it exists).

| Field | Value |
|---|---|
| Type | Ansible (run by SRC-External) |
| Git repo | `https://github.com/d3i-infra/researchcloud-ddp-transcribe` |
| Playbook / entry | `deploy-ddp-transcribe.yaml` (repo root) |
| Version created | development (promote later — see end) |
| Visibility | **restrict to the owner CO** — component visibility *cannot be withdrawn*, so do not make it public |

The component declares the parameters in Step F's table. No Component Secrets:
the pipeline repo and all downloads (NVIDIA repo, HuggingFace, crates.io) are
public/anonymous.

## Step B — Catalog item wizard, Step 1: Components (order matters)

```
1. SRC-OS
2. SRC-CO
3. SRC-External
4. ddp-transcribe        ← must come after SRC-External
```

**No SRC-Nginx** — the pipeline has no web UI; access is SSH only.

## Step C — Name & description

- **Name:** DDP Transcribe
- **Subtitle:** _(short — e.g. "Video transcription pipeline for data-donation studies")_
- **Description:** _(what it provisions; point at the component README)_

## Step D — Owner & support

- **Owner CO:** _(your decision above — PERMANENT)_
- **Documentation URL:** `https://github.com/d3i-infra/researchcloud-ddp-transcribe`
- **Support name / email:** _(maintainer)_

## Step E — Access

- **Allowed collaborations:** explicit whitelist (the owner CO; add others only
  as needed). Do **not** use "on request" unless you want catalog-wide visibility.

## Step F — Cloud settings

- **Provider:** SURF HPC Cloud
- **OS:** Ubuntu **24.04** (the `libclang-18-dev` pin is 24.04-specific — do not
  offer 22.04)
- **Flavours** (offer the subset you want selectable):
  - one CPU flavour with high core count (faster cargo build) — e.g. 16 Core - 64 GB
  - **1×A10** GPU flavour
  - **2×A10** GPU flavour (if available — see decisions above)

## Step G — Parameters (Step 6)

Wiring per the component README. Action column: Keep / Overwrite / Make-interactive.

| Parameter | Source | Action | Value |
|---|---|---|---|
| `storage_path` | ddp-transcribe | **Make interactive** | creator supplies the mounted volume path, e.g. `/home/<user>/data/<volume>` |
| `pipeline_user` | ddp-transcribe | **Make interactive** | the workspace user (their SRC username) |
| `model_large_v3_turbo` | ddp-transcribe | **Make interactive** | checkbox; default true |
| `model_tiny_en` | ddp-transcribe | **Make interactive** | checkbox; default false |
| `model_small` | ddp-transcribe | **Make interactive** | checkbox; default false |
| `pipeline_git_ref` | ddp-transcribe | Keep | `v0.2.0-rc1` until promoted to `v0.2.0` |
| `download_workers` | ddp-transcribe | Keep | `3` |
| `compute_lang_probs` | ddp-transcribe | Keep | `false` |
| `run_smoke_test` | ddp-transcribe | Keep | `false` (operator smokes by hand post-provision) |
| `force_cpu_build` | ddp-transcribe | Keep | `false` |
| `co_passwordless_sudo` | SRC-CO | **Overwrite** | `true` |
| `timeout` | SRC-External | **Overwrite** | `7200` — see note below |
| `remote_ansible_version` | SRC-External | Keep | `9.1.0` |

> **timeout:** the default 3600 s may be too tight for a *cold* provision — the
> `cargo build --release --features cuda` of whisper-rs compiles CUDA kernels via
> nvcc (the long pole), on top of the ~5 GB toolkit install and the ~573 MB model
> download. Set 7200 for the first validation and tune down once the cold
> wallclock is measured (record it below).

## Step H — Workspace settings

- **Access button:** Command line (SSH)
- **Firewall:** inbound TCP **22** only; all outbound open (GitHub, NVIDIA repo,
  HuggingFace, crates.io, TikTok CDNs). Leave "allow owner to change security
  groups" unchecked to lock the firewall.

| From | To | IP | Direction | Protocol | Mutable |
|---|---|---|---|---|---|
| 22 | 22 | 0.0.0.0/0 | in | tcp | No |

## Tier 5 — validation pass (after Submit)

1. Launch a workspace on **1×A10** with an attached storage volume; supply
   `storage_path` + `pipeline_user`; check the model boxes you want.
2. Watch the deployment log to green — **no manual SSH fixes allowed** (that's
   the whole point of the catalog item).
3. SSH in and verify: `ddp-transcribe --help`; `ldd $(which ddp-transcribe) | grep
   libcudart`; `ls <storage>/models/`; `ls ~/run-pipeline-gpu0.sh ~/ddp-state/`.
4. Operator smoke: drop a fixture DDP JSON into `<storage>/inbox`,
   `~/run-pipeline-gpu0.sh init`, `… ingest`, `… process --max-videos 3`,
   inspect a transcript artifact with `jq`.
5. Relaunch on **2×A10**: confirm both `~/run-pipeline-gpu0.sh` and
   `-gpu1.sh` exist; run both concurrently; `nvidia-smi` shows load on both GPUs.
   **First real test of two-process claim contention (R11)** — watch for stale
   `processing` rows / double-claims in the shared state DB.
6. Pause/resume the workspace; confirm the run layout survives.
7. Promote component **development → pilot → live**; once live, tag the pipeline
   repo **`v0.2.0`** and bump `pipeline_git_ref` to it (overwrite stays in the item).

---

## Item record (fill in once live)

- **Catalog item name:** DDP Transcribe
- **Owner CO:** _(TBD — PERMANENT)_
- **Component:** ddp-transcribe (`d3i-infra/researchcloud-ddp-transcribe`,
  `deploy-ddp-transcribe.yaml`), visibility restricted to owner CO
- **Allowed COs:** _(TBD)_
- **Flavours offered:** _(record exact names)_

### Validation log

_(workspace names, flavour, cold provision wallclock, boot-disk high-water
`df -h`, smoke results, 2-GPU concurrent run outcome, R11 observations)_
