<#
.SYNOPSIS
    Moon Installer - richtet das komplette Moon-Theme mit einem Klick ein.

.DESCRIPTION
    1. Grund-Theme (Hintergrund, Dunkelmodus, Akzentfarbe) ueber install.ps1
    2. Windhawk installieren (winget), falls noch nicht vorhanden
    3. Windhawk-Mods installieren:
         - Windhawk 2.x mit windhawk-cli.exe: vollautomatisch
         - Windhawk 1.x: Windhawk wird geoeffnet, du klickst je Mod auf "Installieren"
    4. Sobald ein Mod installiert ist, traegt die App den Moon-Style automatisch ein
       (direkt in Windhawks Einstellungsspeicher, kein Kopieren/Einfuegen).

    Start: "Moon Installer.cmd" doppelklicken.
#>
param([switch]$NoElevate)

$ErrorActionPreference = 'Stop'
$AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root    = Split-Path -Parent $AppDir
$JsonDir = Join-Path $Root 'windhawk\json'
$LogFile = Join-Path $env:TEMP 'MoonInstaller.log'

function Add-LogLine([string]$Text) {
    try { Add-Content -Path $LogFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch { }
}

# Zeigt einen Absturz sichtbar an, statt dass sich das Fenster einfach schliesst
function Show-Fatal($ErrorRecord) {
    $msg = "$($ErrorRecord.Exception.Message)`r`n`r`n$($ErrorRecord.InvocationInfo.PositionMessage)`r`n$($ErrorRecord.ScriptStackTrace)"
    Add-LogLine "ABSTURZ: $msg"
    Write-Host ''
    Write-Host '  Der Moon Installer ist abgestuerzt:' -ForegroundColor Red
    Write-Host "  $msg"
    Write-Host "  Log: $LogFile"
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(
            "Der Moon Installer ist abgestürzt.`n`n$($ErrorRecord.Exception.Message)`n`nZeile $($ErrorRecord.InvocationInfo.ScriptLineNumber)`n`nDetails stehen in:`n$LogFile",
            'Moon Installer', 'OK', 'Error')
    } catch { }
    Read-Host '  Enter druecken zum Schliessen' | Out-Null
}

trap {
    Show-Fatal $_
    exit 1
}

Add-LogLine "Start (PowerShell $($PSVersionTable.PSVersion), $([Environment]::OSVersion.VersionString))"

# --- Als Administrator neu starten (Windhawk speichert seine Einstellungen in HKLM) ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $NoElevate -and -not $script:IsAdmin) {
    $elevArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $elevArgs -Verb RunAs
        exit
    } catch {
        # Admin-Abfrage abgelehnt: ohne Adminrechte weitermachen (Styles koennen dann nicht eingetragen werden)
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Hex) { $script:BrushConverter.ConvertFromString($Hex) }

# Konsolenfenster ausblenden, sobald die App laeuft (bei Fehlern bleibt es sichtbar)
try {
    Add-Type -Namespace MoonInstaller -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
} catch { }

# =============================================================================
#  Windhawk-Zugriff
# =============================================================================

function Get-WindhawkRoot {
    $candidates = @()
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Windhawk',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Windhawk') {
        try {
            $loc = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
            if ($loc) { $candidates += $loc.Trim('"') }
        } catch { }
    }
    $candidates += (Join-Path $env:ProgramFiles 'Windhawk')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'windhawk.ini'))) { return $c }
    }
    return $null
}

