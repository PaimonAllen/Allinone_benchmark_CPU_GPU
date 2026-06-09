<#
.SYNOPSIS
Configure and build CUTLASS 3.8.0 on Windows.

.DESCRIPTION
Builds the CUTLASS profiler from the local cutlass-3.8.0 source tree using
Visual Studio 2022, CUDA Toolkit, and CMake. Defaults are tuned for this
machine's RTX 4070 Ti (SM 89) and cover the local GEMM float benchmark set.
#>

[CmdletBinding()]
param(
    [string]$SourceDir = "",
    [string]$BuildDir = "",
    [ValidateSet("Visual Studio 17 2022", "Ninja")]
    [string]$Generator = "Visual Studio 17 2022",
    [string]$Config = "Release",
    [string]$CudaArchs = "89",
    [string]$Target = "cutlass_profiler",
    [ValidateSet("gemm", "all", "conv2d", "conv3d", "rank_k", "rank_2k", "trmm", "symm")]
    [string]$Operations = "gemm",
    [AllowEmptyString()]
    [string]$Kernels = "sgemm,tf32gemm,16816,dgemm,e4m3,e5m2,e2m1",
    [int]$Parallel = 23,
    [switch]$Clean,
    [switch]$ConfigureOnly,
    [switch]$SkipConfigure,
    [switch]$DryRun,
    [string]$LogDir = "",
    [string]$TempDir = "C:\cutlass_tmp",
    [switch]$KeepTempDir,
    [string[]]$ExtraCMakeArgs = @()
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

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
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

function Get-VsDevCmd {
    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\Common7\Tools\VsDevCmd.bat"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($installationPath) {
            $candidate = Join-Path $installationPath "Common7\Tools\VsDevCmd.bat"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    throw "VsDevCmd.bat not found. Install Visual Studio 2022 with Desktop development with C++."
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Required command not found in PATH: $Name"
    }
    return $cmd.Source
}

