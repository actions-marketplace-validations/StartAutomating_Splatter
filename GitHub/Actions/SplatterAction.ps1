﻿<#
.Synopsis
    GitHub Action for Splatter
.Description
    GitHub Action for Splatter.  This will:

    * Import Splatter
    * Run all *.Splatter.ps1 files beneath the workflow directory
    * Run a .SplatterScript parameter

    Any files changed can be outputted by the script, and those changes can be checked back into the repo.
    Make sure to use the "persistCredentials" option with checkout.
#>

param(
# A PowerShell Script that uses Splatter.  
# Any files outputted from the script will be added to the repository.
# If those files have a .Message attached to them, they will be committed with that message.
[string]
$SplatterScript,

# If set, will not process any files named *.Splatter.ps1
[switch]
$SkipSplatterPS1,

# A list of modules to be installed from the PowerShell gallery before scripts run.
[string[]]
$InstallModule = @(),

# If provided, will commit any remaining changes made to the workspace with this commit message.
# If no commit message is provided, changes will not be committed.
[string]
$CommitMessage,

# The user email associated with a git commit.
[string]
$UserEmail,

# The user name associated with a git commit.
[string]
$UserName
)

"::group::Parameters" | Out-Host
[PSCustomObject]$PSBoundParameters | Format-List | Out-Host
"::endgroup::" | Out-Host

$gitHubEvent = if ($env:GITHUB_EVENT_PATH) {
    [IO.File]::ReadAllText($env:GITHUB_EVENT_PATH) | ConvertFrom-Json
} else { $null }

@"
::group::GitHubEvent
$($gitHubEvent | ConvertTo-Json -Depth 100)
::endgroup::
"@ | Out-Host


# Check to ensure we are on a branch
$branchName = git rev-parse --abrev-ref HEAD    
# If we were not, return.
if ((-not $branchName) -or $LASTEXITCODE) {
    $LASTEXITCODE = 0
    "::warning title=No Branch Found::Not on a Branch.  Can not run." | Out-Host
    exit 0
    return
}

$repoRoot = (git rev-parse --show-toplevel *>&1) -replace '/', [IO.Path]::DirectorySeparatorChar

# Use ANSI rendering if available
if ($PSStyle.OutputRendering) {
    $PSStyle.OutputRendering = 'ANSI'
}

#region -InstallModule
if ($InstallModule) {
    "::group::Installing Modules" | Out-Host
    foreach ($moduleToInstall in $InstallModule) {
        $moduleInWorkspace = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Recurse -File |
            Where-Object Name -eq "$($moduleToInstall).psd1" |
            Where-Object { 
                $(Get-Content $_.FullName -Raw) -match 'ModuleVersion'
            }
        if (-not $moduleInWorkspace) {
            Install-Module $moduleToInstall -Scope CurrentUser -Force
            Import-Module $moduleToInstall -Force -PassThru | Out-Host
        }
    }
    "::endgroup::" | Out-Host
}
#endregion -InstallModule

$PSD1Found = Get-ChildItem -Recurse -Filter "*.psd1" |
    Where-Object Name -eq 'Splatter.psd1' | 
    Select-Object -First 1

if ($PSD1Found) {
    $PipeScriptModulePath = $PSD1Found
    Import-Module $PSD1Found -Force -PassThru | Out-Host
} elseif ($env:GITHUB_ACTION_PATH) {
    $SplatterModulePath = Join-Path $env:GITHUB_ACTION_PATH 'Splatter.psd1'
    if (Test-path $SplatterModulePath) {
        Import-Module $SplatterModulePath -Force -PassThru | Out-Host
    } else {
        throw "Splatter not found"
    }
} elseif (-not (Get-Module Splatter)) {    
    throw "Action Path not found"
}

"::notice title=ModuleLoaded::Splatter Loaded from Path - $($SplatterModulePath)" | Out-Host

$anyFilesChanged = $false
$totalFilesOutputted = 0 
$totalFilesChanged   = 0
$filesOutputted      = @()
$filesChanged        = @()

