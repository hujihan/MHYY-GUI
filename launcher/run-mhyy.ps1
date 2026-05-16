param(
    [string]$ProjectRoot = "",
    [switch]$SkipWait,
    [string]$LogLevel = "INFO",
    [switch]$InstallOnly,
    [switch]$GetCookie
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function T {
    param([string]$Base64Text)
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64Text))
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
    $ProjectRoot = (Resolve-Path $ProjectRoot).Path
}

$VenvDir = Join-Path $ProjectRoot ".venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$RequirementsPath = Join-Path $ProjectRoot "requirements.txt"
$MainPath = Join-Path $ProjectRoot "main.py"
$GetCookiePath = Join-Path $ProjectRoot "get_cookies.py"
$ConfigPath = Join-Path $ProjectRoot "config.yml"
$MainExePath = Join-Path $ProjectRoot "MHYY.exe"
$GetCookieExePath = Join-Path $ProjectRoot "MHYY-GetCookies.exe"
$IsRelease = (Test-Path $MainExePath) -and (Test-Path $GetCookieExePath)

function Write-Step {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$stamp [$(T "5ZCv5Yqo5Zmo")] $Message"
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ($ErrorMessage + (T "6YCA5Ye656CB77ya") + $LASTEXITCODE)
    }
}

function Test-PythonCommand {
    param(
        [string]$FilePath,
        [string[]]$PrefixArgs = @()
    )

    try {
        & $FilePath @PrefixArgs -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Find-BasePython {
    foreach ($envPath in @($env:MHYY_PYTHON, $env:PYTHON)) {
        if (-not [string]::IsNullOrWhiteSpace($envPath)) {
            $resolved = $envPath.Trim('"')
            if ((Test-Path $resolved) -and (Test-PythonCommand -FilePath $resolved)) {
                return @{ FilePath = $resolved; PrefixArgs = @(); Name = $resolved }
            }
        }
    }

    $pythonCmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($pythonCmd -and (Test-PythonCommand -FilePath $pythonCmd.Source)) {
        return @{ FilePath = $pythonCmd.Source; PrefixArgs = @(); Name = "python" }
    }

    $pyCmd = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($pyCmd -and (Test-PythonCommand -FilePath $pyCmd.Source -PrefixArgs @("-3"))) {
        return @{ FilePath = $pyCmd.Source; PrefixArgs = @("-3"); Name = "py -3" }
    }

    return $null
}

function Try-InstallPythonWithWinget {
    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if (-not $winget) {
        return $false
    }

    Write-Step (T "5pyq5om+5YiwIFB5dGhvbiAzLjExK++8jOato+WcqOWwneivlemAmui/hyB3aW5nZXQg5a6J6KOFIFB5dGhvbiAzLjEx44CC")
    & $winget.Source install -e --id Python.Python.3.11 --scope user --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Step (T "d2luZ2V0IOacquiDveaIkOWKn+WujOaIkOWuieijheOAgg==")
        return $false
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "User") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    return $true
}

function Ensure-PythonEnvironment {
    if (Test-Path $VenvPython) {
        Write-Step ((T "5L2/55So5bey5pyJ6Jma5ouf546v5aKD77ya") + $VenvDir)
        return $VenvPython
    }

    $basePython = Find-BasePython
    if (-not $basePython) {
        [void](Try-InstallPythonWithWinget)
        $basePython = Find-BasePython
    }

    if (-not $basePython) {
        throw (T "6ZyA6KaBIFB5dGhvbiAzLjExIOaIluabtOmrmOeJiOacrO+8jOS9huW9k+WJjeacquaJvuWIsOOAguivt+WuieijhSBQeXRob24gMy4xMSsg5ZCO6YeN5paw6L+Q6KGM5ZCv5Yqo5Zmo44CC")
    }

    Write-Step ((T "5q2j5Zyo5L2/55SoIA==") + $basePython.Name + (T "IOWIm+W7uuiZmuaLn+eOr+Wig+OAgg=="))
    $venvArgs = @() + $basePython.PrefixArgs + @("-m", "venv", $VenvDir)
    Invoke-Checked -FilePath $basePython.FilePath -Arguments $venvArgs -ErrorMessage (T "5Yib5bu66Jma5ouf546v5aKD5aSx6LSl")

    if (-not (Test-Path $VenvPython)) {
        throw ((T "6Jma5ouf546v5aKD5bey5Yib5bu677yM5L2G5pyq5ZyoIA==") + $VenvPython + (T "IOaJvuWIsCBweXRob24uZXhl"))
    }

    return $VenvPython
}

function Ensure-Dependencies {
    param([string]$PythonPath)

    Write-Step (T "5q2j5Zyo5qOA5p+lIFB5dGhvbiDkvp3otZbljIXjgII=")
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $PythonPath -c "import httpx, yaml, sentry_sdk, cryptography" *> $null
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -eq 0) {
        Write-Step (T "5L6d6LWW5YyF5bey5bCx57uq44CC")
        return
    }

    if (-not (Test-Path $RequirementsPath)) {
        throw ((T "5pyq5om+5YiwIHJlcXVpcmVtZW50cy50eHTvvJo=") + $RequirementsPath)
    }

    Write-Step (T "5q2j5Zyo5qC55o2uIHJlcXVpcmVtZW50cy50eHQg5a6J6KOF5L6d6LWW5YyF44CC")
    Invoke-Checked -FilePath $PythonPath -Arguments @("-m", "pip", "install", "-r", $RequirementsPath) -ErrorMessage (T "5a6J6KOF5L6d6LWW5YyF5aSx6LSl")
}

