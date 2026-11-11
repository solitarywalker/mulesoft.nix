# Anypoint Code Builder — MuleSoft's VS Code-based IDE, assembled from the
# Marketplace extensions it is made of.
#
# Upstream publishes these for win32-x64, darwin-x64 and darwin-arm64 only, but
# what differs between those builds is small: of the eight extensions, six are
# byte-for-byte the same on every platform (only extension.vsixmanifest, which
# names the platform, changes). The other two each bundle a native runtime:
#
#   mule-dx-dependencies   a Temurin JDK 17         -> pkgs.temurin-bin-17
#   mule-dx-api-component  Node.js 22               -> pkgs.nodejs_22
#                          acv, a Go binary         -> built from source below
#
# So the darwin-x64 builds are taken as they are and only those runtimes are
# swapped for Linux ones. Everything else that is native — the Tanuki wrapper of
# the bundled Mule runtime, tree-sitter's node addon — already ships a
# linux-x86-64 copy next to the others.
{
  lib,
  stdenv,
  autoPatchelfHook,
  buildGoModule,
  fetchFromGitHub,
  jq,
  vscode-utils,
  vscode-with-extensions,

  # The design-time Mule runtime's start script looks these up in a fixed list
  # of FHS directories; see mule-dx-runtime below.
  coreutils,
  procps,

  # Upstream bundles Temurin 17.0.20.1 and Node.js 22.23.4.
  temurin-bin-17,
  nodejs_22,
}:

