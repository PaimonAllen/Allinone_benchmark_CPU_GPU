<#
.SYNOPSIS
Compile the STREAM C benchmark for Windows CPU memory bandwidth measurements.
#>

[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$BuildDir = "",
    [string]$Compiler = "cl.exe",
    [string]$VsDevCmd = "",
    [int64]$ArraySize = 100000000,
    [int]$NTimes = 20,
    [int]$Offset = 0,
    [string]$StreamType = "double",
    [ValidateSet("dynamic", "static")]
    [string]$AllocationMode = "dynamic",
    [switch]$NoOpenMP,
    [switch]$DryRun,
    [string]$LogDir = "",
    [string[]]$ExtraCFlags = @(),
    [string[]]$ExtraLdFlags = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LogFile = $null

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $SourceDir) { $SourceDir = Join-Path $scriptRoot "stream-5.10" }
if (-not $BuildDir) { $BuildDir = Join-Path $scriptRoot "build" }
if (-not $LogDir) { $LogDir = Join-Path $scriptRoot "logs" }

function ConvertTo-CmdArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\s"&|<>^]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Resolve-InputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Join-CmdArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    return ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
}

function Get-VsDevCmd {
    if ($VsDevCmd) {
        if (Test-Path -LiteralPath $VsDevCmd -PathType Leaf) { return (Resolve-Path -LiteralPath $VsDevCmd).Path }
        throw "VsDevCmd.bat not found: $VsDevCmd"
    }

    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\Common7\Tools\VsDevCmd.bat"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installationPath) {
            $candidate = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    throw "VsDevCmd.bat not found. Install Visual Studio 2022 with Desktop development with C++."
}

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Invoke-VsDevCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $commandText = Join-CmdArguments -Arguments $Arguments
    $fullCommand = "call `"$script:VsDevCmdPath`" -arch=x64 >nul && $commandText"

    Write-Host ""
    Write-Host "==> $Title"
    Write-Host $commandText
    Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value @("", "==> $Title", $commandText)

    if ($DryRun) { return }

    & cmd.exe /d /s /c $fullCommand 2>&1 | Tee-Object -FilePath $script:LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $commandText"
    }
}

function New-WindowsCompatHeader {
    param([Parameter(Mandatory = $true)][string]$CompatRoot)

    $sysDir = Join-Path $CompatRoot "sys"
    New-Item -ItemType Directory -Path $sysDir -Force | Out-Null
    $unistdHeader = Join-Path $CompatRoot "unistd.h"
    Set-Content -LiteralPath $unistdHeader -Encoding ASCII -Value @'
#ifndef STREAM_WINDOWS_UNISTD_H
#define STREAM_WINDOWS_UNISTD_H
#ifdef _WIN32
#ifndef _SSIZE_T_DEFINED
#ifdef _WIN64
typedef __int64 ssize_t;
#else
typedef int ssize_t;
#endif
#define _SSIZE_T_DEFINED
#endif
#endif
#endif
'@

    $timeHeader = Join-Path $sysDir "time.h"
    Set-Content -LiteralPath $timeHeader -Encoding ASCII -Value @'
#ifndef STREAM_WINDOWS_SYS_TIME_H
#define STREAM_WINDOWS_SYS_TIME_H
#ifdef _WIN32
#include <windows.h>
struct timezone {
    int tz_minuteswest;
    int tz_dsttime;
};
static int gettimeofday(struct timeval *tv, struct timezone *tz) {
    static LARGE_INTEGER freq;
    static int initialized = 0;
    LARGE_INTEGER counter;
    if (tz) {
        tz->tz_minuteswest = 0;
        tz->tz_dsttime = 0;
    }
    if (!tv) {
        return 0;
    }
    if (!initialized) {
        QueryPerformanceFrequency(&freq);
        initialized = 1;
    }
    QueryPerformanceCounter(&counter);
    tv->tv_sec = (long)(counter.QuadPart / freq.QuadPart);
    tv->tv_usec = (long)(((counter.QuadPart % freq.QuadPart) * 1000000) / freq.QuadPart);
    return 0;
}
#endif
#endif
'@
    return $CompatRoot
}

function New-WindowsStreamSource {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    if ($Mode -eq "static") {
        return $InputPath
    }

    $source = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
    $source = $source -replace '(# include <limits\.h>\s*# include <sys/time\.h>)', "`$1`r`n#ifdef _WIN32`r`n# include <stdlib.h>`r`n# include <malloc.h>`r`n#endif"

    $staticArrayPattern = 'static STREAM_TYPE\s+a\[STREAM_ARRAY_SIZE\+OFFSET\],\s*b\[STREAM_ARRAY_SIZE\+OFFSET\],\s*c\[STREAM_ARRAY_SIZE\+OFFSET\];'
    $dynamicArrayBlock = @'
static STREAM_TYPE *a = NULL, *b = NULL, *c = NULL;

static void allocate_stream_arrays(void)
{
    size_t array_bytes = (size_t)(STREAM_ARRAY_SIZE + OFFSET) * sizeof(STREAM_TYPE);
    a = (STREAM_TYPE*)_aligned_malloc(array_bytes, 64);
    b = (STREAM_TYPE*)_aligned_malloc(array_bytes, 64);
    c = (STREAM_TYPE*)_aligned_malloc(array_bytes, 64);
    if (!a || !b || !c) {
        fprintf(stderr, "Failed to allocate STREAM arrays: %llu bytes per array\n", (unsigned long long)array_bytes);
        exit(1);
    }
}
'@
    $updated = [regex]::Replace($source, $staticArrayPattern, $dynamicArrayBlock, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($updated -eq $source) {
        throw "Could not patch STREAM static arrays for Windows dynamic allocation."
    }

    $setupMarker = "    /* --- SETUP --- determine precision and check timing --- */"
    if (-not $updated.Contains($setupMarker)) {
        throw "Could not find STREAM setup marker for Windows dynamic allocation patch."
    }
    $updated = $updated.Replace($setupMarker, "    allocate_stream_arrays();`r`n`r`n$setupMarker")
    $updated = $updated.Replace("sizeof(STREAM_TYPE) = %lu", "sizeof(STREAM_TYPE) = %zu")

    Set-Content -LiteralPath $OutputPath -Encoding UTF8 -Value $updated
    return $OutputPath
}

