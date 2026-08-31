# NavAlert environment check - Windows.
#
# Reports what is present, what is missing, and the exact command to fix each
# gap. Read-only: it installs nothing and changes nothing.
#
# Delegates the Android toolchain and JDK verdict to `flutter doctor`, which
# already resolves them correctly, and only adds the checks it does not make:
# the pinned Flutter version, the emulator binaries, whether an AVD exists, and
# hardware acceleration.
#
# Usage:  powershell -ExecutionPolicy Bypass -File doctor.ps1

$ErrorActionPreference = 'SilentlyContinue'

$PINNED_FLUTTER = '3.41.9'
$PINNED_JDK     = '17'
$DEFAULT_AVD    = 'Pixel_6'   # the name the run skill boots unless given another

$script:Missing = @()

function Report {
    param([string]$Status, [string]$Name, [string]$Detail, [string]$Fix)
    $mark = switch ($Status) {
        'ok'   { '[ OK ]' }
        'warn' { '[WARN]' }
        'fail' { '[FAIL]' }
    }
    $color = switch ($Status) {
        'ok'   { 'Green' }
        'warn' { 'Yellow' }
        'fail' { 'Red' }
    }
    Write-Host ("{0} {1,-22} {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
    if ($Status -ne 'ok' -and $Fix) { $script:Missing += ,@($Name, $Fix) }
}

Write-Host ''
Write-Host 'NavAlert environment check - Windows' -ForegroundColor Cyan
Write-Host '====================================='

# ---------- Flutter ----------
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Report 'fail' 'Flutter' 'not on PATH' `
        "Download Flutter $PINNED_FLUTTER (see SKILL.md - there is NO winget package for Flutter)"
} else {
    # Guard the match: with $ErrorActionPreference='SilentlyContinue' a failed
    # parse silently yields $null and the version then reports as blank, which
    # reads as "wrong version" on a machine that is actually fine.
    $m = flutter --version 2>&1 | Select-String -Pattern 'Flutter (\d+\.\d+\.\d+)' | Select-Object -First 1
    $v = if ($m) { $m.Matches.Groups[1].Value } else { '' }
    if (-not $v) {
        Report 'warn' 'Flutter' 'on PATH but version unreadable' `
            "Run 'flutter --version' by hand; project pins $PINNED_FLUTTER"
    } elseif ($v -eq $PINNED_FLUTTER) {
        Report 'ok' 'Flutter' "$v (pinned)" ''
    } else {
        Report 'warn' 'Flutter' "$v - project pins $PINNED_FLUTTER" `
            "Version drift rewrites pubspec.lock on every machine. See SKILL.md."
    }
}

# ---------- JDK ----------
# Deliberately JAVA_HOME, not `java -version`. The java on PATH is frequently a
# stale JRE 8 while Gradle uses JAVA_HOME - checking PATH reports a false
# failure on a machine that builds perfectly.
if (-not $env:JAVA_HOME) {
    Report 'fail' 'JDK (JAVA_HOME)' 'JAVA_HOME not set' `
        "winget install Microsoft.OpenJDK.$PINNED_JDK"
} else {
    $javaExe = Join-Path $env:JAVA_HOME 'bin\java.exe'
    if (-not (Test-Path $javaExe)) {
        Report 'fail' 'JDK (JAVA_HOME)' "JAVA_HOME points nowhere: $env:JAVA_HOME" `
            "winget install Microsoft.OpenJDK.$PINNED_JDK"
    } else {
        # Read the JDK's own `release` file rather than parsing `java -version`.
        # java prints its version to STDERR, and in PowerShell 5.1 redirecting a
        # native command's stderr wraps every line in an ErrorRecord - the string
        # match then silently yields nothing and the version reads as blank.
        $jv = ''
        $releaseFile = Join-Path $env:JAVA_HOME 'release'
        if (Test-Path $releaseFile) {
            $line = Select-String -Path $releaseFile -Pattern '^JAVA_VERSION="([^"]+)"'
            if ($line) { $jv = $line.Matches.Groups[1].Value }
        }
        if (-not $jv) { $jv = 'unknown' }
        if ($jv -match "^$PINNED_JDK\.") {
            Report 'ok' 'JDK (JAVA_HOME)' "$jv" ''
        } else {
            Report 'warn' 'JDK (JAVA_HOME)' "$jv - project expects $PINNED_JDK" `
                "winget install Microsoft.OpenJDK.$PINNED_JDK"
        }
    }
}

# ---------- Android SDK ----------
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

