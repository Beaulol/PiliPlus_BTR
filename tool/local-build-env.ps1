# Machine-specific paths belong in an untracked environment file, not source.
$taskProjectRoot = Split-Path $PSScriptRoot -Parent
$taskWorkspace = Split-Path $taskProjectRoot -Parent
$taskEnvironmentFile = if ($env:BTR_BUILD_ENV) {
    $env:BTR_BUILD_ENV
} else {
    Join-Path $taskWorkspace '.tooling\build-env.ps1'
}
if (Test-Path -LiteralPath $taskEnvironmentFile) {
    . $taskEnvironmentFile
}
$taskFlutterExecutable = (Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
$taskFlutterRoot = if ($taskFlutterExecutable) {
    Split-Path (Split-Path $taskFlutterExecutable -Parent) -Parent
} else { $null }
$taskAdbExecutable = (Get-Command adb -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1).Source
