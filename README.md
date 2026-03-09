# CamelClaw 🐪🦞

CamelClaw is an autonomous Perl-based agent designed for high-speed Linux and ESP-IDF development. It bridges the gap between Large Language Models (LLMs) and local hardware, providing a specialized environment for building, flashing, and monitoring firmware on ESP32 devices (specifically optimized for ESP32-C3).

## Features

- **Autonomous Loop:** Operates in a Research -> Strategy -> Execution cycle.
- **ESP-IDF Integration:** Built-in tools for project creation, component management, C source generation, building, flashing, and real-time monitoring.
- **Skill System:** Modular toolsets (`System`, `ESP32`, `ModifySelf`) that the agent can utilize to interact with the host and target.
- **Robust Monitoring:** Background logging with automated success/error detection and unique session-based log files.
- **Interactive UI:** Curses-based terminal interface for rich user input and real-time guidance.
- **Model Flexibility:** Supports Google Cloud Vertex AI (Gemini 2.0 Flash/Lite) and Local Models (OpenAI-compatible APIs).

## Prerequisites

### 1. Perl Dependencies
Ensure you have Perl installed (v5.30+) along with the following CPAN modules:
```bash
sudo apt-get install libjson-maybexs-perl libhttp-tiny-perl libterm-readkey-perl 
                     libcurses-ui-perl libfile-slurper-perl libtext-wrap-perl
```

### 2. ESP-IDF Environment
CamelClaw expects ESP-IDF v5.5.1 to be installed in `$HOME/esp/v5.5.1`.
```bash
# Example setup (adjust as needed for your system)
mkdir -p ~/esp
cd ~/esp
git clone -b v5.5.1 --recursive https://github.com/espressif/esp-idf.git v5.5.1
cd v5.5.1
./install.sh esp32c3
```

### 3. Google Cloud SDK (Optional)
Required if using Vertex AI models.
```bash
# Authenticate with your GCP project
gcloud auth login
gcloud auth application-default login
```

## Setup & Configuration

### Environment Configuration
CamelClaw uses a `.env` file for configuration. A template is provided in `.env.example`.

1. **Create your .env file:**
   ```bash
   cp .env.example .env
   ```
2. **Edit `.env`** with your specific details (GCP Project, Region, local paths).

### How it Works (The Perl Way)
- **`.env`**: Stores your private credentials and local paths. This file is ignored by Git.
- **`config.pl`**: The central configuration engine. It automatically loads variables from `.env` and enforces mandatory checks for `GCP_PROJECT_ID`, `GCP_REGION`, `IDF_PATH`, and `PROJECTS_ROOT`.
- **Environment Overrides**: You can still override any setting directly from the shell:
  ```bash
  GCP_REGION=europe-west1 perl camelclaw.pl
  ```

### Variable Reference
| Variable | Description |
|----------|-------------|
| `GCP_PROJECT_ID` | **Mandatory.** Your Google Cloud Project ID. |
| `GCP_REGION` | **Mandatory.** GCP Region for Vertex AI (e.g., `us-central1`). |
| `IDF_PATH` | **Mandatory.** Path to ESP-IDF installation (e.g., `/home/user/esp/v5.5.1`). |
| `PROJECTS_ROOT` | **Mandatory.** Directory where CamelClaw projects are stored. |
| `LOCAL_API_URL` | URL for local OpenAI-compatible API. |
| `GEMINI_LOCAL_TOKEN` | Bearer token for local API. |
| `GEMINI_MODEL` | Default model (e.g., `gemini-2.0-flash-001`). |

### Starting CamelClaw
Run the main script:
```bash
perl camelclaw.pl
```
If you want to skip the menu and provide a goal immediately:
```bash
perl camelclaw.pl --model=gemini-2.0-flash-001 "Create a blink project for ESP32-C3 on GPIO 8"
```

## How It Works

### Architecture
- **`camelclaw.pl`**: The entry point. Handles command-line arguments and the startup menu.
- **`Camel::Kernel`**: The orchestrator. Manages the turn loop, history, background processes, and tool execution.
- **`Camel::Brain`**: The LLM interface. Handles communication with Vertex AI or local APIs, including specialized prompt engineering for function calling.
- **`skills/`**:
    - **`System.pm`**: General Linux utilities (read/write files, run shell commands).
    - **`ESP32.pm`**: Deep integration with `idf.py`. Manages the full lifecycle of an ESP32 project.
    - **`ModifySelf.pm`**: Allows the agent to improve its own skills or the kernel logic.

### The Debugging Protocol
CamelClaw includes a built-in "Debugging Protocol" that helps the agent distinguish between:
- **Compilation Errors:** Missing headers or syntax issues.
- **Build Failures:** Linker errors or missing dependencies.
- **Communication Failures:** Serial port conflicts or incorrect wiring.

The kernel appends "Hints" to tool outputs to guide the model toward the correct root cause, preventing it from hallucinating serial port issues when the code simply doesn't compile.

### Background Processes
When the agent starts a `monitor` or `flash` task, the Kernel forks a background process. 
- Logs are saved to `logs/monitor_$PID.log`.
- The Kernel scans logs for `stop_patterns` (e.g., "APP_START") to automatically notify the agent of success.
- All background processes are automatically cleaned up when the session ends.

## Usage Tips
- **Interruptions:** Press `ESC` during thinking or execution to provide real-time guidance or course corrections.
- **Persistent Projects:** All projects are stored in the `projects/` directory. The agent can "see" existing projects and resume work on them.
- **Logs:** Check `logs/monitor.log` (or the specific PID log) for detailed output from the ESP32 device.

---
*Developed for the CamelClaw Project.*
