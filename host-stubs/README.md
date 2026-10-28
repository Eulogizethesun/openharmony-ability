# host-stubs: Windows-host link stubs for OHOS system libraries

## Why this exists

The OHOS `*-sys` binding crates declare `#[link(name = "ace_ndk.z")]`-style
dependencies on device-only system libraries. Linking this workspace on a
Windows host (`cargo test`, doctests, `cargo test --no-run --workspace`) fails
before any Rust code runs:

- `LNK1181 "cannot open input file '<name>.lib'"` - the device library does not
  exist on the host at all.
- `LNK2019 "unresolved external symbol OH_*"` - the library shell exists but
  the symbol was never stubbed.

Rust `cargo check` does NOT link, so it succeeds silently without the stubs -
the failure only appears at test/doctest build time. The stubs are Windows-host
only; `aarch64-unknown-linux-ohos` / `x86_64-unknown-linux-ohos` cross builds
are unaffected, and the GitHub CI (ubuntu-latest, format + lint only) never
links host binaries, so no CI step is needed.

## Regenerate (one-time per clone, Windows host)

```powershell
powershell -ExecutionPolicy Bypass -File host-stubs/generate.ps1
```

Outputs land in `target/host-stub-libs/` and are wired into every host link via
the `[target.'cfg(all(target_os = "windows", target_env = "msvc"))']` rustflags
`-L native=target/host-stub-libs` in `.cargo/config.toml`. The script is
idempotent - rerunning rebuilds every output from the checked-in sources.

If you see `LNK1181` on a fresh clone, this script was not run yet - run it
before `cargo test`. Nothing in the workspace suggests it automatically.

## Adding a new unresolved symbol (LNK2019)

1. Add `#[no_mangle] extern "C" fn <SymbolName>() {}` directly to the stub
   source:
   - `stubs.rs` - the ArkUI/IME/XComponent/dlopen/hilog/resource-manager family
     (lands in `ohos-host-stubs.lib`, also copied to `ohinputmethod.lib`);
   - `stub-web.rs` - the ArkWeb scheme-handler/resource family (lands in
     `ohweb.lib`).
2. Rerun `generate.ps1` (the script compiles the two sources into the archives;
   it never reads the symbol record files).
3. Update the symbol record files **in the same change** - `generate.ps1`
   diff-verifies them against the sources and fails on drift:
   - `symbols_round<N>.txt` (one file per triage round) - merged, they must
     equal the full symbol set of `stubs.rs`;
   - `symbols_web.txt` - must equal the full symbol set of `stub-web.rs`.

## Files

| File | Purpose |
|------|---------|
| `generate.ps1` | Builds empty per-name archives + the two symbol archives into `target/host-stub-libs/` |
| `stubs.rs` | ArkUI/IME/XComponent/dlopen/hilog/resource-manager stub symbols (`ohos-host-stubs.lib`) |
| `stub-web.rs` | ArkWeb stub symbols (`ohweb.lib`) |
| `symbols_round1-5.txt` | Triage-round records of the `stubs.rs` symbol set (round 1/2 full ArkUI+IME sweeps, round 3 dlopen/dlsym/XComponent, round 4 resmgr family + ArkWeb scheme set + hilog, round 5 resmgr OpenRawFile/OpenRawFile64 completion) |
| `symbols_web.txt` | Record of the `stub-web.rs` symbol set |
