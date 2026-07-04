# Report data + rendering. Terminal dashboard uses $PSStyle (pwsh 7 built-in, no deps);
# the saved reports\<date>.txt stays plain text.

function Get-ReportData {
    param($Config, [datetime]$Date, [string]$LogPath)
    $day = $Date.ToString('yyyy-MM-dd')

    $repos = @()
    foreach ($root in $Config.git_roots) {
        foreach ($repo in Find-Repos -Root $root) {
            $commits = @(Get-DayCommits -Repo $repo -Date $Date)
            if (-not $commits.Count) { continue }
            $repos += [pscustomobject]@{
                Path = $repo; Name = Split-Path $repo -Leaf
                Commits = $commits; NetLines = ($commits | Measure-Object NetLines -Sum).Sum
            }
        }
    }

    $snaps = @()
    if (Test-Path $LogPath) {
        # [datetime] cast: ConvertFrom-Json may give a DateTime or a string depending on PS version
        $snaps = @(Get-Content $LogPath | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { ([datetime]$_.timestamp).Date -eq $Date.Date })
    }

    [pscustomobject]@{
        Day       = $day
        Repos     = $repos
        Stats     = if ($day -eq (Get-Date).ToString('yyyy-MM-dd')) { Get-SystemStats } else { $null }
        Snaps     = $snaps
        Focus     = @($snaps | Group-Object focused | Sort-Object Count -Descending)
        IdleCount = @($snaps | Where-Object { $_.idle_seconds -ge $Config.idle_threshold_seconds }).Count
        Games     = @($snaps | ForEach-Object { $_.games_running } | Sort-Object -Unique)
    }
}

function Get-Bar {
    param([double]$Pct, [int]$Width = 12)
    $fill = [math]::Round([math]::Max(0, [math]::Min(100, $Pct)) / 100 * $Width)
    ('█' * $fill) + ('░' * ($Width - $fill))
}

function Show-Dashboard {
    param($Data)
    $s = $PSStyle
    $cy = $s.Foreground.Cyan; $ye = $s.Foreground.Yellow; $gr = $s.Foreground.Green
    $re = $s.Foreground.Red; $dim = $s.Foreground.BrightBlack; $b = $s.Bold; $r = $s.Reset
    $w = 64

    Write-Host ''
    Write-Host "$cy╭$('─' * ($w - 2))╮$r"
    Write-Host ("$cy│$r$b  {0,-$($w - 4)}$r$cy│$r" -f "SHIPD · daily report · $($Data.Day)")
    Write-Host "$cy╰$('─' * ($w - 2))╯$r"

    if ($Data.Stats) {
        $st = $Data.Stats
        $ramPct = $st.ram_used / $st.ram_total * 100
        $cpuCol = if ($st.cpu -ge 90) { $re } elseif ($st.cpu -ge 60) { $ye } else { $gr }
        $ramCol = if ($ramPct -ge 90) { $re } elseif ($ramPct -ge 70) { $ye } else { $gr }
        Write-Host "$ye SYSTEM$r"
        Write-Host ("   CPU  $cpuCol$(Get-Bar $st.cpu)$r {0,3}%          GPU  {1}" -f $st.cpu, $st.gpu)
        Write-Host ("   RAM  $ramCol$(Get-Bar $ramPct)$r $($st.ram_used)/$($st.ram_total) GB")
        Write-Host "   $dim$($st.disks -join '    ')$r"
        Write-Host ''
    }

    Write-Host "$ye GIT$r"
    if (-not $Data.Repos.Count) { Write-Host "$dim   no commits$r" }
    foreach ($repo in $Data.Repos) {
        $sign = if ($repo.NetLines -ge 0) { '+' } else { '' }
        Write-Host "   $b$($repo.Name)$r $dim· $($repo.Commits.Count) commit(s) · $sign$($repo.NetLines) lines$r"
        foreach ($c in $repo.Commits) {
            $msg = if ($c.Message.Length -gt 42) { $c.Message.Substring(0, 41) + '…' } else { $c.Message }
            $s2 = if ($c.NetLines -ge 0) { '+' } else { '' }
            Write-Host ("     $gr$($c.Hash)$r {0,-43} $dim{1,3}f {2,6}$r" -f $msg, $c.Files, "$s2$($c.NetLines)")
        }
    }
    Write-Host ''

    Write-Host "$ye ACTIVITY$r"
    if (-not $Data.Snaps.Count) { Write-Host "$dim   no snapshots$r" }
    else {
        $active = $Data.Snaps.Count - $Data.IdleCount
        Write-Host "   $($Data.Snaps.Count) snapshots · $gr$active active$r · $dim$($Data.IdleCount) idle$r"
        $max = ($Data.Focus | Measure-Object Count -Maximum).Maximum
        foreach ($g in $Data.Focus | Select-Object -First 8) {
            $name = if ($g.Name) { $g.Name } else { '(unknown)' }
            Write-Host ("   {0,-22} $cy$(Get-Bar ($g.Count / $max * 100) 16)$r {1}" -f $name, $g.Count)
        }
        if ($Data.Games.Count) { Write-Host "   ${re}games seen: $($Data.Games -join ', ')$r" }
    }
    Write-Host ''
}

function Format-ReportText {
    param($Data)
    $L = @("SHIPD REPORT  $($Data.Day)", ('=' * 64), '')

    if ($Data.Stats) {
        $st = $Data.Stats
        $L += 'SYSTEM'
        $L += "  CPU $($st.cpu)%   GPU $($st.gpu)   RAM $($st.ram_used)/$($st.ram_total) GB"
        $L += "  $($st.disks -join '   ')"
        $L += ''
    }

    $L += 'GIT'
    if (-not $Data.Repos.Count) { $L += '  no commits' }
    foreach ($repo in $Data.Repos) {
        $sign = if ($repo.NetLines -ge 0) { '+' } else { '' }
        $L += "  $($repo.Name)  ($($repo.Commits.Count) commits, $sign$($repo.NetLines) lines)  [$($repo.Path)]"
        foreach ($c in $repo.Commits) {
            $s2 = if ($c.NetLines -ge 0) { '+' } else { '' }
            $L += ('    {0}  {1,-50} {2,3} files {3,7}' -f $c.Hash, $c.Message, $c.Files, "$s2$($c.NetLines)")
        }
    }
    $L += ''

    $L += 'ACTIVITY'
    if (-not $Data.Snaps.Count) { $L += '  no snapshots' }
    else {
        $L += "  snapshots: $($Data.Snaps.Count) ($($Data.Snaps.Count - $Data.IdleCount) active, $($Data.IdleCount) idle)"
        foreach ($g in $Data.Focus) {
            $name = if ($g.Name) { $g.Name } else { '(unknown)' }
            $L += ('    {0,-24} {1}' -f $name, $g.Count)
        }
        if ($Data.Games.Count) { $L += "  games seen: $($Data.Games -join ', ')" }
    }
    $L
}
