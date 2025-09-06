# Compile all shaders script
# This script compiles all GLSL shaders to SPIR-V format

Write-Host "Compiling shaders..."

# Set working directory to assets/shaders
Set-Location "assets\shaders"

# Get username for output path
$username = $env:USERNAME
$outputDir = "C:\Users\$username\Documents\Cardinal\assets\shaders"

# Ensure output directory exists
if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force
}

# Compile PBR shaders
Write-Host "Compiling PBR vertex shader..."
glslc pbr.vert -o "$outputDir\pbr.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ PBR vertex shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile PBR vertex shader"
}

Write-Host "Compiling PBR fragment shader..."
glslc pbr.frag -o "$outputDir\pbr.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ PBR fragment shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile PBR fragment shader"
}

# Compile UV shaders
Write-Host "Compiling UV vertex shader..."
glslc uv.vert -o "$outputDir\uv.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ UV vertex shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile UV vertex shader"
}

Write-Host "Compiling UV fragment shader..."
glslc uv.frag -o "$outputDir\uv.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ UV fragment shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile UV fragment shader"
}

# Compile wireframe shaders
Write-Host "Compiling wireframe vertex shader..."
glslc wireframe.vert -o "$outputDir\wireframe.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Wireframe vertex shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile wireframe vertex shader"
}

Write-Host "Compiling wireframe fragment shader..."
glslc wireframe.frag -o "$outputDir\wireframe.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "✓ Wireframe fragment shader compiled successfully"
} else {
    Write-Host "✗ Failed to compile wireframe fragment shader"
}

Write-Host "Shader compilation complete!"

# Return to original directory
Set-Location "..\.."