$package = "com.ferryhasan.realtime_face_recognition.v1"

# Prompt for experimental variables
Write-Host "=== Research Benchmark Setup ===" -ForegroundColor Green
$identity = Read-Host "Enter Face Identity (e.g. A, B, C)"
$lighting = Read-Host "Enter Lighting Condition (e.g. Good, Dark, Accent)"
$csvFile = "perf_ID_${identity}_${lighting}.csv"

# Write CSV Headers
"Timestamp,CPU_Percentage,Memory_PSS_MB" | Out-File -FilePath $csvFile -Encoding utf8

Write-Host "Getting Process ID..." -ForegroundColor Green
$pidStr = (adb shell pidof $package).Trim()

if ([string]::IsNullOrEmpty($pidStr)) {
    Write-Error "App is not running! Please open the app on your device first."
    exit
}

Write-Host "Logging performance data for $package (PID: $pidStr) to $csvFile..." -ForegroundColor Cyan
Write-Host "Press [Ctrl+C] to stop logging." -ForegroundColor Yellow
while ($true) {
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    
    # 1. Capture CPU (get the specific PID line from top and parse using regex)
    $cpu = "0.0"
    $topOutput = adb shell top -n 1 -p $pidStr | Select-String -Pattern $pidStr
    if ($topOutput -match '([RSDIT])\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+\S+\s+com\.ferryhasan') {
        $cpu = $Matches[2]
    }

    # 2. Capture Memory (dumpsys meminfo TOTAL PSS row)
    $memOutput = adb shell dumpsys meminfo $package | Select-String -Pattern "TOTAL PSS:"
    if (-not $memOutput) {
        # Fallback to the general TOTAL row if TOTAL PSS: is not present
        $memOutput = adb shell dumpsys meminfo $package | Select-String -Pattern "TOTAL\s+\d+"
    }

    if ($memOutput) {
        if ($memOutput -match 'TOTAL PSS:\s+(\d+)') {
            $memKb = [double]$Matches[1]
            $memMb = [math]::Round($memKb / 1024, 2)
        } elseif ($memOutput -match 'TOTAL\s+(\d+)') {
            $memKb = [double]$Matches[1]
            $memMb = [math]::Round($memKb / 1024, 2)
        } else {
            $memMb = "0.0"
        }
    } else {
        $memMb = "0.0"
    }

    # Print to console
    Write-Host "[$timestamp] CPU: $cpu% | RAM: $memMb MB"
    
    # Append to CSV
    "$timestamp,$cpu,$memMb" | Out-File -FilePath $csvFile -Append -Encoding utf8
    
    Start-Sleep -Seconds 1
}
