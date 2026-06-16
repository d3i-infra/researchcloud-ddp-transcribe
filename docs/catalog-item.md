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
be added to an item until it exists). The "Add component" wizard has 5 steps.

**Step 1 — script source:**

| Field | Value |
|---|---|
| Component script type | Ansible Playbook |
| Source Url repository | `https://github.com/d3i-infra/researchcloud-ddp-transcribe.git` |
| Path | `deploy-ddp-transcribe.yaml` |
| Tag | `main` — *version of the **component repo** SRC clones; distinct from the `pipeline_git_ref` parameter, which pins the **pipeline repo** the playbook builds* |
| Access format / label | leave blank (no web UI — SSH only) |
| Script availability | "publicly available on Git" if the component repo is public; else fixed / CO-secret credentials |

**Step 2 — name, subtitle, description** (developer-facing; the catalog item has
its own user-facing set in Step C):

- **Name:** `ddp-transcribe`
- **Subtitle:** Provisions a video-transcription pipeline workspace (CUDA, Rust, yt-dlp, whisper models)
- **Description:** Ansible playbook that bakes a `ddp-transcribe` workspace.
  **Base OS: Ubuntu 24.04** (the `libclang-18-dev` pin is 24.04-specific). Builds
  the pipeline from a pinned git ref with whisper-rs (`--features cuda` on GPU
  flavours), installs `yt-dlp[curl-cffi]` and the selected whisper models, lays
  out inbox/transcripts/archive on the attached volume and the state DB on the
  boot disk. CUDA toolkit 13.2 is detect-else-install; never installs drivers.
  Operator-driven, SSH only.
- **Icon:** `assets/icon.png` (d3i brand palette; <100KB, reads at 32–40px)

**Step 3 — parameters:** **DO NOT SKIP.** SRC does *not* auto-discover variables
from the playbook — you must declare each parameter here by hand, or it will not
appear at the catalog item's Parameters step (a param "not explicitly required by
a component has no effect"). Declare exactly these (defaults match the playbook's
`vars:`; the two without a default are required):

Each declaration has a **Source type** (`Fixed` / `Resource` / `Co-Secret` /
`Workspace`) and an **Overwritable** checkbox. For all ten of ours: Source type
= **`Fixed`** (a literal value you type) and **Overwritable = checked** — the
Overwritable flag is what lets the catalog item later "Make interactive" or
"Overwrite"; unchecked locks the value at the component default.

Each parameter also takes a short **Description** (shown to the workspace creator
for the interactive ones); suggested text in the last column.

| Parameter | Source type | Default value | Overwritable | Description |
|---|---|---|---|---|
| `storage_path` | Fixed | *(blank — required)* | ✓ | Mount point of the attached storage volume (e.g. `/home/<user>/data/<volume>`); holds inbox, transcripts, models, archive. |
| `pipeline_user` | Fixed | *(blank — required)* | ✓ | Workspace account that owns the source tree, run scripts, and state DB (your SRC username, e.g. `dmccool`). |
| `model_large_v3_turbo` | Fixed | `true` | ✓ | Download the large-v3-turbo whisper model (~573 MB; recommended production model). |
| `model_tiny_en` | Fixed | `false` | ✓ | Download the tiny.en whisper model (~75 MB; fast, English-only; for smoke tests). |
| `model_small` | Fixed | `false` | ✓ | Download the small whisper model (~466 MB; multilingual fallback). |
| `pipeline_git_ref` | Fixed | `v0.2.0-rc1` | ✓ | Git tag/ref of the ddp-transcribe pipeline to build. |
| `download_workers` | Fixed | `3` | ✓ | Parallel video-download workers baked into the run scripts. |
| `compute_lang_probs` | Fixed | `false` | ✓ | Add a per-language probability pass during transcription (~1.5–2× slower per video). |
| `run_smoke_test` | Fixed | `false` | ✓ | Run an init+ingest against a bundled fixture during provisioning (verification only). |
| `force_cpu_build` | Fixed | `false` | ✓ | Build without CUDA even on a GPU flavor (debug aid; also bypasses the GPU-without-driver hard-fail). |

