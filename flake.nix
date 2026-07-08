{
  description = "google/xls (Accelerated HW Synthesis) - build from source, fetch latest release, DSLX LSP";

  # Cachix binary cache: after you build packages locally, push them so that
  # CI / other machines (and you, next time) pull the built store paths
  # instead of re-running Bazel from scratch.
  #   1. cachix create <your-cache-name>          (once, on cachix.org)
  #   2. cachix use <your-cache-name>              (adds it to nix.conf)
  #   3. nix build .# && cachix push <your-cache-name> ./result
  # Replace "your-cache-name" below once you have created your cache, then
  # `nix flake lock` / `nix build` will trust it automatically.
  nixConfig = {
    extra-substituters = [ "https://omar238sh.org" ];
    extra-trusted-public-keys = [
      "omar238sh.cachix.org-1:QOVqP8RL66i+X8zvEM4pBlOZaoRoNzUt1hFYSvCgopI="
    ];
  };


  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Tracks the default branch of google/xls. Run `nix flake update xls-src`
    # (or `nix flake update`) whenever you want to bump to the latest commit
    # — this is the "always latest" mechanism for the from-source build,
    # since flakes require a locked, content-addressed input for reproducible
    # evaluation (a truly dynamic "always fetch whatever is newest right now"
    # source cannot be expressed in a pure flake).
    xls-src = {
      url = "github:google/xls";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, xls-src }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # -----------------------------------------------------------------
        # Option A: fetch the latest prebuilt release tarball, no build
        # tools required. This is intentionally a plain script (not a
        # hermetic Nix derivation) because "always the latest GitHub
        # release" is inherently a network/impure query — the same reason
        # the flake input above is pinned instead. Running this app gets
        # you the newest binaries every time, on demand.
        # -----------------------------------------------------------------
        fetchLatestRelease = pkgs.writeShellApplication {
          name = "xls-fetch-latest-release";
          runtimeInputs = [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.gnugrep ];
          text = ''
            set -euo pipefail
            out_dir="''${1:-./xls-release}"
            mkdir -p "$out_dir"
            cd "$out_dir"

            echo "Querying GitHub for the latest google/xls release..." >&2
            url=$(curl -s -L \
              -H "Accept: application/vnd.github+json" \
              -H "X-GitHub-Api-Version: 2022-11-28" \
              https://api.github.com/repos/google/xls/releases |
              grep -m 1 -o 'https://[^"]*/releases/download/[^"]*\.tar\.gz')

            if [ -z "$url" ]; then
              echo "Could not determine the latest release URL." >&2
              exit 1
            fi

            echo "Downloading: $url" >&2
            curl -O -L "$url"
            tar -xzvf ./*.tar.gz

            cd ./xls-*/
            echo "--- Installed tool versions ---"
            for tool in interpreter_main ir_converter_main opt_main codegen_main proto_to_dslx_main; do
              [ -x "./$tool" ] && ./"$tool" --version || true
            done
          '';
        };

        # -----------------------------------------------------------------
        # Option B: build from source. We tried packaging this as a fully
        # hermetic `buildBazelPackage` derivation (fixed-output fetch phase
        # + sandboxed offline build), but hit a wall: xls's MODULE.bazel
        # graph genuinely requires Bazel 8 semantics (repo-name validation,
        # rules_cc/rules_hdl versions), while `buildBazelPackage` in the
        # current nixpkgs only supports `bazel_7` (bazel_8 doesn't yet
        # accept the `enableNixHacks` override buildBazelPackage requires).
        # Forcing bazel_7 against a Bazel-8-targeted tree surfaces a new
        # incompatibility every step (7zip repo-name rule, rules_cc.bzl
        # load errors, ...) with no end in sight.
        #
        # So: this runs a *real* bazel_8 in a plain script instead of a
        # hermetic Nix derivation. Trade-off: the compiled LSP binary itself
        # is not a Nix store path, so Cachix won't cache it directly (it
        # still caches every nixpkgs tool this script depends on, e.g.
        # bazel_8/git/python3, via cache.nixos.org — just not the xls build
        # output). If you want the LSP build's own outputs cached across
        # runs/CI, use Bazel's own remote-cache mechanism (bazel-remote,
        # BuildBuddy, etc.) via --remote_cache, not Cachix.
        # -----------------------------------------------------------------
        buildDslxLsp = pkgs.writeShellApplication {
          name = "xls-build-dslx-lsp";
          runtimeInputs = [ pkgs.bazel_8 pkgs.git pkgs.python3 pkgs.which pkgs.coreutils ];
          text = ''
            set -euo pipefail
            work_dir=$(mktemp -d)
            trap 'rm -rf "$work_dir"' EXIT

            echo "Copying xls source to a writable build dir..." >&2
            cp -r --no-preserve=mode ${xls-src}/. "$work_dir/"
            cd "$work_dir"

            # Same patches as before: don't let Bazel try to auto-download
            # a pinned release, and drop a flag bazel_8 doesn't need here.
            rm -f .bazelversion
            sed -i '/downloader_config/d' .bazelrc || true

            echo "Building //xls/dslx/lsp:dslx_ls_main with Bazel $(bazel --version)..." >&2
            bazel build -c opt //xls/dslx/lsp:dslx_ls_main

            out_dir="''${1:-./dslx-lsp-out}"
            mkdir -p "$out_dir"
            find bazel-bin -maxdepth 4 -name 'dslx_ls_main' -exec cp {} "$out_dir/dslx_ls" \;
            echo "Built: $out_dir/dslx_ls" >&2
          '';
        };

        devShellPkgs = with pkgs; [
          bazel_8
          python3
          python3Packages.pip
          libtinfo
          git
          gcc
          gnumake
          pkg-config
          zlib
          clang-tools # clangd, for compile_commands.json-based completion
        ];
      in
      {
        packages = {
          # `nix run .#fetch-latest-release` -> downloads newest release binaries, no build tools needed.
          fetch-latest-release = fetchLatestRelease;
          # `nix run .#build-dslx-lsp` -> builds the DSLX LSP from source with real Bazel 8 (not Nix-cached, see comment above).
          build-dslx-lsp = buildDslxLsp;
          default = fetchLatestRelease;
        };

        apps = {
          fetch-latest-release = {
            type = "app";
            program = "${fetchLatestRelease}/bin/xls-fetch-latest-release";
          };
          build-dslx-lsp = {
            type = "app";
            program = "${buildDslxLsp}/bin/xls-build-dslx-lsp";
          };
          default = {
            type = "app";
            program = "${fetchLatestRelease}/bin/xls-fetch-latest-release";
          };
        };

        devShells.default = pkgs.mkShell {
          name = "xls-dev";
          packages = devShellPkgs;
          shellHook = ''
            export PYTHON_BIN_PATH=${pkgs.python3}/bin/python3
            echo "xls dev shell ready. Source tracked via flake input xls-src (run 'nix flake lock --update-input xls-src' for latest)."
            echo "Full source build: bazel test -c opt -- //xls/... -//xls/contrib/xlscc/..."
            echo "DSLX LSP build script: nix run .#build-dslx-lsp -- ./out"
            echo "Latest release binaries, no build tools: nix run .#fetch-latest-release"
            echo "clangd completions (per-target, slower to set up):"
            echo "  bazel build -c opt //xls/... -k && bazel run //:refresh_compile_commands"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
