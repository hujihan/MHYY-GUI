$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:RunnerPath = Join-Path $PSScriptRoot "run-mhyy.ps1"
$script:ConfigPath = Join-Path $script:ProjectRoot "config.yml"
$script:LogDir = Join-Path $script:ProjectRoot "logs"
$script:CurrentProcess = $null
$script:CurrentStdout = $null
$script:CurrentStderr = $null
$script:Timer = $null
$script:SchedulerTimer = $null
$script:ScheduleEnabled = $false
$script:LastScheduledDate = ""

$ColorBg       = [System.Drawing.Color]::FromArgb(245, 247, 250)
$ColorPanel    = ([System.Drawing.Color]::White)
$ColorPrimary  = [System.Drawing.Color]::FromArgb(64, 158, 255)
$ColorSuccess  = [System.Drawing.Color]::FromArgb(103, 194, 58)
$ColorDanger   = [System.Drawing.Color]::FromArgb(245, 108, 108)
$ColorWarning  = [System.Drawing.Color]::FromArgb(230, 162, 60)
$ColorText     = [System.Drawing.Color]::FromArgb(48, 49, 51)
$ColorMuted    = [System.Drawing.Color]::FromArgb(144, 147, 153)
$ColorBorder   = [System.Drawing.Color]::FromArgb(228, 231, 237)
$ColorLogBg    = [System.Drawing.Color]::FromArgb(40, 42, 54)
$ColorLogFg    = [System.Drawing.Color]::FromArgb(200, 200, 210)

function Get-DefaultConfigText {
    $text = @'
# 使用前请阅读文档：https://bili33.top/posts/MHYY-AutoCheckin-Manual/
# 有问题请前往Github开启issue：https://github.com/GamerNoTitle/MHYY/issues

proxy: ''

notifications:
  serverchan:
    key: ''
  dingtalk:
    webhook_url: ''
  telegram:
    bot_token: ''
    chat_id: ''
  pushplus:
    key: ''

######## 以下为账号配置项，可以多账号，详情请参考文档 ########
accounts:
  # 第一个账号
  - token:
    type:
    sysver:
    deviceid:
    devicename:
    devicemodel:
    appid:
'@
    return $text
}

function Read-ConfigText {
    if (Test-Path $script:ConfigPath) {
        return [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
    }
    return Get-DefaultConfigText
}

function Save-ConfigText {
    param([string]$Text)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:ConfigPath, $Text, $utf8NoBom)
}

function Append-Log {
    param([string]$Text)
    $txtLog.AppendText($Text + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Set-RunningState {
    param([bool]$Running)
    $btnGetCookie.Enabled = -not $Running
    $btnRun.Enabled = -not $Running
    $btnInstall.Enabled = -not $Running
    $btnStop.Enabled = $Running
    $chkScheduleEnabled.Enabled = -not $Running
    if ($Running) {
        $lblStatus.Text = "● 运行中"
        $lblStatus.ForeColor = $ColorSuccess
    } else {
        $lblStatus.Text = "● 空闲"
        $lblStatus.ForeColor = $ColorMuted
    }
}

function Update-RunLog {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($script:CurrentStdout, $script:CurrentStderr)) {
        if ($path -and (Test-Path $path)) {
            try {
                $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    [void]$parts.Add($content.TrimEnd())
                }
            } catch { }
        }
    }
    $text = [string]::Join([Environment]::NewLine, $parts)
    if ($text.Length -gt 200000) {
        $text = $text.Substring($text.Length - 200000)
    }
    $txtLog.Text = $text
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    if ($script:CurrentProcess -and $script:CurrentProcess.HasExited) {
        $exitCode = $script:CurrentProcess.ExitCode
        $script:Timer.Stop()
        Append-Log ("任务已结束，退出码：" + $exitCode)
        Set-RunningState $false
        $script:CurrentProcess = $null
    }
}

