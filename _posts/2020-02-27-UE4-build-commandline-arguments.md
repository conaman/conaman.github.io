---
title: "Unreal Engine 4 build command-line arguments"
date: 2020-02-27
tags: [UnrealEngine, UE4, Build, Automation]
summary: "A source-based note on how RunUAT, AutomationToolLauncher, AutomationTool, and BuildCookRun actually parse arguments and execute in UE4.27.2."
---

I rewrote this note after reading through the local `UE4.27.2` engine source again. The main files referenced here are:

- `Engine/Build/BatchFiles/RunUAT.bat`
- `Engine/Source/Programs/AutomationToolLauncher/Launcher.cs`
- `Engine/Source/Programs/AutomationTool/Program.cs`
- `Engine/Source/Programs/AutomationTool/AutomationUtils/Automation.cs`
- `Engine/Source/Programs/AutomationTool/AutomationUtils/ProjectParams.cs`
- `Engine/Source/Programs/AutomationTool/Scripts/BuildCookRun.Automation.cs`

The goal is not just to list available flags. The more useful question is how `RunUAT.bat BuildCookRun ...` actually flows through the toolchain, and where each argument is interpreted in the source.

## Overall flow

A typical `UE4` scripted build runs through the following path:

```text
RunUAT.bat
  -> AutomationToolLauncher.exe (or AutomationTool.exe)
  -> AutomationTool.Program.Main()
  -> Automation.Process()
  -> BuildCookRun.ExecuteBuild()
  -> Project.Build()
  -> Project.Cook()
  -> Project.CopyBuildToStagingDirectory()
  -> Project.Package()
  -> Project.Archive()
  -> Project.Deploy()
  -> Project.Run()
  -> Project.GetFile()
```

On the surface it looks like a single `BuildCookRun` command, but in practice the batch file, the launcher, the global command parser, and the `BuildCookRun` implementation all take turns shaping the result.

## 1. When does RunUAT.bat add `-compile`?

`RunUAT.bat` starts with `UATCompileArg=-compile` by default. In other words, in a source-built engine setup it will usually try to rebuild AutomationTool before running it.

It switches to the precompiled path under the following conditions:

- `-nocompile` is present on the command line
- `Build/InstalledBuild.txt` exists
- the `ForcePrecompiledUAT` environment variable is set
- `AutomationTool.csproj` or `AutomationToolLauncher.csproj` is missing
- `GetMSBuildPath.bat` fails to locate MSBuild

In a normal source branch, the batch file will:

1. call `GetMSBuildPath.bat`
2. build `AutomationToolLauncher.csproj`
3. build `AutomationTool.csproj`
4. run the compiled tool

In an installed build or `-nocompile` path, it uses `Binaries\DotNET\AutomationTool.exe` directly.

In practice, this is the easiest way to think about it:

- on a source engine, `RunUAT.bat` often ends up using `-compile`
- on installed engines or cached CI environments, the precompiled path is more common
- `-nocompile` does not just mean "skip compiling"; it effectively pushes `RunUAT.bat` toward the precompiled execution path

## 2. Why does AutomationToolLauncher exist?

`AutomationToolLauncher` looks like a thin forwarder, but it changes its execution strategy depending on whether `-compile` is present.

- with `-compile`, it creates a new `AppDomain`, enables `ShadowCopyFiles=true`, and runs `AutomationTool.exe`
- without `-compile`, it loads `AutomationTool.exe` directly and invokes its `EntryPoint`

That difference matters because it is tied to the runtime script and assembly recompilation flow. In the source-based path, the launcher sets up a more replaceable execution context through shadow copying and a separate domain.

So `-compile` is not just "do one extra build step." It also changes how the launcher executes AutomationTool.

## 3. What AutomationTool.exe actually does

Inside `AutomationTool.Program.Main()`, the following things happen first:

- `-Utf8output` switches console output to UTF-8
- `-Verbose` and `-VeryVerbose` control log verbosity
- `-TimeStamps` enables timestamped logs
- the working directory is moved to the engine root
- the host platform is initialized
- a single-instance guard is enforced

