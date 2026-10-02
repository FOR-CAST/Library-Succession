#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run a PnET scenario repeatedly, swapping the Succession library and the
    thread count, and report which comparisons differ.

.DESCRIPTION
    Four cells, each run -Reps times:

        base/serial    baseline library, Parallel 1
        fixed/serial   candidate library, Parallel 1
        base/parallel  baseline library, Parallel N
        fixed/parallel candidate library, Parallel N

    The comparisons that matter are not all the same question:

      * within-cell (rep 1 vs rep 2 of the SAME library and thread count) asks
        whether a run reproduces itself at all;
      * across-library at the same thread count asks whether the library change
        alters results.

    An across-library difference is only interpretable if the corresponding
    within-cell comparisons are clean, which is why both are run and reported
    together rather than jumping to the comparison of interest.

    Two design points that are easy to get wrong, and were:

    1. THE SCENARIO REWRITES ITS OWN INPUTS. Magic Harvest launches
       switchManagementNames.py, which three-way-renames the Biomass Harvest
       prescription file. With Timestep 10 over Duration 50 it fires five times
       -- an odd number -- so the inputs are left swapped when the run ends, and
       the two prescriptions differ substantively. Re-running in the same
       directory, or copying from a directory that has already been run in,
       silently compares two different harvest regimes. Every run here is
       therefore a fresh copy of a pristine tree that is never run in.

    2. NOISE IS MEASURED, NOT ASSUMED. Some outputs differ between identical
       runs for reasons that have nothing to do with the library: log files
       carry timestamps, and Hurricane draws its storm heading from a
       clock-seeded generator that its own seed parameter never re-seeds.
       Rather than hard-coding a guessed exclusion list -- which risks both
       masking a real difference and reporting a fake one -- the within-cell
       baseline/serial comparison DEFINES the noise set, and that measured set
       is then excluded from every other comparison. If that control is clean,
       nothing is excluded at all.

.NOTES
    Requires an installed LANDIS-II v8 and write access to the install
    directory. Intended for CI, where the runner is administrator.
#>
[CmdletBinding()]
param(
    ## Landis.Console.dll inside the install (used to locate the console and the
    ## install root; the library to swap is found beneath the latter).
    [Parameter(Mandatory)] [string] $ConsoleDll,

    ## A scenario directory that has NEVER been run in. Copied per run; never
    ## used directly, for reason (1) above.
    [Parameter(Mandatory)] [string] $PristineScenario,

    ## Scenario file to run, relative to the scenario directory.
    [string] $ScenarioFile = 'scenario_UCLv2.txt',

    [Parameter(Mandatory)] [string] $FixedDll,
    [Parameter(Mandatory)] [string] $BaselineDll,

    ## Where run directories are created.
    [Parameter(Mandatory)] [string] $WorkRoot,

    ## Repetitions per cell. Two detects gross non-determinism; more is needed
    ## before calling a cell reproducible, so this is a knob rather than a 2.
    [int] $Reps = 2,

    ## Thread count for the parallel cells. An integer is used rather than
    ## `true`, because `true` logs "determined by system" with no number and
    ## leaves nothing to assert against.
    [int] $Threads = 4
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

## --------------------------------------------------------------------------
## Locate the library to swap. On Windows there is exactly one copy, under the
## install's extensions directory -- unlike the Linux layout, which has two and
## loads only one of them.
## --------------------------------------------------------------------------
$consoleDir  = Split-Path -Parent $ConsoleDll
$installRoot = Split-Path -Parent $consoleDir

$targets = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File `
                           -Filter 'Landis.Library.Succession-v10.dll')
if ($targets.Count -ne 1) {
    throw ("expected exactly one Landis.Library.Succession-v10.dll under " +
           "$installRoot, found $($targets.Count): " +
           ($targets.FullName -join '; '))
}
$swapTarget = $targets[0].FullName
Write-Host "swap target     : $swapTarget"
Write-Host "console         : $ConsoleDll"
Write-Host "processors       : $env:NUMBER_OF_PROCESSORS"
Write-Host "reps per cell   : $Reps"
Write-Host "parallel threads: $Threads"

foreach ($p in @($FixedDll, $BaselineDll, $PristineScenario)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing input: $p" }
}

## The pristine tree must not already contain outputs: if it does, it has been
## run in, and reason (1) means its inputs may already be the swapped variant.
foreach ($leak in 'Landis-log.txt', 'output', 'outputs', 'Metadata') {
    if (Test-Path -LiteralPath (Join-Path $PristineScenario $leak)) {
        throw ("the pristine scenario contains '$leak', so it has been run in; " +
               "its harvest inputs may be the swapped variant. Re-extract it.")
    }
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

## --------------------------------------------------------------------------
## The Parallel setting is a row in PnETGenericParameters.txt. It may also live
## in pnetsuccession.txt, but not both -- the run aborts with "Parameter
## Parallel was provided twice" -- so the shipped row is edited in place rather
## than a new one being added. The value is compared case-sensitively.
## --------------------------------------------------------------------------
function Set-ParallelValue {
    param([string] $RunDir, [string] $Value)

    $f = Join-Path $RunDir 'inputs\succession\PnETGenericParameters.txt'
    if (-not (Test-Path -LiteralPath $f)) { throw "not found: $f" }

    $text = Get-Content -LiteralPath $f -Raw
    if ($text -notmatch '(?m)^Parallel\s+\S+\s*$') {
        throw "no 'Parallel' row found in $f; refusing to guess where to add one"
    }
    $text = [regex]::Replace($text, '(?m)^Parallel\s+\S+\s*$', "Parallel`t$Value")
    Set-Content -LiteralPath $f -Value $text -NoNewline -Encoding ascii

    $check = Select-String -LiteralPath $f -Pattern '^Parallel' |
             ForEach-Object { $_.Line.Trim() }
    Write-Host "    Parallel row -> $check"
}

