# NXP MCU Build Verify

`nxp-mcu-build-verify` is a skill for command-line build verification of NXP MCU projects on Windows. It detects the nearest supported project type, chooses the matching native build tool, and avoids incorrect GCC fallback for IDE-managed projects.

**Compatible with:** Claude Code, OpenAI Codex, and other AI agents that support skills.

## Highlights

- Auto-detects the nearest supported NXP MCU project
- Supports IAR, Keil, MCUXpresso IDE, and MCUXpresso VS Code projects
- Uses the native toolchain for each project type
- Emits compact, machine-friendly output for automation and debugging
- Refuses sandboxed real builds when the host environment is required

## Supported project types

| Project type | Marker |
| --- | --- |
| IAR | `.ewp` |
| Keil | `.uvprojx` |
| MCUXpresso IDE | `.project` + `.cproject` |
| MCUXpresso VS Code | `CMakePresets.json` or workspace/task markers |

## Why use this skill

NXP example projects often live behind multiple IDE-specific formats, toolchain assumptions, and workspace requirements. This skill standardizes the detection and verification flow so AI agents can:

- choose the right build path automatically
- avoid falling back to the wrong compiler
- emit a host-ready command when the build must run outside a sandbox
- keep console output short while still saving the full tool log

## Host execution policy

For real builds in sandboxed or agent-run environments, this skill emits `host_execution_command` and refuses in-place execution for:

- IAR
- Keil
- MCUXpresso IDE
- MCUXpresso VS Code

This behavior is intentional. It preserves host licensing, native IDE expectations, user-profile assumptions, and real workspace behavior.

## Repository layout

```text
nxp-mcu-build-verify/
  .gitignore
  README.md
  SKILL.md
  agents/
    claude-code.yaml
    openai.yaml
  references/
    project-markers.md
  scripts/
    detect-build.ps1
```

## Installation

### Claude Code

Copy this folder into your Claude Code skills directory:

```text
%USERPROFILE%\.claude\skills\nxp-mcu-build-verify\
```

Then start a new Claude Code session so the skill is discoverable.

### OpenAI Codex

Copy this folder into your Codex skills directory:

```text
%USERPROFILE%\.codex\skills\nxp-mcu-build-verify\
```

Then start a new Codex session so the skill is discoverable.

## Usage

### Claude Code

Use the skill via slash command or ask Claude to use it:

```text
/nxp-mcu-build-verify
```

Or:

```text
Use nxp-mcu-build-verify to detect this NXP MCU project type and run the matching command-line build check without GCC fallback.
```

### OpenAI Codex

Ask Codex to use the skill directly:

```text
Use $nxp-mcu-build-verify to detect this NXP MCU project type and run the matching command-line build check without GCC fallback.
```

## Direct script usage

Dry-run detection:

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project" -DryRun
```

Real build verification:

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project"
```

Explicit project-type examples:

```powershell
# IAR
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project" -Type IAR -Config "Debug"

# Keil
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project" -Type Keil -Config "Debug"

# MCUXpresso IDE
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project" -Type MCUXpressoIDE -Config "Debug"

# MCUXpresso VS Code
powershell -ExecutionPolicy Bypass -File ".\scripts\detect-build.ps1" -ProjectRoot "C:\path\to\project" -Type MCUXpressoVSCode -Config "debug"
```

## Output contract

The script emits machine-readable keys that are easy to parse in logs and automation:

- `project_type`
- `detected_file`
- `tool_path`
- `selected_command`
- `tool_output_mode`
- `tool_log`
- `preferred_execution_mode`
- `recommended_timeout_ms`
- `execution_hint`
- `host_execution_command`

For host-only refusal cases, it also emits:

- `sandbox_execution_refused=true`

## Requirements

- Windows host
- PowerShell capable of running `detect-build.ps1`
- The matching native toolchain installed for the project being built

If a required tool is missing, install or configure that toolchain instead of switching to GCC.

## Design notes

- IAR, Keil, and MCUXpresso IDE builds intentionally stay on their native toolchains
- MCUXpresso VS Code preset builds are translated into explicit `cmake -S/-B` and `cmake --build` commands
- Detection precedence and markers are documented in `references/project-markers.md`

## Included files

- `SKILL.md` contains the skill instructions and hard rules
- `scripts/detect-build.ps1` contains the detection and build logic
- `references/project-markers.md` documents supported markers and precedence
- `agents/claude-code.yaml` provides Claude Code UI metadata
- `agents/openai.yaml` provides OpenAI Codex UI metadata
