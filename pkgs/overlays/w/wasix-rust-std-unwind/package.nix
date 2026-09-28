# An unwind-capable `std` for the two WASIX Rust targets.
#
# The fork's wasm base spec hardcodes the panic strategy:
# `compiler/rustc_target/src/spec/base/wasm.rs:63-68` ("Unwinding doesn't work
# right now, so the whole target unconditionally defaults to panic=abort...
# guaranteed to change it once WebAssembly supports exceptions"), and neither
# `wasm32_wasmer_wasi.rs` nor its `-dl` sibling puts `exception-handling` in
# `options.features`. So the std the toolchain ships cannot recover a panic, and
# a crate that asks for `-C panic=unwind` against it stops at
# `error: the crate 'panic_unwind' does not have the panic strategy 'unwind'`.
#
# WebAssembly exceptions do now exist and Wasmer executes them: the runtime has
# exnref as a first-class entity (`lib/api/src/backend/sys/entities/exception.rs`
# `VMExceptionRef`) and a module carrying standard EH runs, which is what the
# pgrust WASIX lane needs to survive a backend error. The same spec file already
# anticipates the std half of this: `base/wasm.rs:113-119` passes
# `-wasm-use-legacy-eh=false` because "for `-Zbuild-std` builds, however, this
# affects when rebuilding libstd with unwinding".
#
# So this package rebuilds std the way that comment describes, with the
# substituted compiler rather than a rebuilt one, and re-exports the toolchain's
# layout with the result in place of each target's abort `lib`. A crate consumes
# it through `--sysroot` and needs no build-std of its own; when the fork drops
# the abort default this whole unit goes away.
#
# The rebuilt set is what `-Zbuild-std=std,panic_unwind` produces: the std graph
# plus both panic strategies, but not `test`/`getopts`, so a crate running
# `cargo test` on these targets would still need the abort sysroot for the test
# harness. Nothing in this repo's WASIX Rust lane does.
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({
  lib,
  stdenv,
  writableTmpDirAsHomeHook,
  wasix-rust,
  wasix-sysroot,
  ...
}: let
  inherit (wasix-sysroot.passthru.variants) eh ehpic;
  # The C EH runtime each Rust target links against: the static target takes the
  # `eh` tree, the dynamic-linking target the PIC one. Only the `-L` search path
  # differs; the archives themselves arrive through wasixcc's own sysroot.
  stdTargets = {
    "wasm32-wasmer-wasi" = eh.sysroot;
    "wasm32-wasmer-wasi-dl" = ehpic.sysroot;
  };
  targetNames = builtins.attrNames stdTargets;
  # The same source the toolchain is built from. `fetchSubmodules` is load-bearing
  # there: `library/backtrace` and `library/compiler-builtins` are submodules and
  # std does not compile without them (`couldn't read .../library/backtrace/src/lib.rs`).
  inherit (wasix-rust) src;
  # The three flags a WASIX build that unwinds has to carry: the strategy, the
  # encoding the strategy lowers to, and the search path for libunwind.a.
  rustflagsFor = target: "-C panic=unwind -C target-feature=+exception-handling -L ${stdTargets.${target}}/lib/wasm32-wasi";
in
  stdenv.mkDerivation {
    pname = "wasix-rust-std-unwind";
    inherit (wasix-rust) version;
    inherit src;

    dontUnpack = true;

    # rustc and cargo from the toolchain. Its own sysroot is never used as a std
    # source, so nothing here rebuilds the compiler.
    nativeBuildInputs = [
      wasix-rust
      writableTmpDirAsHomeHook
    ];

    # Only two phases: the outputs are wasm rlibs and symlinks, so there is no
    # configure step, and strip/autoPatchelf have nothing here to act on.
    phases = [
      "buildPhase"
      "installPhase"
    ];

    buildPhase = let
      # One build per target, because `-Zbuild-std` resolves the std sources
      # against a single `--target` and the two targets differ in code model.
      buildLeg = target: ''
        RUSTC="$ov/bin/rustc" \
        RUSTFLAGS="${rustflagsFor target}" \
          cargo build --offline --release --manifest-path "$PWD/crate/Cargo.toml" \
            -Zbuild-std=std,panic_unwind --target ${target}
      '';
    in ''
      runHook preBuild

      # `-Zbuild-std` wants the library workspace at <sysroot>/lib/rustlib/src/rust,
      # which the toolchain does not ship: its install phase deletes `lib/rustlib/src`
      # (wasix-rust/package.nix:368-376) because stage2 leaves it as symlinks into the
      # build directory. cargo's rust-src probe reads the sysroot *rustc reports*, and
      # `--sysroot` reaches that probe only through a RUSTC wrapper - RUSTFLAGS is not
      # passed to cargo's own compiler probes - so the overlay is a tree of symlinks
      # with the source injected and a wrapper that pins the sysroot.
      ov="$PWD/src-sysroot"
      mkdir -p "$ov/bin" "$ov/lib" "$ov/lib/rustlib/src/rust"
      for e in ${wasix-rust}/lib/*; do
        [ "$(basename "$e")" = rustlib ] || ln -s "$e" "$ov/lib/$(basename "$e")"
      done
      for e in ${wasix-rust}/lib/rustlib/*; do
        ln -s "$e" "$ov/lib/rustlib/$(basename "$e")"
      done
      ln -s ${src}/library "$ov/lib/rustlib/src/rust/library"
      ln -s ${src}/Cargo.lock "$ov/lib/rustlib/src/rust/Cargo.lock"
      mkdir -p "$ov/lib/rustlib/src/rust/src"
      ln -s ${src}/src/version "$ov/lib/rustlib/src/rust/src/version"
      # The overlay path is bound into the wrapper at build time, not left as a
      # `$ov` reference: the wrapper runs as its own process, where only the
      # nix-interpolated toolchain path and the shell's own variables exist, and an
      # unset one there reads as an empty sysroot (cargo then reports
      # `lib/rustlib/src/rust/library/Cargo.lock does not exist`).
      printf '#!/bin/sh\nexec ${wasix-rust}/bin/rustc --sysroot "%s" "$@"\n' "$ov" > "$ov/bin/rustc"
      chmod +x "$ov/bin/rustc"

      # A dependency-free library crate: building a lib stops before the link, so
      # the rlibs under the target dir are all this produces and no C EH runtime has
      # to be resolved to get them. A bin here would need `crt1.o`/`-lunwind` for
      # each target, which is the consumer's problem.
      mkdir -p crate/src .cargo
      substitute ${wasix-rust.cargoDeps}/.cargo/config.toml .cargo/config.toml \
        --subst-var-by vendor ${wasix-rust.cargoDeps}
      printf '[package]\nname = "unwind-std-carrier"\nversion = "0.0.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' > crate/Cargo.toml
      : > crate/src/lib.rs

      # No `cd`: stdenv runs every phase in one shell, so a buildPhase directory
      # change would still be in effect in installPhase. cargo finds the config
      # above from the unchanged build directory, and the manifest and target dir
      # are given as paths.
      export CARGO_NET_OFFLINE=true
      ${lib.concatMapStrings buildLeg targetNames}

      runHook postBuild
    '';

    installPhase = let
      # rustc takes a target's std from <sysroot>/lib/rustlib/<triple>/lib, and it
      # selects sysroot crates by name. The toolchain's abort set must therefore be
      # replaced, not extended: leaving both sets reachable is what produces
      # `the crate 'panic_unwind' does not have the panic strategy 'unwind'`.
      installLeg = target: ''
        target_lib="$out/lib/rustlib/${target}/lib"
        mkdir -p "$target_lib"
        ln -s ${wasix-rust}/lib/rustlib/${target}/lib/self-contained "$target_lib/self-contained"
        for unit in "$PWD"/crate/target/${target}/release/deps/*.rlib \
                    "$PWD"/crate/target/${target}/release/deps/*.rmeta; do
          [ -e "$unit" ] || continue
          # The carrier crate itself is not std, and a sysroot must not offer a
          # crate no build asked for.
          case "$(basename "$unit")" in libunwind_std_carrier-*) continue ;; esac
          # Copies, not symlinks: the build directory they came from is temporary,
          # which is the mistake wasix-rust's own install phase documents.
          cp -f "$unit" "$target_lib/$(basename "$unit")"
          chmod +w "$target_lib/$(basename "$unit")"
        done
        echo "unwind std for ${target}: $(ls -1 "$target_lib" | grep -c '\.rlib$') rlibs"
      '';
    in ''
      runHook preInstall

      mkdir -p "$out/lib"
      for e in ${wasix-rust}/lib/*; do
        [ "$(basename "$e")" = rustlib ] || ln -s "$e" "$out/lib/$(basename "$e")"
      done
      mkdir -p "$out/lib/rustlib"
      ${lib.concatMapStrings installLeg targetNames}
      # Everything else the toolchain's rustlib holds - the host triple's std
      # above all, because build scripts and proc macros are compiled against this
      # sysroot too and must still find a host libstd. The two WASIX triples are
      # the ones just written out, so they are the only names skipped.
      for e in ${wasix-rust}/lib/rustlib/*; do
        case "$(basename "$e")" in
          ${lib.concatStringsSep "|" (map (target: ''"${target}"'') targetNames)}) ;;
          *) ln -s "$e" "$out/lib/rustlib/$(basename "$e")" ;;
        esac
      done

      runHook postInstall
    '';

    passthru = {
      # A capability of the Rust toolchain, not a WASIX-lane package: no profile of
      # its own, and the profiles it exists for are the ones with a Rust std.
      wasix.supportedProfiles = [];
      targets = targetNames;

      # The flags a crate has to carry to unwind over Wasm EH against this std.
      # `--sysroot ''${this package}` is the consumer's half, and stays out of the
      # string so a package that reaches this std through its own sysroot overlay
      # cannot get the flag twice.
      rustflags = rustflagsFor;
    };

    meta = {
      description = "std for the WASIX Rust targets, built with panic=unwind and Wasm exception handling";
      longDescription = "A copy of the wasix-rust sysroot whose WASIX target libraries are rebuilt from the fork's own source with unwinding enabled, for crates that recover panics through WebAssembly exception handling.";
      homepage = "https://github.com/wasix-org/rust";
      license = with lib.licenses; [
        mit
        asl20
      ];
      platforms = ["x86_64-linux"];
    };
  }) {})
