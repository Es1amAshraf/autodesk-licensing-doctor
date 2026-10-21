Option Explicit
' Smart App Control blocks new unsigned .exe files. This launcher uses the
' Microsoft-signed PowerShell host instead, so the app still starts when the
' compiled EXE is unsigned (SignPath signing needs GitHub Actions).
' Do not rely on PATH: some Windows 10/11 machines have it stripped, which is
' what produced "The term 'powershell' is not recognized..." on scan.
On Error Resume Next
Dim fso, here, ps, args, winDir
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
winDir = fso.GetSpecialFolder(1).Path
ps = fso.BuildPath(winDir, "WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then ps = "powershell.exe"
args = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & here & "\AdskDoctor-GUI.ps1"""
CreateObject("Shell.Application").ShellExecute ps, args, here, "runas", 0
