# Research Paper Benchmarking Methodology

To publish a scientifically rigorous research paper, your data collection must be systematic, repeatable, and free of initial initialization noise. This document outlines the experimental design and the step-by-step benchmarking procedure for your **9 test scenarios** (3 Identities × 3 Lighting Conditions).

---

## 1. The Experimental Test Matrix (9 Scenarios)

For each of the 3 face identities (e.g., **A**, **B**, **C**), you will evaluate 3 lighting conditions:
1. **Good Lighting:** Even, diffuse front-lighting (approx. 300–500 lux).
2. **Dark:** Dim environment (approx. < 10 lux), where face features are harder to extract.
3. **Accent Light:** Strong directional side-lighting causing heavy shadowing (tests robustness of bbox cropping/alignment).

---

## 2. Experimental Setup Checklist

1. **Build Configuration:** Always run the app in **Profile Mode** (`flutter run --profile`). Never benchmark in Debug mode, as the Dart VM includes developer observation overhead that adds 50ms+ to latency.
2. **Hardware State:** 
   * Ensure the mobile device is not charging (charging triggers thermal throttling which artificially degrades CPU/FPS performance).
   * Close all background applications on the phone to prevent RAM and CPU usage spikes from other apps.

---

## 3. Step-by-Step Testing Procedure

Follow this exact sequence for each of the 9 scenarios (e.g., Scenario: **Identity A under Dark Lighting**):

### Step 1: Initialize the Environment & App
1. Position the target subject (**Identity A**) in the designated lighting condition (**Dark**).
2. Open the app on the phone and navigate to the **Recognition Screen**.
3. Point the camera at the subject. Let it run for 5 seconds to warm up the camera hardware, camera auto-exposure, and the TFLite runtime.

### Step 2: Start the System Profiler (CPU & RAM)
1. Open PowerShell on your computer, navigate to the project folder, and run:
   ```powershell
   .\profile_telementry.ps1
   ```
2. When prompted:
   * **Face Identity:** Enter `A`
   * **Lighting Condition:** Enter `Dark`
3. The script will start logging to `perf_ID_A_Dark.csv`.

### Step 3: Trigger the Pipeline Profiler (Latency & FPS)
1. In the app UI, tap the **"Start Telemetry"** button in the OSD (On-Screen Display).
2. Ensure the face is consistently tracked inside the camera frame.
3. Let both trackers run concurrently for exactly **30 seconds** (about 120-150 processed frames).

### Step 4: Stop the Test
1. In the app UI, tap the **"Stop Telemetry"** button. A "Telemetry Results" dialog will appear on the screen, and the raw statistics table will print to your IDE console.
2. In the PowerShell terminal, press **`Ctrl + C`** to stop the system logging.

---

## 4. How to Consolidate the Data for Your Paper

For each test scenario, you now have two sets of output:

### Data Source 1: System Performance (`perf_ID_A_Dark.csv`)
This contains a log of CPU and RAM usage sampled every second. In your paper:
* **CPU Usage:** Calculate the **Average (Mean) CPU %** and **Peak (Max) CPU %** during the test run.
* **RAM Usage:** Calculate the **Average Memory PSS (MB)**.

### Data Source 2: Pipeline Latency (IDE Console or OSD Dialog)
When you tapped "Stop Telemetry", the app calculated the statistics for all frames processed during that window:
* **T_pre (Preprocessing):** Mean ± StdDev (ms).
* **T_infer (Inference):** Mean ± StdDev (ms).
* **T_post (Postprocessing):** Mean ± StdDev (ms).
* **Throughput (AI FPS):** Mean ± StdDev (FPS).

### Suggested Publication Data Table Structure

Combine these metrics into a table in your paper like this:

| Scenario ID | Identity | Lighting | CPU Mean (%) | RAM Avg (MB) | $T_{pre}$ Mean (ms) | $T_{infer}$ Mean (ms) | $T_{post}$ Mean (ms) | Throughput (FPS) |
|---|---|---|---|---|---|---|---|---|
| 1 | A | Good | 215.4% | 263.2 MB | 14.8 ± 1.2 | 120.4 ± 3.4 | 0.2 ± 0.05 | 6.5 ± 0.3 |
| 2 | A | Dark | 212.1% | 263.5 MB | 15.1 ± 1.5 | 120.6 ± 3.1 | 0.2 ± 0.05 | 6.4 ± 0.4 |
| 3 | A | Accent | ... | ... | ... | ... | ... | ... |
| 4 | B | Good | ... | ... | ... | ... | ... | ... |
| ... | ... | ... | ... | ... | ... | ... | ... | ... |

---

## 5. Scientific Notes for the Paper's Analysis Section

When writing your analysis, here are the key engineering points to explain your results:
1. **Consistency of $T_{infer}$:** Regardless of identity or lighting, the inference time ($T_{infer}$) should remain virtually constant (e.g., ~120ms). This is because the feed-forward pass of a convolutional neural network (CNN) executes the exact same mathematical operations (matrix multiplications) on every 112x112 input tensor, regardless of its visual content.
2. **Impact of Dark/Accent Lighting on $T_{pre}$:** In low lighting or side lighting, face detection ($T_{pre}$) might experience minor variations because the Face Detector (ML Kit BlazeFace) may require slightly more cycles to resolve bounding box edges, or fail to detect a face entirely (resulting in skipped frames).
3. **Multi-threaded CPU Load (>100%):** Explain that CPU usage exceeds 100% because the background Isolate runs TFLite with XNNPack multi-threading (`threads = 4`). This utilizes multiple physical cores on the mobile chipset, ensuring high throughput.
