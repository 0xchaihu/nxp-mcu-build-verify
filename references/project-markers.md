# NXP MCU Project Markers and Build Commands

This skill targets Windows PowerShell and chooses a single project type before building.

## Project Markers

1. **IAR**
   - Marker: `*.ewp`
   - Build command template:
     - `IarBuild.exe <project.ewp> -build <config>`
   - Config source: parse `<project><configuration><name>` from `.ewp`; fallback to `Debug`, `Release` when parsing fails.
   - Typical tool locations searched:
     - `C:\iar\ewarm-<version>\common\bin\iarbuild.exe`
     - `C:\Program Files\IAR Systems\Embedded Workbench <version>\common\bin\IarBuild.exe`

2. **Keil MDK**
   - Marker: `*.uvprojx`
   - Build command template:
     - `UV4.exe -b <project.uvprojx> -t <target> -j0`

3. **MCUXpresso IDE (desktop IDE project)**
   - Markers in same directory: `.project` and `.cproject`
   - Exclusion: if VS Code markers are detected in the same directory, classify as VS Code project instead
   - Build command template:
     - `mcuxpressoidec.exe -nosplash --launcher.suppressErrors -application org.eclipse.cdt.managedbuilder.core.headlessbuild -data <temp-workspace> -import <project-dir> -build <project-name>/<config>`

4. **MCUXpresso VS Code**
   - Marker A: `CMakePresets.json`
   - Marker B: `*.code-workspace` and `.vscode/tasks.json` in the same directory
   - Build command templates:
     - Preset-translation flow (preferred):
       - Parse `CMakePresets.json` plus any `include` files in PowerShell
       - Resolve the selected `configurePreset` inheritance chain, `binaryDir`, `toolchainFile`, `cacheVariables`, and preset `environment`
       - `cmake -S <project-dir> -B <resolved-binary-dir> [-G <generator>] [-DCMAKE_TOOLCHAIN_FILE=<toolchain>] [-DKEY=VALUE ...]`
       - `cmake --build <resolved-binary-dir> [--config <config>]`
     - Fallback flow when no `CMakePresets.json` exists:
       - `cmake -S <project-dir> -B <project-dir>/build/<config> -DCMAKE_BUILD_TYPE=<config>`
       - `cmake --build <project-dir>/build/<config> --config <config>`

## Selection Rules
- Prefer nearest project markers first.
- If several types are detected in the same directory, apply fixed priority:
  1. IAR
  2. Keil
  3. MCUXpresso IDE
  4. MCUXpresso VS Code
- Use `-Type` to force one type when needed.
  - Canonical values: `IAR`, `Keil`, `MCUXpressoIDE`, `MCUXpressoVSCode`
  - Supported aliases: `ide` -> `MCUXpressoIDE`, `vscode` -> `MCUXpressoVSCode`
- If the required tool is missing, stop and report; do not silently switch to another compiler.