if (-not $IsRelease) {
    if (-not (Test-Path $MainPath)) {
        throw ((T "5pyq5om+5YiwIG1haW4ucHnvvJo=") + $MainPath)
    }
}

Set-Location $ProjectRoot

if (-not $IsRelease) {
    $python = Ensure-PythonEnvironment
    Ensure-Dependencies -PythonPath $python
}

if ($InstallOnly) {
    Write-Step (T "6L+Q6KGM546v5aKD5bey5YeG5aSH5a6M5oiQ44CC")
    exit 0
}

if (-not (Test-Path $ConfigPath)) {
    Write-Step (T "Y29uZmlnLnltbCDlsJrkuI3lrZjlnKjvvIxHVUkg5Y+v5Lul6YCa6L+H56m655m95qih5p2/5Yib5bu644CC")
}

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$env:MHYY_LOGLEVEL = $LogLevel

if ($GetCookie) {
    if ($IsRelease) {
        Write-Step (T "5q2j5Zyo6L+Q6KGMIE1IWVktR2V0Q29va2llcy5leGXvvIzoh6rliqjojrflj5bphY3nva7kv6Hmga/jgII=")
        & $GetCookieExePath
        $exitCode = $LASTEXITCODE
        Write-Step ((T "TUhZWS1HZXRDb29raWVzLmV4ZSDlt7Lnu5PmnZ/vvIzpgIDlh7rnoIHvvJo=") + $exitCode + (T "44CC"))
        exit $exitCode
    }
    if (-not (Test-Path $GetCookiePath)) {
        throw ((T "5pyq5om+5YiwIGdldF9jb29raWVzLnB577ya") + $GetCookiePath)
    }
    Write-Step (T "5q2j5Zyo6L+Q6KGMIGdldF9jb29raWVzLnB577yM6Ieq5Yqo6I635Y+W6YWN572u5L+h5oGv44CC")
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    & $python $GetCookiePath
    $exitCode = $LASTEXITCODE
    Write-Step ((T "Z2V0X2Nvb2tpZXMucHkg5bey57uT5p2f77yM6YCA5Ye656CB77ya") + $exitCode + (T "44CC"))
    exit $exitCode
}

if ($SkipWait) {
    $env:MHYY_DEBUG = "True"
} else {
    Remove-Item Env:\MHYY_DEBUG -ErrorAction SilentlyContinue
}

if ($IsRelease) {
    Write-Step ((T "5q2j5Zyo6L+Q6KGMIE1IWVkuZXhl77yM5pel5b+X57qn5Yir77ya") + $LogLevel + (T "44CC"))
    & $MainExePath
    $exitCode = $LASTEXITCODE
    Write-Step ((T "TUhZWS5leGUg5bey57uT5p2f77yM6YCA5Ye656CB77ya") + $exitCode + (T "44CC"))
    exit $exitCode
}

Write-Step ((T "5q2j5Zyo6L+Q6KGMIG1haW4ucHnvvIzml6Xlv5fnuqfliKvvvJo=") + $LogLevel + (T "44CC"))
& $python $MainPath
$exitCode = $LASTEXITCODE
Write-Step ((T "bWFpbi5weSDlt7Lnu5PmnZ/vvIzpgIDlh7rnoIHvvJo=") + $exitCode + (T "44CC"))
exit $exitCode
