# Clone dependencies
$deps = @(
    @{ URL = "https://github.com/glfw/glfw.git"; Path = "libs/glfw"; Tag = "3.4" },
    @{ URL = "https://github.com/jkuhlmann/cgltf.git"; Path = "libs/cgltf"; Tag = "v1.15" },
    @{ URL = "https://github.com/nothings/stb.git"; Path = "libs/stb"; Tag = "master" },
    @{ URL = "https://github.com/gabime/spdlog.git"; Path = "libs/spdlog"; Tag = "v1.16.0" },
    @{ URL = "https://github.com/ocornut/imgui.git"; Path = "libs/imgui"; Tag = "docking" }
)

foreach ($dep in $deps) {
    if (-not (Test-Path $dep.Path)) {
        Write-Host "Cloning $($dep.URL)..."
        git clone --depth 1 --branch $dep.Tag $dep.URL $dep.Path
    } else {
        Write-Host "$($dep.Path) already exists."
    }
}