After that, real command parsing and dispatch moves into `Automation.Process()`.

The two important takeaways are:

1. `AutomationTool.exe` normalizes the execution environment around the engine root
2. argument parsing, script compilation, help, and command execution all happen in `Automation.cs`

## 4. Where are global arguments parsed?

Global arguments are registered in `AutomationUtils/Automation.cs` through `GlobalCommandLine`. Common examples include:

- logging: `-Verbose`, `-VeryVerbose`, `-TimeStamps`, `-Utf8output`
- execution control: `-CompileOnly`, `-List`, `-Help`, `-NoKill`
- source control: `-P4`, `-NoP4`, `-Submit`, `-NoSubmit`
- build environment: `-UseLocalBuildStorage`, `-NoAutoSDK`
- script discovery: `-ScriptsForProject=...`, `-ScriptDir=...`
- output and reporting: `-Telemetry=...`

There is also one legacy-looking detail that is easy to miss:

- `-NoCompile` is still accepted for backward compatibility

The source comments explain why. Older flows expected `UAT.exe` to handle script compilation directly, while newer flows rely more on `RunUAT.bat`. Since the batch file still forwards `-nocompile`, AutomationTool keeps a legacy `-NoCompile` path so it does not fail on an otherwise recognized user intent.

## 5. How the command line is split

The parser in `Automation.cs` is simpler than it first appears:

- tokens starting with `-` are treated as parameter candidates
- tokens containing `=` are treated as parameters or environment-variable candidates
- tokens that do not start with `-` and do not contain `=` are treated as command names

For example:

```bat
RunUAT.bat BuildCookRun -project="D:\Projects\MyGame\MyGame.uproject" -cook -stage -pak
```

is interpreted as:

- `BuildCookRun` -> the command to execute
- `-project=...`, `-cook`, `-stage`, `-pak` -> arguments for that command

Also, `KEY=VALUE` style tokens can become environment variables rather than command arguments. That means you can inject environment settings into the UAT run directly from the command line.

## 6. `-profile`, `-ScriptsForProject`, and `-ScriptDir` are more useful than they look

Looking at the source, UAT is not just a single long command line runner.

### `-profile=...`

`ParseProfile()` reads a JSON file and expands entries from its `scripts` array into effective command-line arguments. That makes it a practical way to manage long `BuildCookRun` presets.

### `-ScriptsForProject=...`

This limits script compilation and discovery to a specific project context.

### `-ScriptDir=...`

This adds an extra script directory for AutomationTool to scan.

Taken together, UAT behaves less like "one batch file" and more like a lightweight automation runtime with profiles and project-scoped script loading.

## 7. The real BuildCookRun pipeline

`BuildCookRun.Automation.cs` makes the core sequence very clear:

1. construct `ProjectParams`
2. create a foreign project if needed
3. run `Project.Build()`
4. run `Project.Cook()`
5. run any extra build steps needed for asset nativization
6. run `Project.CopyBuildToStagingDirectory()`
7. run `Project.Package()`
8. run `Project.Archive()`
9. run `Project.Deploy()`
10. run `Project.Run()`
11. run `Project.GetFile()`

So `BuildCookRun` is not just about build, cook, and run. It is an orchestration layer for `stage`, `package`, `archive`, `deploy`, and more.

## 8. `-project` and default map handling

In the source, `-project` is effectively required. If it is missing, `BuildCookRun` throws immediately.

Another useful detail is how default maps are resolved when `-map` is omitted.

`BuildCookRun` checks in this order:

1. the project's `Config/DefaultEngine.ini`
2. `ServerDefaultMap` for dedicated server builds, otherwise `GameDefaultMap`
3. the engine's `BaseEngine.ini`
4. `/Engine/Maps/Entry` as the final fallback

So omitting `-map` does not mean "pick any map." The fallback order is explicit and source-driven.

## 9. Flag relationships that matter in practice

`ProjectParams.cs` shows that several flags do more than just toggle a single boolean.

