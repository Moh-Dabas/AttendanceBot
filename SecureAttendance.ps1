# ====================================================================================================
# SECURE ATTENDANCE EXPORT SYSTEM - FINAL VERSION WITH FIXED NON-ADMIN ACCESS
# ====================================================================================================

$ConfigUrl = "https://raw.githubusercontent.com/Moh-Dabas/AttendanceBot/refs/heads/main/config.enc"
$ErrorActionPreference = "SilentlyContinue"

# ====================================================================================================
# PART 1: CONFIGURATION & CONSTANTS
# ====================================================================================================

$passwordChunks = @("D@hua","!2025$","AttBot#","SecureKey")
$EMBEDDED_MASTER_PASSWORD = $passwordChunks -join ""
$passwordChunks = $null

$WORK_START_HOUR = 7
$WORK_END_HOUR = 19
$INVALID_BEFORE_HOUR = 5
$OVERTIME_START_HOUR = 19
$OVERTIME_START_MINUTE = 1
$OVERTIME_END_HOUR = 4
$OVERTIME_END_MINUTE = 0
$API_TIMEOUT = 60

$FIVE_AM_SECONDS = 18000
$SEVEN_AM_SECONDS = 25200
$SEVEN_PM_SECONDS = 68400

$global:config = $null
$global:devices = $null
$global:employees = $null
$global:employeeNameMap = @{}
$global:useRemoteConnection = $false
$global:fridayOff = $true
$global:saturdayOff = $true
$global:officialHoliday = $false
$global:holidayStart = $null
$global:holidayEnd = $null
$global:rawDeviceResponses = @()

# ====================================================================================================
# PART 2: HELPER FUNCTIONS
# ====================================================================================================

function Clean-Text {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return "" }
    $cleaned = $InputText
    $cleaned = $cleaned -replace "`r", "" -replace "`n", "" -replace "`t", ""
    $cleaned = $cleaned -replace "`0", "" -replace "`a", "" -replace "`b", ""
    $cleaned = $cleaned -replace "`f", "" -replace "`v", ""
    $cleaned = $cleaned -replace "[\u200B-\u200D\uFEFF]", ""
    $cleaned = $cleaned -replace "\u00A0", " "
    $cleaned = $cleaned -replace "\u2028", "" -replace "\u2029", ""
    $cleaned = $cleaned -replace "\u200E", "" -replace "\u200F", ""
    $cleaned = $cleaned -replace "\u061C", ""
    $cleaned = $cleaned -replace "\u2066", "" -replace "\u2067", ""
    $cleaned = $cleaned -replace "\u2068", "" -replace "\u2069", ""
    return $cleaned.Trim()
}

function Convert-UnixToDateTime {
    param([long]$UnixTime)
    try { return [DateTimeOffset]::FromUnixTimeSeconds($UnixTime).LocalDateTime }
    catch { return $null }
}

function Convert-TimeStringToHours {
    param([string]$TimeString)
    if ([string]::IsNullOrWhiteSpace($TimeString)) { return 0.0 }
    if ($TimeString -match '^(-)?(\d{1,2}):(\d{2})(?::(\d{2}))?$') {
        $isNegative = $matches[1] -eq "-"
        $hours = [int]$matches[2]
        $minutes = [int]$matches[3]
        $seconds = if ($matches[4]) { [int]$matches[4] } else { 0 }
        if ($minutes -ge 60 -or $seconds -ge 60) { return 0.0 }
        $totalHours = $hours + ($minutes / 60.0) + ($seconds / 3600.0)
        if ($isNegative) { $totalHours *= -1 }
        return [math]::Round($totalHours, 6)
    }
    return 0.0
}

function Convert-HoursToTimeString {
    param([double]$Hours)
    if ($Hours -eq 0) { return "00:00:00" }
    $sign = if ($Hours -lt 0) { "-" } else { "" }
    $totalSeconds = [math]::Round([math]::Abs($Hours) * 3600)
    $h = [math]::Floor($totalSeconds / 3600)
    $m = [math]::Floor(($totalSeconds % 3600) / 60)
    $s = $totalSeconds % 60
    return ("{0}{1:00}:{2:00}:{3:00}" -f $sign, $h, $m, $s)
}

function Convert-SecondsToTimeString {
    param([int64]$Seconds)
    if ($Seconds -eq 0) { return "00:00:00" }
    $sign = if ($Seconds -lt 0) { "-" } else { "" }
    $absSeconds = [math]::Abs($Seconds)
    $h = [math]::Floor($absSeconds / 3600)
    $m = [math]::Floor(($absSeconds % 3600) / 60)
    $s = $absSeconds % 60
    return ("{0}{1:00}:{2:00}:{3:00}" -f $sign, $h, $m, $s)
}

function Convert-DateTimeToTimeAMPM {
    param([object]$DateTimeValue)
    if ($null -eq $DateTimeValue) { return "" }
    if ($DateTimeValue -isnot [datetime]) { $DateTimeValue = Convert-UnixToDateTime $DateTimeValue }
    if ($null -eq $DateTimeValue) { return "" }
    return $DateTimeValue.ToString("h:mm:ss tt")
}

function Convert-DateTimeToTime24 {
    param([object]$DateTimeValue)
    if ($null -eq $DateTimeValue) { return "" }
    if ($DateTimeValue -isnot [datetime]) { $DateTimeValue = Convert-UnixToDateTime $DateTimeValue }
    if ($null -eq $DateTimeValue) { return "" }
    return $DateTimeValue.ToString("HH:mm:ss")
}

function Convert-HoursToSeconds {
    param([double]$Hours)
    return [int64]($Hours * 3600)
}

function IsInOvertimePeriod {
    param([DateTime]$time)
    $hour = $time.Hour
    $minute = $time.Minute
    if ($hour -gt $OVERTIME_START_HOUR) { return $true }
    if ($hour -lt $OVERTIME_END_HOUR) { return $true }
    if ($hour -eq $OVERTIME_START_HOUR -and $minute -ge $OVERTIME_START_MINUTE) { return $true }
    if ($hour -eq $OVERTIME_END_HOUR -and $minute -le $OVERTIME_END_MINUTE) { return $true }
    return $false
}

function Get-StatusWithInfo {
    param([string]$Status)
    $backgroundColor = 16777215
    $textColor = 0
    switch ($Status) {
        "Weekly Rest" { $backgroundColor = 8421504; $textColor = 16777215 }
        "Official Holiday" { $backgroundColor = 8421504; $textColor = 16777215 }
        "NOT COUNTED" { $backgroundColor = 8421504; $textColor = 16777215 }
        "ABSENT" { $backgroundColor = 5263440; $textColor = 16777215 }
        "Completed" { $backgroundColor = 5296274; $textColor = 16777215 }
        "Working" { $backgroundColor = 8900331; $textColor = 0 }
        "Incomplete" { $backgroundColor = 255; $textColor = 16777215 }
        default { $backgroundColor = 16777215; $textColor = 0 }
    }
    return @{ Text = $Status; BackgroundColor = $backgroundColor; TextColor = $textColor }
}

# ================================================================================================
# UNIFIED EXCEL CELL SETTING FUNCTIONS
# ================================================================================================

function Set-CellText {
    param($Cell, [string]$Value)
    $Cell.NumberFormat = "@"
    $Cell.Value2 = $Value
    $Cell.HorizontalAlignment = -4108
}

function Set-CellNumber {
    param($Cell, [double]$Value, [int]$DecimalPlaces = 0)
    if ($DecimalPlaces -eq 0) {
        $Cell.NumberFormat = "0"
    } else {
        $Cell.NumberFormat = "0." + ("0" * $DecimalPlaces)
    }
    $Cell.Value2 = $Value
    $Cell.HorizontalAlignment = -4108
}

function Set-CellCurrency {
    param($Cell, [double]$Value)
    $Cell.NumberFormat = "#,##0.00"
    $Cell.Value2 = $Value
    $Cell.HorizontalAlignment = -4108
}

function Set-CellDateTime {
    param($Cell, [DateTime]$DateValue, [string]$Format = "yyyy-mm-dd")
    $Cell.NumberFormat = "@"
    $excelDate = [double]$DateValue.Date.ToOADate()
    $Cell.Value2 = $excelDate
    $Cell.NumberFormat = $Format
    $Cell.HorizontalAlignment = -4108
}

function Set-CellTime {
    param($Cell, [string]$TimeString)
    if ([string]::IsNullOrWhiteSpace($TimeString)) {
        $Cell.Value2 = ""
        return
    }
    try {
        $time = [datetime]::ParseExact($TimeString, "HH:mm:ss", $null)
        $excelTime = [double]$time.TimeOfDay.TotalDays
        $Cell.NumberFormat = "General"
        $Cell.Value2 = $excelTime
        $Cell.NumberFormat = "hh:mm:ss"
        $Cell.HorizontalAlignment = -4108
    }
    catch {
        $Cell.NumberFormat = "@"
        $Cell.Value2 = $TimeString
    }
}

function Set-CellBoolean {
    param($Cell, [bool]$Value)
    $Cell.NumberFormat = "@"
    $Cell.Value2 = $Value
    $Cell.HorizontalAlignment = -4108
    if ($Value) {
        $Cell.Interior.Color = 5296274
        $Cell.Font.Color = 16777215
    } else {
        $Cell.Interior.Color = 255
        $Cell.Font.Color = 16777215
    }
}

function Set-CellStatus {
    param($Cell, [string]$Status, [int]$BackgroundColor, [int]$TextColor, [string]$Hyperlink = "")
    $Cell.NumberFormat = "@"
    $Cell.Value2 = $Status
    $Cell.Interior.Color = $BackgroundColor
    $Cell.Font.Color = $TextColor
    $Cell.Font.Bold = $true
    $Cell.HorizontalAlignment = -4108
    if ($Hyperlink -ne "") {
        $Cell.Worksheet.Hyperlinks.Add($Cell, "", $Hyperlink, "Go to day sheet", $Status) | Out-Null
        $Cell.Font.Color = $TextColor
        $Cell.Font.Bold = $true
    }
}

function Set-ExcelTitle {
    param($Worksheet, [int]$Row, [int]$Column, [string]$Text, [int]$FontSize = 14)
    $cell = $Worksheet.Cells.Item($Row, $Column)
    Set-CellText -Cell $cell -Value $Text
    $cell.Font.Bold = $true
    $cell.Font.Color = 0
    $cell.Font.Size = $FontSize
    $cell.Interior.Color = 15773696
    $cell.VerticalAlignment = -4108
}

function Set-ExcelHeader {
    param($Worksheet, [int]$Row, [int]$Column, [string]$Text)
    $cell = $Worksheet.Cells.Item($Row, $Column)
    Set-CellText -Cell $cell -Value $Text
    $cell.Font.Bold = $true
    $cell.Font.Color = 0
    $cell.Interior.Color = 15773696
    $cell.VerticalAlignment = -4108
}

function Set-ExcelLabel {
    param($Worksheet, [int]$Row, [int]$Column, [string]$Text, [bool]$FontBold = $false)
    $cell = $Worksheet.Cells.Item($Row, $Column)
    Set-CellText -Cell $cell -Value $Text
    $cell.Font.Bold = $FontBold
}

$global:progressForm = $null
$global:progressBar = $null
$global:progressLabel = $null
$global:statusLabel = $null

