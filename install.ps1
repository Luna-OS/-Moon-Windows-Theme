<#
.SYNOPSIS
    Installiert das Moon-Theme (Nachtblau + Lila) fuer Windows 11.

.DESCRIPTION
    - kopiert Theme und Hintergruende nach %LOCALAPPDATA%\Microsoft\Windows\Themes\Moon
    - aktiviert Dunkelmodus und Transparenz
    - setzt die Moon-Akzentfarbe fuer Startmenue, Taskleiste, Einstellungen und Titelleisten
    - sichert vorher alle geaenderten Werte (uninstall.ps1 stellt sie wieder her)

    Startmenue, Taskleiste, Infocenter und Explorer werden zusaetzlich ueber
    Windhawk umgestylt, siehe README.md und den Ordner "windhawk".

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -Wallpaper crescent -TaskbarAlignment Left
.EXAMPLE
    .\install.ps1 -Slideshow -InstallWindhawk
#>
[CmdletBinding()]
param(
    # Welcher Hintergrund verwendet wird.
    [ValidateSet('night', 'crescent', 'horizon')]
    [string]$Wallpaper = 'night',

    # Wechselt alle 30 Minuten zwischen allen Moon-Hintergruenden.
    [switch]$Slideshow,

    # Position der Taskleisten-Symbole.
    [ValidateSet('Center', 'Left')]
    [string]$TaskbarAlignment = 'Center',

    # Taskleiste und Startmenue NICHT in der Akzentfarbe einfaerben.
    [switch]$NoAccentOnTaskbar,

    # Setzt auch den Sperrbildschirm (benoetigt Administratorrechte).
    [switch]$LockScreen,

    # Installiert Windhawk ueber winget.
    [switch]$InstallWindhawk,

    # Moon-Ordnersymbole NICHT setzen (sie benoetigen Administratorrechte).
    [switch]$NoFolderIcons,

    # Explorer am Ende nicht neu starten.
    [switch]$NoExplorerRestart
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$ThemeDir  = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes\Moon'
$Backup    = Join-Path $ThemeDir 'backup.json'
$LockDir   = Join-Path $env:ProgramData 'MoonTheme'
$IconDir   = Join-Path $LockDir 'Icons'

# --- Moon-Farbpalette -------------------------------------------------------
# Reihenfolge wie bei Windows: Light3, Light2, Light1, Akzent, Dark1, Dark2, Dark3, Extra
$Palette = @('#E2DCFF', '#C9BFFF', '#AC9EFF', '#8E7CFF', '#6A57E0', '#4B3AB3', '#2F2380', '#FF8FB1')
$Accent  = $Palette[3]

$PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$DwmKey         = 'HKCU:\Software\Microsoft\Windows\DWM'
$AccentKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
$AdvancedKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$ThemesKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
$LockKey        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
$ShellIconsKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons'

function Write-Step([string]$Text) { Write-Host "  > $Text" -ForegroundColor Magenta }

function ConvertTo-Int32([long]$Value) {
    [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Value), 0)
}

function Get-Rgb([string]$Hex) {
    @([Convert]::ToInt32($Hex.Substring(1, 2), 16),
      [Convert]::ToInt32($Hex.Substring(3, 2), 16),
      [Convert]::ToInt32($Hex.Substring(5, 2), 16))
}

# DWORD im Format 0xAABBGGRR (so speichert Windows Akzentfarben)
function Get-Abgr([string]$Hex, [int]$Alpha = 0xFF) {
    $r, $g, $b = Get-Rgb $Hex
    ConvertTo-Int32 ((([long]$Alpha) -shl 24) -bor ($b -shl 16) -bor ($g -shl 8) -bor $r)
}

# DWORD im Format 0xAARRGGBB (DWM-Colorization)
function Get-Argb([string]$Hex, [int]$Alpha = 0xC4) {
    $r, $g, $b = Get-Rgb $Hex
    ConvertTo-Int32 ((([long]$Alpha) -shl 24) -bor ($r -shl 16) -bor ($g -shl 8) -bor $b)
}

