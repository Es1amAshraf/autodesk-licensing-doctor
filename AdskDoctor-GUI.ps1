<#
    AdskDoctor-GUI.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor (GUI)
    ---------------------------------------------------------------------------
    Bilingual Windows GUI (Arabic / English) with a live language toggle.
    Wraps the Phase 1-4 scripts:
        AdskDoctor.ps1 (diagnostic)  Backup.ps1  Clean.ps1  Purge.ps1  Repair.ps1
        LicenseMode.ps1 (license type switch, driven by the panel on the left)
    Loads the AdskDoctor mark (adskdoctor-logo.png) from this folder if present.

    Run:  powershell -STA -ExecutionPolicy Bypass -File .\AdskDoctor-GUI.ps1
          powershell -STA -ExecutionPolicy Bypass -File .\AdskDoctor-GUI.ps1 -Lang ar
#>

param(
    # Language the window opens in: 'en' (default) or 'ar'. The toggle button
    # still switches between the two at runtime.
    [ValidateSet('ar', 'en')]
    [string]$Lang = 'en'
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Drawing

# WPF needs an STA thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-PowerShellExe)
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

# Never rely on PATH for the PowerShell host. Some Windows 10/11 machines have
# a damaged PATH (or a policy that strips it), and then Get-Command powershell
# fails even though Windows PowerShell is installed. $PSHOME is the folder of
# the host that is already running this script, so it is always correct.
function Get-PowerShellExe {
    $candidates = @()
    try { if ($PSHOME) { $candidates += (Join-Path $PSHOME 'powershell.exe') } } catch {}
    try {
        if ($env:SystemRoot) {
            $candidates += (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        }
    } catch {}
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return 'powershell.exe'
}

# The tool repairs services and Program Files, so it must always run elevated.
# The shortcuts and Run-GUI.vbs already ask for elevation; this is the final
# guard for anyone who starts the .ps1 directly. If elevation is refused, the
# app exits instead of running with a misleading "Standard user" state.
try {
    $principal = New-Object System.Security.Principal.WindowsPrincipal ([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $scriptPath = $PSCommandPath
        if ($scriptPath -and (Test-Path -LiteralPath $scriptPath)) {
            $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $scriptPath + '"'
            if ($Lang -and $Lang -ne 'en') { $argLine += ' -Lang ' + $Lang }
            try {
                Start-Process -FilePath (Get-PowerShellExe) -ArgumentList $argLine -Verb RunAs -ErrorAction Stop
            } catch {}
            exit
        }
    }
} catch {}

# ===========================================================================
# Translations
# ===========================================================================
$L = @{
  ar = @{
    windowTitle   = 'UNLOCK DIGITAL - دكتور ترخيص أوتوديسك'
    brand         = 'UNLOCK DIGITAL'
    subtitle      = 'تشخيص وإصلاح مشاكل الترخيص'
    brandSmall    = 'دكتور ترخيص أوتوديسك'
    actions       = 'إجراءات سريعة'
    actionsHint   = 'ابدأ بالفحص'
    bDiag         = 'فحص الجهاز (تشخيص)'
    bDiagDesc     = 'فحص سريع بدون أي تعديل'
    bBackup       = 'نسخة احتياطية'
    bBackupDesc   = 'احفظ الحالة قبل أي تغيير'
    bClean        = 'تنظيف الجهاز'
    bCleanDesc    = 'إزالة بقايا النسخ غير الرسمية'
    bRepair       = 'إصلاح المكوّنات الرسمية'
    bRepairDesc   = 'إعادة تثبيت مكوّنات الترخيص'
    bUndo         = 'رجوع (Undo)'
    bUndoDesc     = 'الرجوع عن آخر تغيير'
    bReport       = 'فتح آخر تقرير'
    bReportShort  = 'تقرير'
    reportTip     = 'فتح آخر تقرير تشخيصي'
    bLang         = 'English'
    bPurge        = 'إزالة أوتوديسك بالكامل'
    dangerZone    = 'منطقة الخطر'
    removeDesc    = 'إزالة التطبيقات والترخيص والخدمات ومدخلات السجل وبقايا الكراك. يتم عمل نسخة احتياطية أولاً.'
    purgeTip      = 'يمسح كل منتجات ومكوّنات أوتوديسك من الجهاز (بنسخة احتياطية أولاً) — عشان تبدأ من الصفر بنسخة رسمية جديدة'
    purgeTitle    = 'إزالة أوتوديسك بالكامل'
    purgeText     = "هتشيل كل حاجة تخص أوتوديسك من الجهاز: البرامج، الترخيص، الخدمات، السجل، وبقايا الكراك.`n`nنعم = تنفيذ فعلي (بعد نسخة احتياطية)`nلا  = معاينة بس (بدون أي تغيير)"
    purgeWarn     = "تحذير أخير: الإزالة نهائية — بعدها هتحتاج تسطّب نسخة رسمية جديدة بنفسك.`n`nمتأكد؟"
    purgeApply    = 'إزالة أوتوديسك بالكامل (تنفيذ)'
    purgePreview  = 'إزالة أوتوديسك بالكامل (معاينة)'
    purgeMissing  = 'ملف الإزالة Purge.ps1 لسه مش موجود.'
    bUpdate       = 'تحديث'
    updateTip     = 'يفحص على آخر إصدار على GitHub وينزّله ويثبته لو فيه جديد'
    updateTitle   = 'تحديث الأداة'
    updateMissing = 'ملف التحديث (Update.ps1) لسه مش موجود في المجلد ده.'
    updateChecking    = 'بيفحص على آخر إصدار...'
    updateDownloading = 'بينزّل الإصدار الجديد...'
    updateUpToDate    = 'أنت على أحدث إصدار (v{0}).'
    updateAvailable   = "فيه إصدار جديد: v{0}`nعندك دلوقتي: v{1}`n`nتنزّل وتحدّث حالاً؟"
    updateReady       = 'تم تنزيل الإصدار v{0}. الأداة هتقفل وتفتح تاني لوحدها على الإصدار الجديد.'
    updateFailed      = "التحديث فشل:`n"
    updateOffline     = 'مش قادر يوصل لـ GitHub. اتأكد من الإنترنت وجرّب تاني.'
    updateUnavailable = 'تعذر الوصول لمصدر التحديث. اضبط update-config.json على رابط update.json، أو نزّل آخر إصدار يدويًا.'
    bBundle       = 'حزمة الدعم (تقرير + لوجات)'
    bBundleShort  = 'حزمة'
    bundleTip     = 'يعمل فحص ويجمع لوجات الترخيص مع التقرير في ملف ZIP واحد تبعته للدعم'
    tip           = 'نصيحة: ابدأ بـ «فحص الجهاز»، بعدين «نسخة احتياطية»، وبعدها «تنظيف» ثم «إصلاح». ولو منتج واقف على شاشة سيرفر الترخيص واشتراكك مستخدم واحد: استعمل «وضع الترخيص» وحوّله لـ«مستخدم واحد».'
    logTitle      = 'سجل العمليات'
    logLive       = 'مباشر'
    logTip        = 'الفحص لا يغيّر أي شيء. القرار في يدك.'
    copyLog       = 'نسخ'
    clearLog      = 'مسح'
    chipAdmin     = 'مسؤول'
    chipStandard  = 'مستخدم عادي'
    chipLocal     = 'محلي فقط'
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
    repairText    = "إصلاح/إعادة تسطيب مكوّنات الترخيص الرسمية؟`n`nلو فيه بقايا NLM قديمة بتمنع تسطيب AutoCAD 2027، هتتشال بعد نسخة احتياطية.`n`nنعم = تنفيذ فعلي`nلا  = معاينة بس"
    repairApply   = 'إصلاح المكوّنات (تنفيذ)'
    repairPreview = 'إصلاح المكوّنات (معاينة)'
    repairMissing = 'ملف الإصلاح Repair.ps1 لسه مش موجود.'
    repairAskDir  = "الفحص مش قادر يحدد المكوّنات الناقصة.`n`nعندك فولدر فيه المثبّتات الرسمية؟`nنعم = اختار الفولدر`nلا  = كمّل، والبرنامج هيقولك المصادر الرسمية"
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
    licModeTitle  = 'وضع الترخيص'
    licProductField = 'المنتج'
    licModeField  = 'الوضع'
    licApply      = 'تحويل نوع الترخيص'
    licRefresh    = 'تحديث القائمة'
    licMissing    = 'ملف LicenseMode.ps1 لسه مش موجود.'
    licMissingShort = 'LicenseMode.ps1 مش موجود'
    licNoHelper   = 'خدمة ترخيص أوتوديسك (ADLS) مش متسطّبة على الجهاز — سطّب منتج 2020 أو أحدث الأول.'
    licNoHelperShort = 'ADLS غير مثبت'
    licNoProducts = 'مفيش منتجات أوتوديسك (2020 أو أحدث) مسجّلة على الجهاز.'
    licNoProductsShort = 'لا توجد منتجات'
    licListFailed = 'تعذّر قراءة قائمة المنتجات من خدمة الترخيص.'
    licListFailedShort = 'فشل قراءة القائمة'
    licError      = 'حصل خطأ أثناء قراءة حالة الترخيص.'
    licErrorShort = 'فشل قراءة الحالة'
    licCurrent    = 'الحالي: {0}'
    licServersHint = 'سيرفرات الترخيص (مثال: 10.0.0.5 أو 27000@10.0.0.5,10.0.0.6) — لو سيبتها فاضية هيتحوّل الوضع بس'
    licConfirmIntro = 'هيتم تحويل نوع ترخيص المنتج ده:'
    licFrom       = 'من'
    licTo         = 'إلى'
    licServersLabel = 'السيرفرات'
    licSure       = 'متأكد؟'
    licNoServerAsk = "مفيش سيرفرات مكتوبة. تحويل الوضع من غير سيرفر؟`n`nنعم = كمّل`nلا = رجوع"
    licUser       = 'مستخدم واحد (تسجيل دخول)'
    licNetwork    = 'شبكة (سيرفر ترخيص NLM)'
    licStandalone = 'سيريال (Standalone)'
    licReset      = 'بدون وضع (Reset)'
    licMssa       = 'MSSA'
    licUnknown    = 'غير معروف'
    licAutodesk   = 'منتج أوتوديسك'
  }
  en = @{
    windowTitle   = 'UNLOCK DIGITAL - Autodesk Licensing Doctor'
    brand         = 'UNLOCK DIGITAL'
    subtitle      = 'Diagnose and fix licensing problems'
    brandSmall    = 'Autodesk Licensing Doctor'
    actions       = 'Quick actions'
    actionsHint   = 'Start with a scan'
    bDiag         = 'Scan this PC (diagnose)'
    bDiagDesc     = 'Read-only health check'
    bBackup       = 'Create backup'
    bBackupDesc   = 'Capture state before any change'
    bClean        = 'Clean this PC'
    bCleanDesc    = 'Remove non-genuine leftovers'
    bRepair       = 'Repair official components'
    bRepairDesc   = 'Reinstall the licensing stack'
    bUndo         = 'Roll back (Undo)'
    bUndoDesc     = 'Undo the last change'
    bReport       = 'Open last report'
    bReportShort  = 'Report'
    reportTip     = 'Open the last diagnostic report'
    bLang         = 'العربية'
    bPurge        = 'Remove Autodesk completely'
    dangerZone    = 'Danger zone'
    removeDesc    = 'Uninstalls apps, licensing, services, registry entries and crack leftovers. Backup first.'
    purgeTip      = 'Removes every Autodesk product and component from this PC (with a backup first) - start from zero with a fresh official copy'
    purgeTitle    = 'Remove Autodesk completely'
    purgeText     = "This removes everything Autodesk from this PC: products, licensing, services, registry and crack leftovers.`n`nYes = apply (a backup runs first)`nNo  = preview only (no changes)"
    purgeWarn     = "Final warning: the removal is permanent - afterwards you install a fresh official copy yourself.`n`nAre you sure?"
    purgeApply    = 'Remove Autodesk completely (apply)'
    purgePreview  = 'Remove Autodesk completely (preview)'
    purgeMissing  = 'Purge.ps1 is not present yet.'
    bUpdate       = 'Update'
    updateTip     = 'Checks GitHub for the latest published release and installs it in place when a newer one exists'
    updateTitle   = 'Tool update'
    updateMissing = 'Update.ps1 is not present in this folder yet.'
    updateChecking    = 'Checking for the latest version...'
    updateDownloading = 'Downloading the new version...'
    updateUpToDate    = 'You are on the latest version (v{0}).'
    updateAvailable   = "New version available: v{0}`nYou have: v{1}`n`nDownload and update now?"
    updateReady       = 'Version v{0} has been downloaded. The tool will close and reopen on the new version.'
    updateFailed      = "Update failed:`n"
    updateOffline     = 'Could not reach GitHub. Check the internet connection and try again.'
    updateUnavailable = 'Could not reach the update source. Point update-config.json at your update.json, or download the latest release manually.'
    bBundle       = 'Support bundle (report + logs)'
    bBundleShort  = 'Bundle'
    bundleTip     = 'Scan, then collect the licensing logs with the report into one zip to send to support'
    tip           = 'Tip: start with "Scan this PC", then "Create backup", then "Clean this PC" and finally "Repair". Stuck on the license-server screen with a sign-in subscription? Use "License mode" and switch the product back to "Single-user".'
    logTitle      = 'Activity log'
    logLive       = 'Live output'
    logTip        = 'No changes are made by scanning. You stay in control.'
    copyLog       = 'Copy'
    clearLog      = 'Clear'
    chipAdmin     = 'Administrator'
    chipStandard  = 'Standard user'
    chipLocal     = 'Local only'
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
    repairText    = "Repair / reinstall the official licensing components?`n`nStale NLM pointers that block AutoCAD 2027 setup are backed up and cleared first.`n`nYes = apply`nNo  = preview only"
    repairApply   = 'Repair components (apply)'
    repairPreview = 'Repair components (preview)'
    repairMissing = 'Repair.ps1 is not present yet.'
    repairAskDir  = "The component check could not determine what is missing.`n`nDo you have a folder with the official installers?`nYes = pick the folder`nNo  = continue, and the tool will show the official sources"
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
    licModeTitle  = 'License mode'
    licProductField = 'Product'
    licModeField  = 'Mode'
    licApply      = 'Switch license type'
    licRefresh    = 'Refresh list'
    licMissing    = 'LicenseMode.ps1 is not present yet.'
    licMissingShort = 'LicenseMode.ps1 missing'
    licNoHelper   = 'The Autodesk licensing service (ADLS) is not installed - install a 2020+ product first.'
    licNoHelperShort = 'ADLS missing'
    licNoProducts = 'No Autodesk products (2020 or newer) are registered on this PC.'
    licNoProductsShort = 'No products'
    licListFailed = 'Could not read the product list from the licensing service.'
    licListFailedShort = 'Read failed'
    licError      = 'Reading the license state failed.'
    licErrorShort = 'Read failed'
    licCurrent    = 'Current: {0}'
    licServersHint = 'License servers (e.g. 10.0.0.5 or 27000@10.0.0.5,10.0.0.6) - leave empty to switch the mode only'
    licConfirmIntro = 'About to switch the license type of:'
    licFrom       = 'From'
    licTo         = 'To'
    licServersLabel = 'Servers'
    licSure       = 'Are you sure?'
    licNoServerAsk = "No license servers typed. Switch the mode without a server?`n`nYes = continue`nNo = go back"
    licUser       = 'Single-user (sign-in)'
    licNetwork    = 'Network (NLM license server)'
    licStandalone = 'Standalone (serial)'
    licReset      = 'No mode (Reset)'
    licMssa       = 'MSSA'
    licUnknown    = 'unknown'
    licAutodesk   = 'Autodesk product'
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
        Title="UNLOCK DIGITAL" Height="760" Width="1120" MinHeight="560" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        Background="#070A10" FontFamily="Segoe UI" FlowDirection="RightToLeft"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <!-- Shared text styles -->
    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#C2CCDB"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7F8DA1"/>
      <Setter Property="FontSize" Value="10.5"/>
    </Style>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#748297"/>
      <Setter Property="FontSize" Value="9.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,7,0,4"/>
    </Style>

    <!-- Header and small toolbar buttons -->
    <Style x:Key="HeaderButton" TargetType="Button">
      <Setter Property="Background" Value="#171F2A"/>
      <Setter Property="BorderBrush" Value="#2A3647"/>
      <Setter Property="Foreground" Value="#DBE4F1"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="12"
                           Foreground="{TemplateBinding Foreground}" Margin="0,0,7,0" VerticalAlignment="Center"/>
                <ContentPresenter VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#202A37"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#36465A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#121923"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="UpdateButton" TargetType="Button" BasedOn="{StaticResource HeaderButton}">
      <Setter Property="Background" Value="#12231D"/>
      <Setter Property="BorderBrush" Value="#24523F"/>
      <Setter Property="Foreground" Value="#84E6BC"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource HeaderButton}">
      <Setter Property="Background" Value="#1D1318"/>
      <Setter Property="BorderBrush" Value="#4B222A"/>
      <Setter Property="Foreground" Value="#FFD9DD"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Margin" Value="0"/>
    </Style>
    <Style x:Key="LogToolButton" TargetType="Button" BasedOn="{StaticResource HeaderButton}">
      <Setter Property="Background" Value="#151D28"/>
      <Setter Property="BorderBrush" Value="#263243"/>
      <Setter Property="Foreground" Value="#93A3B8"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Padding" Value="7,0"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Margin" Value="0,0,5,0"/>
    </Style>
    <Style x:Key="SmallButton" TargetType="Button">
      <Setter Property="Background" Value="#171F2A"/>
      <Setter Property="BorderBrush" Value="#2A3647"/>
      <Setter Property="Foreground" Value="#DBE4F1"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#202A37"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#36465A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#121923"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Large action buttons -->
    <Style x:Key="ActionButton" TargetType="Button">
      <Setter Property="Background" Value="#161E29"/>
      <Setter Property="BorderBrush" Value="#243041"/>
      <Setter Property="Foreground" Value="#DFE7F2"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ContentTemplate" Value="{DynamicResource ActionTemplate}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1C2634"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#314054"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#131A24"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryActionButton" TargetType="Button">
      <Setter Property="Background" Value="#21131A"/>
      <Setter Property="BorderBrush" Value="#5B2530"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ContentTemplate" Value="{DynamicResource PrimaryActionTemplate}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A1720"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#74303C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1B0F14"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Action button content -->
    <DataTemplate x:Key="ActionTemplate">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Width="26" Height="26" Background="#1D2836" BorderBrush="#2A394C"
                BorderThickness="1" CornerRadius="6" Margin="0,0,9,0">
          <TextBlock Text="{Binding [Glyph]}" FontFamily="Segoe MDL2 Assets" FontSize="13"
                     Foreground="#9FB0C6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="{Binding [Title]}" FontSize="12" FontWeight="SemiBold" Foreground="#DFE7F2"
                     TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding [Desc]}" FontSize="10.5" Foreground="#7F8DA1"
                     TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        </StackPanel>
        <TextBlock Grid.Column="2" Text="&#x203A;" FontSize="18" Foreground="#59687C"
                   VerticalAlignment="Center" Margin="8,0,0,0"/>
      </Grid>
    </DataTemplate>
    <DataTemplate x:Key="PrimaryActionTemplate">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Width="26" Height="26" Background="#3A1A22" BorderBrush="#6B2A35"
                BorderThickness="1" CornerRadius="6" Margin="0,0,9,0">
          <TextBlock Text="{Binding [Glyph]}" FontFamily="Segoe MDL2 Assets" FontSize="13"
                     Foreground="#FF8A94" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="{Binding [Title]}" FontSize="12" FontWeight="SemiBold" Foreground="#FFFFFF"
                     TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding [Desc]}" FontSize="10.5" Foreground="#C8969C"
                     TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
        </StackPanel>
        <TextBlock Grid.Column="2" Text="&#x203A;" FontSize="18" Foreground="#FF7C88"
                   VerticalAlignment="Center" Margin="8,0,0,0"/>
      </Grid>
    </DataTemplate>

    <!-- Dark combo box -->
    <Style x:Key="DarkComboBoxItem" TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#D5DEEB"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#202B3A"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A1A20"/>
                <Setter Property="Foreground" Value="#FFD9DD"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkComboBox" TargetType="ComboBox">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#D5DEEB"/>
      <Setter Property="Background" Value="#151D28"/>
      <Setter Property="BorderBrush" Value="#273447"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,0"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource DarkComboBoxItem}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="28"/>
                  </Grid.ColumnDefinitions>
                  <ContentPresenter Grid.Column="0" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"
                                    HorizontalAlignment="Left"
                                    Content="{TemplateBinding SelectionBoxItem}"
                                    ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                    ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
                  <Path Grid.Column="1" Data="M 0 0 L 4 4 L 8 0" Stroke="#7D8CA1" StrokeThickness="1.4"
                        HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </Border>
              <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="240" Background="#151D28" BorderBrush="#2A3647" BorderThickness="1"
                        CornerRadius="6" Margin="0,4,0,0">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4B62"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DarkTextBox" TargetType="TextBox">
      <Setter Property="Height" Value="28"/>
      <Setter Property="Background" Value="#151D28"/>
      <Setter Property="BorderBrush" Value="#273447"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#D5DEEB"/>
      <Setter Property="CaretBrush" Value="#D5DEEB"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="9,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" VerticalScrollBarVisibility="{TemplateBinding VerticalScrollBarVisibility}"
                            HorizontalScrollBarVisibility="{TemplateBinding HorizontalScrollBarVisibility}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A4B62"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ChipBorder" TargetType="Border">
      <Setter Property="Background" Value="#131B25"/>
      <Setter Property="BorderBrush" Value="#243143"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>

    <!-- Slim dark scrollbar: the default Windows bar is far too bright on this surface. -->
    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Background="Transparent" BorderThickness="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb MinHeight="28">
                    <Thumb.Template>
                      <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border x:Name="ThumbBorder" Background="#3A4B62" CornerRadius="4" Margin="1,2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="ThumbBorder" Property="Background" Value="#4B5F7A"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="ThumbBorder" Property="Background" Value="#5A7190"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Background="Transparent" BorderThickness="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter Property="Height" Value="8"/>
                <Setter Property="MinHeight" Value="8"/>
                <Setter Property="Width" Value="Auto"/>
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- License-mode header: compact summary, click to reveal the controls. -->
    <Style x:Key="LicenseHeaderButton" TargetType="Button">
      <Setter Property="Background" Value="#0E141C"/>
      <Setter Property="BorderBrush" Value="#202B3A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Margin" Value="0,0,0,5"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#121923"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#2D3A4D"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#0B1017"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#10151D" BorderBrush="#1D2633" BorderThickness="0,0,0,1" Padding="22,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="5" Height="58" CornerRadius="3" Background="#E41E2E" Margin="0,0,14,0"/>
          <Border x:Name="LogoTile" Width="52" Height="52" Background="Transparent" CornerRadius="11" Margin="0,0,14,0"
                  FlowDirection="LeftToRight" Visibility="Collapsed">
            <Image x:Name="LogoImage" Width="52" Height="52" Stretch="Uniform"
                   RenderOptions.BitmapScalingMode="HighQuality"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="UNLOCK DIGITAL" Foreground="#95A1B3" FontSize="10" FontWeight="Bold" Margin="0,0,0,3"/>
            <TextBlock x:Name="BrandText" Text="UNLOCK DIGITAL" Foreground="#E8EDF5" FontSize="24" FontWeight="Bold"/>
            <TextBlock x:Name="SubTitle" Text="" Foreground="#8A96A9" FontSize="12" Margin="0,4,0,0"
                       TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#141C26" BorderBrush="#253141" BorderThickness="1" CornerRadius="12"
                  Padding="9,7" Margin="0,0,4,0">
            <StackPanel Orientation="Horizontal">
              <Ellipse Width="7" Height="7" Fill="#37D39B" Margin="0,0,7,0" VerticalAlignment="Center"/>
              <TextBlock Text="{Binding Text, ElementName=StatusText}" Foreground="#9FB0C4" FontSize="11.5"
                         FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="BtnUpdate" Style="{StaticResource UpdateButton}" Tag="&#xE895;" Content="Update"/>
          <Button x:Name="BtnLang" Style="{StaticResource HeaderButton}" Tag="&#xE8C1;" Content="العربية"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Body -->
    <Grid Grid.Row="1" Margin="16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="340"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Sidebar -->
      <Border Grid.Column="0" Background="#121923" BorderBrush="#222C3A" BorderThickness="1"
              CornerRadius="11" Padding="14" Margin="0,0,16,0">
        <DockPanel LastChildFill="True">
          <Border DockPanel.Dock="Bottom" Background="#1B1217" BorderBrush="#4B222A" BorderThickness="1"
                  CornerRadius="8" Padding="9" Margin="0,8,0,0">
            <StackPanel>
              <TextBlock x:Name="DangerLabelText" Text="DANGER ZONE" Foreground="#8C6670" FontSize="9"
                         FontWeight="Bold" Margin="0,0,0,4"/>
              <Button x:Name="BtnPurge" Style="{StaticResource DangerButton}" Tag="&#xE74D;"
                      Content="Remove Autodesk completely"/>
              <TextBlock x:Name="RemoveDesc" Text="Uninstalls apps, licensing, services, registry entries and crack leftovers. Backup first."
                         Foreground="#B58A91" FontSize="9" TextWrapping="Wrap" Margin="0,5,0,0"/>
            </StackPanel>
          </Border>

          <ScrollViewer VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" PanningMode="VerticalOnly" x:Name="SideScroll">
            <StackPanel>
              <StackPanel x:Name="ActionsPanel">
                <DockPanel Margin="0,0,0,8">
                  <TextBlock x:Name="ActionsHint" DockPanel.Dock="Right" Text="Start with a scan"
                             Style="{StaticResource MutedText}" VerticalAlignment="Bottom"/>
                  <TextBlock x:Name="ActionsLabel" Text="Quick actions" Style="{StaticResource SectionLabel}"/>
                </DockPanel>

                <Button x:Name="BtnDiag" Style="{StaticResource PrimaryActionButton}"/>
                <Button x:Name="BtnBackup" Style="{StaticResource ActionButton}"/>
                <Button x:Name="BtnClean" Style="{StaticResource ActionButton}"/>
                <Button x:Name="BtnRepair" Style="{StaticResource ActionButton}"/>
                <Button x:Name="BtnUndo" Style="{StaticResource ActionButton}"/>

                <Border Height="1" Background="#1A2330" Margin="0,6,0,8"/>
              </StackPanel>
              <Button x:Name="LicToggle" Style="{StaticResource LicenseHeaderButton}" ToolTip="License mode">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="LicModeLabel" Text="License mode" Style="{StaticResource SectionLabel}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="LicCurrent" Grid.Column="1" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"
                             Foreground="#9FB0C4" FontSize="10.5" Margin="8,0,8,0" MaxWidth="150" VerticalAlignment="Center"/>
                  <TextBlock x:Name="LicChevron" Grid.Column="2" Text="&#x2304;" Foreground="#7D8CA1" FontSize="12"
                             VerticalAlignment="Center"/>
                </Grid>
              </Button>

              <Border x:Name="LicCard" Background="#0E141C" BorderBrush="#202B3A" BorderThickness="1" CornerRadius="9"
                      Padding="10" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock x:Name="LicProductFieldLabel" Text="Product" Style="{StaticResource FieldLabel}"/>
                  <!-- An explicit ItemTemplate is required: with this custom
                       ComboBox ControlTemplate, DisplayMemberPath leaves
                       SelectionBoxItemTemplate empty and WPF falls back to
                       rendering the raw object (@{Product=; Display=...}). -->
                  <ComboBox x:Name="LicProductCombo" Style="{StaticResource DarkComboBox}">
                    <ComboBox.ItemTemplate>
                      <DataTemplate>
                        <TextBlock Text="{Binding Display}"/>
                      </DataTemplate>
                    </ComboBox.ItemTemplate>
                  </ComboBox>
                  <TextBlock x:Name="LicModeFieldLabel" Text="Mode" Style="{StaticResource FieldLabel}"/>
                  <ComboBox x:Name="LicModeCombo" Style="{StaticResource DarkComboBox}"/>
                  <TextBox x:Name="LicServersBox" Style="{StaticResource DarkTextBox}" Margin="0,6,0,4"
                           FlowDirection="LeftToRight" Visibility="Collapsed"/>
                  <TextBlock x:Name="LicServersHint" TextWrapping="Wrap" Foreground="#8A8F99" FontSize="10.5"
                             Margin="0,0,0,6" Visibility="Collapsed"/>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="LicApply" Grid.Column="0" Style="{StaticResource SmallButton}" Margin="0,0,6,0"/>
                    <Button x:Name="LicRefresh" Grid.Column="1" Style="{StaticResource SmallButton}"/>
                  </Grid>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <!-- Log panel -->
      <Border Grid.Column="1" Background="#0B1017" BorderBrush="#202B3A" BorderThickness="1" CornerRadius="11">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="48"/>
            <RowDefinition Height="36"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="38"/>
          </Grid.RowDefinitions>

          <Border Grid.Row="0" Background="#121923" BorderBrush="#202B3A" BorderThickness="0,0,0,1" Padding="15,0">
            <Grid>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Width="7" Height="7" Fill="#37D39B" Margin="0,0,9,0"/>
                <TextBlock x:Name="LogTitle" Text="Activity log" Foreground="#DBE4F1" FontSize="12" FontWeight="SemiBold"/>
                <TextBlock x:Name="LogLiveText" Text="Live output" Foreground="#67768A" FontSize="10" Margin="8,0,0,0"
                           VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="BtnReport" Style="{StaticResource LogToolButton}" Tag="&#xE8A5;" Content="Report"/>
                <Button x:Name="BtnBundle" Style="{StaticResource LogToolButton}" Tag="&#xE7B8;" Content="Bundle"/>
                <Button x:Name="BtnCopyLog" Style="{StaticResource LogToolButton}" Tag="&#xE8C8;" Content="Copy"/>
                <Button x:Name="BtnClearLog" Style="{StaticResource LogToolButton}" Tag="&#xE711;" Content="Clear"/>
              </StackPanel>
            </Grid>
          </Border>

          <Border Grid.Row="1" Background="#0E151E" BorderBrush="#18222E" BorderThickness="0,0,0,1" Padding="15,0">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Border Style="{StaticResource ChipBorder}">
                <StackPanel Orientation="Horizontal">
                  <Ellipse Width="5" Height="5" Fill="#37D39B" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock x:Name="ChipWindows" Text="Windows" Foreground="#8FDCB9" FontSize="9.5" FontWeight="SemiBold"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource ChipBorder}">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="ChipAdminDot" Width="5" Height="5" Fill="#37D39B" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock x:Name="ChipAdmin" Text="Administrator" Foreground="#8FDCB9" FontSize="9.5" FontWeight="SemiBold"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource ChipBorder}">
                <StackPanel Orientation="Horizontal">
                  <Ellipse Width="5" Height="5" Fill="#7AA7FF" Margin="0,0,6,0" VerticalAlignment="Center"/>
                  <TextBlock x:Name="ChipLocal" Text="Local only" Foreground="#9CAABD" FontSize="9.5" FontWeight="SemiBold"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <TextBox x:Name="TxtLog" Grid.Row="2" Background="Transparent" BorderThickness="0"
                   Foreground="#C3CEDD" FontFamily="Consolas" FontSize="12" Padding="15,12"
                   IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Disabled" FlowDirection="LeftToRight"/>

          <Border Grid.Row="3" Background="#0D141C" BorderBrush="#18222E" BorderThickness="0,1,0,0" Padding="15,7">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" Foreground="#7690B6" FontSize="12"
                         Margin="0,0,7,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="TipText" Grid.Column="1" Foreground="#6F7E92" FontSize="10" TextWrapping="Wrap"
                         VerticalAlignment="Center"/>
            </Grid>
          </Border>

          <Border Grid.Row="4" Background="#0E141C" BorderBrush="#19232F" BorderThickness="0,1,0,0" Padding="15,0">
            <Grid>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse Width="6" Height="6" Fill="#37D39B" Margin="0,0,7,0"/>
                <TextBlock x:Name="StatusText" Foreground="#94A3B6" FontSize="10" FontWeight="SemiBold"/>
              </StackPanel>
              <TextBlock Text="%ProgramData%\Autodesk\AdskLicensingService" Foreground="#526277"
                         FontFamily="Consolas" FontSize="9.5" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <!-- Footer -->
    <Border Grid.Row="2" Background="#0E141C" BorderBrush="#1B2532" BorderThickness="0,1,0,0" Padding="16,0" Height="32">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="CopyText" Text="© Unlock Digital - By Eng. Eslam Ashraf" Foreground="#617084"
                   FontSize="9.5" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <ProgressBar x:Name="Bar" Grid.Column="1" Width="150" Height="5" Foreground="#E41E2E"
                     Background="#1D2836" BorderThickness="0" VerticalAlignment="Center" Margin="12,0,18,0"/>
        <TextBlock Grid.Column="2" Text="Windows 10/11 · 64-bit" Foreground="#7E8DA2" FontSize="9.5"
                   VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [System.Windows.Markup.XamlReader]::Load($reader)

# Use the product mark in the title bar too, including when the GUI is run
# directly as a .ps1 during development (the compiled exe gets it embedded).
$iconPath = Join-Path $here 'AdskDoctor.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $ico = New-Object System.Drawing.Icon($iconPath, 32, 32)
        $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $ico.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $ico.Dispose()
    } catch { }
}

