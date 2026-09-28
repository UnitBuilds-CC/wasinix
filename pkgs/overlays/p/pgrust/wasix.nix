# pgrust is a Rust rewrite of PostgreSQL 18.6. Only the WASIX lane is packaged:
# the socket, epoll, and accept-loop changes that let the postmaster hand each
# pgwire connection its own backend thread, and the pqsignal installs that let it
# take a termination signal, exist in no public revision, so there is no native
# build to project and the lane arrives as a patch.
{
  exposeWasixPackage,
  lib,
  packages,
  pkgs,
}:
exposeWasixPackage (packages.sameProfile.rustPlatform.buildRustPackage {
  pname = "pgrust";

  # The source carries no release version, and no upstream release covers this
  # snapshot, so the revision date is the version.
  version = "0-unstable-2026-09-15";

  src = packages.sameProfile.fetchFromGitHub {
    owner = "malisper";
    repo = "pgrust";
    rev = "79ad992ede22bcf6ae0c4fdead6fb01eeac5a990";
    hash = "sha256-irogFqn8Lpkdv2r2IGEkmGPLBgFachRuQO65qscGvoM=";
  };

  # The lane adds no dependency declaration, so the crate set stays the pinned
  # revision's own and `cargoHash` does not move with the patch.
  patches = [./patches/wasix-lane.patch];
  cargoHash = "sha256-vvKLREWgpUuPiKRp8WiVBcN055PuA0Iz/p1yAiUsKj8=";

  # One binary, named postgres: the workspace also carries benches and the crash
  # simulator's harnesses.
  cargoBuildFlags = ["-p" "main_main" "--bin" "postgres"];

  # The lane links unwinds, and its 64 MiB shadow stack is what makes
  # max_stack_depth=60000 reachable. `panic=unwind` cannot resolve against the
  # toolchain's own std: the fork's wasm base spec records that std as
  # abort-flavoured, so the compiler answers
  # `error: the crate 'panic_unwind' does not have the panic strategy 'unwind'`.
  # The sysroot here is that same compiler's source rebuilt with unwinding, which
  # is what the fork patch in the deliverables makes unnecessary.
  # `+exception-handling` is the encoding that strategy lowers to and rustc adds it
  # by itself once `panic=unwind` is set - measured, the two flag sets produce
  # modules of identical size and behaviour - but it is kept because every
  # benchmarked artifact of this lane was built with it.
  env = {
    RUSTFLAGS = "--sysroot ${packages.native.wasix-rust-std-unwind} -C panic=unwind -C target-feature=+exception-handling -C link-arg=-zstack-size=67108864";

    # The install phase globs the `release` profile, but the measured module was
    # built by the fork's `--profile wasm-release` leg
    # (`repos/pgrust/wasm/wasm-build.sh:89,95`), which is `opt-level = "s"`,
    # `lto = false`, `codegen-units = 16` inheriting a `release` of `lto = "thin"`,
    # `codegen-units = 1` (`repos/pgrust/Cargo.toml:914-928`). Reconciling the
    # three keeps the shipped bytes in the profile that was measured, and skips a
    # whole-program LTO tail over a ~40 MB module for the same reason rustfs
    # overrides them (`pkgs/overlays/r/rustfs/wasix.nix:45-53`).
    CARGO_PROFILE_RELEASE_OPT_LEVEL = "s";
    CARGO_PROFILE_RELEASE_LTO = "false";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };

  passthru = {
    wasix.supportedProfiles = ["eh" "ehpic"];
    wasinix.shipped = true;
    updateScript = {
      command = pkgs.buildPackages.nix-update-script {
        extraArgs = ["--flake" "--version=branch"];
      };
      # A revision target only: `release` would move the pin onto upstream tags,
      # which carry none of the WASIX lane changes this source is pinned for.
      accepts = ["revision"];
      source = {
        kind = "github";
        owner = "malisper";
        repo = "pgrust";
      };
    };
    wasmer = {
      # A webc takes its published name from meta.mainProgram, which would put
      # this at `postgres`; postgresql already ships under that name.
      name = "pgrust";
      # toSemver refuses the four numeric components of 0-unstable-YYYY-MM-DD, so
      # a snapshot publishes its revision date as the patch component.
      version = v: let
        d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
      in
        assert lib.assertMsg (d != null) "pgrust: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${lib.concatStrings d}";
      entrypoint = "postgres";
      # postgresql holds the global `postgres` command.
      commands = [
        {
          name = "postgres";
          global = false;
        }
      ];
      # This is the contract the fork's own guest runners use: USER stands in for
      # the passwd database WASIX gives a guest no view of, and the two paths point
      # at the mounted share tree instead of the executable-relative default.
      env = {
        USER = "postgres";
        PGRUST_RUNTIME = "0";
        PGRUST_TZDIR = "/share/timezone";
        PGRUST_PGSHAREDIR = "/share";
      };
      # postgresql is declared PIC-only, so its share data cannot come from the
      # eh profile's own set. Mounting is enough: an `fs` entry copies the store
      # path into this webc, while `dependencies` means a package this one execs,
      # whose command atoms wasmer places at /bin -- and postgresql owns the
      # global `postgres` name this manifest avoids.
      #
      # Two sibling mounts rather than the whole share, because that share carries
      # `timezonesets` but no zone files: the compiled zones are tzdata's, and
      # PGRUST_TZDIR is read as a sibling of the PGRUST_PGSHAREDIR parent. Without
      # them the guest logs `could not open directory "/share/timezone"`, rejects
      # both the `log_timezone` and `TimeZone` parameters, and exits on a conf-file
      # error before any statement runs.
      fs."/share/timezone" = "${packages.sameProfile.buildPackages.tzdata}/share/zoneinfo";
      fs."/share/timezonesets" = "${packages.wasix.preferred.postgresql}/share/postgresql/timezonesets";
    };
  };

  meta = {
    mainProgram = "postgres";
    description = "Rust rewrite of PostgreSQL, serving pgwire from one WASIX instance";
    homepage = "https://pgrust.com";
    license = lib.licenses.agpl3Only;
  };
})
