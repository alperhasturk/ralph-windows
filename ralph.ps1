param(
    [string]$PromptFile,
    [string]$Prompt,
    [int]$MaxIterations = 10,
    [string]$Promise = "<promise>COMPLETE</promise>",
    [string]$Workspace,
    [int]$IterationTimeoutSeconds,
    [string]$VerifyCommand,
    [switch]$FailOnTimeout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-WorkspaceRoot {
    param([string]$WorkspacePath)

    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        return (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $WorkspacePath)) {
        throw "Workspace path not found: $WorkspacePath"
    }

    return (Resolve-Path -LiteralPath $WorkspacePath).Path
}

function Resolve-PromptSource {
    param(
        [string]$PromptInline,
        [string]$PromptFilePath,
        [string]$WorkspaceRoot
    )

    $result = [ordered]@{
        Type = ""
        Value = ""
    }

    if (-not [string]::IsNullOrWhiteSpace($PromptInline)) {
        $result.Type = "inline"
        $result.Value = $PromptInline
        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace($PromptFilePath)) {
        $resolved = $PromptFilePath
        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $WorkspaceRoot $resolved
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Prompt file not found: $resolved"
        }
        $result.Type = "file"
        $result.Value = (Resolve-Path -LiteralPath $resolved).Path
        return $result
    }

    $defaultPrompt = Join-Path $WorkspaceRoot "prompt.md"
    if (-not (Test-Path -LiteralPath $defaultPrompt)) {
        throw "No prompt found. Provide -Prompt, -PromptFile, or create prompt.md in the workspace root."
    }

    $result.Type = "file"
    $result.Value = (Resolve-Path -LiteralPath $defaultPrompt).Path
    return $result
}

