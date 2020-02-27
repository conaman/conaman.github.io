---
title : Unreal Engine 4 build command line arguments
date: 2020-02-27
category:
- Unreal Engine 4
---

# Unreal Engine 4 build command line arguments

## Build command
	<Step>
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
<pre>
	This command is LEGACY because we used to run UAT.exe to compile scripts by default.
	Now we only compile by default when run via RunUAT.bat, which still understands -nocompile.
	However, the batch file simply passes on all arguments, so UAT will choke when encountering -nocompile.
	Keep this CommandLineArg around so that doesn't happen.
</pre>
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

#### BuildCommand : Argument without '-'
- 