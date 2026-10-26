# Regenerates the Windows-host link stubs for the OHOS system libraries.
#
# Why this exists: the OHOS *-sys binding crates declare
# `#[link(name = "ace_ndk.z")]`-style dependencies on device-only system
# libraries. Linking this workspace on a Windows host (cargo test /
# doctests) fails with LNK1181 "cannot open input file" before any Rust
# code runs. This script fabricates the expected import names:
#
#   - one empty archive per requested name (satisfies the link line,
#     provides no symbols);
#   - ohos-host-stubs.lib  - all ArkUI/native symbols listed in
#     symbols_round1.txt/symbols_round2.txt, compiled from stubs.rs;
#   - ohinputmethod.lib    - copy of the host stub archive (the
#     ohos-input-method-sys `#[link]` name puts it on every host link, so
#     the ArkUI/IME stub symbols resolve through it);
#   - ohweb.lib            - ArkWeb symbols from stub-web.rs.
#
# Output: target/host-stub-libs/ (wired into host builds via the
# [target.x86_64-pc-windows-msvc] rustflags in .cargo/config.toml).
# Cross builds (aarch64/x86_64-unknown-linux-ohos) are unaffected.
#
# Idempotent: reruns rebuild every output from the checked-in sources.
# If a host link still reports unresolved `OH_*` symbols, append them to
# symbols_roundN.txt and rerun (see symbols_round1/2/3/4 for the round 1-4
# iteration records).

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$stubDir  = Join-Path $repoRoot "host-stubs"
$outDir   = Join-Path $repoRoot "target\host-stub-libs"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- locate MSVC lib.exe (archive tool) via vswhere -----------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe not found; install Visual Studio 2022 Build Tools (C++ workload)."
}
$libExe = & $vswhere -latest -products * -find '**\lib.exe' | Select-Object -First 1
if (-not $libExe) {
    throw "MSVC lib.exe not found; install the Visual Studio C++ toolset."
}
Write-Host "using lib.exe: $libExe"

function Invoke-RustcObj([string]$Source, [string]$ObjOut) {
    & rustc --edition 2021 --crate-type lib --emit=obj `
        -C codegen-units=1 -C opt-level=0 `
        $Source "-o" $ObjOut
    if ($LASTEXITCODE -ne 0) { throw "rustc failed for $Source" }
}

function Invoke-LibArchive([string]$Obj, [string]$LibOut) {
    & $libExe /NOLOGO ("/OUT:" + $LibOut) $Obj
    if ($LASTEXITCODE -ne 0) { throw "lib.exe failed for $LibOut" }
}

# --- 1. empty per-name archives -------------------------------------------
# Compile one empty object, then archive it under every link name the
# binding crates request. Content never matters for these; existence does.
$emptyRs  = Join-Path $outDir "empty.rs"
$emptyObj = Join-Path $outDir "empty.obj"
Set-Content -Path $emptyRs -Value "" -Encoding ascii
Invoke-RustcObj $emptyRs $emptyObj

$emptyNames = @(
    "ace_ndk.z", "image_ndk.z", "image_packer", "image_packer_ndk.z",
    "image_receiver", "image_receiver_ndk.z", "image_source",
    "image_source_ndk.z", "native_buffer", "native_display_manager",
    "native_drawing", "ohimage", "ohresmgr", "picture", "pixelmap",
    "pixelmap_ndk.z", "rawfile.z", "udmf", "hilog_ndk.z"
)
foreach ($n in $emptyNames) {
    Invoke-LibArchive $emptyObj (Join-Path $outDir ($n + ".lib"))
}
Write-Host ("empty stub archives written: " + $emptyNames.Count)

# --- 2. ArkUI/native symbol archive (stubs.rs) ----------------------------
$stubsObj = Join-Path $outDir "stubs.obj"
Invoke-RustcObj (Join-Path $stubDir "stubs.rs") $stubsObj
$hostStubsLib = Join-Path $outDir "ohos-host-stubs.lib"
Invoke-LibArchive $stubsObj $hostStubsLib

# ohinputmethod is the `#[link]` name ohos-input-method-sys puts on every
# host link; ship the full stub archive under that name so the ArkUI/IME
# extern symbols resolve.
Copy-Item $hostStubsLib (Join-Path $outDir "ohinputmethod.lib") -Force
Write-Host "ohos-host-stubs.lib + ohinputmethod.lib written"

# --- 3. ArkWeb symbol archive (stub-web.rs) --------------------------------
$webObj = Join-Path $outDir "stub-web.obj"
Invoke-RustcObj (Join-Path $stubDir "stub-web.rs") $webObj
Invoke-LibArchive $webObj (Join-Path $outDir "ohweb.lib")
Write-Host "ohweb.lib written"

Write-Host "host stubs regenerated in $outDir"
