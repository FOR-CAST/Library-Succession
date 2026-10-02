#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Record the identity of every assembly in one or more directories.

.DESCRIPTION
    Emits AssemblyVersion, FileVersion, ProductVersion, SHA-256 and size for
    each .dll found, as a table on stdout and optionally as CSV.

    ProductVersion is the useful column: for libraries built by the .NET SDK it
    carries InformationalVersion plus the source commit (SourceRevisionId), so
    two builds of the same AssemblyVersion can be told apart. AssemblyVersion
    alone cannot distinguish them -- this repo ships 10.0 regardless of the
    source it was built from.

    The point is to make "which binaries produced this run?" answerable after
    the fact. A LANDIS-II install carries several generations of the cohort
    libraries side by side (UniversalCohorts v1 and v2, Succession v9 and v10),
    and an extension built against one cannot share a landscape with an
    extension built against the other. When a run misbehaves, the versions that
    were actually loaded are the first thing needed and the first thing lost.

.PARAMETER Path
    One or more directories to scan. Missing directories warn rather than fail,
    so the same invocation works across install layouts that differ.

.PARAMETER OutFile
    Optional CSV destination. Parent directories are created as needed.

.EXAMPLE
    ./tools/dll-inventory.ps1 out, src/lib -OutFile inventory.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]] $Path,

    [string] $OutFile
)

$ErrorActionPreference = 'Stop'

$rows = foreach ($dir in $Path) {
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Warning "no such directory, skipping: $dir"
        continue
    }

    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter *.dll -File | Sort-Object Name)) {
        ## Native DLLs (GDAL and friends) have no managed assembly identity.
        ## They still belong in the inventory, so record them rather than
        ## dropping them: a mismatched native dependency is just as capable of
        ## changing results as a managed one.
        try {
            $asmVer = [System.Reflection.AssemblyName]::GetAssemblyName($f.FullName).Version.ToString()
        } catch {
            $asmVer = '(unmanaged)'
        }

        $fileVer = '-'
        $prodVer = '-'
        try {
            $vi = $f.VersionInfo
            if ($vi.FileVersion)    { $fileVer = $vi.FileVersion }
            if ($vi.ProductVersion) { $prodVer = $vi.ProductVersion }
        } catch {
            ## no version resource; leave the placeholders
        }

        [pscustomobject] @{
            Directory       = $dir
            File            = $f.Name
            AssemblyVersion = $asmVer
            FileVersion     = $fileVer
            ProductVersion  = $prodVer
            Sha256          = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
            Bytes           = $f.Length
        }
    }
}

if (-not $rows) {
    Write-Warning "no assemblies found under: $($Path -join ', ')"
    return
}

$rows |
    Format-Table File, AssemblyVersion, FileVersion, Sha256, ProductVersion -AutoSize |
    Out-String -Width 400 |
    Write-Host

Write-Host ("{0} assembl{1} inventoried" -f $rows.Count, $(if ($rows.Count -eq 1) { 'y' } else { 'ies' }))

if ($OutFile) {
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation
    Write-Host "wrote $OutFile"
}