- `-skipcook` -> internally implies `Cook = true`
- `-skippak` -> internally implies `Pak = true`
- `-prepak` -> internally implies `Pak = true` and `SkipCook = true`
- `-skipstage` -> internally implies `Stage = true`
- `-signpak=...` -> also enables `SignedPak`
- `-iterativecooking` and `-iterate` -> map to the same internal behavior

This matters when you are writing scripts. For example, `-skippak` does not mean "do not use pak files." It means "use pak files, but assume they already exist."

## 10. Important validation rules in the source

`ProjectParams.ValidateAndLog()` contains several constraints that are easy to trip over:

- `-fileserver` cannot be used without `-cook`
- `-stage` requires a cooked build or a program target
- `-pak` requires `-stage` or `-skipstage`
- `-deploy` requires `-stage` or `-skipstage`
- `-pak` and `-fileserver` cannot be used together
- `-noclient` only makes sense with `-server` or `-cookonthefly`
- `-server` cannot be combined with `-RunAutomationTests`
- `-EditorTest` cannot be combined with `pak`, `stage`, `cook`, `cookonthefly`, or server-style flows

Knowing these source-level constraints is usually more useful than memorizing a flat list of options.

## 11. Common steps in a scripted UE project build

`BuildCookRun` has a lot of switches, but most real build scripts follow the same high-level sequence. For release packaging and CI, this is usually the baseline flow.

### 1) Build

Compile code and targets.

- core flag: `-build`
- common companions: `-targetplatform=...`, `-clientconfig=...`, `-serverconfig=...`
- situational flags: `-clean`, `-NoXGE`

The most common shape is a `Win64 + Shipping` client build. If you package a dedicated server separately, you usually add something like `-server -serverconfig=Shipping`.

### 2) Cook

Convert assets into target-platform-ready data.

- core flag: `-cook`
- scope control: `-map=...`, `-CookAll`, `-CookMapsOnly`
- iterative optimization: `-iterativecooking`, `-FastCook`, `-CookPartialgc`

For local iteration, teams often prefer `-map=` or `-iterativecooking` over full-project cooking.

### 3) Stage

Gather executables and cooked content into the staging directory.

- core flag: `-stage`
- output location: `-stagingdirectory=...`
- reuse previous staged output: `-skipstage`

Since `-pak` and `-deploy` are tightly tied to the stage flow in the source, it is usually safest to think of `-stage` as the center of the packaging pipeline.

### 4) Pak / Package

Produce distributable packaged content.

- core flag: `-pak`
- reuse existing pak files: `-skippak`, `-prepak`
- common extras: `-signpak=...`, `-PakAlignForMemoryMapping`, `-prereqs`

For Windows distribution builds, `-pak -prereqs` is very common. For internal local testing, teams sometimes skip `-pak` and inspect the staged build directly.

### 5) Archive

Copy final artifacts into a preserved output directory.

- core flag: `-archive`
- output location: `-archivedirectory=...`

In CI or release automation, this step is used almost all the time because it separates final deliverables from intermediate build-machine output.

### 6) Deploy / Run

Deploy to a device or launch immediately.

- deploy: `-deploy`, `-device=...`, `-serverdevice=...`
- run: `-run`, `-clientcmdline=...`, `-servercmdline=...`

This stage is not required for packaging itself, so it is often omitted unless the script is meant for device testing, QA automation, or smoke runs.

In short, the default packaging shape is usually:

```text
-build -> -cook -> -stage -> -pak -> -archive
```

Then you layer in `-map`, `-iterativecooking`, `-prereqs`, `-deploy`, or `-run` depending on the workflow.

## 12. Option combinations that show up often in production

### Full packaging build

This is the most common form for release candidates or QA handoff builds.

- `-build -cook -stage -pak -archive`
- `-targetplatform=Win64 -clientconfig=Shipping`
- `-archivedirectory=... -prereqs -utf8output -unattended -NoP4`

### Fast iteration build

This is a common shape during active development when turnaround time matters more than final packaging.

- `-build -cook -stage`
- `-iterativecooking`
- optionally `-map=/Game/...`
- often without `-archive`

