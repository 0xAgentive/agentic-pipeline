$vbsLauncher = "C:\Scripts\AntigravityProjects\companion-handoff\src\run_worker_hidden.vbs"
$wscriptExe = "C:\Windows\System32\wscript.exe"

$action = New-ScheduledTaskAction -Execute $wscriptExe -Argument "`"$vbsLauncher`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

Unregister-ScheduledTask -TaskName "AntigravityCompanionHandoffWorker" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "AntigravityCompanionHandoffWorker" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
Start-ScheduledTask -TaskName "AntigravityCompanionHandoffWorker"
Write-Host "Task re-registered with wscript.exe + VBS launcher (hidden, no console)." -ForegroundColor Green
