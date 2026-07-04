# Memory breakdown + standby-list purge (RAMMap-lite).
# Breakdown: perf counters, no admin. Purge: NtSetSystemInformation, admin only,
# and only ever invoked manually (shipd free / dashboard 'f') — never by scheduled tasks.

Add-Type -Namespace Win32 -Name Memory -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(int infoClass, ref int info, int length);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool LookupPrivilegeValue(string host, string name, out long luid);
[StructLayout(LayoutKind.Sequential, Pack = 1)]  // Pack=1: Luid must sit at offset 4 (DWORD + LUID + DWORD)
public struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attr; }
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int len, IntPtr prev, IntPtr ret);
'@

function Get-MemoryBreakdown {
    # counter names are English; on localized Windows this fails -> $null, callers degrade
    try {
        $s = (Get-Counter -ErrorAction Stop -Counter @(
                '\Memory\Standby Cache Normal Priority Bytes'
                '\Memory\Standby Cache Reserve Bytes'
                '\Memory\Standby Cache Core Bytes'
                '\Memory\Modified Page List Bytes'
                '\Memory\Free & Zero Page List Bytes'
            )).CounterSamples
    }
    catch { return $null }
    $standby  = ($s | Where-Object Path -like '*standby*' | Measure-Object CookedValue -Sum).Sum
    $modified = ($s | Where-Object Path -like '*modified*').CookedValue
    $free     = ($s | Where-Object Path -like '*free & zero*').CookedValue
    $total    = (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize * 1KB
    [pscustomobject]@{
        total    = [math]::Round($total / 1GB, 2)
        in_use   = [math]::Round(($total - $standby - $modified - $free) / 1GB, 2)
        standby  = [math]::Round($standby / 1GB, 2)
        modified = [math]::Round($modified / 1GB, 2)
        free     = [math]::Round($free / 1GB, 2)
    }
}

function Clear-StandbyList {
    # requires elevation; enables SeProfileSingleProcessPrivilege, then
    # SystemMemoryListInformation(80) / MemoryPurgeStandbyList(4) — same call RAMMap makes
    $before = Get-MemoryBreakdown
    $token = [IntPtr]::Zero
    $procH = [System.Diagnostics.Process]::GetCurrentProcess().Handle
    if (-not [Win32.Memory]::OpenProcessToken($procH, 0x28, [ref]$token)) {  # ADJUST_PRIVILEGES|QUERY
        throw 'OpenProcessToken failed'
    }
    $luid = [long]0
    [void][Win32.Memory]::LookupPrivilegeValue($null, 'SeProfileSingleProcessPrivilege', [ref]$luid)
    $tp = New-Object 'Win32.Memory+TOKEN_PRIVILEGES'
    $tp.Count = 1; $tp.Luid = $luid; $tp.Attr = 2  # SE_PRIVILEGE_ENABLED
    [void][Win32.Memory]::AdjustTokenPrivileges($token, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    $cmd = 4
    $status = [Win32.Memory]::NtSetSystemInformation(80, [ref]$cmd, 4)
    if ($status -ne 0) { throw ('NtSetSystemInformation failed: 0x{0:X8} (not elevated?)' -f $status) }
    $after = Get-MemoryBreakdown
    if ($before -and $after) { [math]::Round([math]::Max(0, $before.standby - $after.standby), 2) } else { [double]0 }
}
