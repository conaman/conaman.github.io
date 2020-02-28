---
title : Unreal Engine 4 build command-line arguments
date: 2020-02-27
category:
- UE4
---

# Unreal Engine 4 build command-line arguments

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
	This command is LEGACY because we used to run UAT.exe to compile scripts by default.
	Now we only compile by default when run via RunUAT.bat, which still understands -nocompile.
	However, the batch file simply passes on all arguments, so UAT will choke when encountering -nocompile.
	Keep this CommandLineArg around so that doesn't happen.

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
	RunUAT BuildCookRun -help

#### BuildCookRun
- Builds/Cooks/Runs a project.
	- For non-uprojects project targets are discovered by compiling target rule files found in the project folder.
	- If -map is not specified, the command looks for DefaultMap entry in the project's DefaultEngine.ini and if not found, in BaseEngine.ini.
	- If no DefaultMap can be found, the command falls back to /Engine/Maps/Entry.
	
- Parameters
	- **-project=Path**: Project path (required), i.e: -project=QAGame, -project=Samples\BlackJack\BlackJack.uproject, -project=D:\Projects\MyProject.uproject
	- **-destsample**: Destination Sample name
	- **-foreigndest**: Foreign Destination
	- **-targetplatform=PlatformName**: target platform for building, cooking and deployment (also -Platform)
	- **-servertargetplatform=PlatformName**: target platform for building, cooking and deployment of the dedicated server (also -ServerPlatform)
	- **-foreign**: Generate a foreign uproject from blankproject and use that
	- **-foreigncode**: Generate a foreign code uproject from platformergame and use that
	- **-CrashReporter**: true if we should build crash reporter
	- **-cook, -cookonthefly**: Determines if the build is going to use cooked data
	- **-skipcook**: use a cooked build, but we assume the cooked data is up to date and where it belongs, implies -cook
	- **-skipcookonthefly**: in a cookonthefly build, used solely to pass information to the package step
	- **-clean**: wipe intermediate folders before building
	- **-unattended**: assumes no operator is present, always terminates without waiting for something.
	- **-pak**: generate a pak file
	- **-signpak=keys**: sign the generated pak file with the specified key, i.e. -signpak=C:\Encryption.keys. Also implies -signedpak.
	- **-prepak**: attempt to avoid cooking and instead pull pak files from the network, implies pak and skipcook
	- **-signed**: the game should expect to use a signed pak file.
	- **-PakAlignForMemoryMapping**: The game will be set up for memory mapping bulk data.
	- **-skippak**: use a pak file, but assume it is already built, implies pak
	- **-stage**: put this build in a stage directory
	- **-skipstage**: uses a stage directory, but assumes everything is already there, implies -stage
	- **-manifests**: generate streaming install manifests when cooking data
	- **-createchunkinstall**: generate streaming install data from manifest when cooking data, requires -stage & -manifests
	- **-archive**: put this build in an archive directory
	- **-build**: True if build step should be executed
	- **-noxge**: True if XGE should NOT be used for building
	- **-CookPartialgc**: while cooking clean up packages as we are done with them rather then cleaning everything up when we run out of space
	- **-CookInEditor**: Did we cook in the editor instead of in UAT
	- **-IgnoreCookErrors**: Ignores cook errors and continues with packaging etc
	- **-nodebuginfo**: do not copy debug files to the stage
	- **-separatedebuginfo**: output debug info to a separate directory
	- **-MapFile**: generates a *.map file
	- **-nocleanstage**: skip cleaning the stage directory
	- **-run**: run the game after it is built (including server, if -server)
	- **-cookonthefly**: run the client with cooked data provided by cook on the fly server
	- **-Cookontheflystreaming**: run the client in streaming cook on the fly mode (don't cache files locally instead force reget from server each file load)
	- **-fileserver**: run the client with cooked data provided by UnrealFileServer
	- **-dedicatedserver**: build, cook and run both a client and a server (also -server)
	- **-client**: build, cook and run a client and a server, uses client target configuration
	- **-noclient**: do not run the client, just run the server
	- **-logwindow**: create a log window for the client
	- **-package**: package the project for the target platform
	- **-distribution**: package for distribution the project
	- **-prereqs**: stage prerequisites along with the project
	- **-applocaldir**: location of prerequisites for applocal deployment
	- **-Prebuilt**: this is a prebuilt cooked and packaged build
	- **-AdditionalPackageOptions**: extra options to pass to the platform's packager
	- **-deploy**: deploy the project for the target platform
	- **-getfile**: download file from target after successful run
	- **-IgnoreLightMapErrors**: Whether Light Map errors should be treated as critical
	- **-stagingdirectory=Path**: Directory to copy the builds to, i.e. -stagingdirectory=C:\Stage
	- **-ue4exe=ExecutableName**: Name of the UE4 Editor executable, i.e. -ue4exe=UE4Editor.exe
	- **-archivedirectory=Path**: Directory to archive the builds to, i.e. -archivedirectory=C:\Archive
	- **-archivemetadata**: Archive extra metadata files in addition to the build (e.g. build.properties)
	- **-createappbundle**: When archiving for Mac, set this to true to package it in a .app bundle instead of normal loose files
	- **-iterativecooking**: Uses the iterative cooking, command line: -iterativecooking or -iterate
	- **-CookMapsOnly**: Cook only maps this only affects usage of -cookall the flag
	- **-CookAll**: Cook all the things in the content directory for this project
	- **-SkipCookingEditorContent**: Skips content under /Engine/Editor when cooking
	- **-FastCook**: Uses fast cook path if supported by target
	- **-cmdline**: command line to put into the stage in UE4CommandLine.txt
	- **-bundlename**: string to use as the bundle name when deploying to mobile device
	- **-map**: map to run the game with
	- **-AdditionalServerMapParams**: Additional server map params, i.e ?param=value
	- **-device**: Devices to run the game on
	- **-serverdevice**: Device to run the server on
	- **-skipserver**: Skip starting the server
	- **-numclients=n**: Start extra clients, n should be 2 or more
	- **-addcmdline**: Additional command line arguments for the program
	- **-servercmdline**: Additional command line arguments for the program
	- **-clientcmdline**: Override command line arguments to pass to the client
	- **-nullrhi**: add -nullrhi to the client commandlines
	- **-fakeclient**: adds ?fake to the server URL
	- **-editortest**: rather than running a client, run the editor instead
	- **-RunAutomationTests**: when running -editortest or a client, run all automation tests, not compatible with -server
	- **-Crash=index**: when running -editortest or a client, adds commands like debug crash, debug rendercrash, etc based on index
	- **-deviceuser**: Linux username for unattended key genereation
	- **-devicepass**: Linux password
	- **-RunTimeoutSeconds**: timeout to wait after we lunch the game
	- **-SpecifiedArchitecture**: Determine a specific Minimum OS
	- **-UbtArgs**: extra options to pass to ubt
	- **-MapsToRebuildLightMaps**: List of maps that need light maps rebuilding
	- **-MapsToRebuildHLODMaps**: List of maps that need HLOD rebuilding
	- **-ForceMonolithic**: Toggle to combined the result into one executable
	- **-ForceDebugInfo**: Forces debug info even in development builds
	- **-ForceNonUnity**: Toggle to disable the unity build system
	- **-ForceUnity**: Toggle to force enable the unity build system
	- **-Licensee**: If set, this build is being compiled by a licensee
	- **-NoSign**: Skips signing of code/content files.