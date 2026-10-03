<#
.SYNOPSIS
    Entfernt das Moon-Theme und stellt die vorherigen Windows-Einstellungen wieder her.

.DESCRIPTION
    Liest das von install.ps1 angelegte Backup, wendet das vorher aktive Theme an,
    setzt alle geaenderten Registry-Werte zurueck und loescht die Moon-Dateien.
    Die Windhawk-Mods werden nicht angefasst - die bitte in Windhawk deaktivieren.
#>
[CmdletBinding()]
param(
    # Moon-Dateien in %LOCALAPPDATA% behalten.
    [switch]$KeepFiles,

    # Explorer am Ende nicht neu starten.
    [switch]$NoExplorerRestart
)

$ErrorActionPreference = 'Stop'

$ThemeDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes\Moon'
$Backup   = Join-Path $ThemeDir 'backup.json'
$LockDir  = Join-Path $env:ProgramData 'MoonTheme'
$LockKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'

function Write-Step([string]$Text) { Write-Host "  > $Text" -ForegroundColor Magenta }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ThemeFile([string]$Path) {
    Start-Process -FilePath $Path
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $settings = Get-Process -Name SystemSettings -ErrorAction SilentlyContinue
    } until ($settings -or (Get-Date) -gt $deadline)
    Start-Sleep -Seconds 3
    if ($settings) { $settings | Stop-Process -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '  Moon Theme entfernen' -ForegroundColor White
Write-Host '  ====================' -ForegroundColor DarkMagenta
Write-Host ''

$entries = @()
if (Test-Path $Backup) {
    # Erst zuweisen, dann in ein Array packen: Windows PowerShell 5.1 gibt
    # JSON-Arrays bei ConvertFrom-Json sonst als ein einzelnes Objekt aus.
    $json = Get-Content -Path $Backup -Raw | ConvertFrom-Json
    $entries = @($json)
} else {
    Write-Warning 'Kein Backup gefunden. Es wird das Windows-Standardtheme (dunkel) angewendet.'
}

# 1) Vorheriges Theme anwenden
$previous = $entries | Where-Object { $_.Name -eq 'CurrentTheme' -and $_.Exists } | Select-Object -First 1
$themeToApply = $null
if ($previous -and $previous.Value -and ($previous.Value -notlike "$ThemeDir*")) {
    $expanded = [Environment]::ExpandEnvironmentVariables($previous.Value)
    if (Test-Path $expanded) { $themeToApply = $expanded }
}
if (-not $themeToApply) {
    $themeToApply = Join-Path $env:SystemRoot 'Resources\Themes\dark.theme'
}
Write-Step "Wende vorheriges Theme an: $themeToApply"
Invoke-ThemeFile $themeToApply

# 2) Registry-Werte zuruecksetzen
Write-Step 'Stelle gesicherte Einstellungen wieder her ...'
foreach ($e in $entries) {
    if ($e.Name -eq 'CurrentTheme') { continue }
    try {
        if ($e.Exists) {
            $value = $e.Value
            if ($e.Type -eq 'Binary') { $value = [Convert]::FromBase64String($value) }
            if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
            New-ItemProperty -Path $e.Path -Name $e.Name -Value $value -PropertyType $e.Type -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Konnte $($e.Path)\$($e.Name) nicht zuruecksetzen: $($_.Exception.Message)"
    }
}

# 3) Sperrbildschirm
if (Test-Path $LockDir) {
    if (Test-Admin) {
        Write-Step 'Entferne Moon-Sperrbildschirm ...'
        foreach ($name in 'LockScreenImagePath', 'LockScreenImageUrl', 'LockScreenImageStatus') {
            Remove-ItemProperty -Path $LockKey -Name $name -ErrorAction SilentlyContinue
        }
        Remove-Item -Path $LockDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warning 'Der Moon-Sperrbildschirm ist gesetzt. Zum Entfernen uninstall.ps1 als Administrator ausfuehren.'
    }
}

# 4) Dateien loeschen
if (-not $KeepFiles) {
    Write-Step 'Loesche Moon-Dateien ...'
    Remove-Item -Path $ThemeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 5) Shell neu starten
if (-not $NoExplorerRestart) {
    Write-Step 'Starte Explorer neu ...'
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

Write-Host ''
Write-Host '  Moon wurde entfernt.' -ForegroundColor Green
Write-Host '  Denk daran, die Moon-Styles in den Windhawk-Mods zu entfernen oder die Mods zu deaktivieren.' -ForegroundColor DarkGray
Write-Host ''
