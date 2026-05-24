# =====================================================================
# ATTENDANCE SYSTEM ENCRYPTION TOOL
# GUI-based tool to encrypt combined configuration file
# CORRECTED VERSION - Fixed Old Names and Remote Link
# =====================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# AES-256 Encryption Function
function Encrypt-Data {
    param([byte[]]$Data, [string]$Password)
    
    $salt = New-Object byte[] 32
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($salt)
    
    $deriveBytes = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 10000, "SHA256")
    $key = $deriveBytes.GetBytes(32)
    $iv = $deriveBytes.GetBytes(16)
    
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    
    $encryptor = $aes.CreateEncryptor($key, $iv)
    $encrypted = $encryptor.TransformFinalBlock($Data, 0, $Data.Length)
    
    $result = $salt + $iv + $encrypted
    return [Convert]::ToBase64String($result)
}

# Create Combined Config from Excel
function Create-CombinedConfig {
    param([string]$ExcelPath, [string]$Password)
    
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        
        $workbook = $excel.Workbooks.Open($ExcelPath)
        
        # =================================================================
        # READ EMPLOYEES SHEET (Sheet 1)
        # Expected columns:
        # A: Employee Name
        # B: Password
        # C: Required Hours
        # D: Old Name 1
        # E: Old Name 2 (Optional)
        # F: Old Name 3 (Optional)
        # G: Old Name 4 (Optional)
        # =================================================================
        $employeesSheet = $workbook.Worksheets.Item(1)
        $employees = @()
        $row = 2
        
        while ($employeesSheet.Cells.Item($row, 1).Text -ne "") {
            $employee = [PSCustomObject]@{
                Name = $employeesSheet.Cells.Item($row, 1).Text.Trim()
                Password = $employeesSheet.Cells.Item($row, 2).Text.Trim()
                RequiredHours = $employeesSheet.Cells.Item($row, 3).Text.Trim()
                OldName = $employeesSheet.Cells.Item($row, 4).Text.Trim()
                OldName1 = $employeesSheet.Cells.Item($row, 5).Text.Trim()
                OldName2 = $employeesSheet.Cells.Item($row, 6).Text.Trim()
                OldName3 = $employeesSheet.Cells.Item($row, 7).Text.Trim()
            }
            
            # Only add if Name is not empty
            if ($employee.Name -ne "") {
                $employees += $employee
            }
            $row++
        }
        
        # =================================================================
        # READ DEVICES SHEET (Sheet 2)
        # Expected columns:
        # A: IP
        # B: Username
        # C: Password
        # D: Direction (IN/OUT)
        # E: Remote Connection Link (Optional)
        # =================================================================
        $devicesSheet = $workbook.Worksheets.Item(2)
        $devices = @()
        $row = 2
        
        while ($devicesSheet.Cells.Item($row, 1).Text -ne "") {
            $device = [PSCustomObject]@{
                IP = $devicesSheet.Cells.Item($row, 1).Text.Trim()
                Username = $devicesSheet.Cells.Item($row, 2).Text.Trim()
                Password = $devicesSheet.Cells.Item($row, 3).Text.Trim()
                Direction = $devicesSheet.Cells.Item($row, 4).Text.Trim()
                "Remote Connection Link" = $devicesSheet.Cells.Item($row, 5).Text.Trim()
            }
            
            # Only add if IP is not empty
            if ($device.IP -ne "") {
                $devices += $device
            }
            $row++
        }
        
        $workbook.Close()
        $excel.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
        [System.GC]::Collect()
        
        # Build config object
        $config = [PSCustomObject]@{
            Employees = $employees
            Devices = $devices
            Version = "1.0"
            Created = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        
        # Convert to JSON and encrypt
        $json = $config | ConvertTo-Json -Depth 10
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $encrypted = Encrypt-Data -Data $jsonBytes -Password $Password
        
        return $encrypted
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# GUI Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Attendance System Encryption Tool"
$form.Size = New-Object System.Drawing.Size(650, 480)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 248, 255)

# Title
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Attendance System Configuration Encryptor"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(50, 20)
$titleLabel.Size = New-Object System.Drawing.Size(550, 40)
$titleLabel.TextAlign = "MiddleCenter"
$form.Controls.Add($titleLabel)

# File selection
$fileLabel = New-Object System.Windows.Forms.Label
$fileLabel.Text = "Select Configuration Excel File:"
$fileLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$fileLabel.Location = New-Object System.Drawing.Point(30, 80)
$fileLabel.Size = New-Object System.Drawing.Size(200, 25)
$form.Controls.Add($fileLabel)

$filePathBox = New-Object System.Windows.Forms.TextBox
$filePathBox.Location = New-Object System.Drawing.Point(30, 110)
$filePathBox.Size = New-Object System.Drawing.Size(450, 25)
$filePathBox.ReadOnly = $true
$form.Controls.Add($filePathBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse..."
$browseButton.Location = New-Object System.Drawing.Point(490, 108)
$browseButton.Size = New-Object System.Drawing.Size(100, 30)
$browseButton.BackColor = [System.Drawing.Color]::LightGray
$browseButton.Add_Click({
    $openDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openDialog.Filter = "Excel Files|*.xlsx;*.xls"
    $openDialog.Title = "Select Attendance Configuration Excel File"
    if ($openDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $filePathBox.Text = $openDialog.FileName
    }
})
$form.Controls.Add($browseButton)

# Password
$passLabel = New-Object System.Windows.Forms.Label
$passLabel.Text = "Master Encryption Password:"
$passLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$passLabel.Location = New-Object System.Drawing.Point(30, 160)
$passLabel.Size = New-Object System.Drawing.Size(200, 25)
$form.Controls.Add($passLabel)

$passBox = New-Object System.Windows.Forms.TextBox
$passBox.Location = New-Object System.Drawing.Point(30, 190)
$passBox.Size = New-Object System.Drawing.Size(560, 25)
$passBox.PasswordChar = '*'
$form.Controls.Add($passBox)

$confirmLabel = New-Object System.Windows.Forms.Label
$confirmLabel.Text = "Confirm Password:"
$confirmLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$confirmLabel.Location = New-Object System.Drawing.Point(30, 225)
$confirmLabel.Size = New-Object System.Drawing.Size(200, 25)
$form.Controls.Add($confirmLabel)

$confirmBox = New-Object System.Windows.Forms.TextBox
$confirmBox.Location = New-Object System.Drawing.Point(30, 255)
$confirmBox.Size = New-Object System.Drawing.Size(560, 25)
$confirmBox.PasswordChar = '*'
$form.Controls.Add($confirmBox)

# Output info
$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "Output File: config.enc (same folder as Excel file)"
$outputLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$outputLabel.Location = New-Object System.Drawing.Point(30, 295)
$outputLabel.Size = New-Object System.Drawing.Size(500, 25)
$outputLabel.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($outputLabel)

# Excel Format Info
$formatLabel = New-Object System.Windows.Forms.Label
$formatLabel.Text = "Excel Format: Sheet1='EMPLOYEES' (A:Name, B:Password, C:Hours, D:OldName1, E:OldName2, F:OldName3, G:OldName4) | Sheet2='DEVICES' (A:IP, B:User, C:Pass, D:Direction, E:RemoteLink)"
$formatLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7, [System.Drawing.FontStyle]::Italic)
$formatLabel.Location = New-Object System.Drawing.Point(30, 320)
$formatLabel.Size = New-Object System.Drawing.Size(580, 40)
$formatLabel.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($formatLabel)

# Status
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$statusLabel.Location = New-Object System.Drawing.Point(30, 365)
$statusLabel.Size = New-Object System.Drawing.Size(500, 25)
$form.Controls.Add($statusLabel)

# Encrypt Button
$encryptButton = New-Object System.Windows.Forms.Button
$encryptButton.Text = "ENCRYPT & SAVE"
$encryptButton.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$encryptButton.Location = New-Object System.Drawing.Point(150, 400)
$encryptButton.Size = New-Object System.Drawing.Size(300, 45)
$encryptButton.BackColor = [System.Drawing.Color]::ForestGreen
$encryptButton.ForeColor = [System.Drawing.Color]::White
$encryptButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($filePathBox.Text)) {
        $statusLabel.Text = "ERROR: Please select an Excel file!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    
    if (-not (Test-Path $filePathBox.Text)) {
        $statusLabel.Text = "ERROR: File not found!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    
    if ($passBox.Text -ne $confirmBox.Text) {
        $statusLabel.Text = "ERROR: Passwords do not match!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($passBox.Text)) {
        $statusLabel.Text = "ERROR: Password cannot be empty!"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        return
    }
    
    $statusLabel.Text = "Encrypting... Please wait..."
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Refresh()
    
    $encrypted = Create-CombinedConfig -ExcelPath $filePathBox.Text -Password $passBox.Text
    
    if ($encrypted) {
        $outputPath = Join-Path (Split-Path $filePathBox.Text -Parent) "config.enc"
        [System.IO.File]::WriteAllText($outputPath, $encrypted)
        $statusLabel.Text = "SUCCESS! Config encrypted and saved to: $outputPath"
        $statusLabel.ForeColor = [System.Drawing.Color]::Green
        
        [System.Windows.Forms.MessageBox]::Show(
            "Configuration encrypted successfully!`n`n" +
            "Saved to: $outputPath`n`n" +
            "Employees: $($encrypted.Length) bytes encrypted`n`n" +
            "IMPORTANT: Save your master password securely!",
            "Success",
            "OK",
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    } else {
        $statusLabel.Text = "ERROR: Failed to encrypt. Check Excel format (needs 'EMPLOYEES' and 'DEVICES' sheets)"
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
    }
})
$form.Controls.Add($encryptButton)

# Info button
$infoButton = New-Object System.Windows.Forms.Button
$infoButton.Text = "?"
$infoButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$infoButton.Location = New-Object System.Drawing.Point(610, 10)
$infoButton.Size = New-Object System.Drawing.Size(25, 25)
$infoButton.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Encryption Tool for Attendance System`n`n" +
        "EXPECTED Excel Structure:`n`n" +
        "SHEET1 Name: 'EMPLOYEES'`n" +
        "  A: Employee Name (required)`n" +
        "  B: Password (required)`n" +
        "  C: Required Hours (HH:MM:SS format)`n" +
        "  D: Old Name 1 (optional)`n" +
        "  E: Old Name 2 (optional)`n" +
        "  F: Old Name 3 (optional)`n" +
        "  G: Old Name 4 (optional)`n`n" +
        "SHEET2 Name: 'DEVICES'`n" +
        "  A: IP Address (required)`n" +
        "  B: Username (required)`n" +
        "  C: Password (required)`n" +
        "  D: Direction (IN/OUT) (required)`n" +
        "  E: Remote Connection Link (optional) - Example: accesscontroler.ddns.net:58081`n`n" +
        "Output: config.enc (AES-256 encrypted)`n`n" +
        "Upload config.enc to GitHub for the Attendance System to use.",
        "Help",
        "OK",
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})
$form.Controls.Add($infoButton)

$form.ShowDialog()