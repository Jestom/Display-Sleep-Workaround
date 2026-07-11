Option Explicit

Dim fso, shell, root, ps, scriptPath, cmd, arg, exitCode

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = root & "\topology-ddcci-workaround.ps1"

Function Quote(value)
  Quote = """" & Replace(CStr(value), """", """""") & """"
End Function

cmd = Quote(ps) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Quote(scriptPath)

For Each arg In WScript.Arguments
  cmd = cmd & " " & Quote(arg)
Next

exitCode = shell.Run(cmd, 0, True)
WScript.Quit exitCode
