# Run clang-tidy code quality checks

# Check if clang-tidy is available
$clangTidy = $null
if (Get-Command clang-tidy -ErrorAction SilentlyContinue) {
    $clangTidy = 'clang-tidy'
} elseif (Test-Path 'C:\Program Files\LLVM\bin\clang-tidy.exe') {
    $clangTidy = 'C:\Program Files\LLVM\bin\clang-tidy.exe'
}

if ($clangTidy) {
    Write-Host "Using clang-tidy: $clangTidy" -ForegroundColor Green
    Get-ChildItem -Path 'client/src','editor/src','editor/include','engine/src','engine/include' -Recurse -Include '*.c','*.h','*.cpp','*.hpp' | ForEach-Object {
        Write-Host "Checking: $($_.Name)" -ForegroundColor Cyan
        & $clangTidy --config-file=.clang-tidy --header-filter=.* $_.FullName
    }
    Write-Host "Code quality check completed!" -ForegroundColor Green
} else {
    Write-Host "clang-tidy not found. Please install LLVM/Clang tools or add to PATH." -ForegroundColor Red
    Write-Host "Download from: https://releases.llvm.org/" -ForegroundColor Yellow
}