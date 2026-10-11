' Rosa Thermal Guard - Start Menu / desktop shortcut target.
' Asks the running app to open its window, and starts the scheduled task if it is not running.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dataDir = sh.ExpandEnvironmentStrings("%ProgramData%") & "\RosaThermalGuard"
If Not fso.FolderExists(dataDir) Then fso.CreateFolder(dataDir)
fso.CreateTextFile(dataDir & "\show.flag", True).Close
sh.Run "schtasks.exe /run /tn RosaThermalGuard", 0, False
