# DDP Transcribe — catalog item record

> Skeleton: fill in during portal registration (Phase 4 of the deployment
> plan). Modeled on the d3i "Next for data donation" item record.

## Identity

- **Catalog item name:** DDP Transcribe
- **Subtitle:** _(TBD)_
- **Owner CO:** _(TBD — PERMANENT, choose deliberately)_
- **Component:** ddp-transcribe (this repo, `deploy-ddp-transcribe.yaml`)
- **Component visibility:** restricted to owner CO
- **Documentation URL:** this repo's README
- **Support contact:** _(TBD)_

## Component sequence

1. SRC-OS
2. SRC-CO (overwrite: `co_passwordless_sudo: true`)
3. SRC-External
4. ddp-transcribe

No SRC-Nginx: the pipeline has no web UI; access is SSH only.

## Cloud settings

- **Provider:** SURF HPC Cloud
- **OS:** Ubuntu 24.04 (the `libclang-18-dev` pin is 24.04-specific)
- **Flavors:** _(record exact names at registration)_ — one large CPU
  flavor, 1×A10 GPU, 2×A10 GPU

## Workspace settings

- Access button: Command line (SSH)
- Firewall: inbound TCP 22 only; all outbound open (GitHub, NVIDIA repo,
  HuggingFace, crates.io, TikTok CDNs)

## Parameter wiring

_(Record the Keep / Overwrite / Make-interactive choice per parameter at
registration; intended wiring is the table in the README.)_

## Validation log

_(Record the Tier 5 validation pass here: workspace names, flavor, wallclock
to provision, boot-disk high-water mark, smoke-test results, 2-GPU
concurrent run outcome.)_
