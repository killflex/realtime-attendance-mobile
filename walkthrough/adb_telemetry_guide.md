# Guide: Profiling App CPU & Memory Usage Using ADB

This guide provides instructions and scripts to profile your Flutter application's CPU and memory usage using Android Debug Bridge (ADB). This data can be directly plotted in Excel/Origin for your research paper.

The package identifier for your application is:
`com.ferryhasan.realtime_face_recognition.v1`

---

## 1. Quick Terminal Commands

Run these commands in your terminal (PowerShell or Bash) while the device is connected and the app is running:

### A. Find the App's Process ID (PID)
Every time the app restarts, it is assigned a new PID. Get the current PID with:
```bash
adb shell pidof com.ferryhasan.realtime_face_recognition.v1
```

### B. Live CPU Usage Monitoring
To continuously track CPU threads and total CPU percentage of the app in real-time (updating every 1 second):
```bash
adb shell top -p $(adb shell pidof com.ferryhasan.realtime_face_recognition.v1) -d 1
```
*Note: In Windows PowerShell, if the subshell syntax doesn't resolve, run `adb shell pidof com.ferryhasan.realtime_face_recognition.v1` first to get the number (e.g. `12709`), then run:*
```powershell
adb shell top -p 12709 -d 1
```

### C. Detailed Memory Breakdown (RAM)
To capture a precise memory snapshot (showing JVM Heap, Native Heap, Graphics/GLES memory, and system overhead):
```bash
adb shell dumpsys meminfo com.ferryhasan.realtime_face_recognition.v1
```
* **TOTAL PSS (Proportional Set Size):** The most realistic measure of physical RAM occupied by your app.
* **Native Heap:** Memory used by native C++ code (TensorFlow Lite, OpenGLES textures, and image arrays).
* **Code/Graphics:** Memory consumed by Dart compiled binaries and OpenGL shaders.

---

## 2. Automated Logging Script (For Excel/Plotting)

To get data for a research paper, you need to collect metrics over time (e.g., during a 30-second continuous face recognition session). 

Create a file named `profile_telemetry.ps1` inside your project directory (or run the snippet below in your terminal). This PowerShell script logs the **CPU %** and **Memory (PSS in MB)** every second into a `.csv` file.

### PowerShell Script (`profile_telemetry.ps1`)
```powershell
$package = "com.ferryhasan.realtime_face_recognition.v1"
$csvFile = "app_performance_telemetry.csv"

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
    
    # 1. Capture CPU (grep the specific PID line from top)
    $topOutput = adb shell top -n 1 -p $pidStr | Select-String -Pattern $pidStr
    if ($topOutput -match '\s+(\d+(\.\d+)?)\s+(\d+(\.\d+)?)\s+com\.ferryhasan') {
        # Extracts the CPU% column
        $cpu = $Matches[1]
    } else {
        # Fallback parse if regex matches differently on your Android version
        $cpu = "0.0"
    }

    # 2. Capture Memory (dumpsys meminfo TOTAL row)
    $memOutput = adb shell dumpsys meminfo $package | Select-String -Pattern "TOTAL:"
    if ($memOutput -match 'TOTAL:\s+(\d+)') {
        # Pss is in KB, convert to MB
        $memKb = [double]$Matches[1]
        $memMb = [math]::Round($memKb / 1024, 2)
    } else {
        $memMb = "0.0"
    }

    # Print to console
    Write-Host "[$timestamp] CPU: $cpu% | RAM: $memMb MB"
    
    # Append to CSV
    "$timestamp,$cpu,$memMb" | Out-File -FilePath $csvFile -Append -Encoding utf8
    
    Start-Sleep -Seconds 1
}
```

### How to use this script:
1. Run the app in **Profile Mode** (`flutter run --profile`) on your device.
2. Open a PowerShell window, navigate to your workspace, and run:
   ```powershell
   .\profile_telemetry.ps1
   ```
3. Let it log for a minute while you switch between the different quantization models (Float32 vs dynamic range) and hardware modes (CPU vs GPU).
4. Press `Ctrl+C` to terminate logging.
5. Open `app_performance_telemetry.csv` in Excel or Python Pandas to plot CPU load and Memory consumption graphs.