# The default height (690 DIP) is taller than the usable work area of a common
# laptop at 125-150% scaling, which pushes the bottom action bar off-screen.
# Clamp the window to the work area; the layout scrolls if it has to.
try {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.Height -gt $wa.Height) { $win.Height = [math]::Max($win.MinHeight, $wa.Height - 16) }
    if ($win.Width  -gt $wa.Width)  { $win.Width  = [math]::Max($win.MinWidth,  $wa.Width  - 16) }
} catch { }

$LogoImage  = $win.FindName('LogoImage')
$LogoTile   = $win.FindName('LogoTile')
$BrandText  = $win.FindName('BrandText')
$SubTitle   = $win.FindName('SubTitle')
$ActionsLabel = $win.FindName('ActionsLabel')
$ActionsHint  = $win.FindName('ActionsHint')
$ActionsPanel = $win.FindName('ActionsPanel')
$SideScroll  = $win.FindName('SideScroll')
$DangerLabelText = $win.FindName('DangerLabelText')
$RemoveDesc = $win.FindName('RemoveDesc')
$LogLiveText = $win.FindName('LogLiveText')
$ChipWindows = $win.FindName('ChipWindows')
$ChipAdmin   = $win.FindName('ChipAdmin')
$ChipAdminDot = $win.FindName('ChipAdminDot')
$ChipLocal   = $win.FindName('ChipLocal')
$TipText    = $win.FindName('TipText')
$TxtLog     = $win.FindName('TxtLog')
$StatusText = $win.FindName('StatusText')
$Bar        = $win.FindName('Bar')
$LogTitle   = $win.FindName('LogTitle')
$LicProductCombo = $win.FindName('LicProductCombo')
$LicModeCombo    = $win.FindName('LicModeCombo')
$LicCurrent      = $win.FindName('LicCurrent')
$LicModeLabel    = $win.FindName('LicModeLabel')
$LicToggle       = $win.FindName('LicToggle')
$LicCard         = $win.FindName('LicCard')
$LicChevron      = $win.FindName('LicChevron')
$LicProductFieldLabel = $win.FindName('LicProductFieldLabel')
$LicModeFieldLabel    = $win.FindName('LicModeFieldLabel')
$LicServersBox   = $win.FindName('LicServersBox')
$LicServersHint  = $win.FindName('LicServersHint')
$buttons    = @{}
foreach ($n in 'BtnDiag','BtnBackup','BtnClean','BtnRepair','BtnUndo','BtnPurge','BtnUpdate','BtnReport','BtnBundle','BtnLang','BtnCopyLog','BtnClearLog','LicApply','LicRefresh') {
    $buttons[$n] = $win.FindName($n)
}

