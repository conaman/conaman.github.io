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
	UnrealBuildTool.exe

---
## RunUAT.bat

### Path
	Engine\Build\BatchFiles/RunUAT.bat

### Arguments
- **-compile** - compile and run the UAT, RunUAT adds this by default
	- RunUAT removes the *-compile*  argument if the following conditions are met
		- *Build\InstalledBuild.txt* exist
		- *Source\Programs\AutomationTool\AutomationTool.csproj*  do not exist
		- *Source\Programs\AutomationToolLauncher\AutomationToolLauncher.csproj* do not exist
		- *ForcePrecompiledUAT* environment variable is set.
- **-nocompile** - run with precompiled UAT.

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