`storage_path`/`pipeline_user` "required-ness" is enforced by making them
interactive at the catalog item **and** the playbook's preflight `assert`
backstop. The model flags' `true`/`false` values render as checkboxes once made
interactive (the playbook coerces with `| bool`). Other source types are unused:
`Co-Secret` (we have no secrets), `Resource`, and `Workspace` — note `Workspace`
exposes only `co_id` / `co_name` / `co_irods`, **no per-user name**, so it
*cannot* supply `pipeline_user` (a CO workspace has many users; the owning
account must be chosen explicitly). `pipeline_user` stays Fixed + interactive,
matching the d3i "Next" item's interactive-username pattern. Do *not* declare
`co_passwordless_sudo` / `timeout` /
`remote_ansible_version` here — those belong to SRC-CO and SRC-External plugin
and surface at the catalog item Parameters step on their own. Internals
(`pipeline_git_repo`, `cuda_*`) stay as playbook vars, undeclared. No Component
Secrets — the pipeline repo and all downloads (NVIDIA, HuggingFace, crates.io)
are public/anonymous.

> If you already created the component without parameters: **edit** it (don't
> recreate). Editing overwrites the development version; the catalog item, which
> references that development version, will then show the parameters.

**Step 4 — owner & support:** owner CO (see decisions above), support url/name/email.

**Step 5 — organizations:** **restrict to the owner CO** — component visibility
*cannot be withdrawn*, so do not make it public.

> **Two version pins, don't confuse them:** the Step 1 **Tag** pins the component
> repo (`main`); the `pipeline_git_ref` parameter pins the pipeline repo
> (`v0.2.0-rc1`). A provisioning-only fix changes the component (re-clone `main`,
> re-run); a pipeline release changes `pipeline_git_ref` (rebuild).

## Step B — Catalog item wizard, Step 1: Components (order matters)

```
1. SRC-OS
2. SRC-CO
3. SRC-External plugin  (the plain Ansible runner — NOT "Docker", "Docker
   Compose", or "pluginansible2.11"; keep its remote_ansible_version at 9.1.0)
4. CUDA                 ← SRC's own component (gitlab rsc-surf-nl/plugins/
                          plugin-cuda). Installs a modern NVIDIA driver + CUDA
                          (NVIDIA's *current* via the dynamic ubuntu2404 keyring
                          — 13.3 + driver 610 as provisioned), gated on
                          `'GPU' in flavour_name`. REQUIRED on GPU flavors: the
                          stock ubuntu-24.04-rsc image ships no driver and
                          SRC-OS/CO don't add one, so without this
                          ddp-transcribe's cuda role hard-fails (GPU on PCI bus,
                          nvidia-smi absent). Must come after SRC-External; it
                          reboots (handled via async + wait_for_connection).
5. ddp-transcribe        ← after CUDA; its cuda role then sees nvidia-smi work,
                          finds nvcc present, and skips its own toolkit install.
```

**No SRC-Nginx** — the pipeline has no web UI; access is SSH only.

> **CPU flavor:** the CUDA component self-gates on `'GPU' in flavour_name`, so it
> cleanly no-ops on the CPU flavor — a mixed CPU/1×A10/2×A10 item is fine on one
> component list. On CPU flavors ddp-transcribe's cuda role finds no GPU and
> builds CPU-only (no `force_cpu_build` needed).
>
> **CUDA version (NOT pinned on SRC):** the CUDA component does `apt install
> cuda` off the dynamic keyring, so it pulls NVIDIA's **current** release —
> **13.3 + driver 610** as provisioned (Tier 5), which built and linked cleanly.
> ddp-transcribe's detect-else-install finds nvcc present and skips its pinned
> 13.2, so the build links whatever SRC installed. **Risk:** the build CUDA
> floats with NVIDIA's latest; a future release could break the whisper.cpp
> build. If that bites, force our pinned toolkit (install even when nvcc is
> present) or pin via the CUDA component. Tracked in FOLLOWUPS.

## Step C — Name & description

User-facing (the Catalog tab); keep distinct from the component's Step 2 set.

- **Name:** DDP Transcribe
- **Subtitle:** Video transcription pipeline for data-donation studies
- **Description:** A ready-to-run workspace that transcribes donor-watched
  videos from TikTok DDP exports. Whisper.cpp transcription (GPU-accelerated on
  NVIDIA flavours); select your models at launch and point it at an attached
  storage volume. SSH in and drive it with the generated run scripts
  (`init` / `ingest` / `process`).
