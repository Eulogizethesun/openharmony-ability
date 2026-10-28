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
#   - ohos-host-stubs.lib  - all ArkUI/native symbols compiled from stubs.rs
#     (full symbol set recorded across symbols_round1-5.txt);
#   - ohinputmethod.lib    - copy of the host stub archive (the
#     ohos-input-method-sys `#[link]` name puts it on every host link, so
#     the ArkUI/IME stub symbols resolve through it);
#   - ohweb.lib            - ArkWeb symbols from stub-web.rs (recorded in
#     symbols_web.txt).
#
# Output: target/host-stub-libs/ (wired into host builds via the
# [target.x86_64-pc-windows-msvc] rustflags in .cargo/config.toml).
# Cross builds (aarch64/x86_64-unknown-linux-ohos) are unaffected.
#
# Idempotent: reruns rebuild every output from the checked-in sources.
#
# New unresolved `OH_*` symbol (LNK2019): add
# `#[no_mangle] extern "C" fn <SymbolName>() {}` DIRECTLY to stubs.rs
# (ArkUI/IME/XComponent/dlopen/hilog/resource-manager family) or stub-web.rs
# (ArkWeb family), then rerun this script. It compiles those two sources into
# the archives - it NEVER reads the symbols_roundN.txt / symbols_web.txt files;
# those are documentation records only, and this script diff-verifies them
# against the sources on every run (update the record in the same change or the
# script fails with a drift error). See host-stubs/README.md for the full
# workflow.

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

# --- 0. symbol-record drift check -------------------------------------------
# The symbols_round*.txt / symbols_web.txt records are documentation of what
# each stub source covers. This script never consumes them for building, but it
# DOES verify they match the sources, so a symbol added to stubs.rs without
# updating the records fails here instead of silently rotting the docs.
function Get-StubSymbols([string]$Source) {
    $names = Select-String -Path $Source -Pattern 'extern "C" fn (\w+)\(' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    if (-not $names -or @($names).Count -eq 0) {
        throw ('no extern "C" symbols found in ' + $Source)
    }
    return @($names)
}

function Assert-SymbolRecord([string[]]$Symbols, [string[]]$RecordPaths, [string]$SourceName) {
    $recorded = @()
    foreach ($path in $RecordPaths) {
        if (-not (Test-Path $path)) {
            throw "symbol record missing: $path (expected for $SourceName)"
        }
        $recorded += Get-Content $path | Where-Object { $_.Trim() -ne "" }
    }
    $recorded = @($recorded | Sort-Object -Unique)
    $actual = @($Symbols | Sort-Object -Unique)
    $drift = Compare-Object -ReferenceObject $recorded -DifferenceObject $actual
    if ($drift) {
        $drift | ForEach-Object {
            $side = if ($_.SideIndicator -eq "<=") { "record-only" } else { "source-only" }
            Write-Host "  $side $($_.InputObject)"
        }
        throw "$SourceName symbols drifted from the symbols_round*/symbols_web records; update the record files in the same change"
    }
    Write-Host ("symbol records verified: " + $actual.Count + " symbols across " + $RecordPaths.Count + " record file(s) for " + $SourceName)
}

$stubSymbols = Get-StubSymbols (Join-Path $stubDir "stubs.rs")
Assert-SymbolRecord $stubSymbols @(
    (Join-Path $stubDir "symbols_round1.txt"),
    (Join-Path $stubDir "symbols_round2.txt"),
    (Join-Path $stubDir "symbols_round3.txt"),
    (Join-Path $stubDir "symbols_round4.txt"),
    (Join-Path $stubDir "symbols_round5.txt")
) "stubs.rs"
$webSymbols = Get-StubSymbols (Join-Path $stubDir "stub-web.rs")
Assert-SymbolRecord $webSymbols @((Join-Path $stubDir "symbols_web.txt")) "stub-web.rs"

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
