# Master formatting script for Cardinal Engine
# Formats both Zig and C/C++ code

$projectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $projectRoot

# --- Zig Formatting ---
Write-Host "--- Formatting Zig Code ---" -ForegroundColor Magenta

$zig = "zig"
if (Get-Command $zig -ErrorAction SilentlyContinue) {
    $zigPaths = @("client/src", "editor/src", "engine/src", "build.zig")
    
    foreach ($path in $zigPaths) {
        if (Test-Path $path) {
            Write-Host "Formatting Zig: $path" -ForegroundColor Cyan
            & $zig fmt $path
        } else {
            Write-Host "Skipping missing Zig path: $path" -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "Zig executable not found in PATH. Skipping Zig formatting." -ForegroundColor Red
}

Write-Host ""

# --- C/C++ Formatting ---
Write-Host "--- Formatting C/C++ Code ---" -ForegroundColor Magenta

$clangFormat = $null
if (Get-Command clang-format -ErrorAction SilentlyContinue) {
    $clangFormat = 'clang-format'
} elseif (Test-Path 'C:\Program Files\LLVM\bin\clang-format.exe') {
    $clangFormat = 'C:\Program Files\LLVM\bin\clang-format.exe'
}

if ($clangFormat) {
    Write-Host "Using clang-format: $clangFormat" -ForegroundColor Green
    
    # Only include paths that actually exist to avoid Get-ChildItem errors
    $cppPaths = @('client/src', 'editor/src', 'editor/include', 'engine/src', 'engine/include')
    $existingCppPaths = @()
    
    foreach ($path in $cppPaths) {
        if (Test-Path $path) {
            $existingCppPaths += $path
        }
    }
    
    if ($existingCppPaths.Count -gt 0) {
        Get-ChildItem -Path $existingCppPaths -Recurse -Include '*.c','*.h','*.cpp','*.hpp' | ForEach-Object {
            & $clangFormat -i --style=file $_.FullName
            Write-Host "Formatted C++: $($_.Name)" -ForegroundColor Cyan
        }
    }
} else {
    Write-Host "clang-format not found. Skipping C/C++ formatting." -ForegroundColor Yellow
}

Write-Host "`nCode formatting completed!" -ForegroundColor Green
