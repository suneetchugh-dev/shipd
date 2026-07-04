# shipd — daily dev + activity report.
# Usage: shipd [dashboard] | snapshot | report [date] | list | install | schedule | start | stop | restart | unschedule
# No command = dashboard.
param(
    [Parameter(Position = 0)]
    [ValidateSet('dashboard', 'snapshot', 'report', 'list', 'install', 'schedule', 'start', 'stop', 'restart', 'unschedule')]
    [string]$Command = 'dashboard',
    [Parameter(Position = 1)][datetime]$Date = (Get-Date)
)

$config = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'git_scan.ps1')
. (Join-Path $PSScriptRoot 'activity.ps1')
. (Join-Path $PSScriptRoot 'report.ps1')
. (Join-Path $PSScriptRoot 'dashboard.ps1')
$logPath = Join-Path $PSScriptRoot 'snapshots.jsonl'
$reportsDir = Join-Path $PSScriptRoot 'reports'

switch ($Command) {

    'dashboard' {
        Show-LiveDashboard -Config $config -LogPath $logPath
    }

    'snapshot' {
        $snap = Get-ActivitySnapshot $config
        ($snap | ConvertTo-Json -Compress) | Add-Content $logPath
        Write-Output "snapshot saved: focused=$($snap.focused) idle=$($snap.idle_seconds)s games=$($snap.games_running -join ',')"
    }

    'report' {
        $data = Get-ReportData -Config $config -Date $Date -LogPath $logPath
        Show-Dashboard $data
        New-Item -ItemType Directory -Force $reportsDir | Out-Null
        Format-ReportText $data | Set-Content (Join-Path $reportsDir "$($data.Day).txt")
    }

    'install' {
        # CurrentUserAllHosts so it works in Windows Terminal AND the VS Code terminal
        $profilePath = $PROFILE.CurrentUserAllHosts
        if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force $profilePath | Out-Null }
        if ((Get-Content $profilePath -Raw) -notmatch 'function shipd') {
            Add-Content $profilePath "`nfunction shipd { & '$PSCommandPath' @args }"
        }
        Write-Output "installed: open a NEW terminal, then run 'shipd report' from any folder"
    }

    'list' {
        if (Test-Path $reportsDir) {
            Get-ChildItem $reportsDir -Filter '*.txt' | Sort-Object Name | ForEach-Object { Write-Output $_.Name }
        }
        else { Write-Output 'no saved reports yet' }
    }

    { $_ -in 'schedule', 'restart' } {
        # Launch via wscript+hidden.vbs: console tasks flash a window even with -WindowStyle Hidden,
        # and S4U/background tasks can't see the foreground window or idle time.
        $exe = (Get-Command pwsh).Source
        $wscript = Join-Path $env:windir 'System32\wscript.exe'
        $vbs = Join-Path $PSScriptRoot 'hidden.vbs'
        $mins = $config.snapshot_interval_minutes
        $snapTrig = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $mins) -RepetitionDuration (New-TimeSpan -Days 3650)
        Register-ScheduledTask -TaskName 'shipd snapshot' -Force -Trigger $snapTrig -Action (
            New-ScheduledTaskAction -Execute $wscript -Argument "//B //Nologo `"$vbs`" `"$exe`" -NoProfile -File `"$PSCommandPath`" snapshot") | Out-Null
        Register-ScheduledTask -TaskName 'shipd report' -Force -Trigger (New-ScheduledTaskTrigger -Daily -At $config.report_time) -Action (
            New-ScheduledTaskAction -Execute $wscript -Argument "//B //Nologo `"$vbs`" `"$exe`" -NoProfile -File `"$PSCommandPath`" report") | Out-Null
        Write-Output "shipd running: snapshot every $mins min, report daily at $($config.report_time) -> reports\<date>.txt"
    }

    'stop' {
        $t = @(Get-ScheduledTask -TaskName 'shipd snapshot', 'shipd report' -ErrorAction SilentlyContinue)
        if (-not $t.Count) { Write-Output 'nothing to stop (not scheduled — run: .\shipd.ps1 schedule)' }
        else { $t | Disable-ScheduledTask | Out-Null; Write-Output 'shipd stopped (tasks kept, disabled — resume with: .\shipd.ps1 start)' }
    }

    'start' {
        $t = @(Get-ScheduledTask -TaskName 'shipd snapshot', 'shipd report' -ErrorAction SilentlyContinue)
        if ($t.Count -eq 2) { $t | Enable-ScheduledTask | Out-Null; Write-Output 'shipd started (tasks enabled)' }
        else { & $PSCommandPath schedule }  # missing/partial -> (re)register
    }

    'unschedule' {
        'shipd snapshot', 'shipd report' | ForEach-Object {
            Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Output 'shipd scheduled tasks removed'
    }
}
exit 0  # don't leak $LASTEXITCODE from git probes on odd repos