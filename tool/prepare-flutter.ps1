# Apply the Android patches required by upstream's build workflow, without
# changing global Git config, resetting checkouts, or deleting shared caches.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-build-env.ps1')
if (!$taskFlutterExecutable) { throw 'Flutter is not configured in PATH' }
$taskProject = Split-Path $PSScriptRoot
$taskFlutter = $taskFlutterRoot
$taskSdkPatches = @(
    'modal_barrier', 'text_selection', 'mouse_cursor', 'image_anim',
    'layout_builder', 'navigation_drawer', 'popup_menu', 'fab',
    'null_safety_for_selectable_region', 'selectable_region', 'editable_text',
    'text_field', 'scroll_position', 'scrollable', 'scrollable_gesture',
    'draggable_scrollable_sheet', 'scaffold', 'text', 'text_painter',
    'sliver', 'refresh_indicator', 'double_tap_gesture', 'bottom_sheet_android',
    'scroll_view', 'navigator'
)
function Apply-TaskPatch([string]$target, [string]$patchPath) {
    & git -C $target apply --reverse --check $patchPath 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Output "Already applied: $patchPath"; return }
    & git -C $target apply --check $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Patch does not match: $patchPath" }
    & git -C $target apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Patch failed: $patchPath" }
    Write-Output "Applied: $patchPath"
}
foreach ($taskPatch in $taskSdkPatches) {
    Apply-TaskPatch $taskFlutter "$taskProject\lib\scripts\$taskPatch.patch"
}
$taskPackages = Get-Content "$taskProject\.dart_tool\package_config.json" -Raw | ConvertFrom-Json
$taskMaterial = $taskPackages.packages | Where-Object name -eq 'material_ui'
if (!$taskMaterial) { throw 'Run flutter pub get first' }
$taskMaterialPath = ([uri]$taskMaterial.rootUri).LocalPath
if (!$env:PUB_CACHE) { throw 'Configure PUB_CACHE in the local build environment first' }
$taskCacheRoot = [IO.Path]::GetFullPath($env:PUB_CACHE).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (![IO.Path]::GetFullPath($taskMaterialPath).StartsWith($taskCacheRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Material cache is outside the configured PUB_CACHE directory'
}
foreach ($taskPatch in @('modal_barrier_material', 'navigation_drawer',
    'popup_menu', 'fab', 'text_field', 'scaffold', 'refresh_indicator', 'tabs',
    'bottom_sheet_android')) {
    Apply-TaskPatch $taskMaterialPath "$taskProject\lib\scripts\material\$taskPatch.patch"
}