function Start-LauncherProcess {
    param([bool]$InstallOnly)
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("已有任务正在运行，请等待结束或先停止。", "MHYY 启动器") | Out-Null
        return
    }
    Save-ConfigText $txtConfig.Text
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:CurrentStdout = Join-Path $script:LogDir "launcher-$stamp.out.log"
    $script:CurrentStderr = Join-Path $script:LogDir "launcher-$stamp.err.log"
    Set-Content -Path $script:CurrentStdout -Value "" -Encoding UTF8
    Set-Content -Path $script:CurrentStderr -Value "" -Encoding UTF8
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$script:RunnerPath`"",
        "-ProjectRoot", "`"$script:ProjectRoot`"",
        "-LogLevel", $cmbLogLevel.SelectedItem.ToString()
    )
    if ($chkSkipWait.Checked) { $args += "-SkipWait" }
    if ($InstallOnly) { $args += "-InstallOnly" }
    $txtLog.Clear()
    Append-Log "已保存 config.yml"
    Append-Log "正在启动任务..."
    $script:CurrentProcess = Start-Process -FilePath "powershell.exe" `
        -ArgumentList $args `
        -WorkingDirectory $script:ProjectRoot `
        -RedirectStandardOutput $script:CurrentStdout `
        -RedirectStandardError $script:CurrentStderr `
        -WindowStyle Hidden `
        -PassThru
    Set-RunningState $true
    $script:Timer.Start()
    if (-not $InstallOnly) {
        $script:LastScheduledDate = [System.DateTime]::UtcNow.AddHours(8).ToString("yyyyMMdd")
    }
}

# ==================== 窗口 ====================
$form = New-Object System.Windows.Forms.Form
$form.Text = "MHYY 云原神自动签到启动器"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1100, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 800)
$form.FormBorderStyle = "Sizable"
$form.BackColor = $ColorBg

$topBar = New-Object System.Windows.Forms.Panel
$topBar.Height = 52
$topBar.Dock = "Top"
$topBar.BackColor = $ColorPanel
$form.Controls.Add($topBar)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "MHYY 云原神自动签到"
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $ColorText
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(20, 12)
$topBar.Controls.Add($lblTitle)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "● 空闲"
$lblStatus.ForeColor = $ColorMuted
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(230, 17)
$topBar.Controls.Add($lblStatus)

$lblProject = New-Object System.Windows.Forms.Label
$lblProject.Text = "项目路径：" + $script:ProjectRoot
$lblProject.ForeColor = $ColorMuted
$lblProject.AutoSize = $true
$lblProject.Location = New-Object System.Drawing.Point(330, 17)
$topBar.Controls.Add($lblProject)

$sepTop = New-Object System.Windows.Forms.Panel
$sepTop.Height = 1
$sepTop.Dock = "Top"
$sepTop.BackColor = $ColorBorder
$form.Controls.Add($sepTop)

# ==================== 主体 ====================
$body = New-Object System.Windows.Forms.TableLayoutPanel
$body.Dock = "Fill"
$body.ColumnCount = 2
$body.RowCount = 1
$body.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 65))) | Out-Null
$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 35))) | Out-Null
$form.Controls.Add($body)

# ---- 左侧：配置编辑器 ----
$leftCard = New-Object System.Windows.Forms.Panel
$leftCard.Dock = "Fill"
$leftCard.BackColor = $ColorPanel
$leftCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$body.Controls.Add($leftCard, 0, 0)

$lblConfigTitle = New-Object System.Windows.Forms.Label
$lblConfigTitle.Text = "config.yml"
$lblConfigTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$lblConfigTitle.ForeColor = $ColorText
$lblConfigTitle.AutoSize = $true
$lblConfigTitle.Location = New-Object System.Drawing.Point(14, 10)
$leftCard.Controls.Add($lblConfigTitle)

$txtConfig = New-Object System.Windows.Forms.TextBox
$txtConfig.Multiline = $true
$txtConfig.AcceptsTab = $true
$txtConfig.ScrollBars = "Both"
$txtConfig.WordWrap = $false
$txtConfig.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtConfig.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 252)
$txtConfig.BorderStyle = "None"
$txtConfig.Location = New-Object System.Drawing.Point(14, 32)
$txtConfig.Width = 670
$txtConfig.Height = 560
$txtConfig.Anchor = "Top,Bottom,Left,Right"
$txtConfig.Text = Read-ConfigText
$leftCard.Controls.Add($txtConfig)

