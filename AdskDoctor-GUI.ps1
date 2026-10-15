<#
    AdskDoctor-GUI.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor (GUI)
    ---------------------------------------------------------------------------
    Bilingual Windows GUI (Arabic / English) with a live language toggle.
    Wraps the Phase 1-4 scripts:
        AdskDoctor.ps1 (diagnostic)  Backup.ps1  Clean.ps1  Repair.ps1
    Loads a company logo (unlock-logo.png) from this folder if present.

    Run:  powershell -STA -ExecutionPolicy Bypass -File .\AdskDoctor-GUI.ps1
          powershell -STA -ExecutionPolicy Bypass -File .\AdskDoctor-GUI.ps1 -Lang ar
#>

param(
    # Language the window opens in: 'en' (default) or 'ar'. The toggle button
    # still switches between the two at runtime.
    [ValidateSet('ar', 'en')]
    [string]$Lang = 'en'
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# WPF needs an STA thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command powershell).Source
        $extra = ''
        if ($Lang -and $Lang -ne 'en') { $extra = ' -Lang ' + $Lang }
        $psi.Arguments = ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $extra)
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit
    }
    # (compiled exe) - cannot relaunch; continue as-is
}

# Robust application directory (works as a .ps1 AND inside a compiled .exe)
function Get-AppDir {
    $candidates = @()
    try { if ($PSScriptRoot) { $candidates += $PSScriptRoot } } catch {}
    try { $candidates += [System.AppDomain]::CurrentDomain.BaseDirectory } catch {}
    try { if ($MyInvocation.MyCommand.Path) { $candidates += (Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent) } } catch {}
    try { $candidates += (Split-Path -LiteralPath ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent) } catch {}
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $c = $c.TrimEnd('\','/')
        if ($c -match '["<>|*?\x00]') { continue }
        try { if (Test-Path -LiteralPath ([System.IO.Path]::Combine($c, 'AdskDoctor.ps1'))) { return $c } } catch {}
    }
    foreach ($c in $candidates) { if ($c) { return ($c.TrimEnd('\','/')) } }
    return (Get-Location).Path
}
$here = Get-AppDir

# ===========================================================================
# Translations
# ===========================================================================
$L = @{
  ar = @{
    windowTitle   = 'UNLOCK DIGITAL - دكتور ترخيص أوتوديسك'
    brand         = 'UNLOCK DIGITAL'
    subtitle      = 'دكتور ترخيص أوتوديسك  —  تشخيص وإصلاح مشاكل الترخيص'
    brandSmall    = 'دكتور ترخيص أوتوديسك'
    actions       = 'الإجراءات'
    bDiag         = 'فحص الجهاز (تشخيص)'
    bBackup       = 'نسخة احتياطية'
    bClean        = 'تنظيف الجهاز'
    bRepair       = 'إصلاح المكوّنات الرسمية'
    bUndo         = 'رجوع (Undo)'
    bReport       = 'فتح آخر تقرير'
    bLang         = 'English'
    bDownload     = 'تحميل البرامج الرسمية'
    downloadTip   = 'افتح موقع أوتوديسك الرسمي لتحميل البرامج (بحساب الاشتراك)'
    bBundle       = 'حزمة الدعم (تقرير + لوجات)'
    bundleTip     = 'يعمل فحص ويجمع لوجات الترخيص مع التقرير في ملف ZIP واحد تبعته للدعم'
    tip           = 'نصيحة: ابدأ بـ «فحص الجهاز»، بعدين «نسخة احتياطية»، وبعدها «تنظيف» ثم «إصلاح».'
    logTitle      = 'سجل العمليات'
    statusReady   = 'جاهز'
    statusRunning = 'شغّال: '
    statusDone    = 'خلص بنجاح'
    statusCode    = 'خلص بكود '
    welcomeTitle  = 'UNLOCK DIGITAL  -  دكتور ترخيص أوتوديسك'
    welcome       = @(
      'اختار إجراء من اللوحة. الترتيب المقترح:',
      '   1) فحص الجهاز     (بيطلعلك تقرير بحالة الجهاز)',
      '   2) نسخة احتياطية  (أمان قبل أي تعديل)',
      '   3) تنظيف          (يشيل بقايا الكراك)',
      '   4) إصلاح          (يعيد مكوّنات الترخيص الرسمية)'
    )
    doneMsg       = 'تمام، خلصت.'
    cleanTitle    = 'تنظيف الجهاز'
    cleanText     = "هتعمل تنفيذ فعلي للتنظيف (بعد نسخة احتياطية إجبارية)؟`n`nنعم = تنفيذ فعلي`nلا  = معاينة بس (بدون أي تغيير)"
    cleanApply    = 'تنظيف الجهاز (تنفيذ فعلي)'
    cleanPreview  = 'تنظيف الجهاز (معاينة)'
    repairTitle   = 'إصلاح المكوّنات'
    repairText    = "إصلاح/إعادة تسطيب مكوّنات الترخيص الرسمية؟`n`nنعم = تنفيذ فعلي`nلا  = معاينة بس"
    repairApply   = 'إصلاح المكوّنات (تنفيذ)'
    repairPreview = 'إصلاح المكوّنات (معاينة)'
    repairMissing = 'ملف الإصلاح Repair.ps1 لسه مش موجود.'
    repairAskDir  = "عندك فولدر فيه المثبّتات الرسمية (ADLS / AdSSO / WebView2)؟`n`nنعم = اختار الفولدر`nلا  = كمّل من غيرهم"
    pickFolderTitle = 'اختَر فولدر المثبّتات الرسمية'
    noBackups     = 'مفيش نسخ احتياطية.'
    noUndo        = 'مفيش نسخ فيها UNDO.'
    undoTitle     = 'رجوع (Undo)'
    undoConfirm   = 'ترجّع النسخة: '
    noReport      = 'مفيش تقرير لسه. ابدأ بفحص الجهاز.'
    pickTitle     = 'اختَر نسخة احتياطية'
    pickOk        = 'اختيار'
    pickCancel    = 'إلغاء'
    busyMsg       = 'فيه عملية شغالة بالفعل، استنى تخلص.'
  }
  en = @{
    windowTitle   = 'UNLOCK DIGITAL - Autodesk Licensing Doctor'
    brand         = 'UNLOCK DIGITAL'
    subtitle      = 'Autodesk Licensing Doctor  —  diagnose and fix licensing problems'
    brandSmall    = 'Autodesk Licensing Doctor'
    actions       = 'Actions'
    bDiag         = 'Scan this PC (diagnose)'
    bBackup       = 'Create backup'
    bClean        = 'Clean this PC'
    bRepair       = 'Repair official components'
    bUndo         = 'Roll back (Undo)'
    bReport       = 'Open last report'
    bLang         = 'العربية'
    bDownload     = 'Download official products'
    downloadTip   = 'Open the official Autodesk download page (sign in with your subscription)'
    bBundle       = 'Support bundle (report + logs)'
    bundleTip     = 'Scan, then collect the licensing logs with the report into one zip to send to support'
    tip           = 'Tip: start with "Scan this PC", then "Create backup", then "Clean this PC" and finally "Repair".'
    logTitle      = 'Activity log'
    statusReady   = 'Ready'
    statusRunning = 'Running: '
    statusDone    = 'Finished successfully'
    statusCode    = 'Finished with code '
    welcomeTitle  = 'UNLOCK DIGITAL  -  Autodesk Licensing Doctor'
    welcome       = @(
      'Pick an action from the panel. Suggested order:',
      '   1) Scan this PC   (produces a health report)',
      '   2) Create backup  (safety before any change)',
      '   3) Clean this PC  (removes non-genuine leftovers)',
      '   4) Repair         (reinstalls official licensing)'
    )
    doneMsg       = 'All done.'
    cleanTitle    = 'Clean this PC'
    cleanText     = "Run the cleanup for real (runs a backup first)?`n`nYes = apply`nNo  = preview only (no changes)"
    cleanApply    = 'Clean this PC (apply)'
    cleanPreview  = 'Clean this PC (preview)'
    repairTitle   = 'Repair components'
    repairText    = "Repair / reinstall the official licensing components?`n`nYes = apply`nNo  = preview only"
    repairApply   = 'Repair components (apply)'
    repairPreview = 'Repair components (preview)'
    repairMissing = 'Repair.ps1 is not present yet.'
    repairAskDir  = "Do you have a folder with the official installers (ADLS / AdSSO / WebView2)?`n`nYes = pick the folder`nNo  = continue without them"
    pickFolderTitle = 'Select the folder with the official installers'
    noBackups     = 'No backups found.'
    noUndo        = 'No backups contain an UNDO.'
    undoTitle     = 'Roll back (Undo)'
    undoConfirm   = 'Roll back this backup: '
    noReport      = 'No report yet. Run a scan first.'
    pickTitle     = 'Choose a backup'
    pickOk        = 'Select'
    pickCancel    = 'Cancel'
    busyMsg       = 'A task is already running, please wait.'
  }
}

$script:lang = $Lang
function T { param([string]$k) $L[$script:lang][$k] }

# ---------------------------------------------------------------------------
# XAML layout
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UNLOCK DIGITAL" Height="690" Width="1010" MinHeight="560" MinWidth="840"
        WindowStartupLocation="CenterScreen"
        Background="#F1F2F4" FontFamily="Segoe UI" FlowDirection="RightToLeft">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#111214" Padding="20,16">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal">
          <Border Background="#E41E2E" Width="6" Height="60" CornerRadius="3" Margin="0,0,16,0"/>
          <Image x:Name="LogoImage" Height="58" Margin="0,0,16,0" Stretch="Uniform" Visibility="Collapsed"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock x:Name="BrandText" Text="UNLOCK DIGITAL" Foreground="White" FontSize="26" FontWeight="Bold"/>
            <TextBlock x:Name="SubTitle" Text="" Foreground="#AEB3BD" FontSize="13" Margin="0,4,0,0"/>
          </StackPanel>
        </StackPanel>
        <Button x:Name="BtnLang" Grid.Column="1" Content="English" Width="110" Height="34"
                VerticalAlignment="Top" Background="#22252B" Foreground="White" BorderBrush="#3A3E46"/>
      </Grid>
    </Border>

    <!-- Body -->
    <Grid Grid.Row="1" Margin="16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Action buttons -->
      <!-- The panel scrolls, so a short window never cuts the tip line in half
           (the buttons grew with every release and the default height is fixed). -->
      <Border Grid.Column="0" Background="White" CornerRadius="10" Padding="14" Margin="0,0,14,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <TextBlock x:Name="ActionsLabel" Text="Actions" FontSize="15" FontWeight="SemiBold" Foreground="#333" Margin="0,0,0,8"/>
          <Button x:Name="BtnDiag"   Content="" Height="40" Margin="0,0,0,6" FontSize="13"/>
          <Button x:Name="BtnBackup" Content="" Height="40" Margin="0,0,0,6" FontSize="13"/>
          <Button x:Name="BtnClean"  Content="" Height="40" Margin="0,0,0,6" FontSize="13"/>
          <Button x:Name="BtnRepair" Content="" Height="40" Margin="0,0,0,6" FontSize="13"/>
          <Button x:Name="BtnUndo"   Content="" Height="40" Margin="0,0,0,6" FontSize="13"/>
          <Separator Margin="0,6,0,6"/>
          <Button x:Name="BtnDownload" Content="" Height="38" Margin="0,0,0,6" FontSize="13" Background="#E41E2E" Foreground="White" FontWeight="SemiBold"/>
          <Button x:Name="BtnReport" Content="" Height="34" Margin="0,0,0,6" FontSize="13"/>
          <Button x:Name="BtnBundle" Content="" Height="34" Margin="0,0,0,6" FontSize="13"/>
          <TextBlock x:Name="TipText" TextWrapping="Wrap" Foreground="#8A8F99" FontSize="11" Margin="0,10,0,0"/>
        </StackPanel>
        </ScrollViewer>
      </Border>

      <!-- Log output -->
      <Border Grid.Column="1" Background="#16181C" CornerRadius="10">
        <DockPanel>
          <Border DockPanel.Dock="Top" Background="#1E2126" CornerRadius="10,10,0,0" Padding="14,10">
            <TextBlock x:Name="LogTitle" Text="" Foreground="#DDE1E7" FontSize="13" FontWeight="SemiBold"/>
          </Border>
          <TextBox x:Name="TxtLog" Background="Transparent" Foreground="#D6DEE8" BorderThickness="0"
                   FontFamily="Consolas" FontSize="12.5" Padding="14,10"
                   IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   FlowDirection="LeftToRight"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="#E7E9ED" Padding="18,10">
      <DockPanel>
        <TextBlock x:Name="CopyText" DockPanel.Dock="Left" Text="© Unlock Digital - By Eng. Eslam Ashraf"
                   Foreground="#6B7280" FontSize="11.5" VerticalAlignment="Center" Margin="0,0,16,0"/>
        <ProgressBar x:Name="Bar" DockPanel.Dock="Right" Width="220" Height="8" IsIndeterminate="False"/>
        <TextBlock x:Name="StatusText" Text="" Foreground="#333" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [System.Windows.Markup.XamlReader]::Load($reader)

$LogoImage  = $win.FindName('LogoImage')
$BrandText  = $win.FindName('BrandText')
$SubTitle   = $win.FindName('SubTitle')
$ActionsLabel = $win.FindName('ActionsLabel')
$TipText    = $win.FindName('TipText')
$TxtLog     = $win.FindName('TxtLog')
$StatusText = $win.FindName('StatusText')
$Bar        = $win.FindName('Bar')
$LogTitle   = $win.FindName('LogTitle')
$buttons    = @{}
foreach ($n in 'BtnDiag','BtnBackup','BtnClean','BtnRepair','BtnUndo','BtnDownload','BtnReport','BtnBundle','BtnLang') {
    $buttons[$n] = $win.FindName($n)
}

# The version comes from the compiled exe, so a support request can name it.
# Running the .ps1 directly (development) has no version to report.
$script:appVersion = 'dev'
try {
    $fvi = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileVersionInfo
    if ($fvi -and $fvi.FileVersion) { $script:appVersion = $fvi.FileVersion }
} catch {}

# logo
$script:hasLogo = $false
$logoPath = Join-Path $here 'unlock-logo.png'
if (Test-Path -LiteralPath $logoPath) {
    try {
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.UriSource = New-Object System.Uri($logoPath); $img.CacheOption = 'OnLoad'; $img.EndInit()
        $LogoImage.Source = $img
        $LogoImage.Visibility = 'Visible'
        $script:hasLogo = $true
    } catch {}
}

# ---------------------------------------------------------------------------
# i18n apply
# ---------------------------------------------------------------------------
function Apply-Language {
    $win.Title = T 'windowTitle'
    $SubTitle.Text = (T 'subtitle') + '   ·  v' + $script:appVersion
    if ($script:hasLogo) { $BrandText.Text = (T 'brandSmall'); $BrandText.FontSize = 22 }
    else { $BrandText.Text = (T 'brand'); $BrandText.FontSize = 26 }
    $ActionsLabel.Text = T 'actions'
    $buttons['BtnDiag'].Content   = T 'bDiag'
    $buttons['BtnBackup'].Content = T 'bBackup'
    $buttons['BtnClean'].Content  = T 'bClean'
    $buttons['BtnRepair'].Content = T 'bRepair'
    $buttons['BtnUndo'].Content   = T 'bUndo'
    $buttons['BtnReport'].Content = T 'bReport'
    $buttons['BtnDownload'].Content = T 'bDownload'
    $buttons['BtnDownload'].ToolTip = T 'downloadTip'
    $buttons['BtnBundle'].Content = T 'bBundle'
    $buttons['BtnBundle'].ToolTip = T 'bundleTip'
    $buttons['BtnLang'].Content   = T 'bLang'
    $TipText.Text = T 'tip'
    $win.FlowDirection = if ($script:lang -eq 'ar') { [System.Windows.FlowDirection]::RightToLeft } else { [System.Windows.FlowDirection]::LeftToRight }
    if (-not $script:busy) {
        $LogTitle.Text = T 'logTitle'
        $StatusText.Text = T 'statusReady'
        Write-Welcome
    }
}

function Write-Welcome {
    $TxtLog.Clear()
    Add-Log (T 'welcomeTitle')
    Add-Log ''
    foreach ($line in (T 'welcome')) { Add-Log $line }
    Add-Log ''
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$script:busy = $false
$script:proc = $null
$script:openAfter = $null
$script:outTask = $null
$script:errTask = $null
$script:timer = $null
$script:taskDone = $false

function Add-Log {
    param([string]$Text)
    $TxtLog.AppendText($Text + "`r`n")
    $TxtLog.ScrollToEnd()
}
function Set-Busy {
    param([bool]$Busy)
    $script:busy = $Busy
    foreach ($b in $buttons.Values) { $b.IsEnabled = -not $Busy }
    $Bar.IsIndeterminate = $Busy
}
function Quote-Arg {
    param([string]$s)
    if ($s -match '[\s"]') { '"' + ($s -replace '"','\"') + '"' } else { $s }
}
function End-Task {
    param([int]$Code)
    Set-Busy $false
    if ($Code -eq 0) { $StatusText.Text = (T 'statusDone'); Add-Log ''; Add-Log ('>> ' + (T 'doneMsg')) }
    else { $StatusText.Text = ((T 'statusCode') + $Code); Add-Log ''; Add-Log ('>> ' + (T 'statusCode') + $Code) }
    if ($script:openAfter -and (Test-Path -LiteralPath $script:openAfter)) { Start-Process $script:openAfter }
    $script:openAfter = $null
}
# ---------------------------------------------------------------------------
# Child-process output
# ---------------------------------------------------------------------------
# The process events (add_OutputDataReceived / add_ErrorDataReceived /
# add_Exited) are deliberately NOT used. .NET raises them on worker threads that
# have no PowerShell runspace, so a scriptblock handler throws
# "PSInvalidOperationException ... ScriptBlock.GetContextFromTLS()" there and
# kills the whole application. A plain "powershell -File" run survives it, but
# the ps2exe-compiled build - the one that ships inside the installer - crashes
# the moment a task produces output.
#
# The async line readers are polled from a DispatcherTimer instead; it ticks on
# the UI thread, which does have a runspace.
function Receive-Output {
    while ($script:outTask -and $script:outTask.IsCompleted) {
        $line = $script:outTask.Result
        if ($null -eq $line) { $script:outTask = $null; break }
        Add-Log $line
        $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
    }
    while ($script:errTask -and $script:errTask.IsCompleted) {
        $line = $script:errTask.Result
        if ($null -eq $line) { $script:errTask = $null; break }
        Add-Log ('! ' + $line)
        $script:errTask = $script:proc.StandardError.ReadLineAsync()
    }
}
function Stop-TaskTimer {
    if ($script:timer) { $script:timer.Stop(); $script:timer = $null }
}
function Complete-Task {
    $script:taskDone = $true
    $guard = 0
    while (($script:outTask -or $script:errTask) -and $guard -lt 20) {
        Receive-Output
        if ($script:outTask -or $script:errTask) { Start-Sleep -Milliseconds 100; $guard++ }
    }
    Receive-Output
    Stop-TaskTimer
    $code = 0
    try { $code = $script:proc.ExitCode } catch { }
    End-Task $code
}

function Run-Task {
    param([string]$Title, [string[]]$Arguments, [string]$OpenAfter)
    if ($script:busy) { [System.Windows.MessageBox]::Show((T 'busyMsg'),'UNLOCK DIGITAL') | Out-Null; return }
    Stop-TaskTimer
    Set-Busy $true
    $TxtLog.Clear()
    $StatusText.Text = ((T 'statusRunning') + $Title)
    $LogTitle.Text = $Title
    $script:openAfter = $OpenAfter
    Add-Log ('==========  ' + $Title + '  ==========')
    Add-Log ''

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell).Source
    $psi.Arguments = (@('-NoProfile','-ExecutionPolicy','Bypass') + $Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { $p.Start() | Out-Null } catch { Add-Log (': ' + $_.Exception.Message); Set-Busy $false; return }

    $script:proc     = $p
    $script:outTask  = $p.StandardOutput.ReadLineAsync()
    $script:errTask  = $p.StandardError.ReadLineAsync()
    $script:taskDone = $false

    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:timer.Add_Tick({
        Receive-Output
        if (-not $script:taskDone -and $script:proc -and $script:proc.HasExited) { Complete-Task }
    })
    $script:timer.Start()
}

# ---------------------------------------------------------------------------
# Button actions
# ---------------------------------------------------------------------------
# Folder picker for the official installers (Repair can be pointed at a folder
# that holds the ADLS / AdSSO / WebView2 installers from the product image).
function Browse-Folder {
    param([string]$Title)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Title
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    } catch { }
    return $null
}
$buttons['BtnLang'].Add_Click({
    $script:lang = if ($script:lang -eq 'ar') { 'en' } else { 'ar' }
    Apply-Language
})

$buttons['BtnDiag'].Add_Click({
    Run-Task -Title (T 'bDiag') `
        -Arguments @('-File', (Join-Path $here 'AdskDoctor.ps1'), '-Html', '-Export', (Join-Path $here 'report.html')) `
        -OpenAfter (Join-Path $here 'report.html')
})

$buttons['BtnBackup'].Add_Click({
    Run-Task -Title (T 'bBackup') -Arguments @('-File', (Join-Path $here 'Backup.ps1'))
})

$buttons['BtnClean'].Add_Click({
    $r = [System.Windows.MessageBox]::Show((T 'cleanText'), (T 'cleanTitle'), 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return }
    if ($r -eq 'Yes') { Run-Task -Title (T 'cleanApply')   -Arguments @('-File', (Join-Path $here 'Clean.ps1'), '-Apply') }
    else              { Run-Task -Title (T 'cleanPreview') -Arguments @('-File', (Join-Path $here 'Clean.ps1')) }
})

$buttons['BtnRepair'].Add_Click({
    $repair = Join-Path $here 'Repair.ps1'
    if (-not (Test-Path -LiteralPath $repair)) { [System.Windows.MessageBox]::Show((T 'repairMissing'),'UNLOCK DIGITAL') | Out-Null; return }
    $r = [System.Windows.MessageBox]::Show((T 'repairText'), (T 'repairTitle'), 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return }
    $repairArgs = @('-File', $repair)
    if ($r -eq 'Yes') { $repairArgs += '-Apply' }
    # Repair installs the official components only when it is given them, so the
    # operator can point it at the folder that holds them.
    if ($r -eq 'Yes' -or $r -eq 'No') {
        $q = [System.Windows.MessageBox]::Show((T 'repairAskDir'), (T 'repairTitle'), 'YesNo', 'Question')
        if ($q -eq 'Yes') {
            $dir = Browse-Folder -Title (T 'pickFolderTitle')
            if ($dir) { $repairArgs += @('-InstallerDir', $dir) }
        }
    }
    Run-Task -Title (T $(if ($r -eq 'Yes') { 'repairApply' } else { 'repairPreview' })) -Arguments $repairArgs
})

$buttons['BtnUndo'].Add_Click({
    $root = Join-Path $here 'backups'
    if (-not (Test-Path -LiteralPath $root)) { [System.Windows.MessageBox]::Show((T 'noBackups'),'UNLOCK DIGITAL') | Out-Null; return }
    $list = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'UNDO.ps1') } | Sort-Object LastWriteTime -Descending)
    if ($list.Count -eq 0) { [System.Windows.MessageBox]::Show((T 'noUndo'),'UNLOCK DIGITAL') | Out-Null; return }
    $pick = Show-Picker -Items (@($list | ForEach-Object { $_.Name })) -Title (T 'pickTitle')
    if (-not $pick) { return }
    $sel = $list | Where-Object { $_.Name -eq $pick } | Select-Object -First 1
    $r = [System.Windows.MessageBox]::Show(((T 'undoConfirm') + $sel.Name + ' ?'), (T 'undoTitle'), 'YesNo', 'Warning')
    if ($r -eq 'Yes') { Run-Task -Title ((T 'undoTitle') + ': ' + $sel.Name) -Arguments @('-File', (Join-Path $sel.FullName 'UNDO.ps1')) }
})

$buttons['BtnReport'].Add_Click({
    $rep = Join-Path $here 'report.html'
    if (Test-Path -LiteralPath $rep) { Start-Process $rep } else { [System.Windows.MessageBox]::Show((T 'noReport'),'UNLOCK DIGITAL') | Out-Null }
})

# One file to send to support: the report + the licensing logs. The folder is
# opened afterwards so the zip is easy to find.
$buttons['BtnBundle'].Add_Click({
    Run-Task -Title (T 'bBundle') `
        -Arguments @('-File', (Join-Path $here 'AdskDoctor.ps1'), '-Html', '-Export', (Join-Path $here 'report.html'), '-Bundle') `
        -OpenAfter $here
})

$buttons['BtnDownload'].Add_Click({ Start-Process 'https://manage.autodesk.com/products/all' })

# ---------------------------------------------------------------------------
# Modal picker
# ---------------------------------------------------------------------------
function Show-Picker {
    param([string[]]$Items, [string]$Title)
    [xml]$px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="pick" Height="320" Width="380" WindowStartupLocation="CenterOwner"
        Background="#F1F2F4" FontFamily="Segoe UI" FlowDirection="RightToLeft">
  <Grid Margin="14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Hdr" Grid.Row="0" FontSize="14" FontWeight="SemiBold" Foreground="#333" Margin="0,0,0,8"/>
    <ListBox x:Name="Lst" Grid.Row="1"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,10,0,0">
      <Button x:Name="Ok" Content="OK" Width="95" Height="32" Margin="0,0,8,0"/>
      <Button x:Name="Cancel" Content="Cancel" Width="95" Height="32"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $r = New-Object System.Xml.XmlNodeReader $px
    $d = [System.Windows.Markup.XamlReader]::Load($r)
    $d.Owner = $win
    $d.Title = $Title
    $d.FindName('Hdr').Text = $Title
    $d.FindName('Ok').Content = (T 'pickOk')
    $d.FindName('Cancel').Content = (T 'pickCancel')
    $d.FlowDirection = if ($script:lang -eq 'ar') { [System.Windows.FlowDirection]::RightToLeft } else { [System.Windows.FlowDirection]::LeftToRight }
    $lst = $d.FindName('Lst')
    foreach ($i in $Items) { [void]$lst.Items.Add($i) }
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $script:pickResult = $null
    $d.FindName('Ok').Add_Click({ $script:pickResult = $lst.SelectedItem; $d.Close() })
    $d.FindName('Cancel').Add_Click({ $script:pickResult = $null; $d.Close() })
    $d.ShowDialog() | Out-Null
    return $script:pickResult
}

# ---------------------------------------------------------------------------
# Show
# ---------------------------------------------------------------------------
Apply-Language
$win.ShowDialog() | Out-Null