### Single-map verification build

This keeps cook scope small for quick local validation.

- `-cook -map=/Game/Maps/Lobby`
- or `-CookMapsOnly`

If your startup map is large or the project has many maps, this can make a noticeable difference.

## 13. High-signal BuildCookRun option groups

| Purpose | Typical options |
| --- | --- |
| Project selection | `-project=...`, `-targetplatform=...`, `-clientconfig=...`, `-serverconfig=...` |
| Core pipeline | `-build`, `-cook`, `-stage`, `-pak`, `-archive`, `-deploy`, `-run` |
| Cook control | `-map=...`, `-CookAll`, `-CookMapsOnly`, `-iterativecooking`, `-FastCook`, `-CookPartialgc` |
| Staging and packaging | `-stagingdirectory=...`, `-archivedirectory=...`, `-signpak=...`, `-PakAlignForMemoryMapping`, `-prereqs` |
| Execution and testing | `-device=...`, `-serverdevice=...`, `-clientcmdline=...`, `-servercmdline=...`, `-RunAutomationTests` |
| Build environment | `-NoP4`, `-NoXGE`, `-UseLocalBuildStorage`, `-NoAutoSDK`, `-Utf8output` |

## 14. A ready-to-use command example

A very common Windows packaging command looks like this:

```bat
Engine\Build\BatchFiles\RunUAT.bat BuildCookRun ^
  -project="D:\Projects\MyGame\MyGame.uproject" ^
  -targetplatform=Win64 ^
  -clientconfig=Shipping ^
  -build ^
  -cook ^
  -stage ^
  -pak ^
  -archive ^
  -archivedirectory="D:\Builds\MyGame\Win64" ^
  -prereqs ^
  -utf8output ^
  -unattended ^
  -NoP4
```

You can extend it with common additions such as:

- package only a specific map: `-map=/Game/Maps/Lobby`
- disable XGE: `-NoXGE`
- enable iterative cooking: `-iterativecooking`
- add client runtime flags: `-clientcmdline="-log -windowed"`

## 15. PowerShell script example

If you run the same build repeatedly, it is usually better to wrap the command in a script. I added these examples alongside the post:

- [BuildCookRun-Win64-Shipping.ps1](/assets/examples/ue4/BuildCookRun-Win64-Shipping.ps1)
- [buildcookrun-win64-shipping.json](/assets/examples/ue4/buildcookrun-win64-shipping.json)

You can run the PowerShell example like this:

```powershell
powershell -ExecutionPolicy Bypass -File .\BuildCookRun-Win64-Shipping.ps1 `
  -EngineRoot "D:\UE4.27.2" `
  -Project "D:\Projects\MyGame\MyGame.uproject" `
  -ArchiveDir "D:\Builds\MyGame\Win64" `
  -Map "/Game/Maps/Lobby"
```

The script automates the following steps:

- validate the `RunUAT.bat` path
- validate the `.uproject` path
- assemble the `BuildCookRun` argument list
- append `-map` and `-clean` only when requested
- surface the process exit code as an exception on failure

## 16. `-profile` JSON example

If you want to use the source-level `ParseProfile()` flow directly, the JSON profile approach works well too.

```bat
Engine\Build\BatchFiles\RunUAT.bat -profile="D:\BuildProfiles\buildcookrun-win64-shipping.json"
```

The main advantage is that long and repetitive argument sets can live in a file instead of inside a huge command line. That is especially useful for CI presets or shared team build profiles.

## Summary

From the UE4.27.2 source, `BuildCookRun` is not just a loose collection of flags.

- `RunUAT.bat` decides whether the compile or precompiled path is used
- `AutomationToolLauncher` changes execution strategy
- `AutomationTool` prepares global parameters and script context
- `BuildCookRun` assembles the `Build -> Cook -> Stage -> Package -> Archive -> Deploy -> Run` pipeline

That is why the most useful practical knowledge is not just the option list. It is understanding:

1. which layer interprets a given argument
2. which flags implicitly enable other behavior
3. which combinations are rejected directly by the source