if ($ArraySize -le 0) { throw "-ArraySize must be positive." }
if ($NTimes -le 1) { throw "-NTimes must be greater than 1." }
if ($Offset -lt 0) { throw "-Offset must be non-negative." }
if (-not $StreamType) { throw "-StreamType cannot be empty." }

$sourceFullPath = Resolve-InputPath -Path $SourceDir
$buildFullPath = Resolve-InputPath -Path $BuildDir
$sourceFile = Join-Path $sourceFullPath "stream.c"
if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "STREAM source not found: $sourceFile. Run .\00_get_stream_source.ps1 first."
}

New-Item -ItemType Directory -Path $LogDir, $buildFullPath -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $LogDir "build_stream_${timestamp}.log"
Set-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value "STREAM Windows build log"

$script:VsDevCmdPath = Get-VsDevCmd
$openmpEnabled = -not $NoOpenMP
$safeType = ConvertTo-SafeName -Value $StreamType
$binaryBaseName = "stream_${safeType}_n${ArraySize}_t${NTimes}"
if ($openmpEnabled) { $binaryBaseName += "_omp" } else { $binaryBaseName += "_serial" }
$binaryPath = Join-Path $buildFullPath "${binaryBaseName}.exe"
$objectPath = Join-Path $buildFullPath "${binaryBaseName}.obj"
$compatRoot = New-WindowsCompatHeader -CompatRoot (Join-Path $buildFullPath "compat")
$compileSourceFile = New-WindowsStreamSource -InputPath $sourceFile -OutputPath (Join-Path $buildFullPath "stream_windows_dynamic.c") -Mode $AllocationMode

$compileArgs = @(
    $Compiler,
    "/nologo",
    "/O2",
    "/DSTREAM_ARRAY_SIZE=$ArraySize",
    "/DNTIMES=$NTimes",
    "/DOFFSET=$Offset",
    "/DSTREAM_TYPE=$StreamType",
    "/I$compatRoot",
    "/Fo:$objectPath"
)
if ($openmpEnabled) { $compileArgs += "/openmp" }
$compileArgs += $ExtraCFlags
$compileArgs += @($compileSourceFile, "/Fe:$binaryPath")
if ($ExtraLdFlags.Count -gt 0) {
    $compileArgs += "/link"
    $compileArgs += $ExtraLdFlags
}

Write-Host "STREAM source      : $sourceFile"
Write-Host "Build directory    : $buildFullPath"
Write-Host "Compiler           : $Compiler"
Write-Host "VS env             : $script:VsDevCmdPath"
Write-Host "STREAM_ARRAY_SIZE  : $ArraySize"
Write-Host "NTIMES             : $NTimes"
Write-Host "OFFSET             : $Offset"
Write-Host "STREAM_TYPE        : $StreamType"
Write-Host "Allocation mode    : $AllocationMode"
Write-Host "OpenMP             : $openmpEnabled"
Write-Host "Output binary      : $binaryPath"
Write-Host "Log file           : $script:LogFile"

Invoke-VsDevCommand -Title "compile STREAM" -Arguments $compileArgs

if ($DryRun) {
    Write-Host "Dry run complete. STREAM binary was not built."
    return
}

if (-not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
    throw "STREAM binary was not created: $binaryPath"
}

$commandPath = Join-Path $buildFullPath "command_${binaryBaseName}.cmd"
$buildInfoPath = Join-Path $buildFullPath "build_info_${binaryBaseName}.json"
$compileCommand = Join-CmdArguments -Arguments $compileArgs
Set-Content -LiteralPath $commandPath -Encoding ASCII -Value @(
    "@echo off",
    "rem STREAM compile command",
    "rem Generated: $(Get-Date -Format o)",
    "call `"$script:VsDevCmdPath`" -arch=x64 >nul",
    $compileCommand
)

$bytesPerWord = if ($StreamType -eq "double") { 8 } elseif ($StreamType -eq "float") { 4 } else { $null }
$payload = [ordered]@{
    schema_version = 1
    generated_at = (Get-Date -Format o)
    source_file = $sourceFile
    binary_path = $binaryPath
    compiler = $Compiler
    compiler_id = "msvc"
    vs_dev_cmd = $script:VsDevCmdPath
    stream_array_size = $ArraySize
    ntimes = $NTimes
    offset = $Offset
    stream_type = $StreamType
    allocation_mode = $AllocationMode
    compile_source_file = $compileSourceFile
    openmp = $openmpEnabled
    bytes_per_word = $bytesPerWord
    estimated_total_bytes = if ($bytesPerWord) { [int64]$ArraySize * [int64]$bytesPerWord * 3 } else { $null }
    compile_command = $compileCommand
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $buildInfoPath -Encoding UTF8

Write-Host "STREAM binary is ready: $binaryPath"
Write-Host "Build info: $buildInfoPath"
Write-Host "Log saved to: $script:LogFile"
