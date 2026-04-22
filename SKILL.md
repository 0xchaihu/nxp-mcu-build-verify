---
name: nxp-mcu-build-verify
description: Use when working in NXP MCU C/C++ projects on Windows and you need command-line build verification without accidental GCC fallback. Trigger for IAR (.ewp), Keil (.uvprojx), MCUXpresso IDE (.project + .cproject), or MCUXpresso VS Code (CMakePresets.json, or .code-workspace + .vscode/tasks.json).
---

# NXP MCU Build Verify

## Overview
Use this skill to detect the NXP MCU project type and run build verification with the matching command-line tool only. Never fall back to GCC for IAR, Keil, or MCUXpresso IDE projects.

## Workflow
1. Use dry-run when you need to confirm detection, preview the exact command, or obtain a host_execution_command before requesting host execution. If the project type and execution path are already known, skip dry-run and run the real build directly.
2. When the project type is already known, prefer an explicit direct invocation such as `-Type MCUXpressoVSCode -Config debug` instead of spending an extra round-trip on dry-run. Match MCUXpresso VS Code preset naming from `CMakePresets.json`; keep IAR, Keil, and MCUXpresso IDE config names as defined by those tools, typically `Debug` / `Release`.
3. Real builds default to compact tool output: write the raw tool log to a system temporary log directory and print only a short summary in the console.
4. Add `-FullToolOutput` only when diagnosing toolchain or project-file issues and the compact summary is insufficient.
5. For MCUXpresso IDE real builds, use `mcuxpressoidec.exe -nosplash --launcher.suppressErrors -application org.eclipse.cdt.managedbuilder.core.headlessbuild -data <workspace-or-temp-workspace> -build <project/config>` as the default generic path for `.project + .cproject` projects. If a parent Eclipse workspace with `.metadata` exists, prefer that real workspace; when running from a mirrored or sandboxed workspace copy, try to resolve the matching real project under the user workspace first. Only fall back to a temporary workspace plus `-import` when no real workspace can be found.
6. In sandboxed or agent-run environments, explicitly refuse MCUXpresso IDE sandbox execution. Emit a direct native-tool `host_execution_command`, print `sandbox_execution_refused=true`, and require the caller to rerun it on the host or in an unsandboxed shell. Do not first try a sandbox build, do not stop at only printing a command, and never launch `mcuxpressoide.exe`.
7. For IAR real builds in sandboxed or agent-run environments, explicitly refuse sandbox execution. Emit a direct native-tool `host_execution_command`, print `sandbox_execution_refused=true`, and require the caller to rerun it on the host or in an unsandboxed shell. Allow at least 20 minutes before timing out once running on the host.
8. For Keil real builds in sandboxed or agent-run environments, explicitly refuse sandbox execution. Emit a direct native-tool `host_execution_command`, print `sandbox_execution_refused=true`, and require the caller to rerun it on the host or in an unsandboxed shell. Prefer the real Windows user environment because sandbox usernames can invalidate user-based licenses.
9. For Keil, prefer `uVision.com` over `UV4.exe` for command-line builds.
10. If an IAR build is interrupted, inspect `<Config>\.ninja_log`, `<Config>\Exe\*.srec`, and `<Config>\Exe\*.out` before concluding it failed.
11. If compact mode reports a native-tool stderr warning without a non-zero exit code, inspect the log or rerun with `-FullToolOutput` before treating it as a hard failure.
12. For MCUXpresso VS Code projects with `CMakePresets.json`, translate the selected configure preset into explicit `cmake -S/-B` and `cmake --build` commands instead of calling `cmake --preset`. Resolve `include`, `inherits`, `binaryDir`, `toolchainFile`, `cacheVariables`, and preset environment values in PowerShell first so the build still works on machines whose CMake cannot parse newer preset versions.
13. For MCUXpresso VS Code real builds in sandboxed or agent-run environments, explicitly refuse to run inside the sandbox. Emit a PowerShell `host_execution_command`, print that sandbox execution was refused, and require the caller to run it directly on the host.
14. If the script reports a missing tool, stop and install/configure that IDE toolchain; do not switch to GCC.

## Commands
```powershell
# Optional dry-run (detect + print command, no build)
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -DryRun

# Real build verification (compact summary + log file)
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>"

# Real build verification with full tool output
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -FullToolOutput

# Recommended direct build when the project type is already known
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Type MCUXpressoVSCode -Config "debug"

# IAR host/unsandboxed build template
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Type IAR -Config "Debug"

# Keil host/unsandboxed build template
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Type Keil -Config "Debug"

# Explicit configuration / target (for tool-defined names such as `Debug`)
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Config "Debug"

# MCUXpresso IDE managedbuilder headlessbuild template
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Type MCUXpressoIDE -Config "Debug"

# Force project type when mixed markers exist
powershell -ExecutionPolicy Bypass -File "<skill-root>\\scripts\\detect-build.ps1" -ProjectRoot "<project-path>" -Type "Keil" -DryRun
```