function Get-AccentPalette {
    $bytes = New-Object byte[] 32
    for ($i = 0; $i -lt 8; $i++) {
        $r, $g, $b = Get-Rgb $Palette[$i]
        $bytes[$i * 4]     = $r
        $bytes[$i * 4 + 1] = $g
        $bytes[$i * 4 + 2] = $b
        $bytes[$i * 4 + 3] = 0
    }
    , $bytes
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-RegEntry([string]$Path, [string]$Name, [string]$Type) {
    $entry = [ordered]@{ Path = $Path; Name = $Name; Type = $Type; Exists = $false; Value = $null }
    try {
        $value = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
        $entry.Exists = $true
        if ($Type -eq 'Binary') { $value = [Convert]::ToBase64String([byte[]]$value) }
        $entry.Value = $value
    } catch { }
    $entry
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ThemeFile([string]$Path) {
    # Windows wendet .theme-Dateien ueber die Einstellungen-App an, die dabei kurz aufgeht.
    Start-Process -FilePath $Path
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $settings = Get-Process -Name SystemSettings -ErrorAction SilentlyContinue
    } until ($settings -or (Get-Date) -gt $deadline)
    Start-Sleep -Seconds 3
    if ($settings) { $settings | Stop-Process -Force -ErrorAction SilentlyContinue }
}

# --- Los geht's -------------------------------------------------------------
Write-Host ''
Write-Host '  Moon Theme fuer Windows 11' -ForegroundColor White
Write-Host '  ==========================' -ForegroundColor DarkMagenta
Write-Host ''

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 22000) {
    Write-Warning "Windows-Build $build erkannt. Das Theme ist fuer Windows 11 (Build 22000+) gemacht; einiges wird nicht greifen."
}

# 1) Dateien kopieren
Write-Step 'Kopiere Theme und Hintergruende ...'
New-Item -ItemType Directory -Path (Join-Path $ThemeDir 'Wallpapers') -Force | Out-Null
Copy-Item -Path (Join-Path $Root 'theme\Wallpapers\*.jpg') -Destination (Join-Path $ThemeDir 'Wallpapers') -Force

# 2) Backup (nur beim ersten Mal, damit ein erneutes Installieren das Original nicht ueberschreibt)
if (-not (Test-Path $Backup)) {
    Write-Step 'Sichere aktuelle Einstellungen ...'
    $entries = @(
        Get-RegEntry $ThemesKey      'CurrentTheme'          'String'
        Get-RegEntry $PersonalizeKey 'AppsUseLightTheme'     'DWord'
        Get-RegEntry $PersonalizeKey 'SystemUsesLightTheme'  'DWord'
        Get-RegEntry $PersonalizeKey 'EnableTransparency'    'DWord'
        Get-RegEntry $PersonalizeKey 'ColorPrevalence'       'DWord'
        Get-RegEntry $DwmKey         'ColorPrevalence'       'DWord'
        Get-RegEntry $DwmKey         'AccentColor'           'DWord'
        Get-RegEntry $DwmKey         'AccentColorInactive'   'DWord'
        Get-RegEntry $DwmKey         'ColorizationColor'     'DWord'
        Get-RegEntry $DwmKey         'ColorizationAfterglow' 'DWord'
        Get-RegEntry $AccentKey      'AccentPalette'         'Binary'
        Get-RegEntry $AccentKey      'AccentColorMenu'       'DWord'
        Get-RegEntry $AccentKey      'StartColorMenu'        'DWord'
        Get-RegEntry $AdvancedKey    'TaskbarAl'             'DWord'
        Get-RegEntry $ShellIconsKey  '3'                     'String'
        Get-RegEntry $ShellIconsKey  '4'                     'String'
    )
    $entries | ConvertTo-Json -Depth 3 | Set-Content -Path $Backup -Encoding UTF8
} else {
    Write-Step 'Backup existiert bereits, wird beibehalten.'
}

# 3) Theme-Datei mit absolutem Hintergrund-Pfad erzeugen und anwenden
Write-Step 'Wende Moon-Theme an (Einstellungen oeffnen sich kurz) ...'
$themeFile = Join-Path $ThemeDir 'Moon.theme'
$wallPath  = Join-Path $ThemeDir "Wallpapers\moon-$Wallpaper.jpg"
$content   = Get-Content -Path (Join-Path $Root 'theme\Moon.theme')
$content   = $content -replace '^Wallpaper=.*$', "Wallpaper=$wallPath"
if ($Slideshow) {
    $content += @('', '[Slideshow]', 'Interval=1800000', 'Shuffle=1', "ImagesRootPath=$(Join-Path $ThemeDir 'Wallpapers')")
}
$content | Set-Content -Path $themeFile -Encoding Unicode
Invoke-ThemeFile $themeFile

# 4) Moon-Farben fest setzen (ueberschreibt die von Windows berechnete Palette)
Write-Step 'Setze Dunkelmodus, Transparenz und Moon-Akzentfarbe ...'
Set-RegValue $PersonalizeKey 'AppsUseLightTheme'    0
Set-RegValue $PersonalizeKey 'SystemUsesLightTheme' 0
Set-RegValue $PersonalizeKey 'EnableTransparency'   1
Set-RegValue $PersonalizeKey 'ColorPrevalence'      ([int](-not $NoAccentOnTaskbar))