# ---- 右侧：操作面板 ----
$rightCard = New-Object System.Windows.Forms.Panel
$rightCard.Dock = "Fill"
$rightCard.BackColor = $ColorPanel
$rightCard.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$body.Controls.Add($rightCard, 1, 0)

$rightLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rightLayout.Dock = "Fill"
$rightLayout.ColumnCount = 1
$rightLayout.RowCount = 3
$rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 342))) | Out-Null
$rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 155))) | Out-Null
$rightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 220))) | Out-Null
$rightCard.Controls.Add($rightLayout)

# -- 按钮区 --
$btnPanel = New-Object System.Windows.Forms.TableLayoutPanel
$btnPanel.Dock = "Fill"
$btnPanel.ColumnCount = 1
$btnPanel.RowCount = 9
for ($i = 0; $i -lt 9; $i++) {
    $btnPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))) | Out-Null
}
$rightLayout.Controls.Add($btnPanel, 0, 0)

function New-MHYYButton {
    param([string]$Text, $Bg, $Fg, [bool]$Bold = $false)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Dock = "Fill"
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 1
    $btn.FlatAppearance.BorderColor = $ColorBorder
    $btn.BackColor = $Bg
    $btn.ForeColor = $Fg
    $btn.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    $btn.Cursor = "Hand"
    $btn.UseVisualStyleBackColor = $true
    if ($Bold) {
        $btn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    }
    return $btn
}

# Row 0
$btnSave = New-MHYYButton "保存配置" $ColorPanel $ColorText
$btnPanel.Controls.Add($btnSave, 0, 0)
# Row 1
$btnTemplate = New-MHYYButton "载入空白模板" $ColorPanel $ColorText
$btnPanel.Controls.Add($btnTemplate, 0, 1)
# Row 2
$btnOpenConfig = New-MHYYButton "用记事本打开" $ColorPanel $ColorText
$btnPanel.Controls.Add($btnOpenConfig, 0, 2)
# Row 3: section
$lblSection1 = New-Object System.Windows.Forms.Label
$lblSection1.Text = "  — 运行控制 —"
$lblSection1.Dock = "Fill"
$lblSection1.ForeColor = $ColorMuted
$lblSection1.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblSection1.TextAlign = "MiddleLeft"
$lblSection1.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$btnPanel.Controls.Add($lblSection1, 0, 3)
# Row 4
$btnInstall = New-MHYYButton "安装 / 修复运行环境" ([System.Drawing.Color]::FromArgb(245, 247, 250)) $ColorText
$btnPanel.Controls.Add($btnInstall, 0, 4)
# Row 5
$btnGetCookie = New-MHYYButton "一键获取 Cookie" $ColorPrimary ([System.Drawing.Color]::White) $true
$btnPanel.Controls.Add($btnGetCookie, 0, 5)
# Row 6
$btnRun = New-MHYYButton "一键运行" $ColorSuccess ([System.Drawing.Color]::White) $true
$btnPanel.Controls.Add($btnRun, 0, 6)
# Row 7
$btnStop = New-MHYYButton "停止任务" $ColorDanger ([System.Drawing.Color]::White)
$btnStop.Enabled = $false
$btnPanel.Controls.Add($btnStop, 0, 7)
# Row 8
$btnClearLog = New-MHYYButton "清除日志" $ColorPanel $ColorText
$btnPanel.Controls.Add($btnClearLog, 0, 8)

# -- 参数区 --
$paramPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$paramPanel.Dock = "Fill"
$paramPanel.FlowDirection = "TopDown"
$paramPanel.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$paramPanel.WrapContents = $false
$rightLayout.Controls.Add($paramPanel, 0, 1)

$paramRow1 = New-Object System.Windows.Forms.FlowLayoutPanel
$paramRow1.FlowDirection = "LeftToRight"
$paramRow1.Height = 24
$paramRow1.Width = 300
$paramPanel.Controls.Add($paramRow1)

$lblLevel = New-Object System.Windows.Forms.Label
$lblLevel.Text = "日志级别："
$lblLevel.AutoSize = $true
$lblLevel.ForeColor = $ColorText
$lblLevel.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
$paramRow1.Controls.Add($lblLevel)