if (-not (Test-Path $sdk)) {
    Report 'fail' 'Android SDK' 'not found' `
        'winget install Google.AndroidStudio  (bundles SDK + emulator)'
} else {
    if ($env:ANDROID_HOME -or $env:ANDROID_SDK_ROOT) {
        Report 'ok' 'Android SDK' "$sdk" ''
    } else {
        # Flutter finds the SDK at the default path regardless, so this is
        # informational - not a failure on a working machine.
        Report 'ok' 'Android SDK' "$sdk (found by default path; ANDROID_HOME unset)" ''
    }

    foreach ($t in @(
        @('adb',        'platform-tools\adb.exe'),
        @('emulator',   'emulator\emulator.exe'),
        @('sdkmanager', 'cmdline-tools\latest\bin\sdkmanager.bat')
    )) {
        $name = $t[0]; $rel = $t[1]
        if (Test-Path (Join-Path $sdk $rel)) {
            Report 'ok' $name 'present' ''
        } else {
            Report 'fail' $name "missing ($rel)" `
                "Android Studio > SDK Manager > SDK Tools, install the matching component"
        }
    }

    # ---------- native build toolchain ----------
    # Flutter's plugins pull in a native build (ndkVersion is set in
    # app/build.gradle.kts). Neither ships with the command-line tools by
    # default, and their absence does not surface until a release build fails
    # minutes in with "[CXX1300] CMake '3.22.1' was not found", which reads as
    # a project fault rather than a missing SDK component.
    foreach ($c in @(
        @('CMake', 'cmake', "sdkmanager --install 'cmake;3.22.1'"),
        @('NDK',   'ndk',   'Android Studio > SDK Manager > SDK Tools > NDK (Side by side)')
    )) {
        $label = $c[0]; $dir = Join-Path $sdk $c[1]; $fix = $c[2]
        $found = @(Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) {
            Report 'ok' $label (($found | ForEach-Object { $_.Name }) -join ' ') ''
        } else {
            Report 'fail' $label 'not installed' $fix
        }
    }
}

# ---------- AVD ----------
# Report NAMES, not a count: the run skill boots an AVD *by name*, so a machine
# with one AVD under a different name passes a count check and then dies with
# "Unknown AVD name".
$avdDir = Join-Path $env:USERPROFILE '.android\avd'
$avds = @(Get-ChildItem -Path $avdDir -Filter '*.ini' -ErrorAction SilentlyContinue |
          ForEach-Object { $_.BaseName })
if ($avds.Count -eq 0) {
    Report 'fail' 'AVD' 'none defined' `
        "flutter emulators --create --name $DEFAULT_AVD"
} elseif ($avds -contains $DEFAULT_AVD) {
    Report 'ok' 'AVD' ($avds -join ' ') ''
} else {
    Report 'ok' 'AVD' (("{0} (skill default '{1}' absent - pass the name)" -f ($avds -join ' '), $DEFAULT_AVD)) ''
}

# ---------- Hardware acceleration ----------
# Ask the emulator itself. Get-WindowsOptionalFeature needs elevation and
# returns nothing without it, which reports "not detected" on a machine whose
# emulator is accelerated and running fine.
$emuExe = Join-Path $sdk 'emulator\emulator.exe'
if (Test-Path $emuExe) {
    $accel = (& $emuExe -accel-check) 2>$null | Out-String
    if ($accel -match 'is installed and usable') {
        $which = 'enabled'
        if ($accel -match '(WHPX|HAXM|AEHD|GVM)') { $which = "$($Matches[1]) usable" }
        Report 'ok' 'Emulator accel' $which ''
    } else {
        Report 'warn' 'Emulator accel' 'no hypervisor - emulator will be slow' `
            'Enable "Windows Hypervisor Platform" in Windows Features, then reboot'
    }
} else {
    Report 'warn' 'Emulator accel' 'cannot check - emulator binary missing' ''
}

# ---------- flutter doctor (authoritative on the toolchain) ----------
if ($flutter) {
    Write-Host ''
    Write-Host 'flutter doctor summary:' -ForegroundColor Cyan
    flutter doctor 2>&1 | Select-String -Pattern '^\[' | ForEach-Object { "  $_" }
}

# ---------- Result ----------
Write-Host ''
if ($script:Missing.Count -eq 0) {
    Write-Host 'Everything the project needs is present.' -ForegroundColor Green
    Write-Host 'Next: flutter pub get && flutter test    (expect 286 passing)'
    exit 0
}

Write-Host "$($script:Missing.Count) item(s) need attention:" -ForegroundColor Yellow
foreach ($m in $script:Missing) {
    Write-Host ("  - {0}" -f $m[0]) -ForegroundColor Yellow
    Write-Host ("      {0}" -f $m[1])
}
Write-Host ''
Write-Host 'Run /setup-navalert and Claude will walk these through with you.'
exit 1
