# Format C/C++ code using clang-format

# Check if clang-format is available
$clangFormat = $null
if (Get-Command clang-format -ErrorAction SilentlyContinue) {
    $clangFormat = 'clang-format'
} elseif (Test-Path 'C:\Program Files\LLVM\bin\clang-format.exe') {
    $clangFormat = 'C:\Program Files\LLVM\bin\clang-format.exe'
}

if ($clangFormat) {
    Write-Host "Using clang-format: $clangFormat" -ForegroundColor Green
    Get-ChildItem -Path 'client/src','editor/src','editor/include','engine/src','engine/include' -Recurse -Include '*.c','*.h','*.cpp','*.hpp' | ForEach-Object {
        & $clangFormat -i --style=file $_.FullName
        Write-Host "Formatted: $($_.Name)" -ForegroundColor Cyan
    }
    Write-Host "Code formatting completed!" -ForegroundColor Green
} else {
    Write-Host "clang-format not found. Please install LLVM/Clang tools or add to PATH." -ForegroundColor Red
    Write-Host "Download from: https://releases.llvm.org/" -ForegroundColor Yellow
}