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

# Script safety defaults and shared state.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:QuoteArgumentMethod = $null

# Workspace and prompt resolution helpers.
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

# Command-line argument quoting helpers.
function Quote-CommandLineArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    $builder.Append('"') | Out-Null

    $index = 0
    while ($index -lt $Value.Length) {
        $backslashCount = 0
        while ($index -lt $Value.Length -and $Value[$index] -eq '\\') {
            $backslashCount++
            $index++
        }

        if ($index -ge $Value.Length) {
            if ($backslashCount -gt 0) {
                $builder.Append(('\\' * ($backslashCount * 2))) | Out-Null
            }
            break
        }

        if ($Value[$index] -eq '"') {
            if ($backslashCount -gt 0) {
                $builder.Append(('\\' * ($backslashCount * 2))) | Out-Null
            }
            $builder.Append('\"') | Out-Null
            $index++
            continue
        }

        if ($backslashCount -gt 0) {
            $builder.Append(('\\' * $backslashCount)) | Out-Null
        }
        $builder.Append($Value[$index]) | Out-Null
        $index++
    }

    $builder.Append('"') | Out-Null
    return $builder.ToString()
}

function Join-Args {
    param([string[]]$CommandArgs)

    $quoted = foreach ($arg in $CommandArgs) {
        if ($null -eq $script:QuoteArgumentMethod) {
            $script:QuoteArgumentMethod = [System.Management.Automation.Language.CodeGeneration].GetMethod("QuoteArgument", [type[]]@([string]))
        }
        if ($script:QuoteArgumentMethod) {
            $script:QuoteArgumentMethod.Invoke($null, @($arg))
        } else {
            Quote-CommandLineArgument -Value $arg
        }
    }
    return ($quoted -join " ")
}

# Output formatting and filtering helpers.
function Format-Color {
    param(
        [string]$Text,
        [string]$Color
    )
    return $Text
}

function Write-Phase {
    param([string]$Message)

    $label = Format-Color -Text "Phase" -Color "cyan"
    Write-Host ("{0}: {1}" -f $label, $Message)
}

function Remove-AnsiEscape {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    return [regex]::Replace($Text, "\x1B\[[0-9;]*[A-Za-z]", "")
}

function Should-PrintLine {
    param(
        [string]$PlainLine,
        [string]$PromiseText
    )

    if ($null -eq $PlainLine) {
        return $false
    }

    $trimmed = $PlainLine.Trim()
    if ($trimmed.Length -eq 0) {
        return $true
    }

    if (-not [string]::IsNullOrEmpty($PromiseText) -and $trimmed -eq $PromiseText.Trim()) {
        return $false
    }

    if ($trimmed -match '^(INFO|DEBUG)\s+\d{4}-\d{2}-\d{2}T') {
        return $false
    }

    if ($trimmed -match '^\|\s+(apply_patch|Apply_patch)\b') {
        return $true
    }

    if ($trimmed -match '^\|\s+\w+') {
        return $false
    }

    return $true
}