function Read-IniStorage([string]$IniPath) {
    $result = @{}
    $section = ''
    foreach ($line in Get-Content -Path $IniPath) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -eq 'Storage' -and $t -match '^([^=;]+)=(.*)$') {
            $result[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    $result
}

# Liefert ein Objekt mit Infos zur Windhawk-Installation oder $null
function Get-WindhawkInfo {
    $root = Get-WindhawkRoot
    if (-not $root) { return $null }
    $storage = Read-IniStorage (Join-Path $root 'windhawk.ini')
    $info = [ordered]@{
        Root      = $root
        Exe       = Join-Path $root 'windhawk.exe'
        Cli       = $null
        Portable  = ($storage['Portable'] -eq '1')
        Hive      = $null
        SubKey    = $null
        Version   = $null
    }
    $cli = Join-Path $root 'windhawk-cli.exe'
    if (Test-Path $cli) { $info.Cli = $cli }
    try { $info.Version = (Get-Item $info.Exe).VersionInfo.ProductVersion } catch { }

    if (-not $info.Portable -and $storage['RegistryKey']) {
        $parts = $storage['RegistryKey'] -split '\\', 2
        switch ($parts[0]) {
            { $_ -in 'HKEY_LOCAL_MACHINE', 'HKLM' } { $info.Hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
            { $_ -in 'HKEY_CURRENT_USER', 'HKCU' }  { $info.Hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
            { $_ -in 'HKEY_USERS', 'HKU' }          { $info.Hive = [Microsoft.Win32.RegistryHive]::Users }
        }
        if ($parts.Count -gt 1) { $info.SubKey = $parts[1] + '\Engine\Mods' }
    }
    [pscustomobject]$info
}

function Open-ModsKey($Info, [bool]$Writable) {
    if (-not $Info -or -not $Info.Hive -or -not $Info.SubKey) { return $null }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Info.Hive, [Microsoft.Win32.RegistryView]::Registry64)
    if ($Writable) { return $base.CreateSubKey($Info.SubKey) }
    return $base.OpenSubKey($Info.SubKey)
}

function Test-ModInstalled($Info, [string]$ModId) {
    $mods = Open-ModsKey $Info $false
    if (-not $mods) { return $false }
    try {
        $k = $mods.OpenSubKey($ModId)
        if (-not $k) { return $false }
        try { return [bool]$k.GetValue('LibraryFileName') } finally { $k.Close() }
    } finally { $mods.Close() }
}

# Prueft, ob die Moon-Werte bereits in Windhawk stehen
function Test-MoonApplied($Info, $Mod) {
    $mods = Open-ModsKey $Info $false
    if (-not $mods) { return $false }
    try {
        $k = $mods.OpenSubKey("$($Mod.modId)\Settings")
        if (-not $k) { return $false }
        try {
            foreach ($p in $Mod.settings.PSObject.Properties) {
                $current = $k.GetValue($p.Name)
                if ($null -eq $current -or "$current" -ne "$($p.Value)") { return $false }
            }
            return $true
        } finally { $k.Close() }
    } finally { $mods.Close() }
}

# Schreibt die Moon-Einstellungen eines Mods (wie Windhawks "Textual mode" -> Save)
function Set-MoonSettings($Info, $Mod) {
    $mods = Open-ModsKey $Info $true
    try {
        $modKey = $mods.CreateSubKey($Mod.modId)
        $settingsKey = $modKey.CreateSubKey('Settings')
        try {
            # Alte Eintraege der von Moon verwalteten Bereiche entfernen (z. B. alte controlStyles[17])
            foreach ($name in $settingsKey.GetValueNames()) {
                foreach ($top in $Mod.managedKeys) {
                    if ($name -eq $top -or $name.StartsWith("$top[") -or $name.StartsWith("$top.")) {
                        $settingsKey.DeleteValue($name, $false)
                        break
                    }
                }
            }
            foreach ($p in $Mod.settings.PSObject.Properties) {
                if ($p.Value -is [string]) {
                    $settingsKey.SetValue($p.Name, $p.Value, [Microsoft.Win32.RegistryValueKind]::String)
                } else {
                    $settingsKey.SetValue($p.Name, [int]$p.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
            }
        } finally { $settingsKey.Close() }
        # Signal an die Windhawk-Engine: Einstellungen haben sich geaendert
        $now = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -band 0x7fffffff)
        $modKey.SetValue('SettingsChangeTime', $now, [Microsoft.Win32.RegistryValueKind]::DWord)
        $modKey.Close()
    } finally { $mods.Close() }
}

# =============================================================================
#  Oberflaeche
# =============================================================================

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Moon Installer" Width="780" Height="760" MinWidth="680" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0E0B1F" Foreground="#EEEAFF"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14">
  <Window.Resources>
    <SolidColorBrush x:Key="Card" Color="#1A1535"/>
    <SolidColorBrush x:Key="CardBorder" Color="#3A3168"/>
    <SolidColorBrush x:Key="Accent" Color="#8E7CFF"/>
    <SolidColorBrush x:Key="AccentLight" Color="#B8ABFF"/>
    <SolidColorBrush x:Key="Dim" Color="#ABA3D6"/>
    <Style TargetType="Border" x:Key="CardStyle">
      <Setter Property="Background" Value="{StaticResource Card}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Heading">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource AccentLight}"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#EEEAFF"/>
      <Setter Property="Background" Value="#2A2250"/>
      <Setter Property="BorderBrush" Value="#4B3AB3"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3A2F6E"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#EEEAFF"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="MinWidth" Value="190"/>
      <Setter Property="Margin" Value="0,0,16,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,16">
      <TextBlock FontSize="28" FontWeight="SemiBold"><Run Text="&#x1F319; "/><Run Text="Moon Installer" Foreground="#EEEAFF"/></TextBlock>
      <TextBlock Foreground="{StaticResource Dim}" Margin="0,4,0,0" TextWrapping="Wrap"
                 Text="Richtet das komplette Moon-Theme ein: Hintergrund, Farben, Ordnersymbole, Sounds, Startmenü, Taskleiste, Infocenter, Explorer und Einstellungen."/>
    </StackPanel>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <Border Style="{StaticResource CardStyle}">
          <StackPanel>
            <TextBlock Style="{StaticResource Heading}" Text="1 · Grund-Theme"/>
            <WrapPanel>
              <StackPanel Margin="0,0,0,6">
                <TextBlock Text="Hintergrund" Foreground="{StaticResource Dim}" FontSize="12" Margin="0,0,0,3"/>
                <ComboBox x:Name="WallpaperBox" SelectedIndex="0">
                  <ComboBoxItem Content="Moon Night (Vollmond)" Tag="night"/>
                  <ComboBoxItem Content="Moon Crescent (Sichel)" Tag="crescent"/>
                  <ComboBoxItem Content="Moon Horizon (Mondaufgang)" Tag="horizon"/>
                  <ComboBoxItem Content="Diashow (alle 30 Min.)" Tag="slideshow"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Margin="0,0,0,6">
                <TextBlock Text="Taskleiste" Foreground="{StaticResource Dim}" FontSize="12" Margin="0,0,0,3"/>
                <ComboBox x:Name="TaskbarBox" SelectedIndex="0">
                  <ComboBoxItem Content="Symbole in der Mitte" Tag="Center"/>
                  <ComboBoxItem Content="Symbole links" Tag="Left"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Margin="0,4,0,0">
                <CheckBox x:Name="FolderIconsBox" Content="Moon-Ordnersymbole" IsChecked="True" Margin="0,0,0,6"/>
                <CheckBox x:Name="SoundsBox" Content="Moon-Sounds" IsChecked="True" Margin="0,0,0,6"/>
                <CheckBox x:Name="LockScreenBox" Content="Auch Sperrbildschirm"/>
              </StackPanel>
            </WrapPanel>
            <TextBlock x:Name="ThemeStatus" Foreground="{StaticResource Dim}" Margin="0,8,0,0" Text="Bereit."/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource CardStyle}">
          <StackPanel>
            <TextBlock Style="{StaticResource Heading}" Text="2 · Windhawk"/>
            <TextBlock x:Name="WindhawkStatus" TextWrapping="Wrap" Text="Wird geprüft ..."/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource CardStyle}">
          <StackPanel>
            <TextBlock Style="{StaticResource Heading}" Text="3 · Moon-Styles"/>
            <TextBlock x:Name="ModsHint" Foreground="{StaticResource Dim}" TextWrapping="Wrap" Margin="0,0,0,10"
                       Text="Die App trägt den Moon-Style automatisch ein, sobald ein Mod installiert ist."/>
            <StackPanel x:Name="ModsPanel"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource CardStyle}">
          <StackPanel>
            <TextBlock Style="{StaticResource Heading}" Text="Protokoll"/>
            <TextBox x:Name="LogBox" Height="120" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                     Background="#0E0B1F" Foreground="#ABA3D6" BorderBrush="#3A3168" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <DockPanel Grid.Row="2" Margin="0,14,0,0" LastChildFill="False">
      <Button x:Name="UninstallButton" DockPanel.Dock="Left" Content="Theme entfernen"/>
      <Button x:Name="OpenWindhawkButton" DockPanel.Dock="Left" Content="Windhawk öffnen" Margin="10,0,0,0"/>
      <Button x:Name="InstallButton" DockPanel.Dock="Right" Content="✨  Alles installieren" FontSize="15" FontWeight="SemiBold"
              Background="#6A57E0" BorderBrush="#8E7CFF" Padding="22,10"/>
    </DockPanel>
  </Grid>
