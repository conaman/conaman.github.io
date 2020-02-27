---
title : Unreal Engine 4 build command line arguments
date: 2020-02-27
category:
- Unreal Engine 4
---

# Unreal Engine 4 build command line arguments

## Build command
	RunUAT.bat
	AutomationToolLauncher.exe
	AutomationTool.exe 

---
## RunUAT.bat

### Path
	Engine\Build\BatchFiles/RunUAT.bat

### Arguments
- **-compile** : compile and run the UAT, RunUAT adds this by default
	- RunUAT removes the *-compile*  argument if the following conditions are met
		- *Build\InstalledBuild.txt* exist
		- *Source\Programs\AutomationTool\AutomationTool.csproj*  do not exist
		- *Source\Programs\AutomationToolLauncher\AutomationToolLauncher.csproj* do not exist
		- *ForcePrecompiledUAT* environment variable is set.
- **-nocompile** : run with precompiled UAT.

### Actions
1. Find platform extension source code that UBT will need when compiling platform extension automation projects
	- Make *Engine/Intermediate\ProjectFiles\UnrealBuildTool.csproj.References* file.
2. Get *MSBuild.exe* path
3. Build *Source\Programs\AutomationToolLauncher\AutomationToolLauncher.csproj*
4. Build *Source\Programs\AutomationTool\AutomationTool.csproj*
5. Launch AutomationTool.exe by AutomationToolLauncher.exe
	```
	AutomationToolLauncher.exe arguments
	```

---
## AutomationToolLauncher.exe

### Path
	Engine\Binaries\DotNET\AutomationToolLauncher.exe
	
### Actions
1. Create Domain for AutomationTool.exe
2. Execute the assembly.

---
## AutomationTool.exe

### Path
	Engine\Binaries\DotNET\AutomationTool.exe
	
### Arguments
- **-VeryVerbose** : Enables very verbose logging
- **-BuildMachine** : build machine, Set *IsBuildMachine* environment variable to 1
- **-UseLocalBuildStorage** : Allows you to use local storage for your root build storage dir (default of P:\Builds (on PC) is changed to Engine\Saved\LocalBuilds). Used for local testing.
- **-IgnoreJunk** : Prevents UBT from cleaning junk files

#### Global  command line parameters
- **-CompileOnly** : Does not run any commands, only compiles them
- **-Verbose** : Enables verbose logging
- **-TimeStamps** : Include timestamps on each line of log output
- **-Submit** : Allows UAT command to submit changes
- **-NoSubmit** : Prevents any submit attempts
- **-NoP4** : Disables Perforce functionality (default if not run on a build machine)
- **-P4** : Enables Perforce functionality (default if run on a build machine)
- **-Compile** : Compile project
- **-IgnoreDependencies** : Ignore dependencies

#### Legacy command line parameters
- This command is LEGACY because we used to run UAT.exe to compile scripts by default.
- Now we only compile by default when run via RunUAT.bat, which still understands -nocompile.
- However, the batch file simply passes on all arguments, so UAT will choke when encountering -nocompile.
- Keep this CommandLineArg around so that doesn't happen.


- **-NoCompile** : No compile
- **-NoCompileEditor** : No compile editor
- **-Help** : Displays help
- **-List** : Lists all available commands
- **-NoKill** : Does not kill any spawned processes on exit
- **-Utf8output** : Set the console output encoding to UTF8
- **-AllowStdOutLogVerbosity**
- **-NoAutoSDK** : Disable AutoSDKs

#### Key=Value Style
- **-Profile=ProfileFileName** : file format is JSON. every object adds to arguments.
- **-ScriptsForProject=ProjectFileName** : Project file name
- **-ScriptDir=ScriptDir** : Additional scripts folder
- **-Telemetry=TelemetryFile** : The telemetry data will write on telemetry file when finished. 

#### Other Key=Value Style
- **Key** : Environment Variable for process
- **Value** : Environment Value for process


### BuildCommand : Argument without '-'

