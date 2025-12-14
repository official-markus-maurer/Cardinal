# Compile all shaders script
# This script compiles all GLSL shaders to SPIR-V format

Write-Host "Compiling shaders..."

# Set working directory to assets/shaders
Set-Location "assets\shaders"

# Use project-relative output directory
$outputDir = (Get-Location).Path

# Ensure output directory exists
if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force
}

# Compile PBR shaders
Write-Host "Compiling PBR vertex shader..."
glslc --target-env=vulkan1.1 pbr.vert -o "$outputDir\pbr.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] PBR vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile PBR vertex shader"
}

Write-Host "Compiling PBR fragment shader..."
glslc --target-env=vulkan1.1 pbr.frag -o "$outputDir\pbr.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] PBR fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile PBR fragment shader"
}

# Compile UV shaders
Write-Host "Compiling UV vertex shader..."
glslc --target-env=vulkan1.1 uv.vert -o "$outputDir\uv.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] UV vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile UV vertex shader"
}

Write-Host "Compiling UV fragment shader..."
glslc --target-env=vulkan1.1 uv.frag -o "$outputDir\uv.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] UV fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile UV fragment shader"
}

# Compile wireframe shaders
Write-Host "Compiling wireframe vertex shader..."
glslc --target-env=vulkan1.1 wireframe.vert -o "$outputDir\wireframe.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Wireframe vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile wireframe vertex shader"
}

Write-Host "Compiling wireframe fragment shader..."
glslc --target-env=vulkan1.1 wireframe.frag -o "$outputDir\wireframe.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Wireframe fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile wireframe fragment shader"
}

# Compile mesh shaders
Write-Host "Compiling task shader..."
glslc task.task -o "$outputDir\task.task.spv" --target-spv=spv1.4
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Task shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile task shader"
}

Write-Host "Compiling mesh shader..."
glslc mesh.mesh -o "$outputDir\mesh.mesh.spv" --target-spv=spv1.4
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Mesh shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile mesh shader"
}

Write-Host "Compiling mesh fragment shader..."
glslc --target-env=vulkan1.1 mesh.frag -o "$outputDir\mesh.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Mesh fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile mesh fragment shader"
}

Write-Host "Shader compilation complete!"

# Return to original directory
Set-Location "..\.."