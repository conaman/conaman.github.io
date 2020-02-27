---
title : Unreal Engine 4 build command line arguments
date: 2020-02-27
category:
- Unreal Engine 4
tags:
---

# Unreal Engine 4 build command line arguments

## Build command
	RunUAT.bat
	AutomationTool.exe 
	UnrealBuildTool.exe
	

## RunUAT
***
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
	- Make *Engine/Intermediate/ProjectFiles/UnrealBuildTool.csproj.References* file.
2. Get *MSBuild.exe* path
3. Build *Source\Programs\AutomationToolLauncher\AutomationToolLauncher.csproj*
4. Build *Source\Programs\AutomationTool\AutomationTool.csproj*
5. Launch AutomationTool.exe by AutomationToolLauncher.exe
	```
	AutomationToolLauncher.exe arguments
	```