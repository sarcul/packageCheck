# Node.js and npm weekly update check

Last updated: 28 October 2026

## Executive summary

`Check-NodeUpdates.ps1` is a small PowerShell script that runs once a week through Windows Task Scheduler. It checks whether your global npm packages or your Node.js installation need updating, and shows a Windows notification only when something needs action. If you see no notification, everything is current.

Setup takes about five minutes and needs no admin rights in most cases.

## What it checks

1. **Global npm packages**: anything reported by `npm outdated -g`.
2. **Node.js patch level**: whether a newer release exists on your current major line (for example 26.x), and whether any of those newer releases are security releases.
3. **Node.js end of life**: a warning when your major line is within 90 days of end of life, or already past it.

If a check fails (for example because you were offline), you get a notification about that too, so a failure is never mistaken for "all clear".

## Requirements

- Windows 10 or 11
- Node.js installed so that `node.exe` and `npm.cmd` are on your PATH. This covers the official installer from nodejs.org, winget, Chocolatey and nvm-windows.
- Windows PowerShell 5.1, which is built into Windows. PowerShell 7 is optional; if you run the script from PowerShell 7 it relaunches itself under 5.1, because Windows notifications need it.

**Note for fnm users:** fnm only adds Node to the PATH inside shells where it has been initialised, so the scheduled task will not find Node and will report a failed check.

## Installation

Open a PowerShell terminal and run each step in turn.

### 1. Put the script in place

This assumes you saved `Check-NodeUpdates.ps1` to your Downloads folder. Adjust the path if not.

```powershell
$dir = "$env:USERPROFILE\Scripts"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Move-Item "$env:USERPROFILE\Downloads\Check-NodeUpdates.ps1" $dir
$script = "$dir\Check-NodeUpdates.ps1"
Unblock-File $script
```

`Unblock-File` removes the "downloaded from the internet" flag so Windows will run the script.

### 2. Test it

```powershell
& $script -AlwaysNotify
Get-Content "$env:LOCALAPPDATA\NodeUpdateCheck\check.log" -Tail 8
```

The `-AlwaysNotify` switch forces a notification even when everything is current. You should see an "Everything is up to date" notification (or a list of what needs updating), and the log should show both checks.

Do not skip this step. If the test does not produce a notification, see [Troubleshooting](#troubleshooting) before scheduling.

### 3. Schedule it

```powershell
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Saturday -At '09:00'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Node update check' -Action $action -Trigger $trigger -Settings $settings -Description 'Weekly check for outdated global npm packages and Node.js releases'
Start-ScheduledTask -TaskName 'Node update check'
```

The last line runs the task once straight away so you can confirm it works from Task Scheduler.

## How it behaves

| Behaviour | Detail |
|---|---|
| Schedule | Every Saturday at 09:00 |
| Missed runs | If your PC is off at 09:00, it runs the next time you log on |
| Logged in only | It runs only while you are logged in, because Windows can only show you a notification then |
| Battery | It runs on battery as well as mains power |
| Window | A console window flashes briefly when it starts |
| Notifications | Appear from "Windows PowerShell" and stay in the notification centre if you miss them |
| Log | Every run is written to `%LOCALAPPDATA%\NodeUpdateCheck\check.log` |

## When you get a notification

Open the log. It lists what is out of date and the exact command or download link to fix it:

```powershell
Get-Content "$env:LOCALAPPDATA\NodeUpdateCheck\check.log" -Tail 20
```

- **Outdated npm packages:** the log gives a ready-made `npm install -g <package>@latest` command. Before taking a **major** version jump (for example ESLint 9 to 10), read that package's release notes, because majors can contain breaking changes.
- **Newer Node.js release:** the log gives the download link for the Windows installer. Close VS Code and any terminals running Node before installing. Releases marked "security release" should be installed promptly.
- **End of life warning:** plan a move to the current LTS line. The current lines and dates are at [nodejs.org/about/previous-releases](https://nodejs.org/en/about/previous-releases).

## What the script contacts

The script runs entirely on your machine and sends nothing about you or your system anywhere. It only reads from:

- the npm registry, via `npm outdated -g`
- `https://nodejs.org/dist/index.json` (official Node.js release list)
- `https://raw.githubusercontent.com/nodejs/Release/main/schedule.json` (official Node.js support dates)

`-ExecutionPolicy Bypass` in the scheduled task applies only to that one PowerShell process. It does not change your system's execution policy.

## Managing the task

**Check when it last ran and whether it succeeded** (a `LastTaskResult` of `0` means success):

```powershell
Get-ScheduledTaskInfo -TaskName 'Node update check' | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

**Change the schedule**, for example to Sunday evenings:

```powershell
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '18:00'
Set-ScheduledTask -TaskName 'Node update check' -Trigger $trigger
```

**Change the end of life warning period**: edit `$EolWarningDays = 90` near the top of the script.

**Uninstall**:

```powershell
Unregister-ScheduledTask -TaskName 'Node update check' -Confirm:$false
Remove-Item "$env:USERPROFILE\Scripts\Check-NodeUpdates.ps1"
Remove-Item "$env:LOCALAPPDATA\NodeUpdateCheck" -Recurse
```

## Troubleshooting

**No notification during the test**

- Check Settings > System > Notifications: notifications must be on, and "Windows PowerShell" must not be switched off in the list of senders.
- Do Not Disturb or Focus holds notifications silently in the notification centre. Check there.
- Look at the end of the log. A line starting `Toast failed:` gives the reason.

**"Access is denied" when registering the task**

Run step 3 in a terminal opened with "Run as administrator".

**"Running scripts is disabled on this system" during the test**

Run `Unblock-File` on the script (step 1), or test with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -AlwaysNotify
```

**The log says "npm check failed" or "Node check failed"**

- `The term 'npm.cmd' is not recognized` or similar: Node is not on the PATH that Task Scheduler sees. Run `where.exe node` in a new terminal to confirm where it is installed.
- A network error: you were offline or behind a proxy that blocked the request. The next weekly run will retry.
