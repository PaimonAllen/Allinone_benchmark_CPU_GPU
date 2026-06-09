[CmdletBinding()]
param(
    [string]$CondaEnv = "cudadev",
    [string]$PythonExe = "",
    [int[]]$Sizes = @(1024, 2048, 4096),
    [int[]]$FallbackSizes = @(256, 512),
    [string[]]$Precisions = @("ALL_KNOWN"),
    [int[]]$Threads = @(),
    [int]$RepeatCount = 5,
    [int]$WarmupIterations = 2,
    [int]$ProfilingIterations = 3,
    [int]$Seed = 1234,
    [string]$OutputRoot = "",
    [switch]$AllowAnyBlas,
    [switch]$AllowUserSite,
    [switch]$NoUserSite,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-Tool {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Quote-CommandArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function New-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-DefaultThreadCounts {
    $logicalProcessors = [Environment]::ProcessorCount
    try {
        $processorInfo = Get-CimInstance Win32_Processor
        $logicalFromCim = ($processorInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        if ($logicalFromCim -gt 0) {
            $logicalProcessors = [int]$logicalFromCim
        }
    }
    catch {
        Write-Warning "Could not query logical processor count from CIM: $($_.Exception.Message)"
    }

    $candidates = @(1, 8, $logicalProcessors)
    return @($candidates | Where-Object { $_ -gt 0 -and $_ -le $logicalProcessors } | Sort-Object -Unique)
}

function Test-CondaEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$CondaPath,
        [Parameter(Mandatory = $true)][string]$EnvName
    )
    try {
        $jsonText = & $CondaPath env list --json | Out-String
        $envList = $jsonText | ConvertFrom-Json
        foreach ($envPath in $envList.envs) {
            if ((Split-Path -Leaf $envPath) -ieq $EnvName) {
                return $true
            }
        }
    }
    catch {
        Write-Warning "Could not query conda environments: $($_.Exception.Message)"
    }
    return $false
}

function Read-SelectedCondaEnvironmentState {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.selected_env)) {
            return $state
        }
        Write-Warning "Selected environment state file exists but does not contain selected_env: $Path"
    }
    catch {
        Write-Warning "Could not read selected environment state file '$Path': $($_.Exception.Message)"
    }
    return $null
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runnerPath = (Resolve-Path -LiteralPath (Join-Path $scriptRoot "..\common\openblas_numpy_gemm_benchmark.py")).Path
$selectedEnvStatePath = Join-Path $scriptRoot "selected_env.json"

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $scriptRoot "runs"
}
$OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
$logRoot = Join-Path $scriptRoot "logs"
New-Item -ItemType Directory -Force -Path $OutputRoot, $logRoot | Out-Null

$hostName = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { "unknown_host" } else { $env:COMPUTERNAME }
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$runName = "{0}_{1}_windows" -f $timestamp, (New-SafeName $hostName)
$runDir = Join-Path $OutputRoot $runName
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$logPath = Join-Path $logRoot ("{0}.log" -f $runName)
$transcriptStarted = $false

