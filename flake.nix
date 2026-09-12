{
  description = "DwarfStar (ds4) — native DeepSeek-V4 inference engine, packaged for Nix with ROCm support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Default ROCm target (Strix Halo / Radeon 8060S). Override via
      # `withRocmTarget` or the NixOS module option `rocmGpuTarget`.
      defaultRocmTarget = "gfx1151";

      # ---------------------------------------------------------------------------
      # ds4 derivation
      # ---------------------------------------------------------------------------
      mkDs4 = { pkgs, rocmPackages ? pkgs.rocmPackages, rocmTarget ? defaultRocmTarget }:
        let
          # Override ROCm packages to limit GPU targets, avoiding OOM builds
          # when building for all architectures simultaneously.
          rocmPkgs = rocmPackages.overrideScope (_: rprev: {
            clr = rprev.clr.override { localGpuTargets = [ rocmTarget ]; };
          });

          # ROCm/HIP components ds4's target compiles and links against.
          # hipcc is NOT cc-wrapped, so it ignores NIX_CFLAGS_COMPILE/NIX_LDFLAGS;
          # we hand it -I/-L/-rpath for each store path explicitly (see buildPhase).
          # Header set taken from ds4_rocm.cu / rocm/*.cuh:
          #   hip/* -> clr, hipblas, hipblaslt (+hipblas-common, rocblas),
          #   hipcub (+rocprim), rocwmma.
          rocmDeps = with rocmPkgs; [
            clr
            hipblas hipblaslt hipblas-common rocblas
            hipcub rocprim
            rocwmma
            rocm-core
          ];

          # The only thing this flake genuinely has to add to upstream's flags:
          # the split-store include/lib locations. Everything else comes from
          # the Makefile itself at build time.
          rocmIncludeFlags =
            builtins.concatStringsSep " " (map (p: "-I${p}/include") rocmDeps);
          rocmLibFlags =
            builtins.concatStringsSep " " (map (p: "-L${p}/lib -Wl,-rpath,${p}/lib") rocmDeps);
        in
        pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "ds4";
          version = "0-unstable-2026-09-12";

          src = pkgs.fetchFromGitHub {
            owner = "antirez";
            repo = "ds4";
            rev = "bd66c402070042bf0a79ad6ece8242de4c93680c";
            hash = "sha256-F/MKv3/0Oj8DLa+q6jMtv0wFDgUvii+Xo2f1dPBDg6A=";
          };

          # hipcc is the compiler/linker for the ROCm object + the final link.
          nativeBuildInputs = [ rocmPkgs.hipcc ];
          buildInputs = rocmDeps;

          # The Makefile assigns ROCM_ARCH/ROCM_CFLAGS/ROCM_LDLIBS with `?=`, so an
          # exported value replaces upstream's wholesale. ROCM_ARCH is ours to set;
          # the flag lists are not -- buildPhase reads those back from the Makefile
          # rather than restating them here. See the note there.
          ROCM_ARCH = rocmTarget;

          enableParallelBuilding = true;

          buildPhase = ''
            runHook preBuild
            export HIPCC="${rocmPkgs.hipcc}/bin/hipcc"
            export ROCM_PATH="${rocmPkgs.clr}"
            export HIP_PATH="${rocmPkgs.clr}"
            export HIP_DEVICE_LIB_PATH="${rocmPkgs.rocm-device-libs}/amdgcn/bitcode"

            # Ask the Makefile for its own ROCm flag defaults instead of copying
            # them into this flake. Upstream edits that list (it grew -lrocblas in
            # 2026-09), and because these are `?=` an exported copy silently wins,
            # so a stale copy here surfaces only as an undefined symbol at link.
            # A throwaway makefile adds a print-<VAR> rule; values come back fully
            # expanded, so --offload-arch=$(ROCM_ARCH) picks up the export above.
            printf 'print-%%:\n\t@echo $($*)\n' > .nix-print-var.mk
            upstreamCflags=$(make --no-print-directory -f Makefile -f .nix-print-var.mk print-ROCM_CFLAGS)
            upstreamLdlibs=$(make --no-print-directory -f Makefile -f .nix-print-var.mk print-ROCM_LDLIBS)
            rm -f .nix-print-var.mk

            if [ -z "$upstreamCflags" ] || [ -z "$upstreamLdlibs" ]; then
              echo "ERROR: could not read ROCM_CFLAGS/ROCM_LDLIBS from upstream Makefile." >&2
              echo "       Upstream probably renamed or restructured them; update this flake." >&2
              exit 1
            fi

            # Our -L/-rpath go first so they are searched for every -l upstream
            # lists; -I order is immaterial.
            export ROCM_CFLAGS="$upstreamCflags ${rocmIncludeFlags}"
            export ROCM_LDLIBS="${rocmLibFlags} $upstreamLdlibs"

            echo "ROCM_CFLAGS=$ROCM_CFLAGS"
            echo "ROCM_LDLIBS=$ROCM_LDLIBS"

            make strix-halo -j"$NIX_BUILD_CORES"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 -t $out/bin ds4 ds4-server ds4-bench ds4-eval ds4-agent
            install -Dm755 download_model.sh $out/bin/ds4-download-model
            runHook postInstall
          '';

          meta = {
            description = "DwarfStar (ds4): native DeepSeek-V4 inference engine, ROCm/${rocmTarget} build";
            homepage = "https://github.com/antirez/ds4";
            license = pkgs.lib.licenses.mit;
            platforms = [ "x86_64-linux" ];
          };
        });

      # ---------------------------------------------------------------------------
      # NixOS module
      # ---------------------------------------------------------------------------
      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg = config.services.ds4;
          ds4Pkg = mkDs4 {
            inherit pkgs;
            rocmPackages = if cfg.rocmPackages != null
              then cfg.rocmPackages
              else pkgs.rocmPackages;
            rocmTarget = cfg.rocmGpuTarget;
          };
        in {
          options.services.ds4 = {
            enable = lib.mkEnableOption "DwarfStar (ds4) DeepSeek-V4 inference engine";

            package = lib.mkOption {
              type = lib.types.package;
              default = ds4Pkg;
              description = "Which ds4 package to use. Defaults to the ROCm build from this flake.";
            };

            rocmPackages = lib.mkOption {
              type = lib.types.nullOr lib.types.raw;
              default = null;
              description = ''
                ROCm package set to use. If null, uses pkgs.rocmPackages from the
                system's nixpkgs. Otherwise, pass the rocmPackages from an
                alternative nixpkgs channel (e.g. nixpkgs-master.rocmPackages).
              '';
            };

            rocmGpuTarget = lib.mkOption {
              type = lib.types.str;
              default = defaultRocmTarget;
              description = "ROCm GPU target architecture (e.g. gfx1151 for Strix Halo).";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "carl";
              description = "Linux user account to grant render/video group access for ROCm.";
            };

            openFirewallPort = lib.mkOption {
              type = lib.types.port;
              default = 8000;
              description = "TCP port for ds4-server API (set to 0 to disable firewall rule).";
            };

            # Kernel parameter tuning — these are critical on Strix Halo where
            # the default UMA carve-out steals ~32 GiB as dedicated VRAM that
            # ds4 never uses, starving the ~80 GiB GGUF model loaded via GTT.
            kernelTuning = lib.mkOption {
              type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
              default = {
                "amd_iommu" = "off";
                "amdgpu.gttsize" = "126976";            # 124 GiB GTT aperture
                "ttm.pages_limit" = "32505856";          # 124 GiB in 4 KiB pages
                "ttm.page_pool_size" = "32505856";
              };
              description = ''
                Kernel parameters for ds4. Set a value to null to omit the parameter.
                The defaults widen the GTT aperture on Strix Halo.
              '';
            };

            # Swap file for OOM cushion (not for holding weights).
            swapSizeMB = lib.mkOption {
              type = lib.types.int;
              default = 32768;
              description = ''
                Size of the swap file (in MB) used as an OOM cushion. ds4 sets
                oom_score_adj=1000 and volunteers as first victim; headroom is
                the fix. Set to 0 to disable.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            # ROCm user configuration for ds4 access
            users.users.${cfg.user}.extraGroups = [ "render" "video" ];

            # Allow ds4-server to serve its API on the configured port across LAN
            networking.firewall.allowedTCPPorts = lib.optional (cfg.openFirewallPort > 0) cfg.openFirewallPort;

            # Kernel parameter tuning for ds4 GTT aperture
            boot.kernelParams = lib.flatten (lib.mapAttrsToList (name: value:
              if value != null then "${name}=${value}" else []
            ) cfg.kernelTuning);

            # Swap file as OOM cushion
            swapDevices = lib.optional (cfg.swapSizeMB > 0) {
              device = "/var/lib/swapfile";
              size = cfg.swapSizeMB;
            };

            # systemd-oomd proactively kills on memory pressure — counterproductive
            # on a box that intentionally runs near-full for inference.
            systemd.oomd.enable = lib.mkDefault false;

            boot.kernel.sysctl = {
              "vm.overcommit_memory" = 1;    # don't spuriously reject large KV-cache / compute allocations
              "vm.swappiness" = 10;          # keep swapfile a true last resort
              "vm.min_free_kbytes" = 262144; # ~256 MiB reclaim reserve on a near-full box
            };

            # ds4's lockable --ssd-streaming expert cache uses mlock(); the 8 MiB
            # default limit is far too small (full-residency GTT loads don't need this).
            security.pam.loginLimits = [
              { domain = "@wheel"; type = "-"; item = "memlock"; value = "unlimited"; }
            ];
          };
        };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs   = nixpkgs.legacyPackages.${system};
        ds4Pkg = mkDs4 { pkgs = pkgs; };
      in {
        packages.ds4         = ds4Pkg;
        packages.default     = ds4Pkg;
        devShells.default    = pkgs.mkShell { packages = [ ds4Pkg ]; };
      }
    ) // {
      nixosModules.default = nixosModule;
      nixosModules.ds4     = nixosModule;
    };
}