$cmbLogLevel = New-Object System.Windows.Forms.ComboBox
$cmbLogLevel.DropDownStyle = "DropDownList"
$cmbLogLevel.Items.AddRange(@("INFO", "DEBUG", "WARNING", "ERROR"))
$cmbLogLevel.SelectedIndex = 0
$cmbLogLevel.Width = 90
$cmbLogLevel.FlatStyle = "Flat"
$paramRow1.Controls.Add($cmbLogLevel)

$paramRow2 = New-Object System.Windows.Forms.FlowLayoutPanel
$paramRow2.FlowDirection = "LeftToRight"
$paramRow2.Height = 24
$paramRow2.Width = 300
$paramPanel.Controls.Add($paramRow2)

$chkSkipWait = New-Object System.Windows.Forms.CheckBox
$chkSkipWait.Text = "跳过随机等待"
$chkSkipWait.Checked = $false
$chkSkipWait.AutoSize = $true
$chkSkipWait.ForeColor = $ColorText
$paramRow2.Controls.Add($chkSkipWait)

# -- 定时任务区 --
$lblSection2 = New-Object System.Windows.Forms.Label
$lblSection2.Text = "  — 定时运行 (UTC+8) —"
$lblSection2.AutoSize = $true
$lblSection2.ForeColor = $ColorMuted
$lblSection2.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblSection2.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$paramPanel.Controls.Add($lblSection2)

$paramRow4 = New-Object System.Windows.Forms.FlowLayoutPanel
$paramRow4.FlowDirection = "LeftToRight"
$paramRow4.Height = 24
$paramRow4.Width = 300
$paramPanel.Controls.Add($paramRow4)

$lblScheduleTime = New-Object System.Windows.Forms.Label
$lblScheduleTime.Text = "执行时间："
$lblScheduleTime.AutoSize = $true
$lblScheduleTime.ForeColor = $ColorText
$lblScheduleTime.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
$paramRow4.Controls.Add($lblScheduleTime)

$dtpScheduleTime = New-Object System.Windows.Forms.DateTimePicker
$dtpScheduleTime.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpScheduleTime.CustomFormat = "HH:mm"
$dtpScheduleTime.ShowUpDown = $true
$dtpScheduleTime.Width = 70
$dtpScheduleTime.Value = [System.DateTime]::Today.AddHours(8).AddMinutes(0)
$paramRow4.Controls.Add($dtpScheduleTime)

$paramRow5 = New-Object System.Windows.Forms.FlowLayoutPanel
$paramRow5.FlowDirection = "LeftToRight"
$paramRow5.Height = 24
$paramRow5.Width = 300
$paramPanel.Controls.Add($paramRow5)

$chkScheduleEnabled = New-Object System.Windows.Forms.CheckBox
$chkScheduleEnabled.Text = "启用定时运行"
$chkScheduleEnabled.Checked = $false
$chkScheduleEnabled.AutoSize = $true
$chkScheduleEnabled.ForeColor = $ColorText
$paramRow5.Controls.Add($chkScheduleEnabled)

$script:lblNextRun = New-Object System.Windows.Forms.Label
$script:lblNextRun.Text = "定时未启用"
$script:lblNextRun.AutoSize = $true
$script:lblNextRun.ForeColor = $ColorMuted
$script:lblNextRun.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$script:lblNextRun.Padding = New-Object System.Windows.Forms.Padding(4, 3, 0, 0)
$paramRow5.Controls.Add($script:lblNextRun)

$chkScheduleEnabled.Add_CheckedChanged({
    $script:ScheduleEnabled = $chkScheduleEnabled.Checked
    if ($script:ScheduleEnabled) {
        $script:SchedulerTimer.Start()
        $script:LastScheduledDate = ""
        $script:lblNextRun.Text = "等待到达 " + $dtpScheduleTime.Value.ToString("HH:mm") + " ..."
        $script:lblNextRun.ForeColor = $ColorSuccess
        Append-Log ("[定时] 已启用，执行时间 " + $dtpScheduleTime.Value.ToString("HH:mm"))
    } else {
        $script:SchedulerTimer.Stop()
        $script:lblNextRun.Text = "定时未启用"
        $script:lblNextRun.ForeColor = $ColorMuted
        Append-Log "[定时] 已停用"
    }
})