# The version comes from the compiled exe, so a support request can name it.
# Running the .ps1 directly (development) has no version to report, so keep
# the release version instead of showing powershell.exe's Windows build.
$script:appVersion = '1.5.5'
try {
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    if ($proc.ProcessName -notin @('powershell', 'pwsh')) {
        $fvi = $proc.MainModule.FileVersionInfo
        if ($fvi -and $fvi.FileVersion) { $script:appVersion = $fvi.FileVersion }
    }
} catch {}

# Environment chips (always local, never guessed)
$osv = [System.Environment]::OSVersion.Version
$script:winNum = if ($osv.Build -ge 22000) { '11' } elseif ($osv.Major -ge 10) { '10' } else { '' }
$script:isAdmin = $false
try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    $script:isAdmin = $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
$brushConverter = New-Object System.Windows.Media.BrushConverter
$script:chipGreen = $brushConverter.ConvertFromString('#8FDCB9')
$script:chipAmber = $brushConverter.ConvertFromString('#E7C485')
$script:dotGreen  = $brushConverter.ConvertFromString('#37D39B')
$script:dotAmber  = $brushConverter.ConvertFromString('#F5B84B')

# logo
$script:hasLogo = $false
$logoPath = Join-Path $here 'adskdoctor-logo.png'
if (Test-Path -LiteralPath $logoPath) {
    try {
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.UriSource = New-Object System.Uri($logoPath); $img.CacheOption = 'OnLoad'; $img.EndInit()
        $LogoImage.Source = $img
        $LogoImage.Visibility = 'Visible'
        $LogoTile.Visibility = 'Visible'
        $script:hasLogo = $true
    } catch {}
}

