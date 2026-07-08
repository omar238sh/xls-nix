{
  description = "google/xls (Accelerated HW Synthesis) - build from source, fetch latest release, DSLX LSP";

  nixConfig = {
    extra-substituters = [ "https://omar238sh.org" ];
    extra-trusted-public-keys = [
      "omar238sh.cachix.org-1:QOVqP8RL66i+X8zvEM4pBlOZaoRoNzUt1hFYSvCgopI="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils = {
      url =  "github:numtide/flake-utils";
      inputs.nixpkgs.follow = "nixpkgs";
    };
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
        # Option B: build from source.
        # -----------------------------------------------------------------
        xlsDslxLsp = pkgs.stdenv.mkDerivation {
          pname = "xls-dslx-lsp";
          version = "unstable-${xls-src.shortRev or "dirty"}";
          src = xls-src;

          # تم إضافة xz و unzip و patch هنا لحل مشكلة استخراج حزم Bazel الاعتمادية
          nativeBuildInputs = [ 
            pkgs.bazel_8 
            pkgs.git 
            pkgs.python3 
            pkgs.which 
            pkgs.cacert 
            pkgs.xz 
            pkgs.unzip 
            pkgs.patch 
          ];
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
            
            # ترتيب صحيح: خيار التخزين --output_user_root يأتي قبل أمر build
            bazel --output_user_root="$TMPDIR/bazel_output" build -c opt //xls/dslx/lsp:dslx_ls
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            find bazel-bin -maxdepth 4 -name dslx_ls -exec cp {} $out/bin/dslx_ls \;
            runHook postInstall
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-LfPR5w1iuzK6Vbb707BRjwz/BhP320DvEETD6q3SrQY="; # <-- سيفشل أول بناء ويطبع الهاش الصحيح لمخرجات بازل، قم باستبداله هنا.

          meta = with pkgs.lib; {
            description = "DSLX language server built from google/xls source";
            homepage = "https://github.com/google/xls";
            license = licenses.asl20;
            platforms = [ "x86_64-linux" ];
          };
        };

        # -----------------------------------------------------------------
        # Option C: Pinned Release Binaries (xlsTools)
        # -----------------------------------------------------------------
        xlsToolsVersion = "v0.0.0-10242-g9d8ef0bc6";

        # اشتقاق ثابت المخرجات (Fixed-output) للتحميل النظيف فقط بدون استدعاء store paths
        xlsToolsSrc = pkgs.stdenv.mkDerivation {
          pname = "xls-tools-src";
          version = xlsToolsVersion;

          dontUnpack = true;
          nativeBuildInputs = [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.gnugrep pkgs.cacert ];

          buildPhase = ''
            runHook preBuild
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            url=$(curl -s -L \
              -H "Accept: application/vnd.github+json" \
              https://api.github.com/repos/google/xls/releases/tags/${xlsToolsVersion} |
              grep -o 'https://[^"]*/releases/download/[^"]*\.tar\.gz' | head -n1)
      
            if [ -z "$url" ]; then
              echo "Could not find a release asset for tag ${xlsToolsVersion}" >&2
              exit 1
            fi
            echo "Downloading: $url" >&2
            curl -L -o xls.tar.gz "$url"
            mkdir extracted
            tar -xzf xls.tar.gz -C extracted
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r extracted/* $out/
            runHook postInstall
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = "sha256-9WykWXmxOItsaRHWsSkFUO9dK7sT9yd+3iruTqlMZIY="; # الهاش الصحيح بعد معالجة الفصل
        };

        # الاشتقاق الفعلي لتطبيق autoPatchelfHook بأمان
        xlsTools = pkgs.stdenv.mkDerivation {
          pname = "xls-tools";
          version = xlsToolsVersion;

          src = xlsToolsSrc;
          dontUnpack = true;

          nativeBuildInputs = [ pkgs.autoPatchelfHook ];
          buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            find $src -maxdepth 2 -type f -perm -u+x -exec cp {} $out/bin/ \;
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Prebuilt google/xls tool binaries";
            homepage = "https://github.com/google/xls";
            license = licenses.asl20;
            platforms = [ "x86_64-linux" ];
          };
        };

        # -----------------------------------------------------------------
        # Option A: Interactive Script
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
          clang-tools
        ];
      in
      {
        packages = {
          xls-tools = xlsTools;
          dslx-lsp = xlsDslxLsp;
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
            echo "xls dev shell ready."
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
