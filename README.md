# ralph-windows

A PowerShell implementation of the Ralph autonomous agent loop that runs directly on Windows.

This project currently supports only **OpenCode**, which works natively with the Windows filesystem.

Other CLI tools (such as claude-code, codex, or copilot-cli) typically assume a Unix environment or Unix filesystem semantics and therefore require WSL.


## Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+
- OpenCode installed and `opencode` available on PATH
- PowerShell allows local script execution (for example: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`)

## Installation (Windows)

Steps:

1. Clone this repository.
2. From PowerShell, run:

```powershell
./ralph.ps1
```



## Workflow

1. Copy `ralph.ps1` into the root of the workspace you want to operate on.
2. Create or edit `prompt.md` in that workspace and add your tasks/instructions.
3. Open PowerShell in the workspace directory.
4. Run the loop:

```powershell
./ralph.ps1
```

Run with the default `prompt.md` in the workspace root:

```powershell
./ralph.ps1
```

Run with a specific prompt file:

```powershell
./ralph.ps1 -PromptFile .\prompt.md
```

Run with an inline prompt:

```powershell
./ralph.ps1 -Prompt "Write a short status update in the repo"
```

Control iteration count and timeout:

```powershell
./ralph.ps1 -MaxIterations 5 -IterationTimeoutSeconds 120
```


## prompt.md

`prompt.md` is the default instruction source for each loop iteration. If you do not supply `-Prompt` or `-PromptFile`, the loop reads `prompt.md` from the workspace root and passes it to OpenCode as the task payload. Keep it explicit about goals, constraints, and completion criteria.

## .ralph/

`.ralph/` is the only persistent loop state. It is created in the workspace root and contains:

- `state.json` with the latest iteration status and timestamps.
- `logs/iter-###.log` files with the full OpenCode output per iteration.
- Inline prompt snapshots when `-Prompt` is used.

No other state is hidden or stored elsewhere.

## References

- OpenCode CLI `run` docs: https://opencode.ai/docs/cli/#run-1
- Geoffery Huntley, "Ralph": https://ghuntley.com/ralph/

## License

This project is licensed under the MIT License
