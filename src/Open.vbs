' Rosa Thermal Guard - Start Menu / desktop shortcut target.
' Asks the running app to open its window. If the guard is not running, starts its scheduled task;
' that task runs elevated, so when the plain request is denied it asks once through UAC (1.3.3). No UAC bypass.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dataDir = sh.ExpandEnvironmentStrings("%ProgramData%") & "\RosaThermalGuard"
If Not fso.FolderExists(dataDir) Then fso.CreateFolder(dataDir)
fso.CreateTextFile(dataDir & "\show.flag", True).Close
running = False
Set ex = sh.Exec("schtasks.exe /Query /TN RosaThermalGuard /FO CSV /NH")
Do While ex.Status = 0 : WScript.Sleep 50 : Loop
If InStr(ex.StdOut.ReadAll, """Running""") > 0 Then running = True
If Not running Then
  rc = sh.Run("schtasks.exe /run /tn RosaThermalGuard", 0, True)
  If rc <> 0 Then
    appDir = fso.GetParentFolderName(WScript.ScriptFullName)
    CreateObject("Shell.Application").ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & appDir & "\Start-Thermal.ps1""", appDir, "runas", 0
  End If
End If