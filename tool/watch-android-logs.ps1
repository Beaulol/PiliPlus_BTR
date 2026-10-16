param(
    [ValidateSet('release', 'debug', 'both')][string]$Mode = 'both',
    [string]$Device = '',
    [switch]$Background
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'local-build-env.ps1')
if (!$taskAdbExecutable) { throw 'ADB is not configured in PATH' }
$taskAdb = $taskAdbExecutable
$taskDeviceArgs = if ($Device) { @('-s', $Device) } else { @('-d') }
$taskPackages = switch ($Mode) {
    'release' { @('com.example.piliplus') }
    'debug' { @('com.example.piliplus.debug') }
    'both' { @('com.example.piliplus', 'com.example.piliplus.debug') }
}
$taskUids = @()
foreach ($taskPackage in $taskPackages) {
    $taskResult = & $taskAdb @taskDeviceArgs shell cmd package list packages -U $taskPackage
    if ($LASTEXITCODE -ne 0) { throw 'Cannot query installed applications; check USB authorization' }
    foreach ($taskLine in $taskResult) {
        if ($taskLine -match ('^package:' + [regex]::Escape($taskPackage) + '\s+uid:(\d+)\s*$')) {
            $taskUids += $Matches[1]
        }
    }
}
if (!$taskUids.Count) { throw 'No matching BTR application is installed' }
$taskUids = @($taskUids | Select-Object -Unique)
$taskLogDir = if ($env:BTR_LOG_DIR) { $env:BTR_LOG_DIR } else { Join-Path $taskWorkspace 'logs' }
New-Item -ItemType Directory -Force -Path $taskLogDir | Out-Null
$taskLogFile = Join-Path $taskLogDir ("btr-$Mode-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
# Filter by application UID, so process restarts do not require a new capture.
# Read only new records; do not clear the device's system log buffers.
$taskLogArgs = $taskDeviceArgs + @('logcat', "--uid=$($taskUids -join ',')", '-v', 'threadtime', '-T', '1', 'flutter:I', 'AndroidRuntime:E', '*:S')
if ($Background) {
    $taskProcess = Start-Process -FilePath $taskAdb -ArgumentList $taskLogArgs `
        -WindowStyle Hidden -RedirectStandardOutput $taskLogFile `
        -RedirectStandardError ($taskLogFile + '.stderr') -PassThru
    Write-Output "Capture PID: $($taskProcess.Id)"
    Write-Output "Log: $taskLogFile"
    Write-Output "Stop: Stop-Process -Id $($taskProcess.Id)"
} else {
    Write-Output "Log: $taskLogFile (Ctrl+C to stop)"
    & $taskAdb @taskLogArgs | Tee-Object -FilePath $taskLogFile
}
