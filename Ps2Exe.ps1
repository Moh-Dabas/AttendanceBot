Remove-Item "D:\Work\AttendanceSystem\AttendanceSystem-V1.4.exe" -force -ea silentlycontinue
Remove-Item "D:\Work\AttendanceSystem\AttendanceSystem-V1.4.exe.config" -force -ea silentlycontinue

ps2exe -inputFile "D:\Work\AttendanceSystem\SecureAttendance.ps1" `
       -outputFile "D:\Work\AttendanceSystem\AttendanceSystem-V1.4.exe" `
       -noConsole `
       -requireAdmin `
       -x64 `
	   -supportOS `
	   -winFormsDPIAware `
	   -DPIAware `
       -noOutput `
       -version "1.4" `
       -copyright "Mohammad Dabas" `
	   -iconFile "D:\Work\AttendanceSystem\machine.ico" `
	   -title "Attendance System"

Remove-Item "D:\Work\AttendanceSystem\AttendanceSystem-V1.4.exe.config" -force -ea silentlycontinue