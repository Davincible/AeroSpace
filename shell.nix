# shell.nix — Development environment for AeroSpace
#
# Provides build dependencies via nix-shell while preserving access
# to macOS system tools (swift, xcodebuild, xcrun, codesign).
#
# Usage:
#   nix-shell              # Enter the development shell
#   nix-shell --run "..."  # Run a single command
#
# IMPORTANT: nix's stdenv on macOS pulls in xcbuild which provides a
# fake `xcrun` that shadows /usr/bin/xcrun. Since /usr/bin/swift is a
# shim that delegates through xcrun, this breaks the entire Swift
# toolchain. We fix this by creating a .nix-tools directory with
# symlinks to the REAL macOS developer tools, prepended to PATH so
# they shadow the nix xcrun wrapper.

{ pkgs ? import <nixpkgs> { } }:

# Use mkShellNoCC to avoid nix's stdenv injecting its C compiler,
# SDK paths (SDKROOT, NIX_CFLAGS_COMPILE, NIX_LDFLAGS), and the
# broken xcrun wrapper from xcbuild. We use Apple's own toolchain.
pkgs.mkShellNoCC {
  name = "aerospace-dev";

  buildInputs = with pkgs; [
    # --- Core build tools ---
    git               # Used by generate.sh for git hash embedding

    # --- ANTLR shell parser generation (generate-shell-parser.sh) ---
    # python3 creates the venv; install-dep.sh --antlr installs antlr4-tools into it
    python3

    # --- Shell completion generation (build-shell-completion.sh) ---
    # install-dep.sh --complgen uses cargo to build the complgen tool
    rustc
    cargo

    # --- Shell completion validation ---
    # build-shell-completion.sh sources the generated completions to verify syntax
    bash              # Needs bash >= 5 (nixpkgs provides 5.x)
    fish
    zsh

    # --- Documentation (build-docs.sh) ---
    # Gemfile requires Ruby >= 3.0 with asciidoctor and pygments.rb gems
    ruby
    bundler

    # --- Release build polish ---
    xcbeautify        # Prettier xcodebuild output (optional but snapshotted by setup.sh)

    # --- Utilities used by various scripts ---
    coreutils         # GNU coreutils (shasum, etc.)
    curl              # install-dep.sh downloads tool zips via curl
    unzip             # install-dep.sh unpacks downloaded artifacts
    gnugrep           # Some scripts use grep features
  ];

  shellHook = ''
    # --- Fix macOS developer tool resolution ---
    #
    # Problem: nix's stdenv includes xcbuild which installs a fake xcrun
    # that can't find Apple developer tools. /usr/bin/swift is a shim
    # that calls xcrun, so the fake xcrun breaks Swift entirely.
    #
    # Solution: Create a local directory with symlinks to the REAL macOS
    # developer tools and prepend it to PATH, so they shadow nix's
    # broken xcrun wrapper.
    _nixtools="$PWD/.nix-tools"
    mkdir -p "$_nixtools"

    # Symlink real macOS developer tools (these MUST shadow nix's xcrun)
    for tool in swift swiftc xcrun xcodebuild xcode-select codesign \
                plutil strings file ditto lipo install_name_tool \
                dsymutil actool ibtool; do
      if [ -x "/usr/bin/$tool" ]; then
        ln -sf "/usr/bin/$tool" "$_nixtools/$tool"
      fi
    done

    # Also symlink xcrun from Xcode CLT if available
    _clt="/Library/Developer/CommandLineTools/usr/bin"
    if [ -d "$_clt" ]; then
      for tool in swift swiftc sourcekit-lsp swift-build swift-package \
                  swift-test swift-run clang clang++; do
        if [ -x "$_clt/$tool" ] && [ ! -e "$_nixtools/$tool" ]; then
          ln -sf "$_clt/$tool" "$_nixtools/$tool"
        fi
      done
    fi

    # Prepend our tool directory BEFORE nix paths
    export PATH="$_nixtools:$PATH"

    # Set DEVELOPER_DIR so xcrun knows where to look
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
      export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [ -d "/Library/Developer/CommandLineTools" ]; then
      export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    fi

    # --- Fix SDK resolution ---
    #
    # Problem: nix's stdenv sets SDKROOT to its own apple-sdk-14.4
    # which was built with Swift 5.10. The system Swift 6.2.3 can't
    # use that SDK ("SDK is not supported by the compiler"). We must
    # point Swift at the system SDK instead.
    #
    # Also unset NIX_CFLAGS_COMPILE, NIX_LDFLAGS, etc. which inject
    # nix SDK paths into the compiler/linker invocations.
    _sys_sdk="$(xcrun --show-sdk-path 2>/dev/null)"
    if [ -n "$_sys_sdk" ]; then
      export SDKROOT="$_sys_sdk"
    fi
    unset NIX_CFLAGS_COMPILE
    unset NIX_LDFLAGS
    unset NIX_CFLAGS_COMPILE_FOR_BUILD
    unset NIX_LDFLAGS_FOR_BUILD

    # Preserve other macOS system paths (for tools not symlinked above)
    for p in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
      case ":$PATH:" in
        *":$p:"*) ;;
        *)        PATH="$PATH:$p" ;;
      esac
    done
    export PATH

    echo "AeroSpace dev shell"
    echo "  swift:      $(swift --version 2>&1 | head -1 || echo 'NOT FOUND')"
    echo "  xcrun:      $(which xcrun)"
    echo "  git:        $(which git)"
    echo "  python3:    $(which python3)"
    echo "  cargo:      $(which cargo)"
    echo "  ruby:       $(which ruby)"
    echo ""
    echo "Quick start:"
    echo "  ./build-debug.sh          # Debug build"
    echo "  ./run-tests.sh            # Full test suite"
    echo "  swift build               # Direct SPM build (bypasses setup.sh)"
  '';
}
