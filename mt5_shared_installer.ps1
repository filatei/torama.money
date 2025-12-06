# ==============================
# MT5 SHARED EA AUTO INSTALLER
# ==============================

$sharedPath = "C:\MT5_SHARED\MQL5"
$terminalRoot = "C:\Users\trader\AppData\Roaming\MetaQuotes\Terminal"

Write-Host "Scanning for MT5 terminals..."

Get-ChildItem $terminalRoot -Directory | ForEach-Object {

    $terminalPath = $_.FullName
    $mql5Path = "$terminalPath\MQL5"
    $backupPath = "$terminalPath\MQL5_BACKUP"

    Write-Host "Processing: $terminalPath"

    if (Test-Path $mql5Path) {
        if (!(Test-Path $backupPath)) {
            Rename-Item $mql5Path $backupPath
            Write-Host "  Backup created."
        } else {
            Remove-Item $mql5Path -Force -Recurse
        }
    }

    cmd /c mklink /D "$mql5Path" "$sharedPath"
    Write-Host "  Symlink created."
}

Write-Host "✅ ALL MT5 TERMINALS ARE NOW USING SHARED EAs"
Pause