## Map every file in a run directory to its hash, keyed by relative path, so two
## runs can be compared without caring about absolute locations.
function Get-RunFingerprint {
    param([string] $RunDir)

    $map = @{}
    $prefix = (Resolve-Path -LiteralPath $RunDir).Path.TrimEnd('\') + '\'
    foreach ($f in Get-ChildItem -LiteralPath $RunDir -Recurse -File) {
        $rel = $f.FullName.Substring($prefix.Length)
        $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

## Differing relative paths between two fingerprints, including files present in
## only one of them.
function Compare-Fingerprints {
    param([hashtable] $A, [hashtable] $B)

    $diff = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $A.Keys) {
        if (-not $B.ContainsKey($k)) { $diff.Add($k); continue }
        if ($A[$k] -ne $B[$k])       { $diff.Add($k) }
    }
    foreach ($k in $B.Keys) {
        if (-not $A.ContainsKey($k)) { $diff.Add($k) }
    }
    return ($diff | Sort-Object -Unique)
}

## --------------------------------------------------------------------------
## One run.
## --------------------------------------------------------------------------
function Invoke-Run {
    param([string] $Label, [string] $Dll, [string] $ParallelValue, [int] $ExpectThreads)

    $runDir = Join-Path $WorkRoot $Label
    if (Test-Path -LiteralPath $runDir) { Remove-Item -Recurse -Force -LiteralPath $runDir }

    ## Fresh copy every time -- see reason (1).
    Copy-Item -Recurse -LiteralPath $PristineScenario -Destination $runDir

    Set-ParallelValue -RunDir $runDir -Value $ParallelValue
    Copy-Item -Force -LiteralPath $Dll -Destination $swapTarget

    $log = "$runDir.log"
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $runDir
    try {
        & dotnet $ConsoleDll $ScenarioFile *>&1 | Tee-Object -FilePath $log | Out-Null
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
        $sw.Stop()
    }

    ## The thread count must be confirmed from the run's own output. Without
    ## this, a silently ignored Parallel value turns the parallel cells into
    ## duplicates of the serial ones and the whole matrix looks reassuring.
    $seen = $null
    $m = Select-String -LiteralPath $log -Pattern 'MaxParallelThreads\s*=\s*(\d+)' |
         Select-Object -First 1
    if ($m) { $seen = [int]$m.Matches[0].Groups[1].Value }
    elseif (Select-String -LiteralPath $log -Pattern 'MaxParallelThreads determined by system' -Quiet) {
        $seen = -1
    }

    $ok = ($rc -eq 0) -and ($seen -eq $ExpectThreads)
    '{0,-18} rc={1,-3} MaxParallelThreads={2,-5} {3,6:N0}s  {4}' -f `
        $Label, $rc, ($seen ?? 'none'), $sw.Elapsed.TotalSeconds,
        ($ok ? 'ok' : 'PROBLEM') | Write-Host

    if ($rc -ne 0) {
        Write-Host "::error::run '$Label' exited $rc"
        Get-Content -LiteralPath $log -Tail 25 | ForEach-Object { "      $_" | Write-Host }
    } elseif ($seen -ne $ExpectThreads) {
        Write-Host ("::error::run '$Label' reported MaxParallelThreads=$seen, " +
                    "expected $ExpectThreads; this cell would not test what it claims to")
    }

    return [pscustomobject]@{
        Label   = $Label
        Dir     = $runDir
        Ok      = $ok
        Rc      = $rc
        Threads = $seen
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds)
    }
}

## --------------------------------------------------------------------------
## Run the matrix.
## --------------------------------------------------------------------------
$cells = @(
    @{ Key = 'base-serial';    Dll = $BaselineDll; Parallel = '1';       Expect = 1 }
    @{ Key = 'fixed-serial';   Dll = $FixedDll;    Parallel = '1';       Expect = 1 }
    @{ Key = 'base-parallel';  Dll = $BaselineDll; Parallel = "$Threads"; Expect = $Threads }
    @{ Key = 'fixed-parallel'; Dll = $FixedDll;    Parallel = "$Threads"; Expect = $Threads }
)

$runs = [System.Collections.Generic.List[object]]::new()
foreach ($c in $cells) {
    Write-Host ""
    Write-Host "=== cell $($c.Key) ==="
    for ($r = 1; $r -le $Reps; $r++) {
        $runs.Add((Invoke-Run -Label "$($c.Key)-r$r" -Dll $c.Dll `
                              -ParallelValue $c.Parallel -ExpectThreads $c.Expect))
    }
}