function Show-ProgressDialog {
    param([string]$Title, [string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $global:progressForm = New-Object System.Windows.Forms.Form
    $global:progressForm.Text = $Title
    $global:progressForm.Size = New-Object System.Drawing.Size(450, 200)
    $global:progressForm.StartPosition = "CenterScreen"
    $global:progressForm.FormBorderStyle = "FixedDialog"
    $global:progressForm.MaximizeBox = $false
    $global:progressForm.MinimizeBox = $false
    $global:progressForm.ControlBox = $false
    $global:progressForm.BackColor = [System.Drawing.Color]::White
    $global:progressForm.TopMost = $true
    $titlePanel = New-Object System.Windows.Forms.Panel
    $titlePanel.Location = New-Object System.Drawing.Point(0, 0)
    $titlePanel.Size = New-Object System.Drawing.Size(450, 50)
    $titlePanel.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $global:progressForm.Controls.Add($titlePanel)
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Location = New-Object System.Drawing.Point(20, 10)
    $titleLabel.Size = New-Object System.Drawing.Size(410, 30)
    $titleLabel.TextAlign = "MiddleLeft"
    $titlePanel.Controls.Add($titleLabel)
    $global:statusLabel = New-Object System.Windows.Forms.Label
    $global:statusLabel.Text = $Message
    $global:statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $global:statusLabel.Location = New-Object System.Drawing.Point(30, 70)
    $global:statusLabel.Size = New-Object System.Drawing.Size(390, 25)
    $global:progressForm.Controls.Add($global:statusLabel)
    $global:progressBar = New-Object System.Windows.Forms.ProgressBar
    $global:progressBar.Location = New-Object System.Drawing.Point(30, 105)
    $global:progressBar.Size = New-Object System.Drawing.Size(390, 30)
    $global:progressBar.Style = "Marquee"
    $global:progressBar.MarqueeAnimationSpeed = 20
    $global:progressForm.Controls.Add($global:progressBar)
    $global:progressLabel = New-Object System.Windows.Forms.Label
    $global:progressLabel.Text = "Please wait..."
    $global:progressLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $global:progressLabel.ForeColor = [System.Drawing.Color]::Gray
    $global:progressLabel.Location = New-Object System.Drawing.Point(30, 145)
    $global:progressLabel.Size = New-Object System.Drawing.Size(390, 20)
    $global:progressForm.Controls.Add($global:progressLabel)
    $global:progressForm.Show()
    $global:progressForm.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-ProgressDialog {
    param([string]$StatusText, [string]$DetailText)
    if ($global:progressForm -and -not $global:progressForm.IsDisposed) {
        if ($StatusText) { $global:statusLabel.Text = $StatusText }
        if ($DetailText) { $global:progressLabel.Text = $DetailText }
        $global:progressForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Close-ProgressDialog {
    if ($global:progressForm -and -not $global:progressForm.IsDisposed) {
        $global:progressForm.Close()
        $global:progressForm.Dispose()
        $global:progressForm = $null
    }
}

function ShowErrorMessage {
    param([string]$Title, [string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, "OK", [System.Windows.Forms.MessageBoxIcon]::Error)
}

function Decrypt-Data {
    param([string]$EncryptedBase64, [string]$Password)
    try {
        $fullData = [Convert]::FromBase64String($EncryptedBase64)
        $salt = $fullData[0..31]
        $iv = $fullData[32..47]
        $encryptedData = $fullData[48..$fullData.Length]
        $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 10000, "SHA256")
        $key = $deriveBytes.GetBytes(32)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $decryptor = $aes.CreateDecryptor($key, $iv)
        $decrypted = $decryptor.TransformFinalBlock($encryptedData, 0, $encryptedData.Length)
        return $decrypted
    }
    catch { return $null }
}

function Download-And-Decrypt-Config {
    param([string]$Url)
    try {
        Update-ProgressDialog -StatusText "Downloading configuration..." -DetailText "Connecting to server..."
        $encryptedContent = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30 -UseBasicParsing
        Update-ProgressDialog -StatusText "Decrypting configuration..." -DetailText "Processing security keys..."
        $decryptedBytes = Decrypt-Data -EncryptedBase64 $encryptedContent -Password $EMBEDDED_MASTER_PASSWORD
        if ($decryptedBytes -eq $null) { return $null }
        $json = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        $config = $json | ConvertFrom-Json
        return $config
    }
    catch { return $null }
}

# ====================================================================================================
# PART 3: AUTHENTICATION & LOGIN (FIXED FOR CASE-INSENSITIVE MATCHING)
# ====================================================================================================

function Exit-Application {
    [System.Windows.Forms.Application]::Exit()
    Stop-Process -Id $pid -Force
}

function AuthenticateUser {
    param([string]$UserName, [string]$Password)
    
    $cleanUserName = Clean-Text -InputText $UserName
    $cleanPassword = Clean-Text -InputText $Password
    
    $users = @{}
    
    # First pass: collect all employee names exactly as they appear
    foreach ($emp in $global:employees) {
        $empName = Clean-Text -InputText $emp.Name
        $empPassword = Clean-Text -InputText $emp.Password
        $hours = Convert-TimeStringToHours -TimeString $emp.RequiredHours
        
        # Store old name mappings (case-insensitive)
        $oldNames = @()
        if ($emp.OldName -and $emp.OldName -ne "") { $oldNames += Clean-Text -InputText $emp.OldName }
        if ($emp.OldName1 -and $emp.OldName1 -ne "") { $oldNames += Clean-Text -InputText $emp.OldName1 }
        if ($emp.OldName2 -and $emp.OldName2 -ne "") { $oldNames += Clean-Text -InputText $emp.OldName2 }
        if ($emp.OldName3 -and $emp.OldName3 -ne "") { $oldNames += Clean-Text -InputText $emp.OldName3 }
        
        foreach ($oldName in $oldNames) {
            if ($oldName -and $oldName -ne "") {
                $global:employeeNameMap[$oldName.ToLower()] = $empName
            }
        }
        
        # Store user info with original name as key
        $users[$empName] = @{
            Password = $empPassword
            RequiredHours = $hours
            IsNotCounted = ($hours -eq 0)
            OriginalName = $empName
        }
    }
    
    # Admin login (case-insensitive)
    if ($cleanUserName.ToLower() -eq "admin") {
        # Find admin user
        $adminUser = $null
        $adminName = $null
        foreach ($key in $users.Keys) {
            if ($key.ToLower() -eq "admin") {
                $adminUser = $users[$key]
                $adminName = $key
                break
            }
        }
        
        # If no user named "admin", check if any user has password that matches admin login
        if (-not $adminUser) {
            foreach ($key in $users.Keys) {
                if ($users[$key].Password -eq $cleanPassword) {
                    $adminUser = $users[$key]
                    $adminName = $key
                    break
                }
            }
        }
        
        if ($adminUser -and $adminUser.Password -eq $cleanPassword) {
            $targetList = @()
            $requiredMap = @{}
            foreach ($key in $users.Keys) {
                if ($key.ToLower() -ne "admin" -and $key -ne $adminName) {
                    $targetList += $key
                    $requiredMap[$key] = $users[$key]
                }
            }
            return @{
                IsAdmin = $true
                TargetEmployees = $targetList
                RequiredHoursMap = $requiredMap
            }
        }
        return $null
    }
    
    # Regular user login - find matching employee (case-insensitive)
    $matchedKey = $null
    foreach ($key in $users.Keys) {
        if ($key.ToLower() -eq $cleanUserName.ToLower()) {
            $matchedKey = $key
            break
        }
    }
    
    if ($matchedKey -and $users[$matchedKey].Password -eq $cleanPassword) {
        $requiredMap = @{}
        $requiredMap[$matchedKey] = $users[$matchedKey]
        return @{
            IsAdmin = $false
            TargetEmployees = @($matchedKey)
            RequiredHoursMap = $requiredMap
        }
    }
    
    return $null
}

function Show-LoginDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    $registryPath = "HKCU:\Software\AttendanceSystem"
    $usernameKey = "SavedUsername"
    $passwordKey = "SavedPassword"
    $rememberKey = "RememberMeState"
    $remoteKey = "RemoteConnectionState"
    
    $savedUsername = ""
    $savedPassword = ""
    $rememberMe = $false
    $remoteChecked = $false
    
    if (Test-Path $registryPath) {
        try {
            $rawUsername = (Get-ItemProperty -Path $registryPath -Name $usernameKey -ErrorAction SilentlyContinue).$usernameKey
            $rawPassword = (Get-ItemProperty -Path $registryPath -Name $passwordKey -ErrorAction SilentlyContinue).$passwordKey
            $rememberMe = [bool]((Get-ItemProperty -Path $registryPath -Name $rememberKey -ErrorAction SilentlyContinue).$rememberKey)
            $remoteChecked = [bool]((Get-ItemProperty -Path $registryPath -Name $remoteKey -ErrorAction SilentlyContinue).$remoteKey)
            $savedUsername = Clean-Text -InputText $rawUsername
            $savedPassword = Clean-Text -InputText $rawPassword
        }
        catch { }
    }
    
    $global:useRemoteConnection = $remoteChecked
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Attendance Export - Login"
    $form.Size = New-Object System.Drawing.Size(500, 470)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $form.TopMost = $true
    
    $titlePanel = New-Object System.Windows.Forms.Panel
    $titlePanel.Location = New-Object System.Drawing.Point(0, 0)
    $titlePanel.Size = New-Object System.Drawing.Size(500, 85)
    $titlePanel.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $form.Controls.Add($titlePanel)
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "ATTENDANCE SYSTEM"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Location = New-Object System.Drawing.Point(50, 22)
    $titleLabel.Size = New-Object System.Drawing.Size(400, 45)
    $titleLabel.TextAlign = "MiddleCenter"
    $titlePanel.Controls.Add($titleLabel)
    
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = "Please enter your credentials"
    $subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
    $subtitleLabel.ForeColor = [System.Drawing.Color]::LightGray
    $subtitleLabel.Location = New-Object System.Drawing.Point(50, 55)
    $subtitleLabel.Size = New-Object System.Drawing.Size(400, 25)
    $subtitleLabel.TextAlign = "MiddleCenter"
    $titlePanel.Controls.Add($subtitleLabel)
    
    $userLabel = New-Object System.Windows.Forms.Label
    $userLabel.Text = "Username:"
    $userLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $userLabel.Location = New-Object System.Drawing.Point(60, 115)
    $userLabel.Size = New-Object System.Drawing.Size(120, 30)
    $form.Controls.Add($userLabel)
    
    $userTextBox = New-Object System.Windows.Forms.TextBox
    $userTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $userTextBox.Location = New-Object System.Drawing.Point(190, 112)
    $userTextBox.Size = New-Object System.Drawing.Size(250, 35)
    $userTextBox.Text = $savedUsername
    $userTextBox.Add_TextChanged({
        $current = $userTextBox.Text
        $cleaned = Clean-Text -InputText $current
        if ($current -ne $cleaned) {
            $pos = $userTextBox.SelectionStart
            $userTextBox.Text = $cleaned
            $userTextBox.SelectionStart = [Math]::Min($pos, $cleaned.Length)
        }
    })
    $form.Controls.Add($userTextBox)
    
    $passLabel = New-Object System.Windows.Forms.Label
    $passLabel.Text = "Password:"
    $passLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $passLabel.Location = New-Object System.Drawing.Point(60, 165)
    $passLabel.Size = New-Object System.Drawing.Size(120, 30)
    $form.Controls.Add($passLabel)
    
    $passTextBox = New-Object System.Windows.Forms.TextBox
    $passTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 12)
    $passTextBox.Location = New-Object System.Drawing.Point(190, 162)
    $passTextBox.Size = New-Object System.Drawing.Size(250, 35)
    $passTextBox.PasswordChar = '*'
    $passTextBox.Text = $savedPassword
    $passTextBox.Add_TextChanged({
        $current = $passTextBox.Text
        $cleaned = Clean-Text -InputText $current
        if ($current -ne $cleaned) {
            $pos = $passTextBox.SelectionStart
            $passTextBox.Text = $cleaned
            $passTextBox.SelectionStart = [Math]::Min($pos, $cleaned.Length)
        }
    })
    $form.Controls.Add($passTextBox)
    
    $rememberCheckbox = New-Object System.Windows.Forms.CheckBox
    $rememberCheckbox.Text = "Remember Me"
    $rememberCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $rememberCheckbox.Location = New-Object System.Drawing.Point(190, 210)
    $rememberCheckbox.Size = New-Object System.Drawing.Size(150, 25)
    $rememberCheckbox.Checked = $rememberMe
    $form.Controls.Add($rememberCheckbox)
    
    $remoteCheckbox = New-Object System.Windows.Forms.CheckBox
    $remoteCheckbox.Text = "Connect Remotely"
    $remoteCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $remoteCheckbox.Location = New-Object System.Drawing.Point(190, 240)
    $remoteCheckbox.Size = New-Object System.Drawing.Size(200, 25)
    $remoteCheckbox.Checked = $remoteChecked
    $form.Controls.Add($remoteCheckbox)
    
    $clearButton = New-Object System.Windows.Forms.Button
    $clearButton.Text = "Clear Saved"
    $clearButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Underline)
    $clearButton.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
    $clearButton.BackColor = [System.Drawing.Color]::White
    $clearButton.FlatStyle = "Flat"
    $clearButton.FlatAppearance.BorderSize = 0
    $clearButton.Location = New-Object System.Drawing.Point(370, 210)
    $clearButton.Size = New-Object System.Drawing.Size(90, 55)
    $clearButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $clearButton.Add_Click({
        try {
            if (Test-Path $registryPath) {
                Remove-ItemProperty -Path $registryPath -Name $usernameKey -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $registryPath -Name $passwordKey -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $registryPath -Name $rememberKey -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $registryPath -Name $remoteKey -ErrorAction SilentlyContinue
                $userTextBox.Text = ""
                $passTextBox.Text = ""
                $rememberCheckbox.Checked = $false
                $remoteCheckbox.Checked = $false
                [System.Windows.Forms.MessageBox]::Show("Saved credentials and settings have been cleared.", "Cleared", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
            } else {
                [System.Windows.Forms.MessageBox]::Show("No saved credentials found.", "Nothing to Clear", "OK", [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Failed to clear credentials: $($_.Exception.Message)", "Error", "OK", [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $form.Controls.Add($clearButton)
    
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Note: Username and password are automatically cleaned of hidden characters."
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::Gray
    $infoLabel.Location = New-Object System.Drawing.Point(60, 275)
    $infoLabel.Size = New-Object System.Drawing.Size(380, 20)
    $form.Controls.Add($infoLabel)
    
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "LOGIN"
    $okButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $okButton.Location = New-Object System.Drawing.Point(100, 315)
    $okButton.Size = New-Object System.Drawing.Size(130, 45)
    $okButton.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = "Flat"
    $form.Controls.Add($okButton)
    
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "CANCEL"
    $cancelButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $cancelButton.Location = New-Object System.Drawing.Point(270, 315)
    $cancelButton.Size = New-Object System.Drawing.Size(130, 45)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
    $cancelButton.ForeColor = [System.Drawing.Color]::White
    $cancelButton.FlatStyle = "Flat"
    $form.Controls.Add($cancelButton)
    
    $script:result = $null
    
    $okButton.Add_Click({
        $script:result = @{
            Username = Clean-Text -InputText $userTextBox.Text
            Password = Clean-Text -InputText $passTextBox.Text
            Remember = $rememberCheckbox.Checked
            Remote = $remoteCheckbox.Checked
        }
        $form.Close()
    })
    
    $cancelButton.Add_Click({
        $script:result = $null
        $form.Close()
    })
    
    $form.ShowDialog() | Out-Null
    
    if ($script:result -and $script:result.Username -ne "") {
        try {
            if (-not (Test-Path $registryPath)) {
                New-Item -Path $registryPath -Force | Out-Null
            }
            Set-ItemProperty -Path $registryPath -Name $rememberKey -Value $script:result.Remember -Force
            Set-ItemProperty -Path $registryPath -Name $remoteKey -Value $script:result.Remote -Force
            $global:useRemoteConnection = $script:result.Remote
        }
        catch { }
        
        if ($script:result.Remember) {
            try {
                Set-ItemProperty -Path $registryPath -Name $usernameKey -Value $script:result.Username -Force
                Set-ItemProperty -Path $registryPath -Name $passwordKey -Value $script:result.Password -Force
            }
            catch { }
        }
        
        return $script:result
    }
    return $null
}

# ====================================================================================================
# PART 4: DATE SELECTION DIALOG
# ====================================================================================================

function Show-DateSelectionDialog {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select Date Range"
    $form.Size = New-Object System.Drawing.Size(1500, 800)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.TopMost = $true
    
    $titlePanel = New-Object System.Windows.Forms.Panel
    $titlePanel.Location = New-Object System.Drawing.Point(0, 0)
    $titlePanel.Size = New-Object System.Drawing.Size(1500, 65)
    $titlePanel.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $form.Controls.Add($titlePanel)
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "SELECT DATE RANGE"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Location = New-Object System.Drawing.Point(550, 12)
    $titleLabel.Size = New-Object System.Drawing.Size(400, 40)
    $titleLabel.TextAlign = "MiddleCenter"
    $titlePanel.Controls.Add($titleLabel)
    
    $startPanel = New-Object System.Windows.Forms.Panel
    $startPanel.Location = New-Object System.Drawing.Point(30, 85)
    $startPanel.Size = New-Object System.Drawing.Size(680, 280)
    $startPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
    $startPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($startPanel)
    
    $startLabel = New-Object System.Windows.Forms.Label
    $startLabel.Text = "START DATE"
    $startLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $startLabel.Location = New-Object System.Drawing.Point(15, 10)
    $startLabel.Size = New-Object System.Drawing.Size(200, 35)
    $startPanel.Controls.Add($startLabel)
    
    $startCalendar = New-Object System.Windows.Forms.MonthCalendar
    $startCalendar.Location = New-Object System.Drawing.Point(15, 50)
    $startCalendar.Size = New-Object System.Drawing.Size(640, 210)
    $startCalendar.MaxSelectionCount = 1
    $startCalendar.SelectionStart = (Get-Date).Date
    $startPanel.Controls.Add($startCalendar)
    
    $endPanel = New-Object System.Windows.Forms.Panel
    $endPanel.Location = New-Object System.Drawing.Point(760, 85)
    $endPanel.Size = New-Object System.Drawing.Size(680, 280)
    $endPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
    $endPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($endPanel)
    
    $endLabel = New-Object System.Windows.Forms.Label
    $endLabel.Text = "END DATE"
    $endLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $endLabel.Location = New-Object System.Drawing.Point(15, 10)
    $endLabel.Size = New-Object System.Drawing.Size(200, 35)
    $endPanel.Controls.Add($endLabel)
    
    $endCalendar = New-Object System.Windows.Forms.MonthCalendar
    $endCalendar.Location = New-Object System.Drawing.Point(15, 50)
    $endCalendar.Size = New-Object System.Drawing.Size(640, 210)
    $endCalendar.MaxSelectionCount = 1
    $endCalendar.SelectionStart = (Get-Date).Date
    $endPanel.Controls.Add($endCalendar)
    
    $optionsPanel = New-Object System.Windows.Forms.Panel
    $optionsPanel.Location = New-Object System.Drawing.Point(30, 380)
    $optionsPanel.Size = New-Object System.Drawing.Size(1410, 180)
    $optionsPanel.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)
    $optionsPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($optionsPanel)
    
    $optionsTitle = New-Object System.Windows.Forms.Label
    $optionsTitle.Text = "HOLIDAY AND WEEKEND SETTINGS"
    $optionsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $optionsTitle.Location = New-Object System.Drawing.Point(15, 10)
    $optionsTitle.Size = New-Object System.Drawing.Size(350, 25)
    $optionsPanel.Controls.Add($optionsTitle)
    
    $fridayCheckbox = New-Object System.Windows.Forms.CheckBox
    $fridayCheckbox.Text = "Friday Off"
    $fridayCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $fridayCheckbox.Location = New-Object System.Drawing.Point(15, 45)
    $fridayCheckbox.Size = New-Object System.Drawing.Size(150, 30)
    $fridayCheckbox.Checked = $true
    $optionsPanel.Controls.Add($fridayCheckbox)
    
    $saturdayCheckbox = New-Object System.Windows.Forms.CheckBox
    $saturdayCheckbox.Text = "Saturday Off"
    $saturdayCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $saturdayCheckbox.Location = New-Object System.Drawing.Point(180, 45)
    $saturdayCheckbox.Size = New-Object System.Drawing.Size(150, 30)
    $saturdayCheckbox.Checked = $true
    $optionsPanel.Controls.Add($saturdayCheckbox)
    
    $holidayCheckbox = New-Object System.Windows.Forms.CheckBox
    $holidayCheckbox.Text = "Official Holiday"
    $holidayCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $holidayCheckbox.Location = New-Object System.Drawing.Point(345, 45)
    $holidayCheckbox.Size = New-Object System.Drawing.Size(180, 30)
    $holidayCheckbox.Checked = $false
    $optionsPanel.Controls.Add($holidayCheckbox)
    
    $holidayStartLabel = New-Object System.Windows.Forms.Label
    $holidayStartLabel.Text = "Holiday Start:"
    $holidayStartLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $holidayStartLabel.Location = New-Object System.Drawing.Point(15, 90)
    $holidayStartLabel.Size = New-Object System.Drawing.Size(120, 25)
    $holidayStartLabel.Enabled = $false
    $optionsPanel.Controls.Add($holidayStartLabel)
    
    $holidayStartCombo = New-Object System.Windows.Forms.ComboBox
    $holidayStartCombo.Location = New-Object System.Drawing.Point(140, 88)
    $holidayStartCombo.Size = New-Object System.Drawing.Size(200, 25)
    $holidayStartCombo.DropDownStyle = "DropDownList"
    $holidayStartCombo.Enabled = $false
    $optionsPanel.Controls.Add($holidayStartCombo)
    
    $holidayEndLabel = New-Object System.Windows.Forms.Label
    $holidayEndLabel.Text = "Holiday End:"
    $holidayEndLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $holidayEndLabel.Location = New-Object System.Drawing.Point(360, 90)
    $holidayEndLabel.Size = New-Object System.Drawing.Size(120, 25)
    $holidayEndLabel.Enabled = $false
    $optionsPanel.Controls.Add($holidayEndLabel)
    
    $holidayEndCombo = New-Object System.Windows.Forms.ComboBox
    $holidayEndCombo.Location = New-Object System.Drawing.Point(485, 88)
    $holidayEndCombo.Size = New-Object System.Drawing.Size(200, 25)
    $holidayEndCombo.DropDownStyle = "DropDownList"
    $holidayEndCombo.Enabled = $false
    $optionsPanel.Controls.Add($holidayEndCombo)
    
    $populateHolidayDates = {
        $start = $startCalendar.SelectionStart.Date
        $end = $endCalendar.SelectionStart.Date
        $dateList = @()
        $current = $start
        while ($current -le $end) {
            $dateList += $current
            $current = $current.AddDays(1)
        }
        $holidayStartCombo.Items.Clear()
        $holidayEndCombo.Items.Clear()
        foreach ($d in $dateList) {
            $display = $d.ToString("yyyy-MM-dd (ddd)")
            $holidayStartCombo.Items.Add($display)
            $holidayEndCombo.Items.Add($display)
        }
        if ($dateList.Count -gt 0) {
            $holidayStartCombo.SelectedIndex = 0
            $holidayEndCombo.SelectedIndex = $dateList.Count - 1
        }
    }
    
    $validateHolidayDates = {
        if ($holidayStartCombo.SelectedIndex -gt $holidayEndCombo.SelectedIndex) {
            $holidayEndCombo.SelectedIndex = $holidayStartCombo.SelectedIndex
        }
    }
    
    $startCalendar.Add_DateChanged({
        & $populateHolidayDates
        if ($startCalendar.SelectionStart.Date -gt $endCalendar.SelectionStart.Date) {
            [System.Windows.Forms.MessageBox]::Show("Start date cannot be after end date!", "Invalid Date Range", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    
    $endCalendar.Add_DateChanged({
        & $populateHolidayDates
        if ($startCalendar.SelectionStart.Date -gt $endCalendar.SelectionStart.Date) {
            [System.Windows.Forms.MessageBox]::Show("Start date cannot be after end date!", "Invalid Date Range", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })
    
    $holidayCheckbox.Add_CheckedChanged({
        $isChecked = $holidayCheckbox.Checked
        $holidayStartLabel.Enabled = $isChecked
        $holidayStartCombo.Enabled = $isChecked
        $holidayEndLabel.Enabled = $isChecked
        $holidayEndCombo.Enabled = $isChecked
        if ($isChecked -and $holidayStartCombo.Items.Count -eq 0) { & $populateHolidayDates }
    })
    
    $holidayStartCombo.Add_SelectedIndexChanged({ & $validateHolidayDates })
    $holidayEndCombo.Add_SelectedIndexChanged({ & $validateHolidayDates })
    
    & $populateHolidayDates
    
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "Select your start date (left panel) and end date (right panel). Start date cannot be after end date."
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::DarkGray
    $infoLabel.Location = New-Object System.Drawing.Point(30, 575)
    $infoLabel.Size = New-Object System.Drawing.Size(1410, 25)
    $form.Controls.Add($infoLabel)
    
    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Location = New-Object System.Drawing.Point(0, 620)
    $buttonPanel.Size = New-Object System.Drawing.Size(1500, 85)
    $buttonPanel.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)
    $form.Controls.Add($buttonPanel)
    
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "GENERATE REPORT"
    $okButton.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $okButton.Location = New-Object System.Drawing.Point(480, 18)
    $okButton.Size = New-Object System.Drawing.Size(280, 50)
    $okButton.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = "Flat"
    $buttonPanel.Controls.Add($okButton)
    
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "CANCEL"
    $cancelButton.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $cancelButton.Location = New-Object System.Drawing.Point(800, 18)
    $cancelButton.Size = New-Object System.Drawing.Size(220, 50)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
    $cancelButton.ForeColor = [System.Drawing.Color]::White
    $cancelButton.FlatStyle = "Flat"
    $buttonPanel.Controls.Add($cancelButton)
    
    $script:result = $null
    
    $okButton.Add_Click({
        $start = $startCalendar.SelectionStart.Date
        $end = $endCalendar.SelectionStart.Date
        if ($start -gt $end) {
            [System.Windows.Forms.MessageBox]::Show("Start date cannot be after end date!", "Invalid Date Range", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $holidayStartDate = $null
        $holidayEndDate = $null
        if ($holidayCheckbox.Checked) {
            $startIdx = $holidayStartCombo.SelectedIndex
            $endIdx = $holidayEndCombo.SelectedIndex
            $dateList = @()
            $current = $start
            while ($current -le $end) {
                $dateList += $current
                $current = $current.AddDays(1)
            }
            if ($startIdx -ge 0 -and $startIdx -lt $dateList.Count) { $holidayStartDate = $dateList[$startIdx] }
            if ($endIdx -ge 0 -and $endIdx -lt $dateList.Count) { $holidayEndDate = $dateList[$endIdx] }
        }
        $script:result = @{
            StartDate = $start
            EndDate = $end
            FridayOff = $fridayCheckbox.Checked
            SaturdayOff = $saturdayCheckbox.Checked
            OfficialHoliday = $holidayCheckbox.Checked
            HolidayStart = $holidayStartDate
            HolidayEnd = $holidayEndDate
        }
        $form.Close()
    })
    
    $cancelButton.Add_Click({
        $script:result = $null
        $form.Close()
    })
    
    $form.ShowDialog() | Out-Null
    
    if ($script:result) {
        $global:fridayOff = $script:result.FridayOff
        $global:saturdayOff = $script:result.SaturdayOff
        $global:officialHoliday = $script:result.OfficialHoliday
        $global:holidayStart = $script:result.HolidayStart
        $global:holidayEnd = $script:result.HolidayEnd
        return $script:result
    }
    return $null
}

# ====================================================================================================
# PART 5: EMPLOYEE SELECTION DIALOG
# ====================================================================================================

function Show-EmployeeSelectionDialog {
    param(
        [array]$AllEmployees,
        [hashtable]$RequiredHoursMap,
        [ref]$CreateRowDataFile,
        [ref]$CreateRawRecordsFile,
        [ref]$CreateMonthlySheets
    )
    
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    
    $sortedEmployees = $AllEmployees | Sort-Object
    
    $counted = @()
    $notCounted = @()
    foreach ($emp in $sortedEmployees) {
        $hours = $RequiredHoursMap[$emp].RequiredHours
        if ($hours -eq 0) { $notCounted += $emp } else { $counted += $emp }
    }
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select Employees for Report"
    $form.Size = New-Object System.Drawing.Size(1000, 750)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.TopMost = $true
    
    $titlePanel = New-Object System.Windows.Forms.Panel
    $titlePanel.Location = New-Object System.Drawing.Point(0, 0)
    $titlePanel.Size = New-Object System.Drawing.Size(1000, 60)
    $titlePanel.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $form.Controls.Add($titlePanel)
    
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Select employees to include in the report"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::White
    $titleLabel.Location = New-Object System.Drawing.Point(200, 15)
    $titleLabel.Size = New-Object System.Drawing.Size(600, 30)
    $titleLabel.TextAlign = "MiddleCenter"
    $titlePanel.Controls.Add($titleLabel)
    
    $statsLabel = New-Object System.Windows.Forms.Label
    $statsLabel.Text = "0 of 0 employees selected"
    $statsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $statsLabel.Location = New-Object System.Drawing.Point(15, 75)
    $statsLabel.Size = New-Object System.Drawing.Size(250, 25)
    $form.Controls.Add($statsLabel)
    
    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Location = New-Object System.Drawing.Point(280, 70)
    $buttonPanel.Size = New-Object System.Drawing.Size(690, 40)
    $form.Controls.Add($buttonPanel)
    
    $selectAllButton = New-Object System.Windows.Forms.Button
    $selectAllButton.Text = "SELECT ALL"
    $selectAllButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $selectAllButton.Location = New-Object System.Drawing.Point(0, 5)
    $selectAllButton.Size = New-Object System.Drawing.Size(140, 30)
    $selectAllButton.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
    $selectAllButton.ForeColor = [System.Drawing.Color]::White
    $selectAllButton.FlatStyle = "Flat"
    $buttonPanel.Controls.Add($selectAllButton)
    
    $clearAllButton = New-Object System.Windows.Forms.Button
    $clearAllButton.Text = "CLEAR ALL"
    $clearAllButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $clearAllButton.Location = New-Object System.Drawing.Point(155, 5)
    $clearAllButton.Size = New-Object System.Drawing.Size(140, 30)
    $clearAllButton.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
    $clearAllButton.ForeColor = [System.Drawing.Color]::White
    $clearAllButton.FlatStyle = "Flat"
    $buttonPanel.Controls.Add($clearAllButton)
    
    $selectCountedButton = New-Object System.Windows.Forms.Button
    $selectCountedButton.Text = "COUNTED ONLY"
    $selectCountedButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $selectCountedButton.Location = New-Object System.Drawing.Point(310, 5)
    $selectCountedButton.Size = New-Object System.Drawing.Size(150, 30)
    $selectCountedButton.BackColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
    $selectCountedButton.ForeColor = [System.Drawing.Color]::White
    $selectCountedButton.FlatStyle = "Flat"
    $buttonPanel.Controls.Add($selectCountedButton)
    
    $optionsPanel = New-Object System.Windows.Forms.Panel
    $optionsPanel.Location = New-Object System.Drawing.Point(15, 115)
    $optionsPanel.Size = New-Object System.Drawing.Size(960, 50)
    $optionsPanel.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)
    $optionsPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($optionsPanel)
    
    $rowDataCheckbox = New-Object System.Windows.Forms.CheckBox
    $rowDataCheckbox.Text = "Row Data"
    $rowDataCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $rowDataCheckbox.Location = New-Object System.Drawing.Point(15, 12)
    $rowDataCheckbox.Size = New-Object System.Drawing.Size(120, 25)
    $optionsPanel.Controls.Add($rowDataCheckbox)
    
    $rawRecordsCheckbox = New-Object System.Windows.Forms.CheckBox
    $rawRecordsCheckbox.Text = "Raw Records"
    $rawRecordsCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $rawRecordsCheckbox.Location = New-Object System.Drawing.Point(160, 12)
    $rawRecordsCheckbox.Size = New-Object System.Drawing.Size(120, 25)
    $optionsPanel.Controls.Add($rawRecordsCheckbox)
    
    $monthlySheetsCheckbox = New-Object System.Windows.Forms.CheckBox
    $monthlySheetsCheckbox.Text = "Monthly Sheets"
    $monthlySheetsCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $monthlySheetsCheckbox.Location = New-Object System.Drawing.Point(310, 12)
    $monthlySheetsCheckbox.Size = New-Object System.Drawing.Size(150, 25)
    $optionsPanel.Controls.Add($monthlySheetsCheckbox)
    
    $scrollPanel = New-Object System.Windows.Forms.Panel
    $scrollPanel.Location = New-Object System.Drawing.Point(15, 175)
    $scrollPanel.Size = New-Object System.Drawing.Size(960, 430)
    $scrollPanel.AutoScroll = $true
    $scrollPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
    $scrollPanel.BorderStyle = "FixedSingle"
    $form.Controls.Add($scrollPanel)
    
    $checkboxes = @{}
    $yPos = 10
    
    if ($counted.Count -gt 0) {
        $header = New-Object System.Windows.Forms.Label
        $header.Text = "COUNTED EMPLOYEES"
        $header.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $header.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        $header.Location = New-Object System.Drawing.Point(15, $yPos)
        $header.Size = New-Object System.Drawing.Size(900, 25)
        $scrollPanel.Controls.Add($header)
        $yPos += 35
        
        foreach ($emp in $counted) {
            $hours = $RequiredHoursMap[$emp].RequiredHours
            $hoursDisplay = Convert-HoursToTimeString -Hours $hours
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = "$emp - Required: $hoursDisplay"
            $cb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
            $cb.Location = New-Object System.Drawing.Point(35, $yPos)
            $cb.Size = New-Object System.Drawing.Size(850, 28)
            $cb.Checked = $true
            $cb.Tag = $emp
            $scrollPanel.Controls.Add($cb)
            $checkboxes[$emp] = $cb
            $yPos += 35
        }
    }
    
    if ($notCounted.Count -gt 0) {
        $yPos += 10
        $header = New-Object System.Windows.Forms.Label
        $header.Text = "NOT COUNTED EMPLOYEES"
        $header.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $header.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
        $header.Location = New-Object System.Drawing.Point(15, $yPos)
        $header.Size = New-Object System.Drawing.Size(900, 25)
        $scrollPanel.Controls.Add($header)
        $yPos += 35
        
        foreach ($emp in $notCounted) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = "$emp - NOT COUNTED"
            $cb.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic)
            $cb.ForeColor = [System.Drawing.Color]::Gray
            $cb.Location = New-Object System.Drawing.Point(35, $yPos)
            $cb.Size = New-Object System.Drawing.Size(850, 28)
            $cb.Checked = $false
            $cb.Tag = $emp
            $scrollPanel.Controls.Add($cb)
            $checkboxes[$emp] = $cb
            $yPos += 35
        }
    }
    
    $updateStats = {
        $selected = 0
        $total = 0
        foreach ($key in $checkboxes.Keys) {
            $total++
            if ($checkboxes[$key].Checked) { $selected++ }
        }
        $statsLabel.Text = "$selected of $total employees selected"
        if ($selected -eq $total) {
            $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
        } elseif ($selected -eq 0) {
            $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
        } else {
            $statsLabel.ForeColor = [System.Drawing.Color]::FromArgb(52, 73, 94)
        }
    }
    
    foreach ($cb in $checkboxes.Values) {
        $cb.Add_CheckedChanged({ & $updateStats })
    }
    
    $selectAllButton.Add_Click({
        foreach ($cb in $checkboxes.Values) { $cb.Checked = $true }
        & $updateStats
    })
    
    $clearAllButton.Add_Click({
        foreach ($cb in $checkboxes.Values) { $cb.Checked = $false }
        & $updateStats
    })
    
    $selectCountedButton.Add_Click({
        foreach ($emp in $counted) { if ($checkboxes.ContainsKey($emp)) { $checkboxes[$emp].Checked = $true } }
        foreach ($emp in $notCounted) { if ($checkboxes.ContainsKey($emp)) { $checkboxes[$emp].Checked = $false } }
        & $updateStats
    })
    
    & $updateStats
    
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Location = New-Object System.Drawing.Point(0, 620)
    $bottomPanel.Size = New-Object System.Drawing.Size(1000, 80)
    $bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)
    $form.Controls.Add($bottomPanel)
    
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "GENERATE REPORT"
    $okButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $okButton.Location = New-Object System.Drawing.Point(250, 20)
    $okButton.Size = New-Object System.Drawing.Size(240, 45)
    $okButton.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = "Flat"
    $bottomPanel.Controls.Add($okButton)
    
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "CANCEL"
    $cancelButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $cancelButton.Location = New-Object System.Drawing.Point(520, 20)
    $cancelButton.Size = New-Object System.Drawing.Size(220, 45)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(231, 76, 60)
    $cancelButton.ForeColor = [System.Drawing.Color]::White
    $cancelButton.FlatStyle = "Flat"
    $bottomPanel.Controls.Add($cancelButton)
    
    $script:selected = $null
    $script:createRow = $false
    $script:createRaw = $false
    $script:createMonthly = $false
    
    $okButton.Add_Click({
        $script:selected = @()
        foreach ($cb in $checkboxes.Values) {
            if ($cb.Checked) { $script:selected += $cb.Tag }
        }
        if ($script:selected.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select at least one employee.", "No Selection", "OK", [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $script:createRow = $rowDataCheckbox.Checked
        $script:createRaw = $rawRecordsCheckbox.Checked
        $script:createMonthly = $monthlySheetsCheckbox.Checked
        $form.Close()
    })
    
    $cancelButton.Add_Click({
        $script:selected = $null
        $form.Close()
    })
    
    $form.ShowDialog() | Out-Null
    
    $CreateRowDataFile.Value = $script:createRow
    $CreateRawRecordsFile.Value = $script:createRaw
    $CreateMonthlySheets.Value = $script:createMonthly
    
    return $script:selected
}

# ====================================================================================================
# PART 6: DEVICE COMMUNICATION & RECORD FETCHING
# ====================================================================================================

function Get-DeviceAddress {
    param([string]$OriginalIP, [string]$RemoteLink, [int]$DeviceIndex)
    
    if ($global:useRemoteConnection -and $RemoteLink -and $RemoteLink -ne "") {
        $cleanLink = $RemoteLink -replace '^https?://', ''
        return "http://$cleanLink"
    }
    elseif ($global:useRemoteConnection) {
        return "http://$OriginalIP"
    }
    else {
        return "http://$OriginalIP"
    }
}

function FetchDayRecords {
    param([DateTime]$Date)
    
    $allRecords = @()
    $deviceCount = $global:devices.Count
    $currentDevice = 0
    
    foreach ($device in $global:devices) {
        $currentDevice++
        $deviceIndex = $currentDevice - 1
        $baseAddress = Get-DeviceAddress -OriginalIP $device.IP -RemoteLink $device.'Remote Connection Link' -DeviceIndex $deviceIndex
        
        Update-ProgressDialog -StatusText "Fetching records for $($Date.ToString('yyyy-MM-dd'))" -DetailText "Device $currentDevice of $deviceCount ($($device.Direction))"
        
        $dayStart = $Date.Date
        $dayEnd = $Date.Date.AddDays(1).AddSeconds(-1)
        $startUnix = [int][double]::Parse((Get-Date $dayStart -UFormat %s))
        $endUnix = [int][double]::Parse((Get-Date $dayEnd -UFormat %s))
        
        $url = "$baseAddress/cgi-bin/recordFinder.cgi?action=find&name=AccessControlCardRec&StartTime=$startUnix&EndTime=$endUnix"
        
        $securePass = ConvertTo-SecureString $device.Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($device.Username, $securePass)
        
        try {
            $timeoutSec = if ($global:useRemoteConnection) { 120 } else { $API_TIMEOUT }
            
            $response = Invoke-WebRequest -Uri $url -Method GET -Credential $credential -Headers @{"User-Agent" = "Mozilla/5.0"} -UseBasicParsing -TimeoutSec $timeoutSec
            $content = $response.Content
            
            $global:rawDeviceResponses += @{
                Date = $Date
                DeviceAddress = $baseAddress
                DeviceDirection = $device.Direction
                Url = $url
                RawContent = $content
            }
            
            $records = @{}
            $lines = $content -split "`n"
            
            foreach ($line in $lines) {
                $line = $line.Trim()
                if ($line -match '^records\[(\d+)\]\.(.+?)=(.*)$') {
                    $idx = $matches[1]
                    $field = $matches[2]
                    $value = $matches[3]
                    if (-not $records.ContainsKey($idx)) { $records[$idx] = @{} }
                    $records[$idx][$field] = $value
                }
            }
            
            foreach ($rec in $records.Values) {
                $dt = $null
                if ($rec.ContainsKey("CreateTime")) {
                    try { $dt = Convert-UnixToDateTime -UnixTime $rec.CreateTime }
                    catch { $dt = $null }
                }
                
                $cardName = $rec.CardName
                if ($cardName -and $cardName.Trim() -ne "") {
                    $allRecords += [PSCustomObject]@{
                        Direction = $device.Direction
                        CardName = $cardName
                        DateTime = $dt
                        Time12hr = Convert-DateTimeToTimeAMPM -DateTimeValue $dt
                        Timestamp = $dt
                    }
                }
            }
        }
        catch {
            $global:rawDeviceResponses += @{
                Date = $Date
                DeviceAddress = $baseAddress
                DeviceDirection = $device.Direction
                Url = $url
                RawContent = "ERROR: $($_.Exception.Message)"
            }
        }
    }
    
    return $allRecords
}

function Create-RowDataFile {
    param([string]$FilePath)
    Update-ProgressDialog -StatusText "Creating Row Data file..." -DetailText "Writing raw API responses..."
    $content = @()
    $content += "=" * 80
    $content += "RAW DEVICE API RESPONSES"
    $content += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $content += "=" * 80
    $content += ""
    $idx = 1
    foreach ($resp in $global:rawDeviceResponses) {
        $content += "-" * 80
        $content += "REQUEST #$idx"
        $content += "-" * 80
        $content += "Date: $($resp.Date.ToString('yyyy-MM-dd'))"
        $content += "Device Address: $($resp.DeviceAddress)"
        $content += "Device Direction: $($resp.DeviceDirection)"
        $content += "URL: $($resp.Url)"
        $content += "-" * 40
        $content += "RAW RESPONSE:"
        $content += "-" * 40
        $content += $resp.RawContent
        $content += ""
        $idx++
    }
    $content += "=" * 80
    $content += "END OF RAW DEVICE RESPONSES"
    $content += "=" * 80
    [System.IO.File]::WriteAllText($FilePath, ($content -join "`r`n"), [System.Text.Encoding]::UTF8)
}

function Create-RawRecordsExcel {
    param([string]$ExcelPath, [hashtable]$AllRawRecords, [array]$TargetEmployees)
    
    Update-ProgressDialog -StatusText "Creating Raw Records Excel..." -DetailText "Building raw data spreadsheet..."
    
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $excel.EnableEvents = $false
    
    $workbook = $excel.Workbooks.Add()
    
    $summarySheet = $workbook.Worksheets.Item(1)
    Set-ExcelTitle -Worksheet $summarySheet -Row 1 -Column 1 -Text "RAW RECORDS SUMMARY" -FontSize 16
    Set-ExcelHeader -Worksheet $summarySheet -Row 3 -Column 1 -Text "Employee Name"
    Set-ExcelHeader -Worksheet $summarySheet -Row 3 -Column 2 -Text "Total Records"
    
    $row = 4
    foreach ($emp in ($TargetEmployees | Sort-Object)) {
        $records = $AllRawRecords[$emp]
        $count = $records.Count
        
        $cell1 = $summarySheet.Cells.Item($row, 1)
        Set-CellText -Cell $cell1 -Value $emp
        $cell2 = $summarySheet.Cells.Item($row, 2)
        Set-CellNumber -Cell $cell2 -Value $count
        
        $sheetName = "$emp - Raw"
        $sheetName = $sheetName -replace '[\\/*?:\[\]]', ''
        if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
        
        $summarySheet.Hyperlinks.Add($cell1, "", $sheetName, "Go to raw records", $emp) | Out-Null
        $row++
    }
    
    $summarySheet.UsedRange.EntireColumn.AutoFit() | Out-Null
    
    foreach ($emp in ($TargetEmployees | Sort-Object)) {
        $records = $AllRawRecords[$emp]
        
        $sheetName = "$emp - Raw"
        $sheetName = $sheetName -replace '[\\/*?:\[\]]', ''
        if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
        
        $worksheet = $workbook.Worksheets.Add()
        $worksheet.Name = $sheetName
        
        Set-ExcelTitle -Worksheet $worksheet -Row 1 -Column 1 -Text "RAW RECORDS - $emp" -FontSize 14
        Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 1 -Text "Direction"
        Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 2 -Text "Date/Time"
        Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 3 -Text "Time (12hr)"
        
        $row = 4
        $sorted = $records | Sort-Object { $_.DateTime }
        foreach ($rec in $sorted) {
            $cell1 = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cell1 -Value $rec.Direction
            $cell2 = $worksheet.Cells.Item($row, 2)
            Set-CellDateTime -Cell $cell2 -DateValue $rec.DateTime
            $cell3 = $worksheet.Cells.Item($row, 3)
            Set-CellText -Cell $cell3 -Value $rec.Time12hr
            $row++
        }
        
        $worksheet.UsedRange.EntireColumn.AutoFit() | Out-Null
    }
    
    $summarySheet.Move($workbook.Sheets.Item(1))
    
    $workbook.SaveAs($ExcelPath, 51)
    $workbook.Close()
    $excel.Quit()
    
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    [System.GC]::Collect()
}

# ====================================================================================================
# PART 7: ATTENDANCE PROCESSING (REWRITTEN CORE ENGINE)
# ====================================================================================================

function IsDateExcluded {
    param([DateTime]$Date)
    
    if ($global:officialHoliday -and $global:holidayStart -and $global:holidayEnd) {
        if ($Date.Date -ge $global:holidayStart.Date -and $Date.Date -le $global:holidayEnd.Date) {
            return $true, "Official Holiday"
        }
    }
    
    if ($global:fridayOff -and $Date.DayOfWeek -eq [DayOfWeek]::Friday) {
        return $true, "Weekly Rest"
    }
    
    if ($global:saturdayOff -and $Date.DayOfWeek -eq [DayOfWeek]::Saturday) {
        return $true, "Weekly Rest"
    }
    
    return $false, ""
}

function Calculate-Overtime {
    param(
        [array]$AllRecords,
        [bool]$IsExcludedDay = $false,
        [string]$ExcludeReason = ""
    )
    
    $overtimePeriods = @()
    $totalOvertimeSeconds = 0
    
    if ($AllRecords.Count -eq 0) {
        return @{
            Periods = @()
            TotalOvertimeSeconds = 0
            TotalOvertimeDisplay = "00:00:00"
            HasOvertime = $false
        }
    }
    
    $sortedRecords = $AllRecords | Sort-Object { $_.Timestamp }
    $pendingIn = $null
    
    for ($i = 0; $i -lt $sortedRecords.Count; $i++) {
        $record = $sortedRecords[$i]
        
        if ($record.Direction -eq "IN") {
            $secondsOfDay = [int64]$record.Timestamp.TimeOfDay.TotalSeconds
            if ($secondsOfDay -ge $FIVE_AM_SECONDS) {
                $pendingIn = $record
            }
        }
        elseif ($record.Direction -eq "OUT" -and $pendingIn) {
            $inTime = $pendingIn.Timestamp
            $outTime = $record.Timestamp
            $inOvertime = IsInOvertimePeriod -time $inTime
            $outOvertime = IsInOvertimePeriod -time $outTime
            
            if ($inOvertime -and $outOvertime) {
                $overtimeSeconds = [int64](($outTime - $inTime).TotalSeconds)
                if ($overtimeSeconds -gt 0) {
                    $note = ""
                    if ($IsExcludedDay) { $note = $ExcludeReason }
                    $overtimePeriods += [PSCustomObject]@{
                        Date = $inTime.Date
                        InTime = $inTime
                        OutTime = $outTime
                        Note = $note
                        OvertimeSeconds = $overtimeSeconds
                        Rate = "150%"
                    }
                    $totalOvertimeSeconds += $overtimeSeconds
                }
            }
            $pendingIn = $null
        }
    }
    
    $totalOvertimeSeconds = [math]::Round($totalOvertimeSeconds, 0)
    
    return @{
        Periods = $overtimePeriods
        TotalOvertimeSeconds = $totalOvertimeSeconds
        TotalOvertimeDisplay = Convert-SecondsToTimeString -Seconds $totalOvertimeSeconds
        HasOvertime = ($overtimePeriods.Count -gt 0 -or $totalOvertimeSeconds -gt 0)
    }
}

function Resolve-DayAttendanceRecords {
    param(
        [array]$records,
        [datetime]$dayDate,
        [bool]$isCurrentDay,
        [int64]$requiredWorkSeconds
    )
    
    $currentTime = Get-Date
    
    if ($records.Count -gt 1) {
        $records = @($records | Sort-Object Timestamp)
    }
    else {
        $records = @($records)
    }
    
    $processedRecords = @()
    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        $processedRecords += [PSCustomObject]@{
            Index = $i
            ActualTimestamp = $record.Timestamp
            CountedTimestamp = $null
            Direction = $record.Direction.ToUpper()
            IsValid = $false
            Reason = ""
            Note = ""
            SessionNumber = 0
            InsideSeconds = 0
            OutsideSeconds = 0
            IsOvertime = $false
            FinalizedDirection = $record.Direction.ToUpper()
        }
    }
    
    $state = "SEARCHING_AFTER_5AM"
    $sessionNumber = 0
    $lastValidRecord = $null
    $firstValidIn = $null
    
    for ($i = 0; $i -lt $processedRecords.Count; $i++) {
        $current = $processedRecords[$i]
        $prev = $null
        $next = $null
        if ($i -gt 0) { $prev = $processedRecords[$i - 1] }
        if ($i -lt ($processedRecords.Count - 1)) { $next = $processedRecords[$i + 1] }
        $secondsOfDay = [int64]$current.ActualTimestamp.TimeOfDay.TotalSeconds
        
        if ($state -eq "SEARCHING_AFTER_5AM") {
            if ($secondsOfDay -lt $FIVE_AM_SECONDS) {
                $current.IsValid = $false
                $current.Reason = "Invalid - Before 5AM"
                continue
            }
            $state = "SEARCHING_FIRST_IN"
        }
        
        if ($state -eq "SEARCHING_FIRST_IN") {
            if ($current.Direction -eq "OUT") {
                $current.IsValid = $false
                $current.Reason = "Invalid - Before First In"
                continue
            }
            
            $current.IsValid = $true
            $current.Reason = "Valid - First In"
            $sessionNumber = 1
            $current.SessionNumber = $sessionNumber
            
            if ($secondsOfDay -ge $FIVE_AM_SECONDS -and $secondsOfDay -lt $SEVEN_AM_SECONDS) {
                $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(7)
                $current.Note = "Counted as 7AM"
            }
            else {
                $current.CountedTimestamp = $current.ActualTimestamp
            }
            
            $firstValidIn = $current
            $lastValidRecord = $current
            $state = "SESSION_1"
            continue
        }
        
        if ($state -eq "SESSION_1") {
            $current.SessionNumber = $sessionNumber
            
            if ($current.Direction -eq "IN") {
                if ($prev -and $prev.Direction -eq "IN") {
                    $current.IsValid = $false
                    $current.Reason = "Invalid - Preserving First In"
                    continue
                }
            }
            
            if ($current.Direction -eq "OUT") {
                if ($next -and $next.Direction -eq "OUT") {
                    $current.IsValid = $false
                    $difference = [int64](($next.ActualTimestamp - $current.ActualTimestamp).TotalSeconds)
                    if ($difference -lt 60) {
                        $current.Reason = "Invalid - Duplicate Out"
                    }
                    else {
                        $current.Reason = "Invalid - Out Not Performed"
                    }
                    continue
                }
                
                $current.IsValid = $true
                $current.Reason = "Valid - Session Out"
                
                if ($secondsOfDay -gt $SEVEN_PM_SECONDS) {
                    $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(19)
                    $current.Note = "Counted as 7PM"
                }
                else {
                    $current.CountedTimestamp = $current.ActualTimestamp
                }
                
                $lastValidRecord = $current
                $state = "SEARCHING_NEXT_IN"
                continue
            }
        }
        
        if ($state -eq "SEARCHING_NEXT_IN") {
            if ($current.Direction -eq "OUT") {
                $current.IsValid = $false
                $current.Reason = "Invalid - Consecutive Out"
                continue
            }
            
            $sessionNumber++
            $current.IsValid = $true
            $current.Reason = "Valid - Session In"
            $current.SessionNumber = $sessionNumber
            
            if ($secondsOfDay -ge $FIVE_AM_SECONDS -and $secondsOfDay -lt $SEVEN_AM_SECONDS) {
                $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(7)
                $current.Note = "Counted as 7AM"
            }
            else {
                $current.CountedTimestamp = $current.ActualTimestamp
            }
            
            $lastValidRecord = $current
            $state = "SESSION_2_PLUS"
            continue
        }
        
        if ($state -eq "SESSION_2_PLUS") {
            $current.SessionNumber = $sessionNumber
            
            if ($prev -and $prev.Direction -eq $current.Direction) {
                if ($current.Direction -eq "IN") {
                    $prev.IsValid = $false
                    $prev.Reason = "Invalid - In Not Performed"
                    
                    for ($j = $i - 2; $j -ge 0; $j--) {
                        if ($processedRecords[$j].Direction -eq "OUT") {
                            $difference = [int64](($prev.ActualTimestamp - $processedRecords[$j].ActualTimestamp).TotalSeconds)
                            if ($difference -lt 60) {
                                $prev.Note = "Trick confirmed"
                            }
                            break
                        }
                    }
                    
                    $current.IsValid = $true
                    $current.Reason = "Valid - Replacement In"
                    
                    if ($secondsOfDay -ge $FIVE_AM_SECONDS -and $secondsOfDay -lt $SEVEN_AM_SECONDS) {
                        $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(7)
                        $current.Note = "Counted as 7AM"
                    }
                    else {
                        $current.CountedTimestamp = $current.ActualTimestamp
                    }
                    
                    $lastValidRecord = $current
                    continue
                }
                
                if ($current.Direction -eq "OUT") {
                    $prev.IsValid = $false
                    $difference = [int64](($current.ActualTimestamp - $prev.ActualTimestamp).TotalSeconds)
                    if ($difference -lt 60) {
                        $prev.Reason = "Invalid - Duplicate Out"
                    }
                    else {
                        $prev.Reason = "Invalid - Out Not Performed"
                    }
                    
                    $current.IsValid = $true
                    $current.Reason = "Valid - Replacement Out"
                    
                    if ($secondsOfDay -gt $SEVEN_PM_SECONDS) {
                        $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(19)
                        $current.Note = "Counted as 7PM"
                    }
                    else {
                        $current.CountedTimestamp = $current.ActualTimestamp
                    }
                    
                    $lastValidRecord = $current
                    continue
                }
            }
            
            $current.IsValid = $true
            $current.Reason = "Valid"
            
            if ($current.Direction -eq "IN") {
                if ($secondsOfDay -ge $FIVE_AM_SECONDS -and $secondsOfDay -lt $SEVEN_AM_SECONDS) {
                    $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(7)
                    $current.Note = "Counted as 7AM"
                }
                else {
                    $current.CountedTimestamp = $current.ActualTimestamp
                }
            }
            else {
                if ($secondsOfDay -gt $SEVEN_PM_SECONDS) {
                    $current.CountedTimestamp = $current.ActualTimestamp.Date.AddHours(19)
                    $current.Note = "Counted as 7PM"
                }
                else {
                    $current.CountedTimestamp = $current.ActualTimestamp
                }
            }
            
            $lastValidRecord = $current
        }
    }
    
    $validRecords = @($processedRecords | Where-Object { $_.IsValid })
    
    [int64]$totalInsideSeconds = 0
    [int64]$totalOutsideSeconds = 0
    
    for ($i = 0; $i -lt ($validRecords.Count - 1); $i++) {
        $current = $validRecords[$i]
        $next = $validRecords[$i + 1]
        
        if ($current.Direction -eq "IN" -and $next.Direction -eq "OUT") {
            $insideSeconds = [int64](($next.CountedTimestamp - $current.CountedTimestamp).TotalSeconds)
            if ($insideSeconds -lt 0) { $insideSeconds = 0 }
            
            $startSeconds = [int64]$current.ActualTimestamp.TimeOfDay.TotalSeconds
            $endSeconds = [int64]$next.ActualTimestamp.TimeOfDay.TotalSeconds
            
            if ($startSeconds -ge $FIVE_AM_SECONDS -and $startSeconds -lt $SEVEN_AM_SECONDS -and
                $endSeconds -ge $FIVE_AM_SECONDS -and $endSeconds -lt $SEVEN_AM_SECONDS) {
                $insideSeconds = 0
                $current.Note = "Session counted as zero"
                $next.Note = "Session counted as zero"
            }
            
            $processedRecords[$next.Index].InsideSeconds = $insideSeconds
            $totalInsideSeconds += $insideSeconds
        }
        
        if ($current.Direction -eq "OUT" -and $next.Direction -eq "IN") {
            $outsideSeconds = [int64](($next.CountedTimestamp - $current.CountedTimestamp).TotalSeconds)
            if ($outsideSeconds -lt 0) { $outsideSeconds = 0 }
            $processedRecords[$next.Index].OutsideSeconds = $outsideSeconds
            $totalOutsideSeconds += $outsideSeconds
        }
    }
    
    [int64]$realtimeInsideSeconds = 0
    
    if ($isCurrentDay -and $lastValidRecord -and $lastValidRecord.Direction -eq "IN") {
        $lastInSeconds = [int64]$lastValidRecord.ActualTimestamp.TimeOfDay.TotalSeconds
        if ($lastInSeconds -lt $SEVEN_PM_SECONDS) {
            $realtimeInsideSeconds = [int64](($currentTime - $lastValidRecord.CountedTimestamp).TotalSeconds)
            if ($realtimeInsideSeconds -gt 0) {
                $totalInsideSeconds += $realtimeInsideSeconds
            }
        }
    }
    
    [int64]$remainingSeconds = $requiredWorkSeconds - $totalInsideSeconds
    if ($remainingSeconds -lt 0) { $remainingSeconds = 0 }
    
    $calculatedLeavingTime = $null
    if ($firstValidIn) {
        $calculatedLeavingTime = $firstValidIn.CountedTimestamp.AddSeconds($requiredWorkSeconds + $totalOutsideSeconds)
    }
    
    $leftAt = $null
    if ($lastValidRecord) {
        if ($lastValidRecord.Direction -eq "OUT") {
            $leftAt = $lastValidRecord.CountedTimestamp
        }
        else {
            if ($isCurrentDay) {
                $leftAt = "WORKING"
            }
            else {
                $lastValidRecord.Note = "Didn't Check-Out"
                $lastValidRecord.FinalizedDirection = "OUT"
                $leftAt = $lastValidRecord.CountedTimestamp
            }
        }
    }
    
    $status = ""
    if ($isCurrentDay -and $lastValidRecord -and $lastValidRecord.Direction -eq "IN") {
        $status = "Working"
    }
    else {
        if ($totalInsideSeconds -ge $requiredWorkSeconds) {
            $status = "Completed"
        }
        else {
            $status = "Incomplete"
        }
    }
    
    return [PSCustomObject]@{
        Records = $processedRecords
        FirstValidIn = $firstValidIn
        LastValidRecord = $lastValidRecord
        TotalInsideSeconds = $totalInsideSeconds
        TotalOutsideSeconds = $totalOutsideSeconds
        RealtimeInsideSeconds = $realtimeInsideSeconds
        RequiredWorkSeconds = $requiredWorkSeconds
        RemainingSeconds = $remainingSeconds
        CalculatedLeavingTime = $calculatedLeavingTime
        LeftAt = $leftAt
        Status = $status
    }
}

function ProcessEmployeeDay {
    param(
        [array]$DayRecords,
        [double]$RequiredHours,
        [DateTime]$Date,
        [bool]$IsNotCounted
    )
    
    $isExcluded, $excludeReason = IsDateExcluded -Date $Date
    $isCurrentDay = ($Date.Date -eq (Get-Date).Date)
    $requiredSeconds = Convert-HoursToSeconds -Hours $RequiredHours
    
    if ($IsNotCounted) {
        $processedRecords = @()
        foreach ($record in $DayRecords) {
            $processedRecords += [PSCustomObject]@{
                Direction = $record.Direction
                Time = $record.Time12hr
                Valid = $false
                Reason = "NOT COUNTED"
                Note = ""
                SessionNumber = 0
                InsideSeconds = 0
                InsideDisplay = "00:00:00"
                OutsideSeconds = 0
                OutsideDisplay = "00:00:00"
                DateTime = $record.DateTime
            }
        }
        
        return @{
            Records = $processedRecords
            TotalInsideSeconds = 0
            TotalInsideDisplay = "00:00:00"
            TotalOutsideSeconds = 0
            TotalOutsideDisplay = "00:00:00"
            RemainingSeconds = 0
            RemainingDisplay = "00:00:00"
            CalculatedLeavingTime = $null
            ShouldLeaveDisplay = "N/A"
            LeftAt = $null
            Status = "NOT COUNTED"
            FirstValidIn = $null
            FirstValidInDisplay = "N/A"
            OvertimeResult = $null
        }
    }
    
    if ($isExcluded) {
        $overtimeResult = Calculate-Overtime -AllRecords $DayRecords -IsExcludedDay $true -ExcludeReason $excludeReason
        
        $processedRecords = @()
        foreach ($record in $DayRecords) {
            $processedRecords += [PSCustomObject]@{
                Direction = $record.Direction
                Time = $record.Time12hr
                Valid = $true
                Reason = $excludeReason
                Note = "Counted as Overtime"
                SessionNumber = 0
                InsideSeconds = 0
                InsideDisplay = "00:00:00"
                OutsideSeconds = 0
                OutsideDisplay = "00:00:00"
                DateTime = $record.DateTime
            }
        }
        
        return @{
            Records = $processedRecords
            TotalInsideSeconds = 0
            TotalInsideDisplay = "00:00:00"
            TotalOutsideSeconds = 0
            TotalOutsideDisplay = "00:00:00"
            RemainingSeconds = 0
            RemainingDisplay = "00:00:00"
            CalculatedLeavingTime = $null
            ShouldLeaveDisplay = "N/A"
            LeftAt = $null
            Status = $excludeReason
            FirstValidIn = $null
            FirstValidInDisplay = "N/A"
            OvertimeResult = $overtimeResult
        }
    }
    
    if ($DayRecords.Count -eq 0) {
        $processedRecords = @()
        $processedRecords += [PSCustomObject]@{
            Direction = ""
            Time = ""
            Valid = $false
            Reason = "No records found"
            Note = ""
            SessionNumber = 0
            InsideSeconds = 0
            InsideDisplay = "00:00:00"
            OutsideSeconds = 0
            OutsideDisplay = "00:00:00"
            DateTime = $Date
        }
        
        return @{
            Records = $processedRecords
            TotalInsideSeconds = 0
            TotalInsideDisplay = "00:00:00"
            TotalOutsideSeconds = 0
            TotalOutsideDisplay = "00:00:00"
            RemainingSeconds = $requiredSeconds
            RemainingDisplay = Convert-SecondsToTimeString -Seconds $requiredSeconds
            CalculatedLeavingTime = $null
            ShouldLeaveDisplay = "N/A"
            LeftAt = $null
            Status = "ABSENT"
            FirstValidIn = $null
            FirstValidInDisplay = "N/A"
            OvertimeResult = $null
        }
    }
    
    $result = Resolve-DayAttendanceRecords -records $DayRecords -dayDate $Date -isCurrentDay $isCurrentDay -requiredWorkSeconds $requiredSeconds
    
    $finalRecords = @()
    foreach ($rec in $result.Records) {
        $time12hr = ""
        if ($rec.ActualTimestamp) {
            $time12hr = Convert-DateTimeToTimeAMPM -DateTimeValue $rec.ActualTimestamp
        }
        
        $finalRecords += [PSCustomObject]@{
            Direction = $rec.Direction
            Time = $time12hr
            Valid = $rec.IsValid
            Reason = $rec.Reason
            Note = $rec.Note
            SessionNumber = $rec.SessionNumber
            InsideSeconds = $rec.InsideSeconds
            InsideDisplay = Convert-SecondsToTimeString -Seconds $rec.InsideSeconds
            OutsideSeconds = $rec.OutsideSeconds
            OutsideDisplay = Convert-SecondsToTimeString -Seconds $rec.OutsideSeconds
            DateTime = $rec.ActualTimestamp
        }
    }
    
    $firstValidDisplay = "N/A"
    if ($result.FirstValidIn) {
        $firstValidDisplay = Convert-DateTimeToTimeAMPM -DateTimeValue $result.FirstValidIn.CountedTimestamp
        if ($result.FirstValidIn.Note -eq "Counted as 7AM") {
            $firstValidDisplay = $firstValidDisplay + " (Counted as 7:00 AM)"
        }
    }
    
    $shouldLeaveDisplay = "N/A"
    if ($result.CalculatedLeavingTime) {
        $shouldLeaveDisplay = Convert-DateTimeToTimeAMPM -DateTimeValue $result.CalculatedLeavingTime
    }
    
    $leftAtDisplay = $null
    if ($result.LeftAt) {
        if ($result.LeftAt -eq "WORKING") {
            $leftAtDisplay = "WORKING"
        } else {
            $leftAtDisplay = Convert-DateTimeToTimeAMPM -DateTimeValue $result.LeftAt
        }
    }
    
    $overtimeResult = Calculate-Overtime -AllRecords $DayRecords -IsExcludedDay $false
    
    return @{
        Records = $finalRecords
        TotalInsideSeconds = $result.TotalInsideSeconds
        TotalInsideDisplay = Convert-SecondsToTimeString -Seconds $result.TotalInsideSeconds
        TotalOutsideSeconds = $result.TotalOutsideSeconds
        TotalOutsideDisplay = Convert-SecondsToTimeString -Seconds $result.TotalOutsideSeconds
        RemainingSeconds = $result.RemainingSeconds
        RemainingDisplay = Convert-SecondsToTimeString -Seconds $result.RemainingSeconds
        CalculatedLeavingTime = $result.CalculatedLeavingTime
        ShouldLeaveDisplay = $shouldLeaveDisplay
        LeftAt = $leftAtDisplay
        Status = $result.Status
        FirstValidIn = $result.FirstValidIn
        FirstValidInDisplay = $firstValidDisplay
        OvertimeResult = $overtimeResult
    }
}

# ====================================================================================================
# PART 8: EXCEL REPORT CREATION
# ====================================================================================================

function Create-ExcelReport {
    param(
        [string]$ExcelPath,
        [hashtable]$AllDailyData,
        [hashtable]$AllOvertimeData,
        [array]$DatesToProcess,
        [hashtable]$RequiredHoursMap,
        [array]$TargetEmployees,
        [bool]$IsAdmin = $false,
        [bool]$CreateMonthlySheets = $false,
        [DateTime]$StartDate,
        [DateTime]$EndDate
    )
    
    Update-ProgressDialog -StatusText "Creating Excel report..." -DetailText "Building spreadsheet..."
    
    Get-Process -Name "EXCEL" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $excel.EnableEvents = $false
    $excel.ScreenUpdating = $false
    $excel.Interactive = $false
    
    $workbook = $excel.Workbooks.Add()
    
    $tempName = "TempSheet_" + [System.Guid]::NewGuid().ToString().Substring(0, 8)
    $firstSheet = $workbook.Worksheets.Item(1)
    $firstSheet.Name = $tempName
    
    $sortedEmployees = $TargetEmployees | Sort-Object
    $sheetNames = @{}
    
    # Create Individual Day Sheets
    foreach ($emp in $sortedEmployees) {
        if (-not $AllDailyData.ContainsKey($emp)) {
            Write-Host "WARNING: No daily data for employee: $emp" -ForegroundColor Red
            continue
        }
        
        $dailyData = $AllDailyData[$emp]
        $requiredHoursValue = $RequiredHoursMap[$emp].RequiredHours
        $requiredHours = if ($requiredHoursValue -is [double]) { $requiredHoursValue } else { 9.0 }
        $requiredSeconds = Convert-HoursToSeconds -Hours $requiredHours
        
        foreach ($date in $DatesToProcess) {
            if (-not $dailyData.ContainsKey($date)) {
                Write-Host "WARNING: No data for $emp on $date" -ForegroundColor Yellow
                continue
            }
            
            $data = $dailyData[$date]
            
            $sheetName = "$emp - $($date.ToString('MM-dd'))"
            $sheetName = $sheetName -replace '[\\/*?:\[\]]', ''
            if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
            
            $sheetKey = "$emp|$($date.ToString('yyyy-MM-dd'))"
            $sheetNames[$sheetKey] = $sheetName
            
            $worksheet = $workbook.Worksheets.Add()
            $worksheet.Name = $sheetName
            
            Set-ExcelTitle -Worksheet $worksheet -Row 1 -Column 1 -Text "ATTENDANCE - $emp - $($date.ToString('yyyy-MM-dd'))" -FontSize 14
            
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 1 -Text "Direction"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 2 -Text "Time"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 3 -Text "Valid"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 4 -Text "Reason"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 5 -Text "Note"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 6 -Text "Session"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 7 -Text "Time Inside"
            Set-ExcelHeader -Worksheet $worksheet -Row 3 -Column 8 -Text "Time Outside"
            
            $row = 4
            foreach ($rec in $data.Records) {
                $cell1 = $worksheet.Cells.Item($row, 1)
                Set-CellText -Cell $cell1 -Value $rec.Direction
                $cell2 = $worksheet.Cells.Item($row, 2)
                Set-CellText -Cell $cell2 -Value $rec.Time
                
                $cell3 = $worksheet.Cells.Item($row, 3)
                Set-CellBoolean -Cell $cell3 -Value $rec.Valid
                
                $cell4 = $worksheet.Cells.Item($row, 4)
                Set-CellText -Cell $cell4 -Value $rec.Reason
                $cell5 = $worksheet.Cells.Item($row, 5)
                Set-CellText -Cell $cell5 -Value $rec.Note
                $cell6 = $worksheet.Cells.Item($row, 6)
                Set-CellNumber -Cell $cell6 -Value $rec.SessionNumber
                $cell7 = $worksheet.Cells.Item($row, 7)
                Set-CellTime -Cell $cell7 -TimeString $rec.InsideDisplay
                $cell8 = $worksheet.Cells.Item($row, 8)
                Set-CellTime -Cell $cell8 -TimeString $rec.OutsideDisplay
                
                $row++
            }
            
            $row += 2
            $cellStatusLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellStatusLabel -Value "Status:" -FontBold $true
            $statusInfo = Get-StatusWithInfo -Status $data.Status
            $cellStatus = $worksheet.Cells.Item($row, 2)
            Set-CellStatus -Cell $cellStatus -Status $statusInfo.Text -BackgroundColor $statusInfo.BackgroundColor -TextColor $statusInfo.TextColor
            $row++
            
            $cellFirstInLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellFirstInLabel -Value "First Valid In:" -FontBold $true
            $cellFirstIn = $worksheet.Cells.Item($row, 2)
            Set-CellText -Cell $cellFirstIn -Value $data.FirstValidInDisplay
            $row++
            
            $cellRequiredLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellRequiredLabel -Value "Required Hours:" -FontBold $true
            $cellRequired = $worksheet.Cells.Item($row, 2)
            Set-CellTime -Cell $cellRequired -TimeString (Convert-SecondsToTimeString -Seconds $requiredSeconds)
            $row++
            
            $cellInsideLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellInsideLabel -Value "Total Time Inside:" -FontBold $true
            $cellInside = $worksheet.Cells.Item($row, 2)
            Set-CellTime -Cell $cellInside -TimeString $data.TotalInsideDisplay
            $row++
            
            $cellOutsideLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellOutsideLabel -Value "Total Time Outside:" -FontBold $true
            $cellOutside = $worksheet.Cells.Item($row, 2)
            Set-CellTime -Cell $cellOutside -TimeString $data.TotalOutsideDisplay
            $row++
            
            $cellRemainingLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellRemainingLabel -Value "Remaining:" -FontBold $true
            $cellRemaining = $worksheet.Cells.Item($row, 2)
            Set-CellTime -Cell $cellRemaining -TimeString $data.RemainingDisplay
            $row++
            
            $cellShouldLeaveLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellShouldLeaveLabel -Value "Should Leave At:" -FontBold $true
            $cellShouldLeave = $worksheet.Cells.Item($row, 2)
            Set-CellText -Cell $cellShouldLeave -Value $data.ShouldLeaveDisplay
            $row++
            
            $cellLeftAtLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellLeftAtLabel -Value "Left At:" -FontBold $true
            $cellLeftAt = $worksheet.Cells.Item($row, 2)
            if ($data.LeftAt) {
                Set-CellText -Cell $cellLeftAt -Value $data.LeftAt
            } else {
                Set-CellText -Cell $cellLeftAt -Value "N/A"
            }
            
            $worksheet.UsedRange.EntireColumn.AutoFit() | Out-Null
        }
    }
    
    # Create Overtime Sheets
    foreach ($emp in $sortedEmployees) {
        $empOvertime = $AllOvertimeData[$emp]
        
        if ($empOvertime.HasOvertime) {
            $sheetName = "$emp - Overtime"
            $sheetName = $sheetName -replace '[\\/*?:\[\]]', ''
            if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
            
            $worksheet = $workbook.Worksheets.Add()
            $worksheet.Name = $sheetName
            
            Set-ExcelTitle -Worksheet $worksheet -Row 1 -Column 1 -Text "OVERTIME - $emp" -FontSize 14
            $cellNote = $worksheet.Cells.Item(2, 1)
            Set-CellText -Cell $cellNote -Value "Overtime Period: 7:01 PM to 3:59 AM next day (Weekly Rest/Holiday: Full Day)"
            $cellNote.Font.Italic = $true
            
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 1 -Text "Date"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 2 -Text "Check In"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 3 -Text "Check Out"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 4 -Text "Note"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 5 -Text "Overtime Seconds"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 6 -Text "Overtime Hours"
            Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column 7 -Text "Rate"
            
            $row = 5
            foreach ($period in $empOvertime.Periods) {
                $cell1 = $worksheet.Cells.Item($row, 1)
                Set-CellDateTime -Cell $cell1 -DateValue $period.Date
                
                $cell2 = $worksheet.Cells.Item($row, 2)
                if ($period.InTime) {
                    Set-CellTime -Cell $cell2 -TimeString (Convert-DateTimeToTime24 -DateTimeValue $period.InTime)
                } else {
                    Set-CellText -Cell $cell2 -Value ""
                }
                
                $cell3 = $worksheet.Cells.Item($row, 3)
                if ($period.OutTime) {
                    Set-CellTime -Cell $cell3 -TimeString (Convert-DateTimeToTime24 -DateTimeValue $period.OutTime)
                } else {
                    Set-CellText -Cell $cell3 -Value ""
                }
                
                $cell4 = $worksheet.Cells.Item($row, 4)
                Set-CellText -Cell $cell4 -Value $period.Note
                $cell5 = $worksheet.Cells.Item($row, 5)
                Set-CellNumber -Cell $cell5 -Value $period.OvertimeSeconds
                $cell6 = $worksheet.Cells.Item($row, 6)
                Set-CellTime -Cell $cell6 -TimeString (Convert-SecondsToTimeString -Seconds $period.OvertimeSeconds)
                $cell7 = $worksheet.Cells.Item($row, 7)
                Set-CellText -Cell $cell7 -Value $period.Rate
                $row++
            }
            
            $row++
            $cellTotalLabel = $worksheet.Cells.Item($row, 1)
            Set-CellText -Cell $cellTotalLabel -Value "TOTAL OVERTIME:" -FontBold $true
            $cellTotalSec = $worksheet.Cells.Item($row, 5)
            Set-CellNumber -Cell $cellTotalSec -Value $empOvertime.TotalOvertimeSeconds
            $cellTotalHours = $worksheet.Cells.Item($row, 6)
            Set-CellTime -Cell $cellTotalHours -TimeString $empOvertime.TotalOvertimeDisplay
            
            $worksheet.UsedRange.EntireColumn.AutoFit() | Out-Null
        }
    }
    
    # Create Master Summary Sheet
    $masterSheet = $workbook.Worksheets.Add()
    $masterSheet.Name = "Master Summary"
    
    Set-ExcelTitle -Worksheet $masterSheet -Row 1 -Column 1 -Text "MASTER SUMMARY - $($DatesToProcess[0].ToString('yyyy-MM-dd')) to $($DatesToProcess[-1].ToString('yyyy-MM-dd'))" -FontSize 14
    
    $col = 1
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Employee"
    $col++
    
    foreach ($date in $DatesToProcess) {
        $headerCell = $masterSheet.Cells.Item(3, $col)
        Set-CellText -Cell $headerCell -Value "$($date.ToString('ddd'))`n$($date.ToString('MM-dd'))"
        $headerCell.WrapText = $true
        $headerCell.Font.Bold = $true
        $headerCell.Interior.Color = 15773696
        $headerCell.HorizontalAlignment = -4108
        $col++
        Set-ExcelHeader -Worksheet $masterSheet -Row 4 -Column ($col-1) -Text "Status"
        Set-ExcelHeader -Worksheet $masterSheet -Row 4 -Column $col -Text "Inside"
        $col++
        Set-ExcelHeader -Worksheet $masterSheet -Row 4 -Column $col -Text "Outside"
        $col++
    }
    
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Required"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Total Days"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Present"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Absent"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Completed"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Incomplete"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Total Overtime (Sec)"
    $col++
    Set-ExcelHeader -Worksheet $masterSheet -Row 3 -Column $col -Text "Total Overtime"
    
    $row = 5
    foreach ($emp in $sortedEmployees) {
        $dailyData = $AllDailyData[$emp]
        $empOvertime = $AllOvertimeData[$emp]
        $requiredHoursValue = $RequiredHoursMap[$emp].RequiredHours
        $requiredHours = if ($requiredHoursValue -is [double]) { $requiredHoursValue } else { 9.0 }
        $isNotCounted = ($requiredHours -eq 0)
        
        $col = 1
        $cellEmp = $masterSheet.Cells.Item($row, $col)
        Set-CellText -Cell $cellEmp -Value $emp
        $col++
        
        $totalDays = 0
        $present = 0
        $absent = 0
        $completed = 0
        $incomplete = 0
        
        foreach ($date in $DatesToProcess) {
            $data = $dailyData[$date]
            $statusInfo = Get-StatusWithInfo -Status $data.Status
            
            $sheetKey = "$emp|$($date.ToString('yyyy-MM-dd'))"
            $hyperlink = if ($sheetNames.ContainsKey($sheetKey)) { "'$($sheetNames[$sheetKey])'!A1" } else { "" }
            
            $cellStatus = $masterSheet.Cells.Item($row, $col)
            Set-CellStatus -Cell $cellStatus -Status $statusInfo.Text -BackgroundColor $statusInfo.BackgroundColor -TextColor $statusInfo.TextColor -Hyperlink $hyperlink
            $col++
            
            $cellInside = $masterSheet.Cells.Item($row, $col)
            Set-CellTime -Cell $cellInside -TimeString $data.TotalInsideDisplay
            $col++
            $cellOutside = $masterSheet.Cells.Item($row, $col)
            Set-CellTime -Cell $cellOutside -TimeString $data.TotalOutsideDisplay
            $col++
            
            $totalDays++
            if ($isNotCounted -or $data.Status -eq "Weekly Rest" -or $data.Status -eq "Official Holiday") {
                $present++
                $completed++
            } elseif ($data.Status -ne "ABSENT") {
                $present++
                if ($data.Status -eq "Completed") {
                    $completed++
                } elseif ($data.Status -eq "Working") {
                    $completed++
                } else {
                    $incomplete++
                }
            } else {
                $absent++
            }
        }
        
        $cellRequired = $masterSheet.Cells.Item($row, $col)
        Set-CellTime -Cell $cellRequired -TimeString (Convert-SecondsToTimeString -Seconds (Convert-HoursToSeconds -Hours $requiredHours))
        $col++
        $cellTotalDays = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellTotalDays -Value $totalDays
        $col++
        $cellPresent = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellPresent -Value $present
        $col++
        $cellAbsent = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellAbsent -Value $absent
        $col++
        $cellCompleted = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellCompleted -Value $completed
        $col++
        $cellIncomplete = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellIncomplete -Value $incomplete
        $col++
        $cellOvertimeSec = $masterSheet.Cells.Item($row, $col)
        Set-CellNumber -Cell $cellOvertimeSec -Value $empOvertime.TotalOvertimeSeconds
        $col++
        $cellOvertime = $masterSheet.Cells.Item($row, $col)
        Set-CellTime -Cell $cellOvertime -TimeString $empOvertime.TotalOvertimeDisplay
        
        $row++
    }
    
    $masterSheet.UsedRange.EntireColumn.AutoFit() | Out-Null
    $masterSheet.UsedRange.EntireRow.AutoFit() | Out-Null
    
    # Create Monthly Attendance Sheets
    if ($CreateMonthlySheets) {
        Update-ProgressDialog -StatusText "Creating monthly attendance sheets..." -DetailText "Building employee reports..."
        
        $monthlySheetCounter = 1
        $holidayDatesList = @()
        
        if ($global:officialHoliday -and $global:holidayStart -and $global:holidayEnd) {
            $current = $global:holidayStart.Date
            while ($current -le $global:holidayEnd.Date) {
                $holidayDatesList += $current.ToString("yyyy-MM-dd")
                $current = $current.AddDays(1)
            }
        }
        
        foreach ($emp in $sortedEmployees) {
            $dailyData = $AllDailyData[$emp]
            $requiredHoursValue = $RequiredHoursMap[$emp].RequiredHours
            $requiredHours = if ($requiredHoursValue -is [double]) { $requiredHoursValue } else { 9.0 }
            $isNotCounted = ($requiredHours -eq 0)
            
            if ($isNotCounted) { continue }
            
            $prefix = ($emp -replace ' ', '')
            if ($prefix.Length -gt 5) { $prefix = $prefix.Substring(0, 5) }
            $sheetName = "Monthly_$monthlySheetCounter`_$prefix"
            if ($sheetName.Length -gt 31) { $sheetName = $sheetName.Substring(0, 31) }
            
            $worksheet = $workbook.Worksheets.Add()
            $worksheet.Name = $sheetName
            
            $firstDataRow = 5
            $lastDataRow = 0
            $totalMissingMinutesRow = 0
            $monthlyWorkMinutesRow = 0
            $basicSalaryRow = 0
            $missingTimeDeductRow = 0
            $absentDaysDeductRow = 0
            $netSalaryRow = 0
            $absentDaysRow = 0
            
            Set-ExcelTitle -Worksheet $worksheet -Row 1 -Column 1 -Text "MONTHLY ATTENDANCE REPORT - $emp" -FontSize 14
            $cellPeriod = $worksheet.Cells.Item(2, 1)
            Set-CellText -Cell $cellPeriod -Value "Period: $($StartDate.ToString('dd/MM/yyyy')) to $($EndDate.ToString('dd/MM/yyyy'))"
            $cellPeriod.Font.Italic = $true
            
            $headers = @("Day", "Date", "Arrive Time", "Depart Time", "Total Hours", "Status", "Missing Time (Minutes)", "Notes")
            for ($i = 0; $i -lt $headers.Count; $i++) {
                Set-ExcelHeader -Worksheet $worksheet -Row 4 -Column ($i + 1) -Text $headers[$i]
            }
            
            $worksheet.Columns(2).NumberFormat = "dd/mm/yyyy"
            $worksheet.Columns(3).NumberFormat = "hh:mm:ss"
            $worksheet.Columns(4).NumberFormat = "hh:mm:ss"
            
            $row = 5
            $totalMinutes = 0
            $absentDays = 0
            $presentDays = 0
            $totalMissingMinutes = 0
            $holidayDaysCount = 0
            $weeklyRestDaysCount = 0
            
            foreach ($date in $DatesToProcess) {
                $data = $dailyData[$date]
                $dayOfWeek = $date.ToString("dddd")
                
                $firstIn = $null
                $lastOut = $null
                $totalSeconds = $data.TotalInsideSeconds
                
                foreach ($rec in $data.Records) {
                    if ($rec.Valid -and $rec.Direction -eq "IN" -and $firstIn -eq $null) {
                        $firstIn = $rec.DateTime
                    }
                    if ($rec.Valid -and $rec.Direction -eq "OUT") {
                        $lastOut = $rec.DateTime
                    }
                }
                
                $arrival = if ($firstIn) { Convert-DateTimeToTime24 -DateTimeValue $firstIn } else { "N/A" }
                $depart = if ($lastOut) { Convert-DateTimeToTime24 -DateTimeValue $lastOut } else { "N/A" }
                
                $totalHoursVal = $totalSeconds / 3600
                $totalHours = Convert-SecondsToTimeString -Seconds $totalSeconds
                $totalMinutes += $totalSeconds / 60
                
                $missingSeconds = [math]::Max(0, (Convert-HoursToSeconds -Hours $requiredHours) - $totalSeconds)
                if ($missingSeconds -gt 0 -and $data.Status -ne "Weekly Rest" -and $data.Status -ne "Official Holiday" -and $data.Status -ne "NOT COUNTED" -and $data.Status -ne "ABSENT") {
                    $totalMissingMinutes += $missingSeconds / 60
                    $missingDisplay = [math]::Round($missingSeconds / 60, 2)
                } else {
                    $missingDisplay = 0
                }
                
                if ($data.Status -eq "Weekly Rest") { $weeklyRestDaysCount++ }
                if ($data.Status -eq "Official Holiday") { $holidayDaysCount++ }
                if ($data.Status -eq "ABSENT") { $absentDays++ }
                elseif ($data.Status -ne "Weekly Rest" -and $data.Status -ne "Official Holiday" -and $data.Status -ne "NOT COUNTED") { $presentDays++ }
                
                $statusInfo = Get-StatusWithInfo -Status $data.Status
                $sheetKey = "$emp|$($date.ToString('yyyy-MM-dd'))"
                $hyperlink = if ($sheetNames.ContainsKey($sheetKey)) { "'$($sheetNames[$sheetKey])'!A1" } else { "" }
                
                $cellDay = $worksheet.Cells.Item($row, 1)
                Set-CellText -Cell $cellDay -Value $dayOfWeek
                $cellDate = $worksheet.Cells.Item($row, 2)
                Set-CellDateTime -Cell $cellDate -DateValue $date -Format "dd/mm/yyyy"
                $cellArrive = $worksheet.Cells.Item($row, 3)
                Set-CellTime -Cell $cellArrive -TimeString $arrival
                $cellDepart = $worksheet.Cells.Item($row, 4)
                Set-CellTime -Cell $cellDepart -TimeString $depart
                $cellTotal = $worksheet.Cells.Item($row, 5)
                Set-CellTime -Cell $cellTotal -TimeString $totalHours
                $cellStatus = $worksheet.Cells.Item($row, 6)
                Set-CellStatus -Cell $cellStatus -Status $data.Status -BackgroundColor $statusInfo.BackgroundColor -TextColor $statusInfo.TextColor -Hyperlink $hyperlink
                $cellMissing = $worksheet.Cells.Item($row, 7)
                Set-CellNumber -Cell $cellMissing -Value $missingDisplay -DecimalPlaces 2
                $cellNotes = $worksheet.Cells.Item($row, 8)
                Set-CellText -Cell $cellNotes -Value ""
                
                $row++
            }
            
            $lastDataRow = $row - 1
            $summaryRow = $lastDataRow + 2
            
            $cellSummary = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellSummary -Value "Attendance Summary"
            $cellSummary.Font.Bold = $true
            $cellSummary.Font.Size = 12
            $summaryRow++
            
            $cellTotalDaysLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellTotalDaysLabel -Value "Total Days in Period:" -FontBold $true
            $cellTotalDays = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellNumber -Cell $cellTotalDays -Value $DatesToProcess.Count
            $summaryRow++
            
            $cellHolidayDaysLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellHolidayDaysLabel -Value "Holiday Days:" -FontBold $true
            $cellHolidayDays = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellNumber -Cell $cellHolidayDays -Value $holidayDaysCount
            $summaryRow++
            
            $cellWeeklyRestLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellWeeklyRestLabel -Value "Weekly Rest Days:" -FontBold $true
            $cellWeeklyRest = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellNumber -Cell $cellWeeklyRest -Value $weeklyRestDaysCount
            $summaryRow++
            
            $cellPresentDaysLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellPresentDaysLabel -Value "Days Present:" -FontBold $true
            $cellPresentDays = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellNumber -Cell $cellPresentDays -Value $presentDays
            $summaryRow++
            
            $cellAbsentDaysLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellAbsentDaysLabel -Value "Days Absent:" -FontBold $true
            $cellAbsentDays = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellNumber -Cell $cellAbsentDays -Value $absentDays
            $absentDaysRow = $summaryRow
            $summaryRow++
            
            $cellTotalMissingLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellTotalMissingLabel -Value "Total Missing Minutes:" -FontBold $true
            $cellTotalMissing = $worksheet.Cells.Item($summaryRow, 2)
            $cellTotalMissing.Formula = "=SUM(G${firstDataRow}:G${lastDataRow})"
            $cellTotalMissing.NumberFormat = "0.00"
            $totalMissingMinutesRow = $summaryRow
            $summaryRow++
            
            $cellMonthlyWorkLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellMonthlyWorkLabel -Value "Monthly Work Minutes:" -FontBold $true
            $cellMonthlyWork = $worksheet.Cells.Item($summaryRow, 2)
            $cellMonthlyWork.NumberFormat = "0"
            $cellMonthlyWork.Value2 = ($requiredHours * 30 * 60)
            $monthlyWorkMinutesRow = $summaryRow
            $summaryRow++
            
            $cellHolidayDatesLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellHolidayDatesLabel -Value "Holiday Dates:" -FontBold $true
            $cellHolidayDates = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellText -Cell $cellHolidayDates -Value ($holidayDatesList -join ", ")
            $summaryRow++
            
            $cellBasicSalaryLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellBasicSalaryLabel -Value "Basic Salary:" -FontBold $true
            $cellBasicSalary = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellCurrency -Cell $cellBasicSalary -Value 0
            $basicSalaryRow = $summaryRow
            $summaryRow++
            
            $summaryRow++
            $cellSalaryCalc = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellSalaryCalc -Value "Salary Calculations"
            $cellSalaryCalc.Font.Bold = $true
            $cellSalaryCalc.Font.Size = 12
            $summaryRow++
            
            $cellMissingDeductLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellMissingDeductLabel -Value "Missing Time Deduct:" -FontBold $true
            $cellMissingDeduct = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellCurrency -Cell $cellMissingDeduct -Value 0
            $missingTimeDeductRow = $summaryRow
            $summaryRow++
            
            $cellAbsentDeductLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellAbsentDeductLabel -Value "Absent Days Deduct:" -FontBold $true
            $cellAbsentDeduct = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellCurrency -Cell $cellAbsentDeduct -Value 0
            $absentDaysDeductRow = $summaryRow
            $summaryRow++
            
            $cellNetSalaryLabel = $worksheet.Cells.Item($summaryRow, 1)
            Set-CellText -Cell $cellNetSalaryLabel -Value "Net Salary:" -FontBold $true
            $cellNetSalary = $worksheet.Cells.Item($summaryRow, 2)
            Set-CellCurrency -Cell $cellNetSalary -Value 0
            $cellNetSalary.Font.Bold = $true
            $netSalaryRow = $summaryRow
            
            $cellMissingDeduct.Formula = "=R${basicSalaryRow}C2/R${monthlyWorkMinutesRow}C2*R${totalMissingMinutesRow}C2"
            $cellAbsentDeduct.Formula = "=R${basicSalaryRow}C2/30*R${absentDaysRow}C2"
            $cellNetSalary.Formula = "=R${basicSalaryRow}C2-R${missingTimeDeductRow}C2-R${absentDaysDeductRow}C2"
            
            $worksheet.UsedRange.EntireColumn.AutoFit() | Out-Null
            
            $monthlySheetCounter++
        }
    }
    
    $tempSheet = $workbook.Worksheets.Item($tempName)
    $tempSheet.Delete()
    
    $workbook.SaveAs($ExcelPath, 51)
    $workbook.Close()
    $excel.Quit()
    
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($masterSheet) | Out-Null
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

# ====================================================================================================
# PART 9: MAIN PROGRAM
# ====================================================================================================

# Comment out console hiding for debugging non-admin access
# $null = Add-Type -Name Window -Namespace Console -MemberDefinition '
#     [DllImport("Kernel32.dll")]
#     public static extern IntPtr GetConsoleWindow();
#     [DllImport("User32.dll")]
#     public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
# '
# $consolePtr = [Console.Window]::GetConsoleWindow()
# [Console.Window]::ShowWindow($consolePtr, 0) | Out-Null

Show-ProgressDialog -Title "Attendance System" -Message "Starting..."

$config = Download-And-Decrypt-Config -Url $ConfigUrl

if ($config -eq $null) {
    Close-ProgressDialog
    ShowErrorMessage -Title "Configuration Error" -Message "Failed to load configuration. Please check your internet connection and try again."
    Exit-Application
}

$global:devices = $config.Devices
$global:employees = $config.Employees

Write-Host "`n=== CONFIGURATION LOADED ===" -ForegroundColor Cyan
Write-Host "Number of devices: $($global:devices.Count)" -ForegroundColor Yellow
Write-Host "Number of employees: $($global:employees.Count)" -ForegroundColor Yellow

Close-ProgressDialog

$login = Show-LoginDialog
if (-not $login) { Exit-Application }

Write-Host "`n=== LOGIN ATTEMPT ===" -ForegroundColor Cyan
Write-Host "Username entered: '$($login.Username)'" -ForegroundColor Yellow
Write-Host "Remote connection: $($login.Remote)" -ForegroundColor Yellow

$auth = AuthenticateUser -UserName $login.Username -Password $login.Password
if (-not $auth) {
    ShowErrorMessage -Title "Login Failed" -Message "Invalid username or password!"
    Exit-Application
}

Write-Host "`n=== AUTHENTICATION RESULT ===" -ForegroundColor Cyan
Write-Host "IsAdmin: $($auth.IsAdmin)" -ForegroundColor Yellow
Write-Host "TargetEmployees: $($auth.TargetEmployees -join ', ')" -ForegroundColor Green

$dates = Show-DateSelectionDialog
if (-not $dates) { Exit-Application }

$startDate = $dates.StartDate
$endDate = $dates.EndDate

Write-Host "`n=== DATE RANGE ===" -ForegroundColor Cyan
Write-Host "Start: $($startDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host "End: $($endDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow

$datesToProcess = @()
$currentDate = $startDate
while ($currentDate -le $endDate) {
    $datesToProcess += $currentDate
    $currentDate = $currentDate.AddDays(1)
}

Show-ProgressDialog -Title "Attendance System" -Message "Fetching attendance records..."

$allRawRecords = @{}
$totalDays = $datesToProcess.Count
$dayNum = 0

foreach ($date in $datesToProcess) {
    $dayNum++
    Update-ProgressDialog -StatusText "Fetching records..." -DetailText "Day $dayNum of $totalDays - $($date.ToString('yyyy-MM-dd'))"
    
    $dayRecords = FetchDayRecords -Date $date
    
    $mapped = @()
    foreach ($rec in $dayRecords) {
        $rawName = Clean-Text -InputText $rec.CardName
        
        $currentName = $rawName
        
        # Check old name mappings (case-insensitive)
        foreach ($oldKey in $global:employeeNameMap.Keys) {
            if ($oldKey.ToLower() -eq $rawName.ToLower()) {
                $currentName = $global:employeeNameMap[$oldKey]
                break
            }
        }
        
        # Check direct employee name match (case-insensitive)
        if ($currentName -eq $rawName) {
            foreach ($emp in $global:employees) {
                $empName = Clean-Text -InputText $emp.Name
                if ($empName.ToLower() -eq $rawName.ToLower()) {
                    $currentName = $empName
                    break
                }
            }
        }
        
        $mapped += [PSCustomObject]@{
            Direction = $rec.Direction
            CardName = $currentName
            DateTime = $rec.DateTime
            Time12hr = $rec.Time12hr
            Timestamp = $rec.Timestamp
        }
    }
    
    foreach ($rec in $mapped) {
        $empName = $rec.CardName
        if (-not $allRawRecords.ContainsKey($empName)) { $allRawRecords[$empName] = @() }
        $allRawRecords[$empName] += $rec
    }
}

Write-Host "`n=== RAW RECORDS SUMMARY ===" -ForegroundColor Cyan
foreach ($emp in $allRawRecords.Keys | Sort-Object) {
    Write-Host "  Employee: '$emp' - Records: $($allRawRecords[$emp].Count)" -ForegroundColor Yellow
}

$targetEmployees = $auth.TargetEmployees
$createRowDataFile = $false
$createRawRecordsFile = $false
$createMonthlySheetsFile = $false

if ($auth.IsAdmin) {
    $allEmps = @()
    foreach ($emp in $auth.RequiredHoursMap.Keys) {
        if ($emp -ne "admin") { $allEmps += $emp }
    }
    
    $selected = Show-EmployeeSelectionDialog -AllEmployees $allEmps -RequiredHoursMap $auth.RequiredHoursMap -CreateRowDataFile ([ref]$createRowDataFile) -CreateRawRecordsFile ([ref]$createRawRecordsFile) -CreateMonthlySheets ([ref]$createMonthlySheetsFile)
    
    if (-not $selected -or $selected.Count -eq 0) {
        Close-ProgressDialog
        ShowErrorMessage -Title "No Selection" -Message "No employees selected. Exiting."
        Exit-Application
    }
    
    $targetEmployees = $selected
}

Write-Host "`n=== TARGET EMPLOYEES ===" -ForegroundColor Cyan
foreach ($emp in $targetEmployees) {
    Write-Host "  Target: '$emp'" -ForegroundColor Green
}

# Filter records for selected employees - WITH CASE-INSENSITIVE MATCHING
$filteredRecords = @{}
foreach ($emp in $targetEmployees) {
    $found = $false
    # Try exact match first
    if ($allRawRecords.ContainsKey($emp)) {
        $filteredRecords[$emp] = $allRawRecords[$emp]
        $found = $true
        Write-Host "Exact match found for: '$emp' - $($allRawRecords[$emp].Count) records" -ForegroundColor Green
    } else {
        # Try case-insensitive match
        foreach ($rawKey in $allRawRecords.Keys) {
            if ($rawKey.ToLower() -eq $emp.ToLower()) {
                $filteredRecords[$emp] = $allRawRecords[$rawKey]
                $found = $true
                Write-Host "Case-insensitive match: '$emp' matched to '$rawKey' - $($allRawRecords[$rawKey].Count) records" -ForegroundColor Green
                break
            }
        }
    }
    
    if (-not $found) {
        $filteredRecords[$emp] = @()
        Write-Host "WARNING: No records found for employee: '$emp'" -ForegroundColor Red
    }
}

Write-Host "`n=== FILTERED RECORDS SUMMARY ===" -ForegroundColor Cyan
foreach ($emp in $filteredRecords.Keys | Sort-Object) {
    Write-Host "  $emp : $($filteredRecords[$emp].Count) records" -ForegroundColor Yellow
}

$allDailyData = @{}
$allOvertimeData = @{}
$totalEmps = $targetEmployees.Count
$empNum = 0

foreach ($emp in $targetEmployees) {
    $empNum++
    Update-ProgressDialog -StatusText "Processing attendance..." -DetailText "Employee $empNum of $totalEmps - $emp"
    
    $userInfo = $auth.RequiredHoursMap[$emp]
    $requiredHours = $userInfo.RequiredHours
    $isNotCounted = $userInfo.IsNotCounted
    
    $recordsByDate = @{}
    foreach ($rec in $filteredRecords[$emp]) {
        if ($rec.DateTime) {
            $dateKey = $rec.DateTime.ToString("yyyy-MM-dd")
            if (-not $recordsByDate.ContainsKey($dateKey)) { $recordsByDate[$dateKey] = @() }
            $recordsByDate[$dateKey] += $rec
        }
    }
    
    $dailyResults = @{}
    $employeeOvertimePeriods = @()
    
    foreach ($date in $datesToProcess) {
        $dateKey = $date.ToString("yyyy-MM-dd")
        $dayRecords = if ($recordsByDate.ContainsKey($dateKey)) { $recordsByDate[$dateKey] } else { @() }
        $dailyResults[$date] = ProcessEmployeeDay -DayRecords $dayRecords -RequiredHours $requiredHours -Date $date -IsNotCounted $isNotCounted
        
        if ($dailyResults[$date].OvertimeResult -and $dailyResults[$date].OvertimeResult.HasOvertime) {
            $employeeOvertimePeriods += $dailyResults[$date].OvertimeResult.Periods
        }
    }
    $allDailyData[$emp] = $dailyResults
    
    $totalOvertimeSeconds = 0
    foreach ($period in $employeeOvertimePeriods) {
        $totalOvertimeSeconds += $period.OvertimeSeconds
    }
    
    $allOvertimeData[$emp] = @{
        Periods = $employeeOvertimePeriods
        TotalOvertimeSeconds = $totalOvertimeSeconds
        TotalOvertimeDisplay = Convert-SecondsToTimeString -Seconds $totalOvertimeSeconds
        HasOvertime = ($employeeOvertimePeriods.Count -gt 0 -or $totalOvertimeSeconds -gt 0)
    }
}

$exeDir = [System.IO.Path]::GetDirectoryName([System.Reflection.Assembly]::GetEntryAssembly().Location)
if ([string]::IsNullOrWhiteSpace($exeDir)) { $exeDir = Get-Location }

$dateStamp = $startDate.ToString("yyyyMMdd") + "_to_" + $endDate.ToString("yyyyMMdd")
$excelPath = Join-Path $exeDir "attendance_${dateStamp}.xlsx"

Create-ExcelReport -ExcelPath $excelPath `
    -AllDailyData $allDailyData `
    -AllOvertimeData $allOvertimeData `
    -DatesToProcess $datesToProcess `
    -RequiredHoursMap $auth.RequiredHoursMap `
    -TargetEmployees $targetEmployees `
    -IsAdmin $auth.IsAdmin `
    -CreateMonthlySheets $createMonthlySheetsFile `
    -StartDate $startDate `
    -EndDate $endDate

if ($auth.IsAdmin -and $createRowDataFile) {
    $rowDataPath = Join-Path $exeDir "row_data_${dateStamp}.txt"
    Create-RowDataFile -FilePath $rowDataPath
}

if ($auth.IsAdmin -and $createRawRecordsFile) {
    $rawRecordsPath = Join-Path $exeDir "raw_records_${dateStamp}.xlsx"
    Create-RawRecordsExcel -ExcelPath $rawRecordsPath -AllRawRecords $filteredRecords -TargetEmployees $targetEmployees
}

Close-ProgressDialog

Start-Sleep -Seconds 1
Invoke-Item $excelPath

$global:config = $null
$global:devices = $null
$global:employees = $null
$EMBEDDED_MASTER_PASSWORD = $null
[System.GC]::Collect()

Write-Host "`n=== COMPLETE ===" -ForegroundColor Cyan
Write-Host "Report saved to: $excelPath" -ForegroundColor Green

# ====================================================================================================
# END OF SCRIPT
# ====================================================================================================