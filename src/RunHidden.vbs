' Rosa Thermal Guard - starts the tray app with no console window and waits,
' so Task Scheduler can restart it on failure.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
appDir = fso.GetParentFolderName(WScript.ScriptFullName)
rc = sh.Run("powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & appDir & "\TrayApp.ps1""", 0, True)
WScript.Quit rc