filter ProcessActionOutput {
    $out = $_
    
    $outItem = Get-Item -Path $out -ErrorAction SilentlyContinue
    
    $totalFilesOutputted++
    $fullName, $shouldCommit = 
        if ($out -is [IO.FileInfo]) {
            if ($out.FullName -notlike "$repoRoot*") { return }
            $out.FullName, (git status $out.Fullname -s)
            $filesOutputted += $out
        } elseif ($outItem) {
            if ($outItem.FullName -notlike "$repoRoot*") { return }
            $outItem.FullName, (git status $outItem.Fullname -s)
            $filesOutputted += $outItem
        }
    if ($shouldCommit) {
        git add $fullName
        $filesChanged += $fullName
        if ($out.Message) {
            git commit -m "$($out.Message)" | Out-Host
        } elseif ($out.CommitMessage) {
            git commit -m "$($out.CommitMessage)" | Out-Host
        }  elseif ($gitHubEvent.head_commit.message) {
            git commit -m "$($gitHubEvent.head_commit.message)" | Out-Host
        }
        $anyFilesChanged = $true
        $totalFilesChanged++
    }
    $out
}



if (-not $UserName)  {
    $UserName =  
        if ($env:GITHUB_TOKEN) {
            Invoke-RestMethod -uri "https://api.github.com/user" -Headers @{
                Authorization = "token $env:GITHUB_TOKEN"
            } |
                Select-Object -First 1 -ExpandProperty name
        } else {
            $env:GITHUB_ACTOR
        }
}

if (-not $UserEmail) {
    $GitHubUserEmail = 
        if ($env:GITHUB_TOKEN) {
            Invoke-RestMethod -uri "https://api.github.com/user/emails" -Headers @{
                Authorization = "token $env:GITHUB_TOKEN"
            } |
                Select-Object -First 1 -ExpandProperty email
        } else {''}
    $UserEmail = 
        if ($GitHubUserEmail) {
            $GitHubUserEmail
        } else {
            "$UserName@github.com"
        }    
}
git config --global user.email $UserEmail
git config --global user.name  $UserName

if (-not $env:GITHUB_WORKSPACE) { throw "No GitHub workspace" }

$checkDetached = git symbolic-ref -q HEAD
if (-not $LASTEXITCODE) {
    git pull | Out-Host
}


$SplatterScriptStart = [DateTime]::Now
if ($SplatterScript) {
    Invoke-Expression -Command $SplatterScript |
        . ProcessActionOutput |
        Out-Host
}
$SplatterScriptTook = [Datetime]::Now - $SplatterScriptStart

"::notice title=Runtime::$($SplatterScriptTook.TotalMilliseconds)"   | Out-Host

$SplatterPS1Start = [DateTime]::Now
$SplatterPS1List  = @()
if (-not $SkipSplatterPS1) {
    $SplatterFiles = @(
    Get-ChildItem -Recurse -Path $env:GITHUB_WORKSPACE |
        Where-Object Name -Match '\.Splatter\.ps1$')
        
    if ($SplatterFiles) {
        $SplatterFiles|        
        ForEach-Object {
            $SplatterPS1List += $_.FullName.Replace($env:GITHUB_WORKSPACE, '').TrimStart('/')
            $SplatterPS1Count++
            "::notice title=Running::$($_.Fullname)" | Out-Host
            . $_.FullName |            
                . ProcessActionOutput  | 
                Out-Host
        }
    }
}

$SplatterPS1EndStart = [DateTime]::Now
$SplatterPS1Took = [Datetime]::Now - $SplatterPS1Start
"Ran $($SplatterPS1List.Length) Files in $($SplatterPS1Took.TotalMilliseconds)" | Out-Host
if ($filesChanged) {
    "::group::$($filesOutputted.Length) files generated with $($filesChanged.Length) changes" | Out-Host
    $FilesChanged -join ([Environment]::NewLine) | Out-Host
    "::endgroup::" | Out-Host
} else {
    "$($filesOutputted.Length) files generated with no changes"
}

if ($CommitMessage -or $anyFilesChanged) {
    if ($CommitMessage) {
        Get-ChildItem $env:GITHUB_WORKSPACE -Recurse |
            ForEach-Object {
                $gitStatusOutput = git status $_.Fullname -s
                if ($gitStatusOutput) {
                    git add $_.Fullname
                }
            }

        git commit -m $ExecutionContext.SessionState.InvokeCommand.ExpandString($CommitMessage)
    }    

    $checkDetached = git symbolic-ref -q HEAD 2>&1
    if (-not $LASTEXITCODE) {
        "::group::Pulling Changes" | Out-Host
        git pull | Out-Host
        "::endgroup::" | Out-Host
        "::group::Pushing Changes" | Out-Host        
        git push | Out-Host
        "::endgroup::" | Out-Host
    } else {
        "::warning title=Not pushing changes::(on detached head)" | Out-Host
        $LASTEXITCODE = 0
        exit 0
    }
} else {
    "Nothing to commit in this build." | Out-Host
    exit 0
}