if (@($runs | Where-Object { -not $_.Ok }).Count -gt 0) {
    Write-Host "::error::one or more runs failed or did not honour its thread count; comparisons below are not trustworthy"
}

## --------------------------------------------------------------------------
## Fingerprint, then compare.
## --------------------------------------------------------------------------
Write-Host ""
Write-Host "=== fingerprinting ==="
$fp = @{}
foreach ($run in $runs) {
    $fp[$run.Label] = Get-RunFingerprint -RunDir $run.Dir
    '{0,-18} {1,6} files' -f $run.Label, $fp[$run.Label].Count | Write-Host
}

## The baseline serial cell is the control: it holds the library and the thread
## count fixed, so anything differing between its reps is noise by definition.
$noise = @()
if ($Reps -ge 2) {
    $noise = Compare-Fingerprints -A $fp['base-serial-r1'] -B $fp['base-serial-r2']
}
Write-Host ""
Write-Host "=== measured noise set (differs between two identical baseline serial runs) ==="
if (-not $noise) {
    Write-Host "  none -- serial runs are bit-reproducible, so nothing is excluded below"
} else {
    $noise | ForEach-Object { "  $_" | Write-Host }
    Write-Host ("  {0} file(s) excluded from the comparisons below" -f @($noise).Count)
}

function Show-Comparison {
    param([string] $Question, [string] $X, [string] $Y)

    if (-not $fp.ContainsKey($X) -or -not $fp.ContainsKey($Y)) { return $null }
    $d = @(Compare-Fingerprints -A $fp[$X] -B $fp[$Y]) | Where-Object { $noise -notcontains $_ }
    $n = @($d).Count
    Write-Host ""
    Write-Host ("{0}`n  {1} vs {2}: {3} differing file(s) beyond the noise set" -f $Question, $X, $Y, $n)
    @($d) | Select-Object -First 10 | ForEach-Object { "    $_" | Write-Host }
    if ($n -gt 10) { "    ... and $($n - 10) more" | Write-Host }
    return [pscustomobject]@{ Question = $Question; A = $X; B = $Y; Differing = $n; Files = @($d) }
}

$results = [System.Collections.Generic.List[object]]::new()
Write-Host ""
Write-Host "=== comparisons ==="

## Controls first: an across-library result means nothing if these are dirty.
$results.Add((Show-Comparison 'CONTROL  does a serial run reproduce itself (candidate library)?' 'fixed-serial-r1' 'fixed-serial-r2'))
$results.Add((Show-Comparison 'CONTROL  does a parallel run reproduce itself (baseline library)?' 'base-parallel-r1' 'base-parallel-r2'))
$results.Add((Show-Comparison 'CONTROL  does a parallel run reproduce itself (candidate library)?' 'fixed-parallel-r1' 'fixed-parallel-r2'))

## The questions of interest.
$results.Add((Show-Comparison 'TEST     does the library change alter serial results?' 'base-serial-r1' 'fixed-serial-r1'))
$results.Add((Show-Comparison 'TEST     does the library change alter parallel results?' 'base-parallel-r1' 'fixed-parallel-r1'))

$summary = [pscustomobject]@{
    Processors   = $env:NUMBER_OF_PROCESSORS
    Reps         = $Reps
    Threads      = $Threads
    SwapTarget   = $swapTarget
    Runs         = $runs
    NoiseFiles   = @($noise)
    Comparisons  = @($results | Where-Object { $_ })
}
$out = Join-Path $WorkRoot 'matrix-results.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $out -Encoding utf8
Write-Host ""
Write-Host "wrote $out"

## Only a failed or mis-threaded run fails this script. A difference is a
## finding to be read, not an error -- the parallel controls are EXPECTED to
## differ, and exiting non-zero on that would make the job red for working
## correctly.
if (@($runs | Where-Object { -not $_.Ok }).Count -gt 0) { exit 1 }
exit 0
