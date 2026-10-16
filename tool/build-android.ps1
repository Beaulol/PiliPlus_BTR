param(
    [ValidateSet('debug', 'release')][string]$Mode = 'debug',
    [switch]$Install,
    [string]$Device = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-build-env.ps1')
if (!$taskFlutterExecutable) { throw 'Flutter is not configured in PATH' }
Push-Location (Split-Path $PSScriptRoot)
try {
    & $taskFlutterExecutable pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & "$PSScriptRoot\prepare-flutter.ps1"
    if ($Mode -eq 'release' -and !(Test-Path 'android\key.properties')) {
        throw 'Release signing is not configured: android/key.properties is required'
    }
    & $taskFlutterExecutable build apk "--$Mode" --target-platform android-arm64 --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed' }
    $taskApk = Join-Path (Get-Location) "build\app\outputs\flutter-apk\app-$Mode.apk"
    Write-Output "APK: $taskApk"
    if ($Install) {
        if (!$taskAdbExecutable) { throw 'ADB is not configured in PATH' }
        $taskAdb = $taskAdbExecutable
        if ($Device) { & $taskAdb -s $Device install -r $taskApk }
        else { & $taskAdb -d install -r $taskApk }
        if ($LASTEXITCODE -ne 0) { throw 'APK install failed' }
    }
} finally {
    Pop-Location
}
