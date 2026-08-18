' Antigravity Companion Handoff Worker Launcher
' Launches the Python worker without a visible console window.

Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

Dim scriptDir, workerScript, pythonExe, cmd

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
workerScript = fso.BuildPath(scriptDir, "run_ag_handoff_worker.py")

pythonExe = WshShell.ExpandEnvironmentStrings("%COMPANION_PYTHONW%")
If pythonExe = "%COMPANION_PYTHONW%" Or Not fso.FileExists(pythonExe) Then
    Dim localApp, pyBase, folder, subF
    localApp = WshShell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
    pyBase = fso.BuildPath(localApp, "Programs\Python")
    pythonExe = ""
    If fso.FolderExists(pyBase) Then
        Set folder = fso.GetFolder(pyBase)
        For Each subF In folder.SubFolders
            If fso.FileExists(fso.BuildPath(subF.Path, "pythonw.exe")) Then
                pythonExe = fso.BuildPath(subF.Path, "pythonw.exe")
            ElseIf fso.FileExists(fso.BuildPath(subF.Path, "python.exe")) And pythonExe = "" Then
                pythonExe = fso.BuildPath(subF.Path, "python.exe")
            End If
        Next
    End If
    If pythonExe = "" Then pythonExe = "pythonw.exe"
End If

cmd = """" & pythonExe & """ -X utf8 """ & workerScript & """"
WshShell.Run cmd, 0, True
