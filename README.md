# ds4.nix — DwarfStar (ds4) DeepSeek-V4 inference engine for Nix

A Nix flake that packages [antirez's DwarfStar (ds4)][ds4]
(native DeepSeek-V4 inference engine) as a NixOS module with ROCm support.

This flake is extracted from a working installation on a Framework Desktop
(128GB) and serves to share this solution which should be highly reproducible
on any Framework Desktop, or other Ryzen AI Max+ 395 ("Strix Halo") based
system with sufficient RAM.

## What is DwarfStar (ds4)?

[ds4] is a C/CUDA/ROCm inference engine for DeepSeek-V4, written by Salvatore
Sanfilippo (antirez). It loads large GGUF models (~80 GiB for the full IQ2XXS
quant) into system RAM and uses AMD ROCm/HIP to offload compute to the GPU.

On Strix Halo (Radeon 8060S) it runs entirely via the GTT aperture, no dedicated
VRAM needed. You'll want to configure your BIOS to allocate the minimum VRAM
allowed (0.5GB on Framework Desktop).

## Hardware requirements

- **AMD GPU with ROCm support** (Strix Halo / gfx1151 tested, others may work)
- **Lots of RAM**: the recommended IQ2XXS quant needs ~80 GiB; the full model
  needs ~256 GiB
- **BIOS configuration**: Set UMA Frame Buffer Size to **512 MB** (not "Auto",
  which carves out ~32 GiB as dedicated VRAM and starves the model). This
  is based on Framework Desktop testing, but may be applicable to other Strix
  Halo platforms.

## Why a flake and not nixpkgs?

This is a cutting-edge, rapidly evolving project pinned to a specific commit
(80ebbc3). It depends on ROCm packages from `nixpkgs-master` which are
themselves in flux. A flake gives us the flexibility to track upstream changes
and iterate quickly without polluting the stable nixpkgs tree.

## NixOS Integration

### 1. Add to your flake inputs

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ds4.url = "github:carlzulauf/ds4.nix";
  };
  # ...
}
```

### 2. Import the module

```nix
nixosConfigurations.myhostname = nixpkgs.lib.nixosSystem {
  modules = [
    inputs.ds4.nixosModules.default
    ./configuration.nix
  ];
};
```

### 3. Enable the service

```nix
services.ds4 = {
  enable = true;
  user = "myuser";
};
```

### 4. Build and deploy

```bash
# Build the package alone
nix build .#ds4

# Rebuild your system
sudo nixos-rebuild switch --flake .#
```

### Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `enable` | `false` | Enable DwarfStar inference engine |
| `package` | auto-built | Which ds4 package to use |
| `rocmPackages` | `null` | ROCm package set (`null` = use system `pkgs.rocmPackages`) |
| `rocmGpuTarget` | `gfx1151` | ROCm GPU target architecture |
| `user` | `"carl"` | User added to `render`/`video` groups for ROCm access |
| `openFirewallPort` | `8000` | TCP port for ds4-server API (`0` = no firewall rule) |
| `kernelTuning` | *(see below)* | Kernel parameters to widen GTT aperture |
| `swapSizeMB` | `32768` | Swap file size as OOM cushion (`0` = disabled) |

#### Default kernel parameters

These are critical on Strix Halo where the default UMA carve-out steals ~32 GiB
as dedicated VRAM that ds4 never uses, starving the ~80 GiB GGUF model loaded
via GTT:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `amd_iommu` | `off` | Disable IOMMU for ROCm stability |
| `amdgpu.gttsize` | `126976` | GTT aperture (124 GiB, deprecated but harmless) |
| `ttm.pages_limit` | `32505856` | Real GTT limit (124 GiB in 4 KiB pages) |
| `ttm.page_pool_size` | `32505856` | Page pool for GTT allocations |

Set any parameter to `null` to omit it.

## Building manually (without the NixOS module)

```bash
nix build github:carlzulauf/ds4.nix
# Result: /nix/store/...-ds4-0-unstable-2026-06-17/bin/ds4*
```

Or for a different GPU target:

```nix
# In your flake, override the package:
ds4 = inputs.ds4.packages.x86_64-linux.ds4.override {
  rocmTarget = "gfx1100";  # e.g. RX 7900 XTX
};
```

## Model setup

DwarfStar looks for model files relative to the `ds4` binary, but that's in the
nix store so it's not a good place to put a model.

Instead, download the correct model to a reasoanble location and specify the
model path when starting `ds4`/`ds4-server`/etc.

```bash
DS4_GGUF_DIR=~/.local/ds4/gguf ds4-download-model ds4f-q2
ds4-server -m ~/.local/ds4/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf \
  --ctx 262144 --kv-disk-dir ~/.local/ds4/server-kv --kv-disk-space-mb 8192 --host 0.0.0.0
```

**Recommended model for Strix Halo (128GB RAM):**

```
DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf
```

Model filenames are checkpoint-specific (upstream tags them by release, e.g.
`-0731`); always use the exact filename `ds4-download-model` fetches rather
than a hardcoded one, since older checkpoint files should not be mixed with a
newer ds4 build. Run `ds4-download-model` with no arguments to see all
available targets (`ds4f-q2`, `ds4f-q2-q4`, `ds4f-q4`, `ds4f-mxfp4`, etc).

## Running ds4

```bash
# Run inference
ds4 -m /path/to/model.gguf

# Start the API server (listens on port 8000)
ds4-server -m /path/to/model.gguf
```

Actual realistic command to run the API server, serving on all network
interfaces with 256k context. Confirmed to work well on Framework Desktop.

```bash
ds4-server -m ~/.local/ds4/gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf --ctx 262144 --kv-disk-dir ~/.local/ds4/server-kv --kv-disk-space-mb 8192 --host 0.0.0.0
```

## How it works (the Nix side)

- `mkDs4` builds ds4 from source using `hipcc` (ROCm's compiler wrapper) with
  the correct `-I`/`-L`/`-rpath` flags for each ROCm dependency
- The derivation limits ROCm builds to a single GPU target (`localGpuTargets`),
  avoiding OOM errors from building all architectures
- The NixOS module wires up:
  - Kernel parameters for the GTT aperture
  - Swap file as OOM cushion
  - `memlock` unlimited for mlock-based expert caching
  - `vm.overcommit_memory=1` for large KV-cache allocations
  - Render/video group membership for ROCm device access
  - Firewall port for ds4-server API

[ds4]: https://github.com/antirez/ds4