function Print-FilteredOutput {
    param(
        [string]$Text,
        [string]$PromiseText,
        [ref]$InSystemReminder
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $lines = [regex]::Split($Text, "\r?\n")
    foreach ($line in $lines) {
        $plainLine = Remove-AnsiEscape -Text $line

        if ($plainLine -match '<system-reminder>') {
            $InSystemReminder.Value = $true
            continue
        }
        if ($InSystemReminder.Value) {
            if ($plainLine -match '</system-reminder>') {
                $InSystemReminder.Value = $false
            }
            continue
        }

        if (Should-PrintLine -PlainLine $plainLine -PromiseText $PromiseText) {
            Write-Host $plainLine
        }
    }
}

# Iteration summary and state helpers.
function Write-IterationSummary {
    param(
        [int]$Iteration,
        [int]$MaxIterations,
        [string]$Status,
        [int]$ExitCode,
        [TimeSpan]$Duration,
        [bool]$PromiseDetected,
        [Nullable[int]]$VerifyExitCode,
        [string]$VerifyCommand
    )

    $durationString = $Duration.ToString("hh\:mm\:ss")

    $statusColor = "gray"
    if ($Status -eq "timeout") {
        $statusColor = "yellow"
    } elseif ($ExitCode -ne 0) {
        $statusColor = "red"
    } elseif ($PromiseDetected) {
        $statusColor = "green"
    } else {
        $statusColor = "cyan"
    }

    $exitColor = if ($ExitCode -ne 0) { "red" } else { "green" }
    $promiseLabel = if ($PromiseDetected) { Format-Color -Text "detected" -Color "green" } else { "not found" }

    Write-Host ""
    Write-Host "Summary"
    Write-Host ("  Iteration : {0}/{1}" -f $Iteration, $MaxIterations)
    Write-Host ("  Status    : {0}" -f (Format-Color -Text $Status -Color $statusColor))
    Write-Host ("  Exit Code : {0}" -f (Format-Color -Text $ExitCode.ToString() -Color $exitColor))
    Write-Host ("  Duration  : {0}" -f $durationString)
    Write-Host ("  Promise   : {0}" -f $promiseLabel)

    if (-not [string]::IsNullOrWhiteSpace($VerifyCommand)) {
        if ($null -eq $VerifyExitCode) {
            $verifyLabel = "skipped"
        } elseif ($VerifyExitCode -eq 0) {
            $verifyLabel = Format-Color -Text "passed" -Color "green"
        } else {
            $verifyLabel = Format-Color -Text ("failed ($VerifyExitCode)") -Color "red"
        }
        Write-Host ("  Verify    : {0}" -f $verifyLabel)
    }
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

# Verification command runner.
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

# Main loop: resolve inputs, run iterations, and stop on completion.
try {
    # Validate inputs and resolve prompt sources.
    if ($MaxIterations -lt 1) {
        throw "MaxIterations must be at least 1."
    }

    $workspaceRoot = Resolve-WorkspaceRoot -WorkspacePath $Workspace
    $promptSource = Resolve-PromptSource -PromptInline $Prompt -PromptFilePath $PromptFile -WorkspaceRoot $workspaceRoot

    $opencodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
    if (-not $opencodeCommand) {
        throw "opencode not found on PATH. Install OpenCode or add it to PATH."
    }

    # Prepare workspace state/log directories.
    $ralphDir = Join-Path $workspaceRoot ".ralph"
    $logDir = Join-Path $ralphDir "logs"
    Ensure-Directory -Path $ralphDir
    Ensure-Directory -Path $logDir

    $statePath = Join-Path $ralphDir "state.json"

    # Iteration loop: run OpenCode and evaluate completion.
    for ($i = 1; $i -le $MaxIterations; $i++) {
        $iterId = "{0:D3}" -f $i
        $logPath = Join-Path $logDir "iter-$iterId.log"
        $startedAt = Get-Date

        $boxLine = "=" * 55
        $timeoutLabel = if ($IterationTimeoutSeconds -and $IterationTimeoutSeconds -gt 0) { "${IterationTimeoutSeconds}s" } else { "none" }

        Write-Host ""
        Write-Host $boxLine
        Write-Host ("  Ralph Loop :: Iteration {0}/{1}" -f $iterId, $MaxIterations)
        Write-Host $boxLine
        Write-Host ("  Workspace     : {0}" -f $workspaceRoot)
        Write-Host ("  Prompt Source : {0}" -f $promptSource.Type)
        if ($promptSource.Type -eq "file") {
            Write-Host ("  Prompt File   : {0}" -f $promptSource.Value)
        } else {
            $inlineLength = if ($null -ne $promptSource.Value) { $promptSource.Value.Length } else { 0 }
            Write-Host ("  Prompt Inline : {0} chars" -f $inlineLength)
        }
        Write-Host ("  Timeout       : {0}" -f $timeoutLabel)
        Write-Host ("  Promise       : {0}" -f $Promise)
        Write-Host $boxLine

        # Assemble OpenCode command and write log headers.
        $opencodeArgs = @("run", "Follow the instructions in the attached prompt file.") #opencode run command needs a message to work can't pass in the prompt.md file without a message
        if ($promptSource.Type -eq "inline") {
            $inlinePromptPath = Join-Path $ralphDir ("prompt-inline-$iterId.md")
            $promptSource.Value | Set-Content -LiteralPath $inlinePromptPath -Encoding utf8
            $opencodeArgs += @("--file", $inlinePromptPath)
        } else {
            $opencodeArgs += @("--file", $promptSource.Value)
        }

        $logWriter = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding($false)))
        $logWriter.WriteLine("# ralph iteration $iterId")
        $logWriter.WriteLine("# started_at: $($startedAt.ToString("o"))")
        $logWriter.WriteLine("# workspace: $workspaceRoot")
        $logWriter.WriteLine("# prompt_source: $($promptSource.Type)")
        $logWriter.WriteLine("# command: opencode $(Join-Args $opencodeArgs)")
        $logWriter.WriteLine("# promise: $Promise")
        $logWriter.WriteLine("# max_iterations: $MaxIterations")
        $logWriter.WriteLine("# timeout_seconds: $IterationTimeoutSeconds")
        $logWriter.WriteLine("# verify_command: $VerifyCommand")
        $logWriter.WriteLine("# --- output ---")
        $logWriter.Flush()

        $outputBuilder = New-Object System.Text.StringBuilder

        # Start OpenCode process and enforce timeout.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "opencode"
        $startInfo.Arguments = Join-Args $opencodeArgs
        $startInfo.WorkingDirectory = $workspaceRoot
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $process.EnableRaisingEvents = $true

        Write-Phase "Starting OpenCode"

        $null = $process.Start()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $timedOut = $false
        $deadline = $null
        if ($IterationTimeoutSeconds -and $IterationTimeoutSeconds -gt 0) {
            $deadline = $startedAt.AddSeconds($IterationTimeoutSeconds)
        }

        $heartbeatIntervalSeconds = 2
        $nextHeartbeat = (Get-Date).AddSeconds($heartbeatIntervalSeconds)
        $spinnerFrames = @('|', '/', '-', '\')
        $spinnerIndex = 0
        $lastStatus = $null

        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 200
            $now = Get-Date

            if ($deadline -and $now -ge $deadline) {
                $timedOut = $true
                try {
                    $process.Kill($true)
                } catch {
                    try {
                        $process.Kill()
                    } catch {
                    }
                }
                break
            }

            if ($now -ge $nextHeartbeat) {
                $elapsed = $now - $startedAt
                $elapsedString = $elapsed.ToString("hh\:mm\:ss")
                $spinner = $spinnerFrames[$spinnerIndex % $spinnerFrames.Length]
                $status = "$spinner Iter $iterId/$MaxIterations still running... $elapsedString"
                if ($lastStatus -and $lastStatus.Length -gt $status.Length) {
                    $status = $status + (' ' * ($lastStatus.Length - $status.Length))
                }
                Write-Host -NoNewline ("`r{0}" -f $status)
                $lastStatus = $status
                $spinnerIndex++
                $nextHeartbeat = $now.AddSeconds($heartbeatIntervalSeconds)
            }
        }

        try {
            if (-not $timedOut) {
                $process.WaitForExit()
            } else {
                $process.WaitForExit(5000) | Out-Null
            }
        } catch {
        }

        if ($lastStatus) {
            Write-Host ""
        }
        Start-Sleep -Milliseconds 100

        # Collect output and write logs.
        Write-Phase "Collecting output"

        $stdout = ""
        $stderr = ""
        try {
            $stdout = $stdoutTask.GetAwaiter().GetResult()
        } catch {
        }
        try {
            $stderr = $stderrTask.GetAwaiter().GetResult()
        } catch {
        }

        $inSystemReminder = $false

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $outputBuilder.Append($stdout) | Out-Null
            $logWriter.Write($stdout)
            Print-FilteredOutput -Text $stdout -PromiseText $Promise -InSystemReminder ([ref]$inSystemReminder)
        }

        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $outputBuilder.Append($stderr) | Out-Null
            $logWriter.Write($stderr)
            Print-FilteredOutput -Text $stderr -PromiseText $Promise -InSystemReminder ([ref]$inSystemReminder)
        }

        $logWriter.Flush()

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
            Write-IterationSummary -Iteration $i -MaxIterations $MaxIterations -Status $status -ExitCode $exitCode -Duration $duration -PromiseDetected:$false -VerifyExitCode $null -VerifyCommand $VerifyCommand
            if ($FailOnTimeout) {
                exit 4
            }
            continue
        }

        # Detect completion promise and optionally verify.
        Write-Phase "Checking for completion"

        $outputText = $outputBuilder.ToString()
        $verifyExitCode = $null
        $hasPromise = $outputText -match [regex]::Escape($Promise)
        if (-not $hasPromise) {
            try {
                $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop
                $logOutput = $logText
                $outputMatch = [regex]::Match($logText, "(?s)# --- output ---\s*(.*?)# --- end ---")
                if ($outputMatch.Success) {
                    $logOutput = $outputMatch.Groups[1].Value
                }
                $hasPromise = $logOutput -match [regex]::Escape($Promise)
            } catch {
            }
        }

        if ($hasPromise) {
            if (-not [string]::IsNullOrWhiteSpace($VerifyCommand)) {
                $verifyResult = Invoke-VerifyCommand -Command $VerifyCommand -WorkspaceRoot $workspaceRoot
                $verifyExitCode = $verifyResult.ExitCode
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
                    Write-IterationSummary -Iteration $i -MaxIterations $MaxIterations -Status $status -ExitCode $exitCode -Duration $duration -PromiseDetected:$true -VerifyExitCode $verifyExitCode -VerifyCommand $VerifyCommand
                    exit 0
                }

                Write-Host "Promise detected but verify command failed. Continuing."
                Write-IterationSummary -Iteration $i -MaxIterations $MaxIterations -Status $status -ExitCode $exitCode -Duration $duration -PromiseDetected:$true -VerifyExitCode $verifyExitCode -VerifyCommand $VerifyCommand
                continue
            }

            Write-IterationSummary -Iteration $i -MaxIterations $MaxIterations -Status $status -ExitCode $exitCode -Duration $duration -PromiseDetected:$true -VerifyExitCode $verifyExitCode -VerifyCommand $VerifyCommand
            exit 0
        }

        if ($exitCode -ne 0) {
            Write-Host "Iteration $iterId exited with code $exitCode. Continuing."
        }
        Write-IterationSummary -Iteration $i -MaxIterations $MaxIterations -Status $status -ExitCode $exitCode -Duration $duration -PromiseDetected:$false -VerifyExitCode $verifyExitCode -VerifyCommand $VerifyCommand
    }

    # Max iterations reached without completion.
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
