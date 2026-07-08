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
        # Option B: build from source. We tried packaging this as a fully
        # hermetic `buildBazelPackage` derivation (fixed-output fetch phase
        # + sandboxed offline build), but hit a wall: xls's MODULE.bazel
        # graph genuinely requires Bazel 8 semantics (repo-name validation,
        # rules_cc/rules_hdl versions), while `buildBazelPackage` in the
        # current nixpkgs only supports `bazel_7` (bazel_8 doesn't yet
        # accept the `enableNixHacks` override buildBazelPackage requires).
        # Forcing bazel_7 against a Bazel-8-targeted tree surfaced a new
        # incompatibility every step (7zip repo-name rule, rules_cc.bzl
        # load errors, ...).
        #
        # Fix: build with real bazel_8 inside a *single fixed-output
        # derivation* (network allowed for the whole build, not just a
        # separate fetch phase, because we pin `outputHash` below). This
        # sidesteps buildBazelPackage's bazel_7-only override entirely,
        # and — unlike the earlier script version — the result IS a real
        # Nix store path: cacheable via Cachix and consumable from other
        # flakes as `packages.dslx-lsp`.
        # -----------------------------------------------------------------
        xlsDslxLsp = pkgs.stdenv.mkDerivation {
          pname = "xls-dslx-lsp";
          version = "unstable-${xls-src.shortRev or "dirty"}";
          src = xls-src;

          nativeBuildInputs = [ pkgs.bazel_8 pkgs.git pkgs.python3 pkgs.which pkgs.cacert ];
          buildInputs = [ pkgs.zlib ];

          postPatch = ''
            rm -f .bazelversion
            sed -i '/downloader_config/d' .bazelrc || true
          '';

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export GIT_SSL_CAINFO="$SSL_CERT_FILE"
            bazel build -c opt --output_user_root="$TMPDIR/bazel_output" //xls/dslx/lsp:dslx_ls
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            find bazel-bin -maxdepth 4 -name dslx_ls -exec cp {} $out/bin/dslx_ls \;
            runHook postInstall
          '';

          # Fixed-output: Nix grants network access for the whole
          # derivation (needed for Bazel's MODULE.bazel git/http fetches)
          # in exchange for pinning the result's hash. As with the release
          # tarball above: first build fails and prints the real hash —
          # paste it in below.
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = pkgs.lib.fakeSha256; # <-- replace after first run

          meta = with pkgs.lib; {
            description = "DSLX language server built from google/xls source";
            homepage = "https://github.com/google/xls";
            license = licenses.asl20;
            platforms = [ "x86_64-linux" ];
          };
        };

        # -----------------------------------------------------------------
        # A real, consumable package for the prebuilt release tools
        # (interpreter_main, ir_converter_main, opt_main, codegen_main,
        # proto_to_dslx_main): unlike fetch-latest-release above, this is
        # pinned to a specific tag so it's reproducible and usable as a
        # normal Nix package from another flake. Bump `xlsToolsVersion` and
        # update the hash whenever you want a newer release.
        # -----------------------------------------------------------------
        xlsToolsVersion = "v0.0.0"; # <-- set to a real tag from https://github.com/google/xls/releases
        xlsTools = pkgs.stdenv.mkDerivation {
          pname = "xls-tools";
          version = xlsToolsVersion;

          src = pkgs.fetchurl {
            url = "https://github.com/google/xls/releases/download/${xlsToolsVersion}/xls-${xlsToolsVersion}-linux-x64.tar.gz";
            sha256 = pkgs.lib.fakeSha256; # <-- replace after first run
          };

          sourceRoot = ".";
          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            find . -maxdepth 2 -type f -perm -u+x -exec cp {} $out/bin/ \;
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Prebuilt google/xls tool binaries (interpreter_main, opt_main, codegen_main, ir_converter_main, proto_to_dslx_main)";
            homepage = "https://github.com/google/xls";
            license = licenses.asl20;
            platforms = [ "x86_64-linux" ];
          };
        };

        # -----------------------------------------------------------------
        # Option A: fetch the latest prebuilt release tarball on demand, no
        # build tools required and no fixed hash to maintain. This stays a
        # plain script (not a Nix derivation) because "always the latest
        # GitHub release" is inherently a moving target — the opposite of
        # what a reproducible package (xlsTools above) can express. Use
        # this interactively; use `packages.xls-tools` when you need a
        # pinned, composable package.
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
          # Pinned, reproducible, consumable from other flakes:
          xls-tools = xlsTools; # interpreter_main, opt_main, codegen_main, ir_converter_main, proto_to_dslx_main
          dslx-lsp = xlsDslxLsp; # dslx_ls
          # On-demand scripts (see comments above for why these aren't plain packages):
          fetch-latest-release = fetchLatestRelease;
          default = xlsTools;
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
          packages = devShellPkgs ++ [ xlsTools xlsDslxLsp ];
          shellHook = ''
            export PYTHON_BIN_PATH=${pkgs.python3}/bin/python3
            echo "xls dev shell ready. Source tracked via flake input xls-src (run 'nix flake lock --update-input xls-src' for latest)."
            echo "interpreter_main / opt_main / codegen_main / ir_converter_main / proto_to_dslx_main and dslx_ls are on PATH."
            echo "Full source build: bazel test -c opt -- //xls/... -//xls/contrib/xlscc/..."
            echo "Latest release binaries (script, no fixed version): nix run .#fetch-latest-release"
            echo "clangd completions (per-target, slower to set up):"
            echo "  bazel build -c opt //xls/... -k && bazel run //:refresh_compile_commands"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