## Output Contract
The script always prints these keys so logs are easy to parse:
- `forced_type` (only when `-Type` is set)
- `project_type`
- `detected_file`
- `detected_configs` (comma-separated list of build configurations extracted from the project file)
- `tool_path`
- `selected_command`
- `tool_output_mode` and `tool_log` for real builds in compact mode
- `preferred_execution_mode`, `recommended_timeout_ms`, `execution_hint`, and a `host_execution_command` for IAR, Keil, MCUXpresso IDE, and MCUXpresso VS Code builds that should run on the host
- `keil_tools_ini`, `keil_tools_ini_issue`, `keil_tools_ini_backup_hint`, and `keil_tools_ini_repair_hint` when Keil configuration is invalid

Failures return a non-zero exit code and include actionable guidance on the missing tool path/configuration.

## Detection Rules
See `references/project-markers.md` for marker and command details.

## Hard Rules
- Prefer the nearest detected project root.
- If multiple markers exist in the same directory, prefer: IAR > Keil > MCUXpresso IDE > MCUXpresso VS Code.
- `-Type` can force one type: `IAR`, `Keil`, `MCUXpressoIDE`, `MCUXpressoVSCode` (aliases: `ide`, `vscode`).
- If `-Config` is not provided, all project types extract available build configurations from the project file first (IAR from `.ewp`, Keil from `.uvprojx`, MCUXpresso IDE from `.cproject`, MCUXpresso VS Code from `CMakePresets.json`). Configurations containing "debug" are tried first, then "release", then all others. If no configs are found in the project file, fall back to `Debug` then `Release`.
- For MCUXpresso VS Code, prefer the preset/configuration spelling used in `CMakePresets.json` in examples and direct invocations, which is often lowercase such as `debug` / `release`.
- Dry-run is optional; use it when detection is uncertain, when you need to preview commands, or when you need a `host_execution_command` for host-side execution. If the project type and exact invocation are already known, run the real build directly.
- Real builds default to compact tool output and write the raw tool log under a system temporary log directory; use `-FullToolOutput` only when detailed live output is required.
- For MCUXpresso IDE, default to `mcuxpressoidec.exe -nosplash --launcher.suppressErrors -application org.eclipse.cdt.managedbuilder.core.headlessbuild -build <project/config>`. Prefer the real parent workspace when `.metadata` exists; when running from a mirrored or sandboxed workspace copy, first resolve the matching real project/workspace under the user profile. Only then fall back to a temporary `-data` workspace plus `-import <projectDir>`.
- For MCUXpresso IDE, emit `preferred_execution_mode=host_or_unsandboxed`, `recommended_timeout_ms=1200000`, an `execution_hint`, and a direct native-tool `host_execution_command` for real builds. In Codex or any sandboxed/agent-run environment, emit `sandbox_execution_refused=true` and refuse the real build instead of attempting it.
- For MCUXpresso IDE, do not switch to `com.nxp.mcuxpresso.headless.build`; that application id is not present in this installation.
- For MCUXpresso IDE, pass an explicit writable temporary Eclipse `-configuration` directory instead of relying on the default profile location.
- For MCUXpresso IDE, never launch `mcuxpressoide.exe`; use `mcuxpressoidec.exe` headless only.
- For IAR, emit `recommended_timeout_ms=1200000`, `preferred_execution_mode=host_or_unsandboxed`, and a direct native-tool `host_execution_command`; in Codex or any sandboxed/agent-run environment, emit `sandbox_execution_refused=true` and refuse the real build instead of attempting it.
- For IAR, treat fresh `Exe\*.srec` / `Exe\*.out` / `List\*.map` artifacts as success evidence when the wrapper exits non-zero.
- For Keil, emit `preferred_execution_mode=host_or_unsandboxed`, prefer `uVision.com`, and in Codex or any sandboxed/agent-run environment emit `sandbox_execution_refused=true` and refuse the real build instead of attempting it.
- For Keil, validate `TOOLS.INI` before building; if repair is needed, require explicit user confirmation and back up the original file first.
- For Keil, when `TOOLS.INI` is invalid, emit short repair diagnostics, but never modify `TOOLS.INI` automatically from the shared skill.
- For MCUXpresso VS Code projects with `CMakePresets.json`, do not invoke `cmake --preset` or `cmake --build --preset` directly. Parse the preset files in PowerShell, resolve inherited environment/cache variables, then run explicit `cmake -S <project-dir> -B <binary-dir> ...` followed by `cmake --build <binary-dir>` so the same skill works on computers with older CMake versions.
- For MCUXpresso VS Code real builds in Codex or any sandboxed/agent-run environment, emit `preferred_execution_mode=host_or_unsandboxed`, `recommended_timeout_ms=1200000`, an `execution_hint`, and a PowerShell `host_execution_command`, then explicitly refuse sandbox execution instead of attempting the build.
- When the translated MCUXpresso VS Code configure preset selects a Ninja generator, resolve `ninja.exe` from common MCUXpresso locations before falling back to `PATH`, and pass it as `CMAKE_MAKE_PROGRAM` if the preset did not already define one.
- Do not use GCC fallback unless the project is an actual CMake-based MCUXpresso VS Code project.