# Each action button carries a small icon, a title and a one-line explanation.
# A hashtable is used so WPF can bind to the keys with Path=[Key].
function Set-ActionContent {
    param($Button, [string]$Glyph, [string]$Title, [string]$Description)
    $Button.Content = @{ Glyph = $Glyph; Title = $Title; Desc = $Description }
    $Button.ToolTip = $Description
    try {
        [System.Windows.Automation.AutomationProperties]::SetName($Button, $Title)
        [System.Windows.Automation.AutomationProperties]::SetHelpText($Button, $Description)
    } catch {}
}

# ---------------------------------------------------------------------------
# i18n apply
# ---------------------------------------------------------------------------
function Apply-Language {
    $win.Title = T 'windowTitle'
    $SubTitle.Text = (T 'subtitle') + '   ·  v' + $script:appVersion
    if ($script:hasLogo) { $BrandText.Text = (T 'brandSmall'); $BrandText.FontSize = 22 }
    else { $BrandText.Text = (T 'brand'); $BrandText.FontSize = 24 }
    $ActionsLabel.Text = T 'actions'
    $ActionsHint.Text = T 'actionsHint'
    Set-ActionContent $buttons['BtnDiag']   ([char]0xE721) (T 'bDiag')   (T 'bDiagDesc')
    Set-ActionContent $buttons['BtnBackup'] ([char]0xE896) (T 'bBackup') (T 'bBackupDesc')
    Set-ActionContent $buttons['BtnClean']  ([char]0xE74D) (T 'bClean')  (T 'bCleanDesc')
    Set-ActionContent $buttons['BtnRepair'] ([char]0xE90F) (T 'bRepair') (T 'bRepairDesc')
    Set-ActionContent $buttons['BtnUndo']   ([char]0xE7A7) (T 'bUndo')   (T 'bUndoDesc')
    $buttons['BtnReport'].Content = T 'bReportShort'
    $buttons['BtnReport'].ToolTip = T 'reportTip'
    $buttons['BtnBundle'].Content = T 'bBundleShort'
    $buttons['BtnBundle'].ToolTip = T 'bundleTip'
    $buttons['BtnCopyLog'].Content = T 'copyLog'
    $buttons['BtnClearLog'].Content = T 'clearLog'
    $buttons['BtnPurge'].Content = T 'bPurge'
    $buttons['BtnPurge'].ToolTip = T 'purgeTip'
    $buttons['BtnUpdate'].Content = T 'bUpdate'
    $buttons['BtnUpdate'].ToolTip = T 'updateTip'
    $buttons['BtnLang'].Content   = T 'bLang'
    $LicModeLabel.Text = T 'licModeTitle'
    $LicToggle.ToolTip = T 'licModeTitle'
    try { [System.Windows.Automation.AutomationProperties]::SetName($LicToggle, (T 'licModeTitle')) } catch {}
    $LicProductFieldLabel.Text = T 'licProductField'
    $LicModeFieldLabel.Text = T 'licModeField'
    $DangerLabelText.Text = T 'dangerZone'
    $RemoveDesc.Text = T 'removeDesc'
    $LogLiveText.Text = T 'logLive'
    $buttons['LicApply'].Content = T 'licApply'
    $buttons['LicRefresh'].Content = T 'licRefresh'
    $LicServersHint.Text = T 'licServersHint'
    $ChipWindows.Text = if ($script:lang -eq 'ar') { 'ويندوز ' + $script:winNum } else { 'Windows ' + $script:winNum }
    $ChipAdmin.Text = if ($script:isAdmin) { T 'chipAdmin' } else { T 'chipStandard' }
    $ChipLocal.Text = T 'chipLocal'
    $ChipAdmin.Foreground = if ($script:isAdmin) { $script:chipGreen } else { $script:chipAmber }
    $ChipAdminDot.Fill = if ($script:isAdmin) { $script:dotGreen } else { $script:dotAmber }
    Update-LicModeItems
    Update-LicProductItems
    $TipText.Text = T 'logTip'
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
$script:licScript = Join-Path $here 'LicenseMode.ps1'
$script:licProducts = @()
$script:licModeOrder = @('USER', 'NETWORK', 'STANDALONE', 'RESET')
$script:licUiUpdating = $false
$script:licMessageKey = ''
$script:licRefreshAfter = $false

function Add-Log {
    param([string]$Text)
    $TxtLog.AppendText($Text + "`r`n")
    $TxtLog.ScrollToEnd()
}
function Set-Busy {
    param([bool]$Busy)
    $script:busy = $Busy
    foreach ($b in $buttons.Values) { $b.IsEnabled = -not $Busy }
    $LicProductCombo.IsEnabled = -not $Busy
    $LicModeCombo.IsEnabled = -not $Busy
    $LicServersBox.IsEnabled = -not $Busy
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
    # A license-mode run reloads the panel even when it exited non-zero: the
    # helper may have applied the switch before the verification complained.
    if ($script:licRefreshAfter) {
        $script:licRefreshAfter = $false
        Load-LicProducts
    }
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
    $psi.FileName = (Get-PowerShellExe)
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
# License mode - lists the products the licensing service knows (through
# LicenseMode.ps1 -List -Json) and switches one product's license type
# (single-user / network / standalone / reset) through the same script.
# ---------------------------------------------------------------------------
function Get-MethodLabel {
    param([string]$Method)
    switch ($Method) {
        'USER'       { T 'licUser' }
        'NETWORK'    { T 'licNetwork' }
        'STANDALONE' { T 'licStandalone' }
        'MSSA'       { T 'licMssa' }
        default      { T 'licUnknown' }
    }
}
function Get-ModeChoiceLabel {
    param([string]$Mode)
    switch ($Mode) {
        'USER'       { T 'licUser' }
        'NETWORK'    { T 'licNetwork' }
        'STANDALONE' { T 'licStandalone' }
        'RESET'      { T 'licReset' }
        default      { $Mode }
    }
}
function Get-ProductDisplay {
    param($P)
    $name = if ($P.name) { $P.name } else { (T 'licAutodesk') + ' ' + $P.productKey }
    if ($P.year) { $name = $name + ' ' + $P.year }
    return ('{0}   ({1} / {2})' -f $name, $P.productKey, $P.productVersion)
}
function Get-SelectedLicMode {
    $i = $LicModeCombo.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:licModeOrder.Count) { return $script:licModeOrder[$i] }
    return ''
}
function Update-LicCurrent {
    if ($script:busy) { return }
    if ($script:licMessageKey) {
        $shortKey = switch ($script:licMessageKey) {
            'licMissing'    { 'licMissingShort' }
            'licNoHelper'   { 'licNoHelperShort' }
            'licNoProducts' { 'licNoProductsShort' }
            'licListFailed' { 'licListFailedShort' }
            default         { 'licErrorShort' }
        }
        $LicCurrent.Text = T $shortKey
        $LicCurrent.ToolTip = T $script:licMessageKey
        return
    }
    $it = $LicProductCombo.SelectedItem
    if (-not $it) { $LicCurrent.Text = ''; $LicCurrent.ToolTip = $null; return }
    $p = $it.Product
    $txt = (T 'licCurrent') -f (Get-MethodLabel $p.method)
    $srv = @($p.servers)
    if ($p.method -eq 'NETWORK' -and $srv.Count -gt 0) { $txt = $txt + '  ·  ' + ($srv -join ', ') }
    $LicCurrent.Text = $txt
    $LicCurrent.ToolTip = $txt
}
function Update-LicServersVisibility {
    $vis = if ((Get-SelectedLicMode) -eq 'NETWORK') { 'Visible' } else { 'Collapsed' }
    $LicServersBox.Visibility = $vis
    $LicServersHint.Visibility = $vis
}
function Update-LicModeItems {
    $script:licUiUpdating = $true
    try {
        $keep = Get-SelectedLicMode
        $LicModeCombo.Items.Clear()
        foreach ($m in $script:licModeOrder) { [void]$LicModeCombo.Items.Add((Get-ModeChoiceLabel $m)) }
        $idx = [array]::IndexOf($script:licModeOrder, $keep)
        if ($idx -lt 0) { $idx = 0 }
        if ($LicModeCombo.Items.Count -gt 0) { $LicModeCombo.SelectedIndex = $idx }
    } finally { $script:licUiUpdating = $false }
    Update-LicServersVisibility
}
function Update-LicProductItems {
    $script:licUiUpdating = $true
    try {
        $keep = ''
        if ($LicProductCombo.SelectedItem) { $keep = $LicProductCombo.SelectedItem.Product.productKey + '|' + $LicProductCombo.SelectedItem.Product.productVersion }
        $LicProductCombo.Items.Clear()
        foreach ($p in $script:licProducts) {
            [void]$LicProductCombo.Items.Add([pscustomobject]@{ Product = $p; Display = (Get-ProductDisplay $p) })
        }
        $idx = 0
        if ($keep) {
            for ($i = 0; $i -lt $LicProductCombo.Items.Count; $i++) {
                $it = $LicProductCombo.Items[$i]
                if (($it.Product.productKey + '|' + $it.Product.productVersion) -eq $keep) { $idx = $i; break }
            }
        }
        if ($LicProductCombo.Items.Count -gt 0) { $LicProductCombo.SelectedIndex = $idx }
    } finally { $script:licUiUpdating = $false }
    Update-LicCurrent
}
function Load-LicProducts {
    if (-not (Test-Path -LiteralPath $script:licScript)) {
        $script:licProducts = @()
        $script:licMessageKey = 'licMissing'
        Update-LicProductItems
        return
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-PowerShellExe)
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:licScript, '-List', '-Json') | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        $p.Start() | Out-Null
        $outT = $p.StandardOutput.ReadToEndAsync()
        $errT = $p.StandardError.ReadToEndAsync()
    } catch {
        $script:licProducts = @(); $script:licMessageKey = 'licError'; Update-LicProductItems; return
    }
    if (-not $p.WaitForExit(15000)) {
        try { $p.Kill() } catch { }
        $script:licProducts = @(); $script:licMessageKey = 'licError'; Update-LicProductItems; return
    }
    $txt = ($outT.Result + $errT.Result)
    $j = $null
    try { $j = ($txt.Trim() | ConvertFrom-Json) } catch { $j = $null }
    if ($null -eq $j -or -not $j.ok) {
        $code = ''
        if ($j) { $code = [string]$j.code }
        switch ($code) {
            'no-helper'   { $script:licMessageKey = 'licNoHelper' }
            'no-products' { $script:licMessageKey = 'licNoProducts' }
            'list-failed' { $script:licMessageKey = 'licListFailed' }
            default       { $script:licMessageKey = 'licError' }
        }
        $script:licProducts = @()
        Update-LicProductItems
        return
    }
    $script:licProducts = @($j.products)
    $script:licMessageKey = if ($script:licProducts.Count -eq 0) { 'licNoProducts' } else { '' }
    Update-LicProductItems
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

