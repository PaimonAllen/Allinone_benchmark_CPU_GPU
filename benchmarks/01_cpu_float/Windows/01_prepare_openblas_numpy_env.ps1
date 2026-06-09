[CmdletBinding()]
param(
    [string]$EnvName = "cudadev",
    [switch]$VerifyOnly,
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

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Capture
    )
    $commandText = (@($Executable) + $Arguments | ForEach-Object { Quote-CommandArgument $_ }) -join " "
    Write-Host "Command: $commandText"
    if ($DryRun) {
        return ""
    }
    if ($Capture) {
        $output = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output | Out-String
        Write-Host $text
        if ($exitCode -ne 0) {
            throw "Command failed with exit code $exitCode."
        }
        return $text
    }
    & $Executable @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode."
    }
    return ""
}

function Get-CondaEnvironments {
    param([Parameter(Mandatory = $true)][string]$CondaPath)
    $jsonText = & $CondaPath env list --json | Out-String
    $envList = $jsonText | ConvertFrom-Json
    $environments = @()
    foreach ($envPath in $envList.envs) {
        $environments += [pscustomobject]@{
            Name = Split-Path -Leaf $envPath
            Path = $envPath
        }
    }
    return $environments
}

function Test-CondaEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Environments,
        [Parameter(Mandatory = $true)][string]$EnvName
    )
    foreach ($environment in $Environments) {
        if ($environment.Name -ieq $EnvName) {
            return $true
        }
    }
    return $false
}

function Get-CondaEnvironmentPath {
    param(
        [Parameter(Mandatory = $true)]$Environments,
        [Parameter(Mandatory = $true)][string]$EnvName
    )
    foreach ($environment in $Environments) {
        if ($environment.Name -ieq $EnvName) {
            return $environment.Path
        }
    }
    return ""
}

