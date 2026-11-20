# Measures the Windows machine it runs on, as main.rs does the others: for each line it reads, it writes one line of
# JSON with the machine's processors, its memory and disk in use, how busy its CPU and GPU were every 5 seconds over
# the last two minutes, its containers (none here) and its operating system. It stops when its input closes, which is
# how it's told that the service that started it has gone.
#
# It's PowerShell, which every Windows has, since a Windows machine has no Rust compiler to build main.rs with. CPU and
# GPU are measured every 5 seconds and the rest every 30, in the same loop that waits for a line, so a line is
# answered at once.

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Meter {
    // Each time is a FILETIME, 100 ns ticks in 64 bits.
    [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);

    [StructLayout(LayoutKind.Sequential)]
    public struct Memory {
        public uint Length, Load;
        public ulong Total, Available, PageTotal, PageAvailable, VirtualTotal, VirtualAvailable, ExtendedAvailable;
    }
    [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx(ref Memory memory);

    /// CPU time busy, and in all, since the machine started: GetSystemTimes' kernel time includes its idle time.
    public static ulong[] Ticks() {
        ulong idle, kernel, user;
        GetSystemTimes(out idle, out kernel, out user);
        ulong total = kernel + user;
        return new ulong[] { total - idle, total };
    }
}
"@

$keep = 24
$clock = [Diagnostics.Stopwatch]::StartNew()
$since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$cpu = New-Object System.Collections.Generic.List[int]
$gpu = New-Object System.Collections.Generic.List[int]
$memory = $null
$disk = $null
$last = $null

function Push($to, $sample) {
    if ($null -ne $sample) {
        $to.Add([Math]::Min(100, [int]$sample))
        if ($to.Count -gt $keep) { $to.RemoveRange(0, $to.Count - $keep) }
    }
}

# What Task Manager calls "In use": all memory, less what's available.
function Memory {
    $m = New-Object Meter+Memory
    $m.Length = [Runtime.InteropServices.Marshal]::SizeOf($m)
    if (-not [Meter]::GlobalMemoryStatusEx([ref]$m)) { return $null }
    @{ used = [long]($m.Total - $m.Available); total = [long]$m.Total }
}

# The system drive, in use and in use or free.
function Disk {
    $drive = New-Object IO.DriveInfo ($env:SystemDrive)
    $used = $drive.TotalSize - $drive.AvailableFreeSpace
    @{ used = [long]$used; total = [long]($used + $drive.AvailableFreeSpace) }
}

# The busiest GPU engine, as Task Manager's GPU column has it: each engine's utilisation, summed over the processes using it.
function Gpu {
    try {
        $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
    } catch { return $null }
    $busiest = $null
    foreach ($engine in ($samples | Group-Object { $_.InstanceName -replace '^pid_\d+_', '' })) {
        $busy = ($engine.Group | Measure-Object CookedValue -Sum).Sum
        if ($null -eq $busiest -or $busy -gt $busiest) { $busiest = $busy }
    }
    $busiest
}

function Measure-Cpu {
    $ticks = [Meter]::Ticks()
    $sample = $null
    if ($null -ne $last -and $ticks[1] -gt $last[1]) {
        $sample = [int](($ticks[0] - $last[0]) * 100 / ($ticks[1] - $last[1]))
    }
    Set-Variable -Name last -Value $ticks -Scope Script
    $sample
}

$memory = Memory
$disk = Disk
$in = New-Object IO.StreamReader ([Console]::OpenStandardInput())
$out = [Console]::Out
$asked = $in.ReadLineAsync()
$next = 0
$n = 0

while ($true) {
    if ($clock.ElapsedMilliseconds -ge $next) {
        $n++
        Push $cpu (Measure-Cpu)
        Push $gpu (Gpu)
        if ($n % 6 -eq 0) { $memory = Memory; $disk = Disk }
        $next = $clock.ElapsedMilliseconds + 5000
    }
    $wait = [Math]::Max(0, [int]($next - $clock.ElapsedMilliseconds))
    if (-not $asked.Wait($wait)) { continue }
    if ($null -eq $asked.Result) { break }
    $measured = @{
        processors = [Environment]::ProcessorCount
        since = $since
        os = "windows"
        memory = $memory
        disk = $disk
        cpu = @($cpu)
        gpu = @($gpu)
        containers = @()
    }
    $out.Write((ConvertTo-Json $measured -Depth 4 -Compress) + "`n")
    $out.Flush()
    $asked = $in.ReadLineAsync()
}
