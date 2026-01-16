# Compile all shaders script
# This script compiles all GLSL shaders to SPIR-V format

$projectRoot = Resolve-Path "$PSScriptRoot\.."
Write-Host "Compiling shaders..."

# Set working directory to assets/shaders
Set-Location "$projectRoot\assets\shaders"

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

# Compile Shadow shaders
Write-Host "Compiling shadow vertex shader..."
glslc --target-env=vulkan1.1 shadow.vert -o "$outputDir\shadow.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Shadow vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile shadow vertex shader"
}

Write-Host "Compiling shadow fragment shader..."
glslc --target-env=vulkan1.1 shadow.frag -o "$outputDir\shadow.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Shadow fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile shadow fragment shader"
}

Write-Host "Compiling shadow alpha fragment shader..."
glslc --target-env=vulkan1.1 shadow_alpha.frag -o "$outputDir\shadow_alpha.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Shadow alpha fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile shadow alpha fragment shader"
}

# Compile PostProcess shaders
Write-Host "Compiling PostProcess vertex shader..."
glslc --target-env=vulkan1.1 postprocess.vert -o "$outputDir\postprocess.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] PostProcess vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile PostProcess vertex shader"
}

Write-Host "Compiling PostProcess fragment shader..."
glslc --target-env=vulkan1.1 postprocess.frag -o "$outputDir\postprocess.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] PostProcess fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile PostProcess fragment shader"
}

# Compile Bloom shader
Write-Host "Compiling Bloom compute shader..."
glslc --target-env=vulkan1.1 bloom.comp -o "$outputDir\bloom.comp.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Bloom compute shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile Bloom compute shader"
}

Write-Host "Compiling skybox vertex shader..."
glslc --target-env=vulkan1.1 skybox.vert -o "$outputDir\skybox.vert.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Skybox vertex shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile skybox vertex shader"
}

Write-Host "Compiling skybox fragment shader..."
glslc --target-env=vulkan1.1 skybox.frag -o "$outputDir\skybox.frag.spv"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Skybox fragment shader compiled successfully"
} else {
    Write-Host "[ERROR] Failed to compile skybox fragment shader"
}

Write-Host "Shader compilation complete!"

# Return to original directory
Set-Location $projectRoot