function Select-ExistingCondaEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Environments,
        [Parameter(Mandatory = $true)][string]$DefaultEnvName
    )

    if (Test-CondaEnvironment -Environments $Environments -EnvName $DefaultEnvName) {
        return $DefaultEnvName
    }

    Write-Warning "Conda environment '$DefaultEnvName' was not found. This script will not create or modify conda environments."
    Write-Host ""
    Write-Host "Available conda environments:"
    foreach ($environment in $Environments) {
        Write-Host ("  {0}  {1}" -f $environment.Name, $environment.Path)
    }
    Write-Host ""

    while ($true) {
        $inputName = Read-Host "Enter an existing conda environment name with OpenBLAS [default: $DefaultEnvName]"
        if ([string]::IsNullOrWhiteSpace($inputName)) {
            $inputName = $DefaultEnvName
        }
        if (Test-CondaEnvironment -Environments $Environments -EnvName $inputName) {
            return $inputName
        }
        Write-Warning "Conda environment '$inputName' was not found. Please enter one of the listed environment names."
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$logRoot = Join-Path $scriptRoot "logs"
$selectedEnvPath = Join-Path $scriptRoot "selected_env.json"
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$logPath = Join-Path $logRoot ("{0}_prepare_{1}.log" -f $timestamp, $EnvName)
$verifyPath = Join-Path $logRoot ("{0}_prepare_{1}_verify.json" -f $timestamp, $EnvName)
$verifyScriptPath = Join-Path $logRoot ("{0}_prepare_{1}_verify.py" -f $timestamp, $EnvName)
$transcriptStarted = $false

try {
    Start-Transcript -Path $logPath -Force | Out-Null
    $transcriptStarted = $true

    $condaPath = Resolve-Tool "conda"
    if ($null -eq $condaPath) {
        throw "conda was not found on PATH."
    }

    Write-Host "Conda: $condaPath"
    Write-Host "Default CPU float conda environment: $EnvName"
    Write-Host "This script verifies an existing OpenBLAS NumPy environment for the Windows CPU benchmark."
    Write-Host "It does not create, remove, or modify conda environments."
    Invoke-LoggedCommand -Executable $condaPath -Arguments @("--version") | Out-Null

    $environments = Get-CondaEnvironments -CondaPath $condaPath
    $selectedEnvName = Select-ExistingCondaEnvironment -Environments $environments -DefaultEnvName $EnvName
    if ($selectedEnvName -ne $EnvName) {
        Write-Host "Selected conda environment: $selectedEnvName"
        $EnvName = $selectedEnvName
    }
    Write-Host "Conda environment '$EnvName' exists. Verifying the current BLAS backend."

    $verifyCode = @'
import json
import sys

import numpy as np
from threadpoolctl import threadpool_info

payload = {
    "python_executable": sys.executable,
    "python_version": sys.version.replace("\n", " "),
    "numpy_version": np.__version__,
    "numpy_path": np.__file__,
    "threadpool_info": threadpool_info(),
}
print(json.dumps(payload, indent=2))
'@

    if (-not $DryRun) {
        $verifyCode | Set-Content -LiteralPath $verifyScriptPath -Encoding UTF8
    }
    Write-Host "Verify script: $verifyScriptPath"

    $previousNoUserSite = $env:PYTHONNOUSERSITE
    try {
        $env:PYTHONNOUSERSITE = "1"
        Write-Host "PYTHONNOUSERSITE=1"
        $verifyText = Invoke-LoggedCommand -Executable $condaPath -Arguments @("run", "-n", $EnvName, "python", $verifyScriptPath) -Capture
    }
    finally {
        if ($null -eq $previousNoUserSite) {
            Remove-Item Env:\PYTHONNOUSERSITE -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONNOUSERSITE = $previousNoUserSite
        }
    }

    if (-not $DryRun) {
        $jsonStart = $verifyText.IndexOf("{")
        $jsonEnd = $verifyText.LastIndexOf("}")
        if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
            throw "Could not parse verification JSON from conda output. See $logPath."
        }
        $verifyJsonText = $verifyText.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        $verifyPayload = $verifyJsonText | ConvertFrom-Json
        $verifyJsonText | Set-Content -LiteralPath $verifyPath -Encoding UTF8

        $blasInfo = @($verifyPayload.threadpool_info | Where-Object {
            $_.user_api -eq "blas" -and $_.internal_api -eq "openblas"
        } | Select-Object -First 1)
        if ($blasInfo.Count -eq 0) {
            throw "Environment '$EnvName' did not report OpenBLAS. See $verifyPath. Please choose or prepare an existing conda environment whose NumPy uses OpenBLAS, then rerun this script with -EnvName <name>. If you intentionally want to benchmark the current BLAS backend, run .\02_run_openblas_numpy_benchmark.ps1 -CondaEnv $EnvName -AllowAnyBlas."
        }

        $envPath = Get-CondaEnvironmentPath -Environments $environments -EnvName $EnvName
        $state = [ordered]@{
            schema_version = 1
            selected_env = $EnvName
            env_path = $envPath
            conda_executable = $condaPath
            verified_at = Get-Date -Format o
            verification_json = $verifyPath
            verification_script = $verifyScriptPath
            python_executable = $verifyPayload.python_executable
            python_version = $verifyPayload.python_version
            numpy_version = $verifyPayload.numpy_version
            numpy_path = $verifyPayload.numpy_path
            blas_backend = ("{0} {1} {2} {3}" -f $blasInfo.internal_api, $blasInfo.version, $blasInfo.threading_layer, $blasInfo.architecture).Trim()
            blas_library = $blasInfo.filepath
            blas_num_threads = $blasInfo.num_threads
            threadpool_info = $verifyPayload.threadpool_info
        }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $selectedEnvPath -Encoding UTF8
    }

    if ($DryRun) {
        Write-Host "Dry run completed. No conda environment was modified or verified."
    }
    else {
        Write-Host "OpenBLAS conda environment verified: $EnvName"
        Write-Host "Verification: $verifyPath"
        Write-Host "Selected environment state: $selectedEnvPath"
        Write-Host "Next: .\02_run_openblas_numpy_benchmark.ps1"
    }
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