function Invoke-VsDevCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $commandText = Join-CmdArguments $Arguments
    $fullCommand = "call `"$script:VsDevCmd`" -arch=x64 >nul && $commandText"

    Write-Host ""
    Write-Host "==> $Title"
    Write-Host $commandText
    Add-Content -Path $script:LogFile -Encoding UTF8 -Value @("", "==> $Title", $commandText)

    if ($DryRun) {
        return
    }

    & cmd.exe /d /s /c $fullCommand 2>&1 | Tee-Object -FilePath $script:LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $commandText"
    }
}

function Remove-DirectoryWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 5,
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }

            Write-Warning "Clean attempt $attempt failed: $($_.Exception.Message). Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Clear-CutlassTempDir {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recreate
    )

    if (-not $Path -or $DryRun -or $KeepTempDir) {
        return
    }

    $tempFullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $tempRoot = [System.IO.Path]::GetPathRoot($tempFullPath).TrimEnd('\')
    $tempLeaf = Split-Path -Leaf $tempFullPath

    if ($tempFullPath.Equals($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean filesystem root as temp directory: $tempFullPath"
    }

    if ($tempLeaf -notmatch '(?i)cutlass') {
        $message = "Skipping temp cleanup for non-dedicated temp directory: $tempFullPath"
        Write-Warning $message
        if ($script:LogFile) {
            Add-Content -Path $script:LogFile -Encoding UTF8 -Value $message
        }
        return
    }

    if (Test-Path -LiteralPath $tempFullPath) {
        Write-Host ""
        Write-Host "==> Cleaning temp directory"
        Write-Host $tempFullPath
        Add-Content -Path $script:LogFile -Encoding UTF8 -Value @("", "==> Cleaning temp directory", $tempFullPath)
        Remove-DirectoryWithRetry -Path $tempFullPath
    }

    if ($Recreate) {
        New-Item -ItemType Directory -Path $tempFullPath -Force | Out-Null
    }
}

$sourcePath = Resolve-ExistingPath -Path $SourceDir -Description "CUTLASS source directory"
if (-not $BuildDir) {
    $BuildDir = Join-Path $env:SystemDrive "cutlass_build\cutlass_3_8_0"
}

$sourceCMake = Join-Path $sourcePath "CMakeLists.txt"
$profilerCMake = Join-Path $sourcePath "tools\profiler\CMakeLists.txt"
if (-not (Test-Path -LiteralPath $sourceCMake)) {
    throw "CUTLASS CMakeLists.txt not found: $sourceCMake"
}
if (-not (Test-Path -LiteralPath $profilerCMake)) {
    throw "CUTLASS profiler CMakeLists.txt not found: $profilerCMake"
}

$cmakePath = Test-CommandExists -Name "cmake"
$null = Test-CommandExists -Name "nvcc"
if ($Generator -eq "Ninja") {
    $null = Test-CommandExists -Name "ninja"
}

$script:VsDevCmd = Get-VsDevCmd
$logPathRoot = if (Test-Path -LiteralPath $LogDir) { (Resolve-Path -LiteralPath $LogDir).Path } else { (New-Item -ItemType Directory -Path $LogDir -Force).FullName }
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeGenerator = $Generator -replace '[^A-Za-z0-9]+', "_"
$script:LogFile = Join-Path $logPathRoot "cutlass_3_8_0_${safeGenerator}_${timestamp}.log"

$buildPath = [System.IO.Path]::GetFullPath($BuildDir)
$sourceFullPath = [System.IO.Path]::GetFullPath($sourcePath)

Write-Host "CUTLASS source : $sourceFullPath"
Write-Host "Build dir      : $buildPath"
Write-Host "Generator      : $Generator"
Write-Host "Config         : $Config"
Write-Host "CUDA archs     : $CudaArchs"
Write-Host "Operations     : $Operations"
Write-Host "Kernels        : $Kernels"
Write-Host "Target         : $Target"
Write-Host "Parallel       : $Parallel"
Write-Host "Temp dir       : $TempDir"
Write-Host "Keep temp dir  : $KeepTempDir"
Write-Host "VS env         : $script:VsDevCmd"
Write-Host "CMake          : $cmakePath"
Write-Host "Log            : $script:LogFile"

Set-Content -Path $script:LogFile -Encoding UTF8 -Value @(
    "CUTLASS 3.8.0 Windows build log",
    "Generated: $(Get-Date -Format o)",
    "Source: $sourceFullPath",
    "Build: $buildPath",
    "Generator: $Generator",
    "Config: $Config",
    "CUDA archs: $CudaArchs",
    "Operations: $Operations",
    "Kernels: $Kernels",
    "Target: $Target",
    "Parallel: $Parallel",
    "Temp dir: $TempDir",
    "Keep temp dir: $KeepTempDir",
    "VS env: $script:VsDevCmd"
)

trap {
    try {
        Clear-CutlassTempDir -Path $TempDir
    } catch {
        Write-Warning "Temp cleanup after failure also failed: $($_.Exception.Message)"
    }
    throw
}

if ($TempDir) {
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }
    $env:TEMP = $TempDir
    $env:TMP = $TempDir
}

if ($Clean -and (Test-Path -LiteralPath $buildPath)) {
    $safeCleanRoots = @(
        $sourceFullPath,
        $scriptRoot,
        (Join-Path $env:SystemDrive "cutlass_build")
    )
    $isSafeCleanPath = $false
    foreach ($root in $safeCleanRoots) {
        $rootFullPath = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($buildPath.Equals($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $buildPath.StartsWith($rootFullPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isSafeCleanPath = $true
            break
        }
    }

    if (-not $isSafeCleanPath) {
        throw "Refusing to clean build directory outside known safe roots: $buildPath"
    }

    Write-Host ""
    Write-Host "==> Cleaning build directory"
    Write-Host $buildPath
    Add-Content -Path $script:LogFile -Encoding UTF8 -Value @("", "==> Cleaning build directory", $buildPath)
    if (-not $DryRun) {
        Remove-DirectoryWithRetry -Path $buildPath
    }
}

if ($Clean) {
    Clear-CutlassTempDir -Path $TempDir -Recreate
}

if (-not (Test-Path -LiteralPath $buildPath) -and -not $DryRun) {
    New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
}

if (-not $SkipConfigure) {
    $configureArgs = @(
        $cmakePath,
        "-S", $sourceFullPath,
        "-B", $buildPath,
        "-G", $Generator,
        "-DCMAKE_BUILD_TYPE=$Config",
        "-DCUTLASS_NVCC_ARCHS=$CudaArchs",
        "-DCUTLASS_ENABLE_TESTS=OFF",
        "-DCUTLASS_ENABLE_GTEST_UNIT_TESTS=OFF",
        "-DCUTLASS_ENABLE_PROFILER_UNIT_TESTS=OFF",
        "-DCUTLASS_ENABLE_EXAMPLES=OFF",
        "-DCUTLASS_ENABLE_TOOLS=ON",
        "-DCUTLASS_ENABLE_LIBRARY=ON",
        "-DCUTLASS_ENABLE_PROFILER=ON",
        "-DCUTLASS_ENABLE_PERFORMANCE=ON",
        "-DCUTLASS_ENABLE_CUBLAS=OFF",
        "-DCUTLASS_ENABLE_CUDNN=OFF",
        "-DCUTLASS_LIBRARY_OPERATIONS=$Operations"
    )

    if ($Kernels.Trim().Length -gt 0) {
        $configureArgs += "-DCUTLASS_LIBRARY_KERNELS=$Kernels"
    }

    if ($Generator -eq "Visual Studio 17 2022") {
        $configureArgs += @("-A", "x64")
    }

    if ($env:CUDA_PATH) {
        $configureArgs += "-DCUDAToolkit_ROOT=$env:CUDA_PATH"
    }

    $configureArgs += $ExtraCMakeArgs
    Invoke-VsDevCommand -Arguments $configureArgs -Title "Configure CUTLASS"
}

if (-not $ConfigureOnly) {
    $buildArgs = @(
        $cmakePath,
        "--build", $buildPath,
        "--config", $Config,
        "--target", $Target,
        "--parallel", "$Parallel"
    )
    Invoke-VsDevCommand -Arguments $buildArgs -Title "Build $Target"

    if (-not $DryRun) {
        $expectedProfiler = Join-Path $buildPath "tools\profiler\$Config\cutlass_profiler.exe"
        if (Test-Path -LiteralPath $expectedProfiler) {
            Write-Host ""
            Write-Host "Built profiler: $expectedProfiler"
            Add-Content -Path $script:LogFile -Encoding UTF8 -Value @("", "Built profiler: $expectedProfiler")

            $profilerDir = Split-Path -Parent $expectedProfiler
            $libraryDllDir = Join-Path $buildPath "tools\library\$Config"
            if (Test-Path -LiteralPath $libraryDllDir) {
                $runtimeDlls = Get-ChildItem -LiteralPath $libraryDllDir -Filter "*.dll"
                foreach ($dll in $runtimeDlls) {
                    Copy-Item -LiteralPath $dll.FullName -Destination $profilerDir -Force
                }
                Write-Host "Copied runtime DLLs: $($runtimeDlls.Count) from $libraryDllDir to $profilerDir"
                Add-Content -Path $script:LogFile -Encoding UTF8 -Value "Copied runtime DLLs: $($runtimeDlls.Count) from $libraryDllDir to $profilerDir"
            }
        } else {
            Write-Host ""
            Write-Host "Build completed, but expected profiler path was not found:"
            Write-Host $expectedProfiler
            Write-Host "Search the build directory for cutlass_profiler.exe if the generator used a different output path."
            Add-Content -Path $script:LogFile -Encoding UTF8 -Value @("", "Expected profiler not found: $expectedProfiler")
        }
    }
}

Clear-CutlassTempDir -Path $TempDir

Write-Host ""
Write-Host "Done. Log: $script:LogFile"
