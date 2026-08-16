' Antigravity Companion Handoff Worker Launcher
' This VBScript launches the Python worker without a visible console window.
' It resolves Unicode paths correctly, unlike Task Scheduler with S4U logon.

Set WshShell = CreateObject("WScript.Shell")
Dim pythonExe, workerScript, cmd

' Use WScript.Shell to expand environment variables and resolve the correct path
pythonExe = WshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Python\Python314\pythonw.exe"
workerScript = "C:\Scripts\AntigravityProjects\companion-handoff\src\run_ag_handoff_worker.py"

' Fallback: if pythonw.exe doesn't exist at %LOCALAPPDATA%, try the direct path
Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FileExists(pythonExe) Then
    pythonExe = WshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Python\Python314\python.exe"
End If

cmd = """" & pythonExe & """ -X utf8 """ & workerScript & """"
WshShell.Run cmd, 0, True