</Window>
'@

Add-LogLine 'Lade Oberflaeche ...'
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
Add-LogLine 'Oberflaeche geladen.'
$ui = @{}
foreach ($name in 'WallpaperBox', 'TaskbarBox', 'LockScreenBox', 'FolderIconsBox', 'SoundsBox', 'ThemeStatus', 'WindhawkStatus', 'ModsHint',
                  'ModsPanel', 'LogBox', 'UninstallButton', 'OpenWindhawkButton', 'InstallButton') {
    $ui[$name] = $window.FindName($name)
}

function Write-Log([string]$Text) {
    Add-LogLine $Text
    # Erst formatieren, dann uebergeben: in Methodenklammern trennt das Komma sonst die Methoden-Argumente
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Text
    $ui.LogBox.AppendText($line + "`r`n")
    $ui.LogBox.ScrollToEnd()
}

# --- Mod-Liste aufbauen ---
$script:Mods = @()
$index = Get-Content -Path (Join-Path $JsonDir 'index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($id in $index) {
    $mod = Get-Content -Path (Join-Path $JsonDir "$id.json") -Raw -Encoding UTF8 | ConvertFrom-Json

    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
    $widths = @(
        (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)),
        [System.Windows.GridLength]::Auto,
        [System.Windows.GridLength]::Auto)
    foreach ($w in $widths) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $w
        [void]$row.ColumnDefinitions.Add($cd)
    }
    $check = New-Object System.Windows.Controls.CheckBox
    $check.IsChecked = [bool]$mod.selectedByDefault
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Inlines.Add((New-Object System.Windows.Documents.Run ($mod.label + '  ')))
    $sub = New-Object System.Windows.Documents.Run $mod.modName
    $sub.Foreground = (Get-Brush '#ABA3D6')
    $sub.FontSize = 12
    $label.Inlines.Add($sub)
    $check.Content = $label

    $status = New-Object System.Windows.Controls.TextBlock
    $status.Margin = New-Object System.Windows.Thickness 12, 0, 12, 0
    $status.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $status.Text = '…'

    $copy = New-Object System.Windows.Controls.Button
    $copy.Content = 'Name kopieren'
    $copy.FontSize = 12
    $copy.Padding = New-Object System.Windows.Thickness 10, 4, 10, 4
    $copy.Tag = $mod.modName
    $copy.ToolTip = 'Zum Suchen in Windhawk'
    $copy.Add_Click({ param($s, $e) try { [System.Windows.Clipboard]::SetText([string]$s.Tag); Write-Log "Kopiert: $($s.Tag)" } catch { } })

    [System.Windows.Controls.Grid]::SetColumn($check, 0)
    [System.Windows.Controls.Grid]::SetColumn($status, 1)
    [System.Windows.Controls.Grid]::SetColumn($copy, 2)
    [void]$row.Children.Add($check)
    [void]$row.Children.Add($status)
    [void]$row.Children.Add($copy)
    [void]$ui.ModsPanel.Children.Add($row)

    $script:Mods += [pscustomobject]@{ Data = $mod; Check = $check; Status = $status; Applied = $false; Failed = $false }
}

