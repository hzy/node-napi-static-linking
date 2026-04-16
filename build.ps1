# build.ps1 - Build Node.js with simple-napi statically linked in (Windows).
#
# Usage:
#   .\build.ps1            # full build
#   .\build.ps1 -Clean     # clean and rebuild
#
# Prerequisites:
#   - Visual Studio 2022+ with C++ and Clang tools
#   - Python 3
#   - Node.js (for building simple-napi via node-gyp)
#   - Git
#   - NASM (for OpenSSL asm support, or use openssl-no-asm)

param(
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$RootDir = $PSScriptRoot
$NodeDir = Join-Path $RootDir "deps\node"
$PatchesDir = Join-Path $RootDir "patches"
$AddonDir = Join-Path $RootDir "simple-napi"
$AddonLib = Join-Path $AddonDir "build\Release\simple_napi_static.lib"
$OutputBin = Join-Path $RootDir "build\node.exe"

function Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# ── Clean ────────────────────────────────────────────────────────────
if ($Clean) {
    Info "Cleaning..."
    if (Test-Path (Join-Path $RootDir "build")) {
        Remove-Item -Recurse -Force (Join-Path $RootDir "build")
    }
    Push-Location $AddonDir
    try { npx node-gyp clean 2>$null } catch {}
    Pop-Location
    if (Test-Path $NodeDir) {
        Push-Location $NodeDir
        try { git reset --hard HEAD 2>$null } catch {}
        Pop-Location
    }
    Info "Done."
    exit 0
}

# ── 1. Ensure Node.js submodule ──────────────────────────────────────
Info "Step 1: Node.js source"
if (-not (Test-Path (Join-Path $NodeDir "configure"))) {
    git -C $RootDir submodule update --init --depth 1 deps/node
    if ($LASTEXITCODE -ne 0) { Err "Failed to init submodule" }
}

# ── 2. Apply patches ────────────────────────────────────────────────
Info "Step 2: Applying patches"
Get-ChildItem -Path $PatchesDir -Filter "*.patch" | ForEach-Object {
    $patchFile = $_.FullName
    $subject = (Select-String -Path $patchFile -Pattern "^Subject: \[PATCH\] (.+)$" |
                Select-Object -First 1).Matches.Groups[1].Value

    $logOutput = git -C $NodeDir log --oneline 2>&1 | Out-String
    if ($logOutput -match [regex]::Escape($subject)) {
        Info "  Already applied: $($_.Name)"
    } else {
        Info "  Applying: $($_.Name)"
        git -C $NodeDir am --3way $patchFile
        if ($LASTEXITCODE -ne 0) { Err "Failed to apply $($_.Name)" }
    }
}

# ── 3. Build simple-napi static library ──────────────────────────────
Info "Step 3: Building simple-napi"
Push-Location $AddonDir
if (-not (Test-Path (Join-Path $AddonDir "node_modules"))) {
    npm install
    if ($LASTEXITCODE -ne 0) { Err "npm install failed" }
}
if (-not (Test-Path $AddonLib)) {
    npx node-gyp rebuild
    if ($LASTEXITCODE -ne 0) { Err "node-gyp rebuild failed" }
}
Pop-Location
Info "  Built: $AddonLib"

# ── 4. Configure + Build Node.js ────────────────────────────────────
Info "Step 4: Building Node.js (this takes a long time)..."
Push-Location $NodeDir

# vcbuild.bat picks up extra configure flags from the config_flags env var.
$env:config_flags = "--link-napi-addon `"simple_napi:$AddonLib`""

# Build with vcbuild.bat: nonpm to skip npm, noprojgen will be skipped
# since we need configure to run with our flag.
cmd /c "vcbuild.bat release nonpm"
if ($LASTEXITCODE -ne 0) { Err "vcbuild failed" }

Pop-Location

# ── 5. Copy binary ──────────────────────────────────────────────────
Info "Step 5: Output binary"
$outDir = Join-Path $RootDir "build"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

# vcbuild.bat creates a junction: Release\ -> out\Release\
$builtNode = Join-Path $NodeDir "Release\node.exe"
if (-not (Test-Path $builtNode)) {
    $builtNode = Join-Path $NodeDir "out\Release\node.exe"
}
Copy-Item $builtNode $OutputBin -Force

# ── 6. Smoke test ───────────────────────────────────────────────────
Info "Step 6: Smoke test"
$testScript = @"
const m = process._linkedBinding('simple_napi');
console.log('hello():', m.hello());
console.log('add(3, 4):', m.add(3, 4));
console.log('fibonacci(10):', m.fibonacci(10));
console.assert(m.hello() === 'Hello from N-API!');
console.assert(m.add(3, 4) === 7);
console.assert(m.fibonacci(10) === 55);
console.log('All tests passed!');
"@

& $OutputBin -e $testScript
if ($LASTEXITCODE -ne 0) { Err "Smoke test failed" }

$version = & $OutputBin --version
$size = (Get-Item $OutputBin).Length / 1MB
Info ""
Info "=== Done ==="
Info "Binary: $OutputBin ($version, $([math]::Round($size, 1)) MB)"
Info ""
Info "Usage:"
Info "  $OutputBin -e `"const m = process._linkedBinding('simple_napi'); console.log(m.hello())`""