try {
    Start-Transcript -Path $logPath -Force | Out-Null
    $transcriptStarted = $true

    $selectedEnvState = $null
    $condaEnvSource = "parameter"
    if (-not $PSBoundParameters.ContainsKey("CondaEnv") -and [string]::IsNullOrWhiteSpace($PythonExe)) {
        $selectedEnvState = Read-SelectedCondaEnvironmentState -Path $selectedEnvStatePath
        if ($null -ne $selectedEnvState) {
            $CondaEnv = [string]$selectedEnvState.selected_env
            $condaEnvSource = "selected_env.json"
        }
        else {
            $condaEnvSource = "default"
        }
    }
    elseif (-not $PSBoundParameters.ContainsKey("CondaEnv") -and -not [string]::IsNullOrWhiteSpace($PythonExe)) {
        $condaEnvSource = "python_exe"
    }
    if (-not [string]::IsNullOrWhiteSpace($PythonExe)) {
        if ($PSBoundParameters.ContainsKey("CondaEnv") -and -not [string]::IsNullOrWhiteSpace($CondaEnv)) {
            Write-Warning "-PythonExe is set, so -CondaEnv '$CondaEnv' will be ignored."
            $condaEnvSource = "ignored_by_python_exe"
        }
        $CondaEnv = ""
    }

    if ($Threads.Count -eq 0) {
        $Threads = Get-DefaultThreadCounts
    }

    if (-not [string]::IsNullOrWhiteSpace($CondaEnv)) {
        Write-Host "Conda environment: $CondaEnv"
        Write-Host "Conda environment source: $condaEnvSource"
        Write-Host "Tip: run .\01_prepare_openblas_numpy_env.ps1 -EnvName $CondaEnv -VerifyOnly to verify OpenBLAS before a full run."
        Write-Host "Tip: use -AllowAnyBlas only when intentionally benchmarking MKL or another BLAS backend."
    }
    Write-Host "CPU precision sweep: $(($Precisions | ForEach-Object { $_.ToUpperInvariant() }) -join ',')"
    Write-Host "BLAS sizes: $($Sizes -join ',')"
    Write-Host "Fallback sizes: $($FallbackSizes -join ',')"
    Write-Host "Thread sweep: $($Threads -join ',')"
    Write-Host "RepeatCount=$RepeatCount WarmupIterations=$WarmupIterations ProfilingIterations=$ProfilingIterations"

    $pythonCommand = @()
    if (-not [string]::IsNullOrWhiteSpace($PythonExe)) {
        $pythonCommand = @((Resolve-Path -LiteralPath $PythonExe).Path)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CondaEnv)) {
        $condaPath = Resolve-Tool "conda"
        if ($null -eq $condaPath) {
            throw "CondaEnv was provided, but conda was not found on PATH."
        }
        if (-not (Test-CondaEnvironment -CondaPath $condaPath -EnvName $CondaEnv)) {
            throw "Conda environment '$CondaEnv' was not found. Run .\01_prepare_openblas_numpy_env.ps1 first, or pass -CondaEnv with an existing environment."
        }
        $pythonCommand = @($condaPath, "run", "-n", $CondaEnv, "python")
    }
    else {
        $pythonPath = Resolve-Tool "python"
        if ($null -ne $pythonPath) {
            $pythonCommand = @($pythonPath)
        }
        else {
            $pyLauncher = Resolve-Tool "py"
            if ($null -eq $pyLauncher) {
                throw "Neither python nor py was found on PATH. Use -PythonExe or -CondaEnv."
            }
            $pythonCommand = @($pyLauncher, "-3")
        }
    }

    $runnerArgs = @(
        $runnerPath,
        "--output-dir", $runDir,
        "--sizes", ($Sizes -join ","),
        "--fallback-sizes", ($FallbackSizes -join ","),
        "--precisions", (($Precisions | ForEach-Object { $_.ToUpperInvariant() }) -join ","),
        "--threads", ($Threads -join ","),
        "--repeat-count", $RepeatCount.ToString(),
        "--warmup-iterations", $WarmupIterations.ToString(),
        "--profiling-iterations", $ProfilingIterations.ToString(),
        "--seed", $Seed.ToString()
    )
    if (-not $AllowAnyBlas) {
        $runnerArgs += @("--require-backend", "openblas")
    }
    if ($DryRun) {
        $runnerArgs += "--dry-run"
    }

    $cpuInfoPath = Join-Path $runDir "windows_cpu_info.json"
    $osInfoPath = Join-Path $runDir "windows_os_info.json"
    $runSelectedEnvPath = Join-Path $runDir "selected_env.json"
    try {
        Get-CimInstance Win32_Processor |
            Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, L2CacheSize, L3CacheSize |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $cpuInfoPath -Encoding UTF8
        Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, OSArchitecture, TotalVisibleMemorySize, FreePhysicalMemory |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $osInfoPath -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write Windows CIM metadata: $($_.Exception.Message)"
    }

    $runSelectedEnvState = [ordered]@{
        schema_version = 1
        generated_at = Get-Date -Format o
        conda_env = $CondaEnv
        conda_env_source = $condaEnvSource
        python_exe = $PythonExe
        selected_env_state_file = $selectedEnvStatePath
        prepare_state = $selectedEnvState
    }
    $runSelectedEnvState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runSelectedEnvPath -Encoding UTF8

    $fullCommand = @($pythonCommand + $runnerArgs)
    $commandText = ($fullCommand | ForEach-Object { Quote-CommandArgument $_ }) -join " "
    $commandsPath = Join-Path $runDir "command.ps1"
    $commandLines = @(
        "# CPU OpenBLAS/NumPy GEMM benchmark command",
        "# Generated: $(Get-Date -Format o)"
    )
    $useNoUserSite = $NoUserSite -or ((-not $AllowUserSite) -and (-not [string]::IsNullOrWhiteSpace($CondaEnv)))
    if ($useNoUserSite) {
        $commandLines += '$env:PYTHONNOUSERSITE = "1"'
    }
    $commandLines += $commandText
    $commandLines | Set-Content -LiteralPath $commandsPath -Encoding UTF8

    Write-Host "Run directory: $runDir"
    Write-Host "Log: $logPath"
    Write-Host "Command: $commandText"

    $executable = $pythonCommand[0]
    $prefixArgs = @()
    if ($pythonCommand.Count -gt 1) {
        $prefixArgs = $pythonCommand[1..($pythonCommand.Count - 1)]
    }
    $previousNoUserSite = $env:PYTHONNOUSERSITE
    try {
        if ($useNoUserSite) {
            $env:PYTHONNOUSERSITE = "1"
            Write-Host "PYTHONNOUSERSITE=1"
        }
        & $executable @prefixArgs @runnerArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Benchmark command failed with exit code $exitCode."
        }
    }
    finally {
        if ($null -eq $previousNoUserSite) {
            Remove-Item Env:\PYTHONNOUSERSITE -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONNOUSERSITE = $previousNoUserSite
        }
    }

    Write-Host "Completed. Report: $(Join-Path $runDir 'report.md')"
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