let
  # acv is AML's amf-custom-validator, the API governance validator. The copy in
  # the darwin build says so itself: its Go build info is
  # `path command-line-arguments` with github.com/aml-org/amf-custom-validator as
  # a (devel) dependency, which is exactly what the repository's Makefile
  # produces with `go build -o acv ./cmd/main.go`. Upstream has archived the
  # repository; the tag below is its last commit.
  acv = buildGoModule (finalAttrs: {
    pname = "amf-custom-validator";
    version = "1.8.0-SNAPSHOT.126";

    src = fetchFromGitHub {
      owner = "aml-org";
      repo = "amf-custom-validator";
      tag = "v${finalAttrs.version}";
      hash = "sha256-w8fr3bfB8j9jJdr9elu5vdEYk7Be6lUqN6+Oz9ZOHOk=";
    };

    vendorHash = "sha256-OPeHY01Ys26GgjE/MjzT4b7gbSCCHZdN+jM87JsfxbM=";

    subPackages = [ "cmd" ];
    env.CGO_ENABLED = 0;

    postInstall = ''
      mv $out/bin/cmd $out/bin/acv
    '';

    meta = {
      description = "AML custom validator for API governance profiles";
      homepage = "https://github.com/aml-org/amf-custom-validator";
      license = lib.licenses.asl20;
      mainProgram = "acv";
    };
  });

  mkExtension =
    {
      name,
      version,
      hash,
      ...
    }@args:
    vscode-utils.buildVscodeMarketplaceExtension (
      {
        mktplcRef = {
          publisher = "salesforce";
          inherit name version hash;
          arch = "darwin-x64";
        };
        meta = {
          homepage = "https://docs.mulesoft.com/anypoint-code-builder/";
          license = lib.licenses.unfree;
          sourceProvenance = with lib.sourceTypes; [
            binaryBytecode
            binaryNativeCode
          ];
          platforms = [ "x86_64-linux" ];
        };
      }
      // removeAttrs args [
        "name"
        "version"
        "hash"
      ]
    );

  extensions = {
    mule-dx-extension-pack = mkExtension {
      name = "mule-dx-extension-pack";
      version = "1.28.2";
      hash = "sha256-GJQwAsBm6+dqozED1GJ9Df8cOlcPqMIb9QvNfveetg4=";
    };

    mule-dx-vscode = mkExtension {
      name = "mule-dx-vscode";
      version = "5.22.1";
      hash = "sha256-6LstN1ypRKlkevUnzSk9KL4ecSpQ0rbSB8kREHjXAXQ=";
    };

    # The platform extension reads `contributes."acb.java.home"` out of this
    # one's package.json and resolves it against the extension directory, so an
    # absolute store path works as well as upstream's relative one. It then
    # copies that JDK into its own home directory and runs everything from the
    # copy; the copy is named after the directory's basename, which for
    # temurin-bin is the store path's name and so changes with every JDK update.
    #
    # Maven stays: it is Java and shell, the same on every platform. It is the
    # bin/ scripts' executable bits that do not survive the darwin build's zip.
    mule-dx-dependencies = mkExtension {
      name = "mule-dx-dependencies";
      version = "1.8.1";
      hash = "sha256-hY/hcBp7+7W0YnRmMwIbBzgi7m7bOQBJYYR7hD4Pcdw=";

      nativeBuildInputs = [ jq ];

      postPatch = ''
        rm -r build/deps/jdk-*
        jq --arg jdk ${temurin-bin-17} '.contributes."acb.java.home" = [ $jdk ]' \
          package.json >package.json.new
        mv package.json.new package.json
        chmod +x build/deps/apache-maven-*/bin/{mvn,mvnDebug,mvnyjp}
      '';
    };

    mule-dx-runtime = mkExtension {
      name = "mule-dx-runtime";
      version = "1.4.0";
      hash = "sha256-ZjA6xVRLE3xQT8urT+swEEYHHAL1WOs9XFMbH31Gmv4=";

      nativeBuildInputs = [ autoPatchelfHook ];

      # The same treatment anypoint-studio.nix gives the runtime it bundles, for
      # the same reasons: Tanuki ships one wrapper per platform and
      # autoPatchelfHook would walk into the Solaris and FreeBSD x86-64 ones, and
      # the start script finds ps and tr in a fixed list of FHS directories that
      # never consults $PATH.
      postPatch = ''
        for rt in build/runtime/mule-*-standalone-*; do
          tanuki=$rt/lib/boot/tanuki
          find "$tanuki" -maxdepth 1 -type f \
            \( -name 'libwrapper-*' ! -name 'libwrapper-linux-x86-64.so' \
               -o -name 'wrapper-windows-*' \) -delete
          find "$tanuki/exec" -maxdepth 1 -type f ! -name 'wrapper-linux-x86-64' -delete
          chmod +x "$tanuki/exec/wrapper-linux-x86-64" $rt/bin/{mule,launcher,amc_setup,amc_debug}

          substituteInPlace $rt/bin/mule \
            --replace-fail 'resolveLocation PS_BIN ps "/usr/ucb;/usr/bin;/bin" 1' \
                           'resolveLocation PS_BIN ps "${procps}/bin;/usr/ucb;/usr/bin;/bin" 1' \
            --replace-fail 'resolveLocation TR_BIN tr "/usr/bin;/bin" 1' \
                           'resolveLocation TR_BIN tr "${coreutils}/bin;/usr/bin;/bin" 1'
        done
      '';
    };

    mule-dx-data-weave-client = mkExtension {
      name = "mule-dx-data-weave-client";
      version = "2.13.0";
      hash = "sha256-jovL0jZAlcbCDt5lp78pOanY5mGi4g5ZnLHAt/FeeWM=";
    };

    # On activation this extension copies the newest runtime under
    # mule-dx-runtime's build/runtime into <ACB home>/runtime/<its basename>,
    # skipping the copy whenever that directory already exists, and runs Mule
    # from there. The copy is fs-extra's copySync, which keeps the source's mode:
    # from the store that is a tree of 555 directories and 444 files, and the
    # runtime cannot write its own conf/wrapper.conf, logs/ or apps/. And since
    # the directory then exists, no later start ever gets a second chance.
    #
    # So make the copy writable right after it is made. The match is against
    # minified code, but --replace-fail turns an upstream change into a build
    # failure rather than a runtime that quietly stays read-only.
    mule-dx-mule-dev-component = mkExtension {
      name = "mule-dx-mule-dev-component";
      version = "3.35.5";
      hash = "sha256-MY+mDfnY9PhdDqpYZtLLlzvZw4Xq5sKxNcxHD6CFDuk=";

      postPatch = ''
        substituteInPlace dist/extension.js \
          --replace-fail '$.copySync(n,t),' \
                         '$.copySync(n,t),require("child_process").execFileSync("${coreutils}/bin/chmod",["-R","u+w",t]),'
      '';
    };

    # api.component.node.runtime.home and api.component.acv.home in package.json
    # point at dist/deps/node-runtime and dist/deps/acv; the API language server
    # runs bin/node and acv from there. tree-sitter under node-deps already has a
    # linux-x64 prebuild, which autoPatchelfHook points at libstdc++.
    mule-dx-api-component = mkExtension {
      name = "mule-dx-api-component";
      version = "4.24.3";
      hash = "sha256-HGe/8nV1j1oPAkBq7YoVOUjxVSv8TELIlnsXootKcEA=";

      nativeBuildInputs = [ autoPatchelfHook ];
      buildInputs = [ stdenv.cc.cc.lib ];

      postPatch = ''
        rm -r dist/deps/node-runtime
        ln -s ${nodejs_22} dist/deps/node-runtime
        rm dist/deps/acv/acv
        ln -s ${lib.getExe acv} dist/deps/acv/acv
      '';
    };

    mule-dx-apikit-component = mkExtension {
      name = "mule-dx-apikit-component";
      version = "1.4.4";
      hash = "sha256-ovN/qokyT1mT8CRSvsQulpUYeNOsZBqfk/9jsTCXZMs=";
    };

    mule-dx-munit-component = mkExtension {
      name = "mule-dx-munit-component";
      version = "1.3.17";
      hash = "sha256-bHGVsXYrejJIm+HtRR8fC4/crmHBUgQlkBFbWdSbIr0=";
    };
  };
in
(vscode-with-extensions.override {
  vscodeExtensions = lib.attrValues extensions;
}).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit acv extensions;
    };
  })