# -- 日志区 --
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = "Fill"
$rightLayout.Controls.Add($logPanel, 0, 2)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = "运行日志"
$lblLogTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$lblLogTitle.ForeColor = $ColorText
$lblLogTitle.AutoSize = $true
$lblLogTitle.Location = New-Object System.Drawing.Point(0, 0)
$logPanel.Controls.Add($lblLogTitle)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Both"
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$txtLog.BackColor = $ColorLogBg
$txtLog.ForeColor = $ColorLogFg
$txtLog.BorderStyle = "None"
$txtLog.Location = New-Object System.Drawing.Point(0, 22)
$txtLog.Width = 340
$txtLog.Height = 200
$txtLog.Anchor = "Top,Bottom,Left,Right"
$logPanel.Controls.Add($txtLog)

# ==================== 事件处理 ====================

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 700
$script:Timer.Add_Tick({ Update-RunLog })

$script:SchedulerTimer = New-Object System.Windows.Forms.Timer
$script:SchedulerTimer.Interval = 30000
$script:SchedulerTimer.Add_Tick({
    if (-not $script:ScheduleEnabled) { return }
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) { return }

    $now = [System.DateTime]::UtcNow.AddHours(8)
    $today = $now.ToString("yyyyMMdd")

    if ($today -eq $script:LastScheduledDate) { return }

    $target = $dtpScheduleTime.Value
    if ($now.Hour -eq $target.Hour -and $now.Minute -eq $target.Minute) {
        $script:LastScheduledDate = $today
        Append-Log ("[定时] " + $now.ToString("HH:mm") + " 触发定时运行")
        Start-LauncherProcess -InstallOnly $false
    }
})

$btnSave.Add_Click({
    try {
        Save-ConfigText $txtConfig.Text
        Append-Log "已保存 config.yml"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "保存失败") | Out-Null
    }
})

$btnTemplate.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show("要用空白模板覆盖当前编辑器内容吗？", "MHYY 启动器", "YesNo")
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        $txtConfig.Text = Get-DefaultConfigText
    }
})

$btnOpenConfig.Add_Click({
    try {
        Save-ConfigText $txtConfig.Text
        Start-Process -FilePath "notepad.exe" -ArgumentList "`"$script:ConfigPath`""
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "打开失败") | Out-Null
    }
})

$btnInstall.Add_Click({ Start-LauncherProcess -InstallOnly $true })
$btnRun.Add_Click({ Start-LauncherProcess -InstallOnly $false })
$btnClearLog.Add_Click({ $txtLog.Clear() })

$btnGetCookie.Add_Click({
    try {
        Save-ConfigText $txtConfig.Text
        Append-Log "已保存 config.yml"
        Append-Log "正在启动 Chrome 自动获取配置，请在浏览器打开后登录你的米哈游账号。"
        $args = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$script:RunnerPath`"",
            "-ProjectRoot", "`"$script:ProjectRoot`"",
            "-LogLevel", $cmbLogLevel.SelectedItem.ToString(),
            "-GetCookie"
        )
        $process = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $args `
            -WorkingDirectory $script:ProjectRoot `
            -WindowStyle Normal `
            -Wait `
            -PassThru
        Append-Log ("Chrome 自动配置已完成，退出码：" + $process.ExitCode)
        $txtConfig.Text = Read-ConfigText
        Append-Log "已重新加载 config.yml 编辑器内容。"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "获取Cookie失败") | Out-Null
    }
})

$btnStop.Add_Click({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        try {
            Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $script:CurrentProcess.Id, "/T", "/F") -WindowStyle Hidden -Wait
            Append-Log "已停止正在运行的任务。"
        } catch {
            Append-Log ("停止任务失败：" + $_.Exception.Message)
        }
        Set-RunningState $false
    }
})

$form.Add_FormClosing({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show("任务仍在运行。要停止任务并关闭窗口吗？", "MHYY 启动器", "YesNo")
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", $script:CurrentProcess.Id, "/T", "/F") -WindowStyle Hidden -Wait
            } catch { }
        } else {
            $_.Cancel = $true
        }
    }
})

Append-Log ("已加载项目：" + $script:ProjectRoot)
Append-Log "本界面会写入 config.yml，并运行原版 main.py。"

[void]$form.ShowDialog()