Set-RegValue $AccentKey 'AccentPalette'   (Get-AccentPalette) 'Binary'
Set-RegValue $AccentKey 'AccentColorMenu' (Get-Abgr $Palette[4])
Set-RegValue $AccentKey 'StartColorMenu'  (Get-Abgr $Palette[5])

# Titelleisten und Fensterrahmen (auch die der Einstellungen-App)
Set-RegValue $DwmKey 'ColorPrevalence'       1
Set-RegValue $DwmKey 'AccentColor'           (Get-Abgr $Accent)
Set-RegValue $DwmKey 'AccentColorInactive'   (Get-Abgr '#1E1838')
Set-RegValue $DwmKey 'ColorizationColor'     (Get-Argb $Accent)
Set-RegValue $DwmKey 'ColorizationAfterglow' (Get-Argb $Accent)

# 5) Taskleiste
Write-Step "Taskleisten-Ausrichtung: $TaskbarAlignment"
try {
    Set-RegValue $AdvancedKey 'TaskbarAl' ([int]($TaskbarAlignment -eq 'Center'))
} catch {
    Write-Warning "Taskleisten-Ausrichtung konnte nicht gesetzt werden: $($_.Exception.Message)"
}

# 6) Sperrbildschirm (optional, Admin)
if ($LockScreen) {
    if (Test-Admin) {
        Write-Step 'Setze Sperrbildschirm ...'
        New-Item -ItemType Directory -Path $LockDir -Force | Out-Null
        $lockImage = Join-Path $LockDir 'lockscreen.jpg'
        Copy-Item -Path $wallPath -Destination $lockImage -Force
        Set-RegValue $LockKey 'LockScreenImagePath'   $lockImage 'String'
        Set-RegValue $LockKey 'LockScreenImageUrl'    $lockImage 'String'
        Set-RegValue $LockKey 'LockScreenImageStatus' 1
    } else {
        Write-Warning 'Fuer -LockScreen PowerShell als Administrator starten. Sperrbildschirm wurde uebersprungen.'
    }
}

# 6b) Moon-Ordnersymbole (Admin): ersetzt das gelbe Standard-Ordnersymbol im ganzen System
$iconsChanged = $false
if (-not $NoFolderIcons) {
    if (Test-Admin) {
        Write-Step 'Setze Moon-Ordnersymbole ...'
        New-Item -ItemType Directory -Path $IconDir -Force | Out-Null
        Copy-Item -Path (Join-Path $Root 'theme\Icons\*.ico') -Destination $IconDir -Force
        Set-RegValue $ShellIconsKey '3' ((Join-Path $IconDir 'moon-folder.ico') + ',0') 'String'
        Set-RegValue $ShellIconsKey '4' ((Join-Path $IconDir 'moon-folder-open.ico') + ',0') 'String'
        $iconsChanged = $true
    } else {
        Write-Warning 'Fuer die Moon-Ordnersymbole PowerShell als Administrator starten (oder den Moon Installer benutzen). Uebersprungen.'
    }
}

# 7) Windhawk (optional)
if ($InstallWindhawk) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step 'Installiere Windhawk ueber winget ...'
        winget install --id RamenSoftware.Windhawk -e --accept-source-agreements --accept-package-agreements
    } else {
        Write-Warning 'winget nicht gefunden. Windhawk bitte manuell von https://windhawk.net installieren.'
    }
}

# 8) Shell neu starten, damit Taskleiste und Startmenue die Farben uebernehmen
if (-not $NoExplorerRestart) {
    Write-Step 'Starte Explorer neu ...'
    Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if ($iconsChanged) {
        # Symbol-Cache leeren, damit die neuen Ordnersymbole sofort erscheinen
        Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\iconcache_*.db') -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    if ($iconsChanged) { Start-Process -FilePath 'ie4uinit.exe' -ArgumentList '-show' -WindowStyle Hidden -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '  Fertig! Moon ist aktiv.' -ForegroundColor Green
Write-Host ''
Write-Host '  Fuer den kompletten Look (Startmenue, Taskleiste, Infocenter, Explorer):' -ForegroundColor White
Write-Host '    1. Windhawk installieren (https://windhawk.net oder .\install.ps1 -InstallWindhawk)'
Write-Host '    2. Die Mods aus der README installieren'
Write-Host "    3. Inhalt der Dateien (auch settings.yaml fuer die Einstellungen-App) aus '$(Join-Path $Root 'windhawk')' in den Mod-Einstellungen einfuegen"
Write-Host ''
Write-Host '  Falls die Farben noch nicht ueberall stimmen: einmal ab- und wieder anmelden.' -ForegroundColor DarkGray
Write-Host '  Rueckgaengig machen: .\uninstall.ps1' -ForegroundColor DarkGray
Write-Host ''
