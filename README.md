# wasinix — pgrust WASIX package contribution

This repository holds the **pgrust** package for [wasinix](https://github.com/wasix-org/wasinix)
(WASIX packages built with Nix), published as a standalone, public drop-in set.

It is hosted here because write access to the upstream `wasinix` repository is
currently unavailable. These are the two overlay directories that a wasinix
maintainer can drop into `pkgs/overlays/` and open the pull request from.
Nothing else from the wasinix corpus is reproduced here.

## Layout

```
pkgs/overlays/p/pgrust/
    wasix.nix                     # the WASIX package definition
    patches/wasix-lane.patch      # the WASIX compat lane, applied at build time
    tests/basic.nix               # --single leg (boot, DDL/DML, error, clean shutdown)
    tests/pgwire.nix              # server leg (TCP/pgwire, threaded backends)
pkgs/overlays/w/wasix-rust-std-unwind/
    package.nix                   # unwind-capable std for the WASIX Rust targets
```

wasinix discovers overlays by directory, so both paths register automatically —
no separate registry edit is needed.

## What the package builds

pgrust is a Rust rewrite of PostgreSQL 18.6. Only the **WASIX lane** is packaged:
the socket, epoll and accept-loop changes that let the postmaster hand each
pgwire connection its own backend thread, and the signal installs that let it
take a termination signal. No public revision of the source carries those
changes, so the lane arrives as a patch applied over a pinned, pristine
upstream revision:

- source: `malisper/pgrust` @ `79ad992ede22bcf6ae0c4fdead6fb01eeac5a990`
- patch: `patches/wasix-lane.patch` — applied with `patch -p1` (verified to apply
  clean at `--fuzz=0` against that exact revision)

The lane links with `panic=unwind`, so the build consumes the unwind-capable
sysroot from `pkgs/overlays/w/wasix-rust-std-unwind`.

## Relationship to the rust fork

`wasix-rust-std-unwind` rebuilds `std` with unwinding enabled because the fork's
wasm base spec defaults the WASIX Rust targets to `panic=abort`. That rebuild is
a **workaround**, not the intended end state: once the fork sets
`panic_strategy = PanicStrategy::Unwind` directly on
`wasm32_wasmer_wasi` (and its `-dl` sibling), the toolchain's own std unwinds,
the crate resolves `panic_unwind` against it, and this whole package is no longer
needed. See the companion `rust` fork change for that one-field fix.

## Companion changes

This package depends on work that lives in other repositories and is **not**
contained here:

- the **rust** fork: `panic_strategy = Unwind` on the `wasm32-wasmer-wasi` target
  spec (the fix that lets `wasix-rust-std-unwind` eventually go away)
- the **pgrust** lane branch (`lane/wasix-compat`): the source of
  `patches/wasix-lane.patch`
- the **wasmer** and **wasix-libc** fixes the guest relies on at runtime
  (fd_sync directory flush, thread-spawn range, epoll prune-on-close, host→guest
  signal relay, task-pool bound, and the `make_absolute` TLS race)

## Status

- The package builds and the two test legs pass on the build box.
- Publishing the built module as a webc on wasmer.io is **not yet done**.

## License

pgrust is AGPL-3.0-only; `wasix-rust-std-unwind` inherits the Rust toolchain's
MIT / Apache-2.0 licensing. Each file carries its own `meta.license`.
