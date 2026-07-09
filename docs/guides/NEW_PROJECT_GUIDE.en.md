# New Project Guide

Use this when you have a raw idea and want to start a new project from zero.

## Step 1. Create a folder

```powershell
$Project = "$env:USERPROFILE\Documents\antigravity\My New Project"
New-Item -ItemType Directory -Force $Project | Out-Null
Set-Location $Project
```

## Step 2. Copy the base template

```powershell
$Template = "$env:USERPROFILE\Documents\antigravity\_templates\agy-project-base"
Copy-Item "$Template\*" $Project -Recurse -Force
Copy-Item "$Template\.agents" $Project -Recurse -Force
Copy-Item "$Template\.agy" $Project -Recurse -Force
Copy-Item "$Template\.cbmignore" $Project -Force
```

## Step 3. Open the folder in Antigravity

Start with:

```text
/specdoc
```

Ask the agent to create product docs only. No code yet.

## Step 4. Plan

```text
/planonly
```

The output should be phases, checks, risks, and exact next command.

## Step 5. Implement one phase

```text
/nextphase

Implement only the next planned phase. Stop after verification and checkpoint.
```

## Step 6. Verify and ship

Use the gates that match the project:

```text
/visualqa
/securityaudit
/shipcheck
/githubprepare
/githubsync
```

## Rule of thumb

If the project has private data, exports, local files, money, health-like data, or destructive actions, use the stricter path. Do not use `/phasebatch`.