#### BuildCookRun
- Builds/Cooks/Runs a project.
	- For non-uprojects project targets are discovered by compiling target rule files found in the project folder.
	- If -map is not specified, the command looks for DefaultMap entry in the project's DefaultEngine.ini and if not found, in BaseEngine.ini.
	- If no DefaultMap can be found, the command falls back to /Engine/Maps/Entry.

- Command Arguments
	- **project=Path** : Project path (required)
	- **destsample** : Destination Sample name
	- **foreigndest** : Foreign Destination
	- **cookdir** : Directories to cook
	- **i18npreset=value** : Internationalization preset
	- **cookcultures=value** : Cultures to cook
	- **foreign=boolean** : Make foreign sample
	- **foreigncode=boolean** : Make foreign code sample
	
- ProjectParams
	- **targetplatform=PlatformName** : target platform for building, cooking and deployment (also -Platform)
	- **servertargetplatform=PlatformName** : target platform for building, cooking and deployment of the dedicated server (also -ServerPlatform)
	
- UE4Build
	- **ForceMonolithic** : Toggle to combined the result into one executable
	- **ForceDebugInfo** : Forces debug info even in development builds
	- **NoXGE** : Toggle to disable the distributed build process
	- **ForceNonUnity** : Toggle to disable the unity build system
	- **ForceUnity** : Toggle to force enable the unity build system
	- **Licensee** : If set, this build is being compiled by a licensee
	
- CodeSign
	- **NoSign** : Skips signing of code/content files.

#### SyncDDC
- Merge one or more remote DDC shares into a local share, taking files with the newest timestamps and keeping the size below a certain limit

- Command Arguments
	- **LocalDir=Path** : The local DDC directory to add/remove files from
	- **RemoteDir=Path** : The remote DDC directory to pull from. May be specified multiple times.
	- **MaxSize=Size** : Maximum size of the local DDC directory. TB/MB/GB/KB units are allowed.
	- **MaxDays=Num** : Only copies files with modified timestamps in the past number of days.
	- **TimeLimit=Time** : Maximum time to run for. h/m/s units are allowed.
	- **Preview=boolean** : Preview
	
#### BuildTarget
- Builds the specified targets and configurations for the specified project
	- Example BuildTarget -project=QAGame -target=Editor+Game -platform=PS4+XboxOne -configuration=Development
	- Note: Editor will only ever build for the current platform in a Development config and required tools will be included

- Command Arguments
	- **project=QAGame** :  Project to build. Will search current path and paths in ueprojectdirs. If omitted will build vanilla UE4Editor
	- **platform=PS4+XboxOne** : Platforms to build, join multiple platforms using +
	- **configuration=Development+Test** : Configurations to build, join multiple configurations using +
	- **target=Editor+Game** : Targets to build, join multiple targets using +
	- **notools** : Don't build any tools (UHT, ShaderCompiler, CrashReporter
	- **clean** : Clean

#### RebuildLightMaps
- Helper command used for rebuilding a projects light maps

- Command Arguments
	- **Project=Path** : Absolute path to a .uproject file
	- **MapsToRebuildLightMaps=list** : A list of '+' delimited maps we wish to build lightmaps for.
	- **CommandletTargetName** : The Target used in running the commandlet
	- **StakeholdersEmailAddresses** : Users to notify of completion
	- **nobuild** : Don't build any tools (UHT, ShaderCompiler, CrashReporter
	
#### CleanFormalBuilds
- Removes folders matching a pattern in a given directory that are older than a certain time.

- Command Arguments
	- **ParentDir=Direcctory** : Path to the root directory
	- **SearchPattern=Patterns** : Pattern to match against
	- **Days=N** : Number of days to keep in temp storage (optional - defaults to 4)
	
#### ExportIPAFromArchive
- Creates an IPA from an xarchive file

- Command Arguments
	- **method=method** : Purpose of the IPA. (Development, Adhoc, Store)
	- **TemplateFile=File** : Path to plist template that will be filled in based on other arguments. See ExportOptions.plist.template for an example
	- **OptionsFile** : Path to an XML file of options that we'll select from based on method. See ExportOptions.Values.xml for an example
	- **Project** : Name of this project (e.g ShooterGame, EngineTest)