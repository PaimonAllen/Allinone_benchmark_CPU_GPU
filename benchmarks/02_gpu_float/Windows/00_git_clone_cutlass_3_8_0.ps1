<#
.SYNOPSIS
Clone or update the local CUTLASS 3.8.0 source tree on Windows.

.DESCRIPTION
This script prepares the external CUTLASS source dependency used by
01_build_cutlass_3_8_0.ps1. It is safe to run repeatedly: an existing valid
source tree is left untouched unless -Update is specified.
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/NVIDIA/cutlass.git",
    [string]$Tag = "v3.8.0",
    [string]$SourceDir = "",
    [switch]$Update,
    [switch]$Force,
    [switch]$DryRun,
    [string]$LogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $SourceDir) {
    $SourceDir = Join-Path $scriptRoot "cutlass-3.8.0"
}
if (-not $LogDir) {
    $LogDir = Join-Path $scriptRoot "logs"
}

function ConvertTo-CmdArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '[\s"&|<>^]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Join-CmdArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    return ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command not found in PATH: $Name"
    }
    return $cmd.Source
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Write-Host ("git " + (Join-CmdArguments -Arguments $Arguments))
    if ($DryRun) {
        return
    }

    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git command failed with exit code ${LASTEXITCODE}: git $(Join-CmdArguments -Arguments $Arguments)"
    }
}

function Invoke-GitCapture {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    if ($DryRun) {
        return "<dry-run>"
    }

    $output = & git @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return ($output -join "`n").Trim()
}

function Test-DirectoryEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $firstItem = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    return $null -eq $firstItem
}

function Test-GitCheckout {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Test-Path -LiteralPath (Join-Path $Path ".git"))
}

function Test-CutlassSource {
    param([Parameter(Mandatory = $true)][string]$Path)

    $rootCMake = Join-Path $Path "CMakeLists.txt"
    $profilerCMake = Join-Path $Path "tools\profiler\CMakeLists.txt"
    return (Test-Path -LiteralPath $rootCMake -PathType Leaf) -and
        (Test-Path -LiteralPath $profilerCMake -PathType Leaf)
}

function Assert-SafeSourceDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sourceFull = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($scriptRoot).TrimEnd('\', '/')
    $sourceLeaf = Split-Path -Leaf $sourceFull
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar

    if (-not $sourceFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a source directory outside this script directory: $sourceFull"
    }
    if ($sourceLeaf -notlike "cutlass-*") {
        throw "Refusing to remove a directory whose leaf name is not cutlass-*: $sourceFull"
    }

    return $sourceFull
}

function Remove-SourceDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sourceFull = Assert-SafeSourceDirectory -Path $Path
    Write-Host "Removing invalid source directory: $sourceFull"
    if ($DryRun) {
        return
    }

    Remove-Item -LiteralPath $sourceFull -Recurse -Force
}

function Clone-Cutlass {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Destination))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Invoke-Git -Arguments @("clone", "--branch", $Tag, "--depth", "1", "--recurse-submodules", $RepoUrl, $Destination)
    Invoke-Git -Arguments @("-C", $Destination, "submodule", "sync", "--recursive")
    Invoke-Git -Arguments @("-C", $Destination, "submodule", "update", "--init", "--recursive", "--depth", "1")
}

function Update-Cutlass {
    param([Parameter(Mandatory = $true)][string]$Path)

    Invoke-Git -Arguments @("-C", $Path, "fetch", "--tags", "--force", "origin")
    Invoke-Git -Arguments @("-C", $Path, "checkout", "--detach", $Tag)
    Invoke-Git -Arguments @("-C", $Path, "submodule", "sync", "--recursive")
    Invoke-Git -Arguments @("-C", $Path, "submodule", "update", "--init", "--recursive", "--depth", "1")
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $LogDir "git_clone_cutlass_3_8_0_${timestamp}.log"
$transcriptStarted = $false

try {
    Start-Transcript -Path $script:LogFile -Force | Out-Null
    $transcriptStarted = $true

    $gitPath = Test-CommandExists -Name "git"
    $sourceFullPath = [System.IO.Path]::GetFullPath($SourceDir)

    Write-Host "CUTLASS repo   : $RepoUrl"
    Write-Host "CUTLASS tag    : $Tag"
    Write-Host "Source dir     : $sourceFullPath"
    Write-Host "Git executable : $gitPath"
    Write-Host "Log file       : $script:LogFile"
    if ($DryRun) {
        Write-Host "Dry run        : enabled"
    }

    if (-not (Test-Path -LiteralPath $sourceFullPath)) {
        Write-Host "Source directory does not exist. Cloning CUTLASS."
        Clone-Cutlass -Destination $sourceFullPath
    } elseif (Test-GitCheckout -Path $sourceFullPath) {
        $current = Invoke-GitCapture -Arguments @("-C", $sourceFullPath, "describe", "--tags", "--always", "--dirty")
        if (-not $current) {
            $current = Invoke-GitCapture -Arguments @("-C", $sourceFullPath, "rev-parse", "--short", "HEAD")
        }
        Write-Host "Existing git source found. Current revision: $current"

        if ($Update) {
            Update-Cutlass -Path $sourceFullPath
        } else {
            Write-Host "Use -Update to fetch and check out $Tag again."
        }
    } elseif (Test-CutlassSource -Path $sourceFullPath) {
        Write-Host "Existing non-git CUTLASS source tree found. Leaving it untouched."
        Write-Host "Use -Force only if you want to replace this directory with a fresh clone."
    } elseif (Test-DirectoryEmpty -Path $sourceFullPath) {
        Write-Host "Existing source directory is empty. Cloning CUTLASS into it."
        Clone-Cutlass -Destination $sourceFullPath
    } elseif ($Force) {
        Remove-SourceDirectory -Path $sourceFullPath
        Clone-Cutlass -Destination $sourceFullPath
    } else {
        throw "Source directory exists but is not a valid CUTLASS tree: $sourceFullPath. Remove/fix it or rerun with -Force."
    }

    if ($DryRun) {
        Write-Host "Dry run complete. Source directory was not modified."
    } else {
        if (-not (Test-CutlassSource -Path $sourceFullPath)) {
            throw "CUTLASS source verification failed. Missing CMakeLists.txt or tools\profiler\CMakeLists.txt in $sourceFullPath"
        }

        Write-Host "CUTLASS source is ready: $sourceFullPath"
    }
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Log saved to: $script:LogFile"
    }
}
