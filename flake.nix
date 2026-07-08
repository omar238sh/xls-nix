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
        # Option B: build from source with Bazel, reproducibly, via
        # nixpkgs' buildBazelPackage (used upstream for other large Bazel
        # projects, e.g. TensorFlow). It runs Bazel's fetch phase inside a
        # fixed-output derivation (network allowed, output hash pinned),
        # then does the actual compile fully sandboxed/offline. This is
        # what makes the result cacheable via Cachix like any other Nix
        # derivation.
        #
        # NOTE: fetchAttrs.sha256 below is a placeholder. The first build
        # will fail and print the real hash — paste it in and rebuild.
        # NOTE: verify the exact Bazel target label for the DSLX language
        # server against the current xls-src tree (path may shift between
        # commits); adjust `bazelTargets` if needed.
        # -----------------------------------------------------------------
        xlsDslxLsp = pkgs.buildBazelPackage {
          pname = "xls-dslx-lsp";
          version = "unstable-${xls-src.shortRev or "dirty"}";
          src = xls-src;

          bazel = pkgs.bazel_7;
          bazelFlags = [ "-c" "opt" "--noenable_bzlmod" "--enable_workspace" ];
          bazelTargets = [ "//xls/dslx/lsp:dslx_ls_main" ];

          # The xls repo pins an exact Bazel version via .bazelversion; the
          # wrapper tries to download that exact release, which fails
          # offline inside the Nix sandbox. Drop the pin so it just uses
          # whatever `bazel` (bazel_7 above) is on PATH.
          # Also strip --downloader_config from .bazelrc: it's a newer-Bazel
          # option not recognized by bazel_7.6.0, and we don't need it since
          # we're building fully offline after the fetch phase anyway.
          # We also disable bzlmod because current transitive MODULE deps use
          # repository names (e.g. "7zip") rejected by bazel_7.
          postPatch = ''
            rm -f .bazelversion
            sed -i '/downloader_config/d' .bazelrc
          '';

          fetchAttrs = {
            sha256 = pkgs.lib.fakeSha256; # <-- replace after first run
            nativeBuildInputs = [ pkgs.git ];
          };

          buildAttrs = {
            buildInputs = [ pkgs.python3 pkgs.zlib ];
            nativeBuildInputs = [ pkgs.git ];

            installPhase = ''
              mkdir -p $out/bin
              find bazel-bin -maxdepth 4 -name 'dslx_ls_main' -exec cp {} $out/bin/dslx_ls \;
            '';
          };

          meta = with pkgs.lib; {
            description = "DSLX language server built from google/xls source";
            homepage = "https://github.com/google/xls";
            license = licenses.asl20;
            platforms = [ "x86_64-linux" ];
          };
        };

        devShellPkgs = with pkgs; [
          bazel_7
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
          # `nix build .#dslx-lsp` -> builds the DSLX LSP from source (cacheable via Cachix).
          dslx-lsp = xlsDslxLsp;
          default = xlsDslxLsp;
        };

        apps = {
          fetch-latest-release = {
            type = "app";
            program = "${fetchLatestRelease}/bin/xls-fetch-latest-release";
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
            echo "DSLX LSP prebuilt package: nix build .#dslx-lsp"
            echo "Latest release binaries, no build tools: nix run .#fetch-latest-release"
            echo "clangd completions (per-target, slower to set up):"
            echo "  bazel build -c opt //xls/... -k && bazel run //:refresh_compile_commands"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