- **Icon:** `assets/icon.png` (same as the component)

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
- **Boot disk: ~50 GB — do NOT leave it at the 15 GB default.** The provision
  peak (CUDA toolkit ~5 GB + packages + Rust + the cargo `target/` during the
  CUDA build) hits ~20–25 GB before `cargo clean`; 15 GB risks an `ENOSPC` build
  failure. Models/transcripts live on the storage volume, so steady state is
  ~12–15 GB. Go 80–100 GB only if the pipeline retains audio on the boot disk
  rather than `~/scratch`. This supersedes the `CARGO_TARGET_DIR=~/scratch`
  fallback (R2) — a bigger disk removes the cliff with no moving parts.

## Step G — Parameters (Step 6)

Wiring per the component README. Action column: Keep / Overwrite /
Make-interactive. **Only Make-interactive prompts the workspace creator** — both
Keep (component default) and Overwrite (catalog-item value) are fixed at provision
and invisible to the user. Make-interactive requires the parameter to be
Overwritable at the component (all ten are). Litmus test: make it interactive
only if the value depends on facts known at launch in that specific workspace.

**Make-interactive demands a Label and a Default** (SRC requires a default even
for interactive fields). For `storage_path` and `pipeline_user` there is no
correct fixed default, so use a **placeholder template** the creator overwrites
— it documents the format and, being non-existent, makes preflight fail loudly
if left unedited (better than a wrong-but-valid path):

- `storage_path` — Label `Storage volume mount path`; Default
  `/home/<username>/data/<volume-name>`; Description: mount point of the volume
  attached to this workspace (SRC mounts it at `/home/<user>/data/<volume-name>`).
- `pipeline_user` — Label `Workspace user`; Default `<your-src-username>`.
- the three `model_*` flags use genuine `true`/`false` defaults (pre-set the checkboxes).

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
| `timeout` | SRC-External plugin | **Overwrite** | `7200` — see note below |
| `remote_ansible_version` | SRC-External plugin | Keep | `9.1.0` (the verified version) |

**All other upstream parameters: Keep value** — the defaults are correct for us.
SRC-OS (`add_ips_to_hosts` false, `os_disk_format` true, `volume_mount_no_name`
false — the last is why the external volume mounts at `…/data/<volume-name>`);
SRC-CO (`co_admin_user_only`/`co_owner_user_only` false, `co_roles_enabled` true,
`co_totp` true); SRC-External plugin (`disable_log` false — keep the provisioning
log). Only the two **Overwrite** rows above and the `co_passwordless_sudo` flip
differ from upstream defaults. `co_research_drive` (true) installs WebDAV mount
scripts — harmless; our storage is a block volume, so set false only if you want
a leaner box and will never use Research Drive.

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

0. **Create the storage volume first** (it is a separate object, *not* part of
   this catalog item): SRC portal → CREATE NEW → storage card → SURF HPC Cloud
   volume → same CO as the workspace → size generously (models + 65k transcripts;
   more if audio is retained) → name it (e.g. `ddp-transcribe-<study>`).
1. Launch a workspace on **1×A10**. The **second-to-last wizard step is "Attach
   the storage volume"** — attach the volume from step 0; SRC-OS mounts it at
   `~/data/<volume-name>`. Supply the interactive params: `storage_path` =
   `/home/<pipeline_user>/data/<volume-name>`, `pipeline_user` = your SRC
   username; check the model boxes you want.
2. Watch the deployment log to green — **no manual SSH fixes allowed** (that's
   the whole point of the catalog item).
3. SSH in and verify the ADR 0032 layout: `ddp-transcribe --help`; `ldd $(which
   ddp-transcribe) | grep libcudart`; `ls ~/ddp-work/models/` (models on the boot
   disk); `ls ~/run-pipeline-gpu0.sh ~/sync-to-storage.sh ~/restore-from-storage.sh
   ~/ddp-state/`.
4. Operator smoke: drop a fixture DDP JSON into `<storage>/inbox`,
   `~/run-pipeline-gpu0.sh init`, `… ingest`, `… process --max-videos 3`,
   inspect a transcript artifact (under `~/ddp-work/transcripts/<NN>/`) with `jq`,
   then confirm the auto-sync landed it on the volume (`ls <storage>/transcripts/<NN>/`
   and `<storage>/state-snapshot.sqlite`).
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