# License mode stays as a compact summary by default, so the sidebar does not
# need a permanent scrollbar on smaller screens. Expand it only when needed.
$LicToggle.Add_Click({
    if ($LicCard.Visibility -eq [System.Windows.Visibility]::Visible) {
        $LicCard.Visibility = [System.Windows.Visibility]::Collapsed
        $ActionsPanel.Visibility = [System.Windows.Visibility]::Visible
        $LicChevron.Text = [string][char]0x2304
    } else {
        $LicCard.Visibility = [System.Windows.Visibility]::Visible
        $ActionsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $LicChevron.Text = [string][char]0x2303
    }
    $SideScroll.ScrollToTop()
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

# Runs Repair.ps1 -CheckOnly and returns the missing components ('' = healthy,
# 'unknown' = the check itself failed). Synchronous and read-only: the repair
# flow uses it so a machine that has everything is never asked for installer
# files.
function Get-RepairCheck {
    param([string]$RepairPath)
    $oldNolog = $env:ADSKDOCTOR_NOLOG
    try {
        $env:ADSKDOCTOR_NOLOG = '1'
        $out = & (Get-PowerShellExe) -NoProfile -ExecutionPolicy Bypass -File $RepairPath -CheckOnly 2>&1
        $m = [regex]::Match(($out -join "`n"), 'CHECKRESULT missing=([^\r\n]*)')
        if (-not $m.Success) { return 'unknown' }
        return $m.Groups[1].Value.Trim()
    } catch { return 'unknown' }
    finally {
        if ($null -eq $oldNolog) { Remove-Item Env:ADSKDOCTOR_NOLOG -ErrorAction SilentlyContinue }
        else { $env:ADSKDOCTOR_NOLOG = $oldNolog }
    }
}

$buttons['BtnRepair'].Add_Click({
    $repair = Join-Path $here 'Repair.ps1'
    if (-not (Test-Path -LiteralPath $repair)) { [System.Windows.MessageBox]::Show((T 'repairMissing'),'UNLOCK DIGITAL') | Out-Null; return }
    $r = [System.Windows.MessageBox]::Show((T 'repairText'), (T 'repairTitle'), 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return }
    $repairArgs = @('-File', $repair)
    if ($r -eq 'Yes') { $repairArgs += '-Apply' }
    if ($r -eq 'Yes') {
        # Ask the repair itself what is missing first: a healthy machine is
        # never sent to a folder-picking dialogue, and pressing Repair is all
        # the confirmation the official auto-fetch needs.
        $missing = Get-RepairCheck -RepairPath $repair
        $auto    = @('ADLS','AdSSO','Identity','WebView2')
        $tokens  = @($missing -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $needAuto   = @($tokens | Where-Object { $auto -contains $_ })
        $needManual = @($tokens | Where-Object { $auto -notcontains $_ })
        if ($missing -eq '') {
            # everything is present - run straight away, no installer questions
        } elseif ($missing -ne 'unknown' -and $needManual.Count -eq 0) {
            # all known components can be fetched and signature-verified by
            # Repair itself (Autodesk CDN / Microsoft)
            $repairArgs += '-AllowDownload'
        } else {
            # the check could not answer (Genuine Service has no public
            # download and is not required for sign-in, so it never gets
            # here): offer the local installer folder, but still auto-fetch
            # the known components that are missing.
            $q = [System.Windows.MessageBox]::Show((T 'repairAskDir'), (T 'repairTitle'), 'YesNo', 'Question')
            if ($q -eq 'Yes') {
                $dir = Browse-Folder -Title (T 'pickFolderTitle')
                if ($dir) { $repairArgs += @('-InstallerDir', $dir) }
            }
            if ($missing -ne 'unknown' -and $needAuto.Count -gt 0) { $repairArgs += '-AllowDownload' }
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

$buttons['BtnCopyLog'].Add_Click({
    try {
        if ($TxtLog.SelectionLength -gt 0) { $TxtLog.Copy() }
        else { [System.Windows.Clipboard]::SetText($TxtLog.Text) }
    } catch { }
})

$buttons['BtnClearLog'].Add_Click({
    if ($script:busy) { [System.Windows.MessageBox]::Show((T 'busyMsg'), 'UNLOCK DIGITAL') | Out-Null; return }
    $TxtLog.Clear()
    $StatusText.Text = T 'statusReady'
})

# One file to send to support: the report + the licensing logs. The folder is
# opened afterwards so the zip is easy to find.
$buttons['BtnBundle'].Add_Click({
    Run-Task -Title (T 'bBundle') `
        -Arguments @('-File', (Join-Path $here 'AdskDoctor.ps1'), '-Html', '-Export', (Join-Path $here 'report.html'), '-Bundle') `
        -OpenAfter $here
})

# ---------------------------------------------------------------------------
# Update from GitHub (official releases only)
# ---------------------------------------------------------------------------
# Runs Update.ps1 -Check / -Download synchronously (the archive is tiny, so at
# most a few seconds) and reports through the status line + message boxes.
# Up to date -> a plain "you are on the latest version" note. Newer -> confirm,
# download, verify the SHA256, then hand over to the generated apply script: it
# waits for this process to exit, copies the staged files over this folder and
# reopens the app, so the window closes right after the hand-over.
function Get-UpdateResult {
    param([object[]]$Out)
    $line = ''
    foreach ($l in @($Out)) {
        $s = [string]$l
        if ($s -match '^UPDATERESULT ') { $line = $s.Trim(); break }
    }
    if (-not $line) { return $null }
    $body = $line.Substring('UPDATERESULT '.Length).Trim()
    $info = @{}

    # error= is free text and runs to the end of the line.
    $m = [regex]::Match($body, '(?:^|\s)error=(.*)$')
    if ($m.Success) {
        $info['error'] = $m.Groups[1].Value.Trim()
        $body = $body.Substring(0, $m.Index).Trim()
    }

    # staged / apply are paths and may contain spaces. They are followed by a
    # known key, so stop at the next key= rather than at the first space.
    foreach ($key in @('staged', 'apply')) {
        $m = [regex]::Match($body, '(?:^|\s)' + $key + '=(.*?)(?=\s+(?:current|latest|available|source|version|apply|staged|error)=|$)')
        if ($m.Success) {
            $info[$key] = $m.Groups[1].Value.Trim()
            $body = ($body.Substring(0, $m.Index) + ' ' + $body.Substring($m.Index + $m.Length)).Trim()
        }
    }

    foreach ($m in [regex]::Matches($body, '(\w+)=(\S+)')) {
        $info[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $info
}
function Get-UpdateCheck {
    param([string]$CurrentVersion)
    $upd = Join-Path $here 'Update.ps1'
    try {
        $out = & (Get-PowerShellExe) -NoProfile -ExecutionPolicy Bypass -File $upd -Check -CurrentVersion $CurrentVersion 2>&1
        return (Get-UpdateResult -Out $out)
    } catch { return $null }
}
function Set-UpdateStatus {
    param([string]$Text)
    $StatusText.Text = $Text
    # let WPF paint the line before the blocking network step starts
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{}) } catch {}
}
function Stop-UpdateUi {
    Set-Busy $false
    $StatusText.Text = (T 'statusReady')
}

$buttons['BtnUpdate'].Add_Click({
    if ($script:busy) { [System.Windows.MessageBox]::Show((T 'busyMsg'),'UNLOCK DIGITAL') | Out-Null; return }
    $upd = Join-Path $here 'Update.ps1'
    if (-not (Test-Path -LiteralPath $upd)) {
        [System.Windows.MessageBox]::Show((T 'updateMissing'), (T 'updateTitle')) | Out-Null
        return
    }
    Set-Busy $true
    try {
        Set-UpdateStatus (T 'updateChecking')
        $check = Get-UpdateCheck -CurrentVersion $script:appVersion
        if (-not $check -or $check['error']) {
            $why = ''
            if ($check -and $check['error']) { $why = $check['error'] }
            Stop-UpdateUi
            Add-Log ('>> ' + (T 'updateFailed') + $why)
            $shown = (T 'updateUnavailable')
            if ($why) { $shown += "`n`n" + $why }
            [System.Windows.MessageBox]::Show($shown, (T 'updateTitle')) | Out-Null
            return
        }
        if ($check['available'] -ne '1') {
            Stop-UpdateUi
            Add-Log ('>> ' + ((T 'updateUpToDate') -f $check['latest']))
            [System.Windows.MessageBox]::Show(((T 'updateUpToDate') -f $check['latest']), (T 'updateTitle')) | Out-Null
            return
        }
        $q = [System.Windows.MessageBox]::Show(((T 'updateAvailable') -f $check['latest'], $check['current']), (T 'updateTitle'), 'YesNo', 'Question')
        if ($q -ne 'Yes') { Stop-UpdateUi; return }
        Set-UpdateStatus (T 'updateDownloading')
        $out = & (Get-PowerShellExe) -NoProfile -ExecutionPolicy Bypass -File $upd -Download -CurrentVersion $script:appVersion 2>&1
        $res = Get-UpdateResult -Out $out
        if (-not $res -or -not $res['staged'] -or $res['error']) {
            $why = 'unknown'
            if ($res -and $res['error']) { $why = $res['error'] }
            Stop-UpdateUi
            Add-Log ('>> ' + (T 'updateFailed') + $why)
            [System.Windows.MessageBox]::Show(((T 'updateFailed') + $why), (T 'updateTitle')) | Out-Null
            return
        }
        # hand over to the detached apply script and close; the window stays
        # "busy" so nothing else can be clicked until it goes away
        Add-Log ('>> ' + ((T 'updateReady') -f $res['version']))
        [System.Windows.MessageBox]::Show(((T 'updateReady') -f $res['version']), (T 'updateTitle')) | Out-Null
        $applyArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $res['apply'],
                       '-WaitPid', $PID, '-StagingDir', $res['staged'], '-TargetDir', $here,
                       '-ExeName', 'UNLOCK-DIGITAL-AdskDoctor.exe') |
                     ForEach-Object { Quote-Arg ([string]$_) }
        Start-Process -FilePath (Get-PowerShellExe) -ArgumentList $applyArgs -WindowStyle Hidden
        $win.Close()
    } catch {
        Stop-UpdateUi
        Add-Log ('! ' + $_.Exception.Message)
        [System.Windows.MessageBox]::Show(((T 'updateFailed') + $_.Exception.Message), (T 'updateTitle')) | Out-Null
    }
})

# Full removal: deliberately separate from the repair flow. It does not fix
# anything - it removes every Autodesk trace so a fresh official copy can be
# installed afterwards. Preview sits next to the real run, and the real run
# asks a second, explicit confirmation.
$buttons['BtnPurge'].Add_Click({
    $purge = Join-Path $here 'Purge.ps1'
    if (-not (Test-Path -LiteralPath $purge)) { [System.Windows.MessageBox]::Show((T 'purgeMissing'),'UNLOCK DIGITAL') | Out-Null; return }
    $r = [System.Windows.MessageBox]::Show((T 'purgeText'), (T 'purgeTitle'), 'YesNoCancel', 'Warning')
    if ($r -eq 'Cancel') { return }
    if ($r -eq 'Yes') {
        $r2 = [System.Windows.MessageBox]::Show((T 'purgeWarn'), (T 'purgeTitle'), 'YesNo', 'Warning')
        if ($r2 -ne 'Yes') { return }
        Run-Task -Title (T 'purgeApply') -Arguments @('-File', $purge, '-Apply')
    } else {
        Run-Task -Title (T 'purgePreview') -Arguments @('-File', $purge)
    }
})

# ---------------------------------------------------------------------------
# License mode actions
# ---------------------------------------------------------------------------
$LicProductCombo.Add_SelectionChanged({ if (-not $script:licUiUpdating) { Update-LicCurrent } })
$LicModeCombo.Add_SelectionChanged({ if (-not $script:licUiUpdating) { Update-LicServersVisibility } })

$buttons['LicRefresh'].Add_Click({
    if ($script:busy) { return }
    Load-LicProducts
})

$buttons['LicApply'].Add_Click({
    if (-not (Test-Path -LiteralPath $script:licScript)) { [System.Windows.MessageBox]::Show((T 'licMissing'), 'UNLOCK DIGITAL') | Out-Null; return }
    $it = $LicProductCombo.SelectedItem
    if (-not $it) { [System.Windows.MessageBox]::Show((T 'licNoProducts'), 'UNLOCK DIGITAL') | Out-Null; return }
    $p = $it.Product
    $mode = Get-SelectedLicMode
    if (-not $mode) { return }

    # Network: optionally take license servers from the box. The spaces around
    # the commas are removed here; LicenseMode.ps1 normalizes the rest.
    $srv = ''
    if ($mode -eq 'NETWORK') {
        $srv = ($LicServersBox.Text -replace '\s*,\s*', ',').Trim()
        if (-not $srv) {
            $q = [System.Windows.MessageBox]::Show((T 'licNoServerAsk'), (T 'licModeTitle'), 'YesNo', 'Question')
            if ($q -ne 'Yes') { return }
        }
    }

    $lines = @(
        (T 'licConfirmIntro'),
        '  ' + $it.Display,
        '',
        '  ' + (T 'licFrom') + ': ' + (Get-MethodLabel $p.method),
        '  ' + (T 'licTo') + ': ' + (Get-ModeChoiceLabel $mode)
    )
    if ($srv) { $lines += '  ' + (T 'licServersLabel') + ': ' + $srv }
    $lines += ''
    $lines += (T 'licSure')
    $r = [System.Windows.MessageBox]::Show(($lines -join "`n"), (T 'licModeTitle'), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    $licArgs = @('-File', $script:licScript, '-ProductKey', $p.productKey, '-ProductVersion', $p.productVersion, '-LicenseType', $mode)
    if ($mode -eq 'NETWORK' -and $srv) { $licArgs += @('-LicServers', $srv) }
    $licArgs += '-Apply'
    $script:licRefreshAfter = $true
    Run-Task -Title ((T 'licModeTitle') + ': ' + (Get-ModeChoiceLabel $mode)) -Arguments $licArgs
})

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
Load-LicProducts
$win.ShowDialog() | Out-Null