# =============================================================================
#  Ablauf: eine Warteschlange von Schritten, die ein Timer abarbeitet,
#  damit das Fenster waehrend langer Vorgaenge bedienbar bleibt.
# =============================================================================

$script:Queue    = New-Object System.Collections.Queue
$script:Current  = $null     # @{ Name; Process; OnDone }
$script:Watching = $false    # Mods beobachten und Styles automatisch eintragen
$script:Info     = Get-WindhawkInfo

# $Arg wird beim Start an $Start uebergeben (die Schritte laufen spaeter im Timer,
# lokale Variablen des Aufrufers gibt es dann nicht mehr).
function Start-Step([string]$Name, [scriptblock]$Start, [scriptblock]$OnDone, $Arg = $null) {
    $script:Queue.Enqueue(@{ Name = $Name; Start = $Start; OnDone = $OnDone; Arg = $Arg })
}

$script:StepOut = Join-Path $env:TEMP 'MoonInstaller-step.out.txt'
$script:StepErr = Join-Path $env:TEMP 'MoonInstaller-step.err.txt'

# Startet ein Skript; seine Ausgabe landet in Dateien und wird danach ins Protokoll uebernommen
function Start-PowerShellFile([string]$File, [string]$Arguments) {
    Remove-Item -Path $script:StepOut, $script:StepErr -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath 'powershell.exe' -PassThru -NoNewWindow `
        -RedirectStandardOutput $script:StepOut -RedirectStandardError $script:StepErr `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$File`" $Arguments"
}

function Write-StepOutput {
    foreach ($f in $script:StepOut, $script:StepErr) {
        if (Test-Path $f) {
            foreach ($line in Get-Content -Path $f -ErrorAction SilentlyContinue) {
                $t = ($line -replace "$([char]27)\[[0-9;]*m", '').Trim()
                if ($t -and $t -notmatch '^=+$') { Write-Log "   $t" }
            }
        }
    }
}

function Write-FolderIconStatus {
    $v = $null
    try { $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Icons' -Name '3' -ErrorAction Stop).'3' } catch { }
    if ($v) { Write-Log "Ordnersymbole: gesetzt ($v)" } else { Write-Log 'Ordnersymbole: NICHT gesetzt' }
    $logo = $null
    try { $logo = (Get-ItemProperty -Path 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' -Name 'Logo' -ErrorAction Stop).Logo } catch { }
    if ($logo) { Write-Log 'Ordnervorschau: aus (Moon-Symbol bleibt sichtbar)' } else { Write-Log 'Ordnervorschau: an (kann das Moon-Symbol überdecken)' }
}

function Update-WindhawkStatus {
    $script:Info = Get-WindhawkInfo
    $i = $script:Info
    if (-not $i) {
        $ui.WindhawkStatus.Text = '○  Nicht installiert – wird bei „Alles installieren“ automatisch über winget installiert.'
    } elseif ($i.Portable) {
        $ui.WindhawkStatus.Text = "⚠  Portable Windhawk-Version gefunden ($($i.Root)). Hier kann die App die Styles nicht eintragen – bitte die Dateien aus 'windhawk\' im Textual mode einfügen."
    } elseif ($i.Cli) {
        $ui.WindhawkStatus.Text = "✓  Windhawk $($i.Version) mit Kommandozeile – Mods werden komplett automatisch installiert."
    } else {
        $ui.WindhawkStatus.Text = "✓  Windhawk $($i.Version) installiert. Die Mods installierst du mit je einem Klick in Windhawk, den Rest macht die App."
    }
}

function Update-ModStatus {
    $i = $script:Info
    foreach ($m in $script:Mods) {
        if (-not $m.Check.IsChecked) { $m.Status.Text = 'übersprungen'; $m.Status.Foreground = (Get-Brush '#6F6894'); continue }
        if (-not $i -or $i.Portable) { $m.Status.Text = '–'; $m.Status.Foreground = (Get-Brush '#ABA3D6'); continue }
        if (-not (Test-ModInstalled $i $m.Data.modId)) {
            $m.Status.Text = '○  Mod nicht installiert'; $m.Status.Foreground = (Get-Brush '#ABA3D6'); continue
        }
        if ($m.Applied -or (Test-MoonApplied $i $m.Data)) {
            $m.Applied = $true
            $m.Status.Text = '✓  Moon-Style aktiv'; $m.Status.Foreground = (Get-Brush '#8EE3C0'); continue
        }
        if ($script:Watching -and -not $m.Failed) {
            try {
                Set-MoonSettings $i $m.Data
                $m.Applied = $true
                $m.Status.Text = '✓  Moon-Style aktiv'; $m.Status.Foreground = (Get-Brush '#8EE3C0')
                Write-Log "Moon-Style eingetragen: $($m.Data.modName)"
            } catch {
                $m.Failed = $true
                $m.Status.Text = '⚠  Fehler'; $m.Status.Foreground = (Get-Brush '#FF9DB6')
                Write-Log "Fehler bei $($m.Data.modName): $($_.Exception.Message)"
            }
        } else {
            $m.Status.Text = '●  installiert, Style fehlt'; $m.Status.Foreground = (Get-Brush '#F5D78E')
        }
    }

    if ($script:Watching) {
        $pending = @($script:Mods | Where-Object { $_.Check.IsChecked -and -not $_.Applied })
        if ($pending.Count -eq 0) {
            $script:Watching = $false
            $ui.ModsHint.Text = '🌙  Fertig! Alle ausgewählten Moon-Styles sind aktiv. Startmenü einmal öffnen und die Einstellungen neu starten.'
            Write-Log 'Alles erledigt.'
        } elseif ($i -and -not $script:Current -and $script:Queue.Count -eq 0) {
            $names = ($pending | ForEach-Object { $_.Data.modName }) -join ', '
            $ui.ModsHint.Text = "In Windhawk jetzt diese Mods suchen und auf 'Install' klicken: $names. Die App trägt den Moon-Style danach sofort ein."
        }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1.5)
$timer.Add_Tick({
    try {
        if ($script:Current) {
            $p = $script:Current.Process
            if ($p -and -not $p.HasExited) { return }
            $code = if ($p) { $p.ExitCode } else { 0 }
            $done = $script:Current.OnDone
            $script:Current = $null
            if ($done) { & $done $code }
        }
        if (-not $script:Current -and $script:Queue.Count -gt 0) {
            $step = $script:Queue.Dequeue()
            Write-Log $step.Name
            $proc = & $step.Start $step.Arg
            # Handle sofort abfragen, sonst liefert Windows PowerShell 5.1 spaeter keinen ExitCode
            if ($proc -is [System.Diagnostics.Process]) { $null = $proc.Handle } else { $proc = $null }
            $script:Current = @{ Name = $step.Name; Process = $proc; OnDone = $step.OnDone }
            return
        }
        Update-ModStatus
    } catch {
        Write-Log "Fehler: $($_.Exception.Message)"
    }
})

# --- Buttons -----------------------------------------------------------------

# Fehler in Klicks/Ereignissen nur protokollieren, statt die ganze App zu beenden
function Invoke-Safe([scriptblock]$Body) {
    try { . $Body } catch {
        Write-Log "Fehler: $($_.Exception.Message) (Zeile $($_.InvocationInfo.ScriptLineNumber))"
        $ui.InstallButton.IsEnabled = $true
    }
}

$ui.InstallButton.Add_Click({ Invoke-Safe {
    $ui.InstallButton.IsEnabled = $false
    foreach ($m in $script:Mods) { $m.Failed = $false }

    # 1) Grund-Theme
    $wall = $ui.WallpaperBox.SelectedItem.Tag
    $argList = if ($wall -eq 'slideshow') { '-Slideshow' } else { "-Wallpaper $wall" }
    $argList += " -TaskbarAlignment $($ui.TaskbarBox.SelectedItem.Tag)"
    if ($ui.LockScreenBox.IsChecked) { $argList += ' -LockScreen' }
    if (-not $ui.FolderIconsBox.IsChecked) { $argList += ' -NoFolderIcons' }
    if (-not $ui.SoundsBox.IsChecked) { $argList += ' -NoSounds' }
    $ui.ThemeStatus.Text = 'Wird angewendet ... (die Einstellungen gehen kurz auf und zu)'
    Start-Step 'Grund-Theme wird angewendet ...' { param($a) Start-PowerShellFile (Join-Path $Root 'install.ps1') $a } {
        param($code)
        Write-StepOutput
        if ($code -eq 0) { $ui.ThemeStatus.Text = '✓  Grund-Theme ist aktiv.'; Write-Log 'Grund-Theme fertig.' }
        else { $ui.ThemeStatus.Text = "⚠  install.ps1 meldete Fehlercode $code."; Write-Log "install.ps1 Fehlercode $code" }
        Write-FolderIconStatus
    } $argList

    # 2) Windhawk
    if (-not (Get-WindhawkInfo)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $ui.WindhawkStatus.Text = 'Windhawk wird installiert ...'
            Start-Step 'Windhawk wird über winget installiert ...' {
                Start-Process -FilePath 'winget' -PassThru -WindowStyle Hidden -ArgumentList 'install --id RamenSoftware.Windhawk -e --silent --accept-source-agreements --accept-package-agreements'
            } { param($code) Write-Log "winget beendet (Code $code)."; Update-WindhawkStatus }
        } else {
            Write-Log 'winget nicht gefunden – Windhawk bitte von https://windhawk.net installieren.'
            Start-Process 'https://windhawk.net'
        }
    }

    # 3) Mods installieren bzw. Windhawk oeffnen
    Start-Step 'Mods werden vorbereitet ...' {
        Update-WindhawkStatus
        $i = $script:Info
        if (-not $i) { Write-Log 'Windhawk wurde nicht gefunden.'; $ui.InstallButton.IsEnabled = $true; return $null }
        if ($i.Portable) { Write-Log 'Portable Windhawk: Styles bitte manuell einfügen.'; $ui.InstallButton.IsEnabled = $true; return $null }
        $missing = @($script:Mods | Where-Object { $_.Check.IsChecked -and -not (Test-ModInstalled $i $_.Data.modId) })
        if ($i.Cli -and $missing.Count -gt 0) {
            foreach ($m in $missing) {
                Start-Step "Installiere Mod $($m.Data.modName) ..." {
                    param($a)
                    Start-Process -FilePath $a.Cli -PassThru -WindowStyle Hidden -ArgumentList "mod install $($a.Id)"
                } { param($code) if ($code -ne 0) { Write-Log "Mod-Installation fehlgeschlagen (Code $code)." } } @{ Cli = $i.Cli; Id = $m.Data.modId }
            }
        } elseif ($missing.Count -gt 0) {
            Write-Log 'Windhawk wird geöffnet – bitte dort die angezeigten Mods installieren.'
            Start-Process -FilePath $i.Exe -ArgumentList '-run-ui'
        }
        $script:Watching = $true
        $ui.InstallButton.IsEnabled = $true
        return $null
    } $null
} })

$ui.OpenWindhawkButton.Add_Click({ Invoke-Safe {
    $i = Get-WindhawkInfo
    if ($i) { Start-Process -FilePath $i.Exe -ArgumentList '-run-ui' } else { Start-Process 'https://windhawk.net' }
} })

$ui.UninstallButton.Add_Click({ Invoke-Safe {
    $r = [System.Windows.MessageBox]::Show(
        "Grund-Theme entfernen und die vorherigen Windows-Einstellungen wiederherstellen?`n`nDie Windhawk-Mods bleiben installiert – die kannst du in Windhawk deaktivieren.",
        'Moon entfernen', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Start-Step 'Theme wird entfernt ...' { Start-PowerShellFile (Join-Path $Root 'uninstall.ps1') '' } {
        param($code) Write-StepOutput; $ui.ThemeStatus.Text = 'Theme entfernt.'; Write-Log "uninstall.ps1 beendet (Code $code)."
    }
} })

$window.Add_ContentRendered({ Invoke-Safe {
    try { [void][MoonInstaller.Native]::ShowWindow([MoonInstaller.Native]::GetConsoleWindow(), 0) } catch { }
    Write-Log "Moon Installer bereit. Ordner: $Root"
    if (-not $script:IsAdmin) { Write-Log 'Achtung: ohne Adminrechte gestartet – die Moon-Styles können nicht in Windhawk eingetragen werden.' }
    Update-WindhawkStatus
    Update-ModStatus
    $timer.Start()
} })

[void]$window.ShowDialog()
