The script will:

✔ Auto-detect ALL MT5 terminals
✔ Backup original MQL5
✔ Create symlink to shared folder
✔ Zero manual path guessing
✔ Works under user trader

-- Open MT5 and do File - Open Data Folder and copy path and use it to replace the Path in the ps1 script




Run cmd as Admin and load Powershell
create these folders manually
C:\MT5_SHARED
C:\MT5_SHARED\MQL5\Experts
C:\MT5_SHARED\MQL5\Indicators
C:\MT5_SHARED\MQL5\Include
C:\MT5_SHARED\MQL5\Libraries
C:\MT5_SHARED\MQL5\Presets
C:\MT5_SHARED\MQL5\Profiles
C:\MT5_SHARED\logs



on PowerShell as Admin run the following command
    Set-ExecutionPolicy Unrestricted

TO avoid permissions issues, run this once on powershell

  takeown /f "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal" /r /d y
  icacls "C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal" /grant Administrator:F /t

  then run the script
    cd C:\MT5_SHARED
    .\mt5_shared_installer.ps1

    Copy the content of the backup folder to the new MQL5 folder

    copy C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\4DBD910751CD5A870890C73EE6A3F2D4\MQL5_BACKUP c:\mt5_shared\MQL5\