function Join-Args {
    param([string[]]$Args)

    $quoted = foreach ($arg in $Args) {
        [System.Management.Automation.Language.CodeGeneration]::QuoteArgument($arg)
    }
    return ($quoted -join " ")
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Write-State {
    param(
        [string]$StatePath,
        [int]$Iteration,
        [string]$Status,
        [int]$ExitCode,
        [DateTime]$StartedAt,
        [DateTime]$EndedAt
    )

    $state = [ordered]@{
        iteration = $Iteration
        status = $Status
        exit_code = $ExitCode
        started_at = $StartedAt.ToString("o")
        ended_at = $EndedAt.ToString("o")
    }

    $json = $state | ConvertTo-Json -Depth 3
    $json | Set-Content -LiteralPath $StatePath -Encoding utf8
}

function Invoke-VerifyCommand {
    param(
        [string]$Command,
        [string]$WorkspaceRoot
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $shell = "powershell"
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $shell = "pwsh"
    }

    $startInfo.FileName = $shell
    $startInfo.Arguments = Join-Args @("-NoProfile", "-Command", $Command)
    $startInfo.WorkingDirectory = $WorkspaceRoot
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [ordered]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

try {
    if ($MaxIterations -lt 1) {
        throw "MaxIterations must be at least 1."
    }

    $workspaceRoot = Resolve-WorkspaceRoot -WorkspacePath $Workspace
    $promptSource = Resolve-PromptSource -PromptInline $Prompt -PromptFilePath $PromptFile -WorkspaceRoot $workspaceRoot

    $opencodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $opencodeCommand) {
        throw "opencode not found on PATH. Install OpenCode or add it to PATH."
    }

    $ralphDir = Join-Path $workspaceRoot ".ralph"
    $logDir = Join-Path $ralphDir "logs"
    Ensure-Directory -Path $ralphDir
    Ensure-Directory -Path $logDir

    $statePath = Join-Path $ralphDir "state.json"

    for ($i = 1; $i -le $MaxIterations; $i++) {
        $iterId = "{0:D3}" -f $i
        $logPath = Join-Path $logDir "iter-$iterId.log"
        $startedAt = Get-Date

        Write-Host ""
        Write-Host "==============================================="
        Write-Host "  Ralph Iteration $iterId of $MaxIterations"
        Write-Host "==============================================="

        $args = @("run")
        if ($promptSource.Type -eq "inline") {
            $inlinePromptPath = Join-Path $ralphDir ("prompt-inline-$iterId.md")
            $promptSource.Value | Set-Content -LiteralPath $inlinePromptPath -Encoding utf8
            $args += @("--file", $inlinePromptPath)
        } else {
            $args += @("--file", $promptSource.Value)
        }

        $logWriter = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
        $logWriter.WriteLine("# ralph iteration $iterId")
        $logWriter.WriteLine("# started_at: $($startedAt.ToString("o"))")
        $logWriter.WriteLine("# workspace: $workspaceRoot")
        $logWriter.WriteLine("# prompt_source: $($promptSource.Type)")
        $logWriter.WriteLine("# command: opencode $(Join-Args $args)")
        $logWriter.WriteLine("# promise: $Promise")
        $logWriter.WriteLine("# max_iterations: $MaxIterations")
        $logWriter.WriteLine("# timeout_seconds: $IterationTimeoutSeconds")
        $logWriter.WriteLine("# verify_command: $VerifyCommand")
        $logWriter.WriteLine("# --- output ---")
        $logWriter.Flush()

        $outputBuilder = New-Object System.Text.StringBuilder
        $script:closing = $false

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "opencode"
        $startInfo.Arguments = Join-Args $args
        $startInfo.WorkingDirectory = $workspaceRoot
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $process.EnableRaisingEvents = $true
        $null = $process.Start()

        $process.add_OutputDataReceived({
            param($sender, $eventArgs)
            if ($script:closing) {
                return
            }
            if ($null -ne $eventArgs.Data) {
                $outputBuilder.AppendLine($eventArgs.Data) | Out-Null
                Write-Host $eventArgs.Data
                $logWriter.WriteLine($eventArgs.Data)
                $logWriter.Flush()
            }
        })

        $process.add_ErrorDataReceived({
            param($sender, $eventArgs)
            if ($script:closing) {
                return
            }
            if ($null -ne $eventArgs.Data) {
                $outputBuilder.AppendLine($eventArgs.Data) | Out-Null
                Write-Host $eventArgs.Data
                $logWriter.WriteLine($eventArgs.Data)
                $logWriter.Flush()
            }
        })

        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        $timedOut = $false
        if ($IterationTimeoutSeconds -and $IterationTimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($IterationTimeoutSeconds * 1000)) {
                $timedOut = $true
                try {
                    $process.Kill($true)
                } catch {
                    try {
                        $process.Kill()
                    } catch {
                    }
                }
            }
        }

        if (-not $timedOut) {
            $process.WaitForExit()
        }

        $script:closing = $true
        try {
            $process.CancelOutputRead()
            $process.CancelErrorRead()
        } catch {
        }
        Start-Sleep -Milliseconds 100

        $endedAt = Get-Date
        $duration = $endedAt - $startedAt
        $exitCode = if ($timedOut) { 4 } else { $process.ExitCode }
        $status = if ($timedOut) { "timeout" } else { "completed" }

        $logWriter.WriteLine("# --- end ---")
        $logWriter.WriteLine("# exit_code: $exitCode")
        $logWriter.WriteLine("# duration_seconds: $([math]::Round($duration.TotalSeconds, 3))")
        $logWriter.WriteLine("# ended_at: $($endedAt.ToString("o"))")
        $logWriter.Flush()
        $logWriter.Dispose()
        $process.Dispose()

        Write-State -StatePath $statePath -Iteration $i -Status $status -ExitCode $exitCode -StartedAt $startedAt -EndedAt $endedAt

        if ($timedOut) {
            Write-Host "Iteration $iterId timed out after $IterationTimeoutSeconds seconds."
            if ($FailOnTimeout) {
                exit 4
            }
            continue
        }

        $outputText = $outputBuilder.ToString()
        $hasPromise = $outputText -match [regex]::Escape($Promise)
        if (-not $hasPromise) {
            try {
                $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop
                $hasPromise = $logText -match [regex]::Escape($Promise)
            } catch {
            }
        }

        if ($hasPromise) {
            if (-not [string]::IsNullOrWhiteSpace($VerifyCommand)) {
                $verifyResult = Invoke-VerifyCommand -Command $VerifyCommand -WorkspaceRoot $workspaceRoot
                $logAppend = New-Object System.IO.StreamWriter($logPath, $true, (New-Object System.Text.UTF8Encoding($false)))
                $logAppend.WriteLine("# verify_exit_code: $($verifyResult.ExitCode)")
                $logAppend.WriteLine("# verify_stdout:")
                if (-not [string]::IsNullOrWhiteSpace($verifyResult.Stdout)) {
                    $logAppend.WriteLine($verifyResult.Stdout)
                }
                $logAppend.WriteLine("# verify_stderr:")
                if (-not [string]::IsNullOrWhiteSpace($verifyResult.Stderr)) {
                    $logAppend.WriteLine($verifyResult.Stderr)
                }
                $logAppend.Flush()
                $logAppend.Dispose()

                if ($verifyResult.ExitCode -eq 0) {
                    exit 0
                }

                Write-Host "Promise detected but verify command failed. Continuing."
                continue
            }

            exit 0
        }

        if ($process.ExitCode -ne 0) {
            Write-Host "Iteration $iterId exited with code $($process.ExitCode). Continuing."
        }
    }

    $lastLogPath = Join-Path $logDir ("iter-{0:D3}.log" -f $MaxIterations)
    Write-Host "Max iterations reached without completion."
    Write-Host "Logs directory: $logDir"
    Write-Host "Last log: $lastLogPath"
    exit 2
}
catch {
    Write-Error $_
    exit 1
}
