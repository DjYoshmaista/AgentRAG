#!/bin/bash

# Helper script for detailed service testing called by status.sh

set -euo pipefail # Exit on error, undefined vars, pipe failures

# === Configuration (Inherit from environment or set defaults) ===
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)}"
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/logs}"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/shared/configs/system.yaml}"

# === Logging Setup ===
# Determine if we are running standalone or called by status.sh
STANDALONE_LOG_FILE=""

if [[ -z "${MAIN_STATUS_LOG:-}" ]]; then
    # Case 1: Running standalone (MAIN_STATUS_LOG not set by status.sh)
    # Ensure the logs directory exists (it should, but be safe)
    mkdir -p "$LOG_DIR"

    # Create a unique log file for this standalone run
    # Use printf -v to safely assign the formatted string to a variable
    printf -v TIMESTAMP "%(%Y%m%d-%H%M%S)T" -1
    STANDALONE_LOG_FILE="${LOG_DIR}/test-service-standalone-${TIMESTAMP}.log"

    # Redirect all stdout and stderr for this script to the standalone log file
    # Use the full path variable to avoid any expansion issues within exec
    exec > "${STANDALONE_LOG_FILE}" 2>&1

    # Log initial messages to the newly created log file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Running test-service.sh standalone."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log file: ${STANDALONE_LOG_FILE}"
else
    # Case 2: Called by status.sh (MAIN_STATUS_LOG is set)
    # No redirection needed here, status.sh handles it via 'tee'.
    # The 'log' function will append to the main status log.
    # Optionally log the start:
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] test-service.sh started by status.sh" >> "${MAIN_STATUS_LOG}"
fi
# === End Logging Setup ===

# === Colors (Inherit or define) ===
# Note: Colors might not appear in log files, but will in terminal if run via status.sh's tee
GREEN="${GREEN:-$(tput setaf 2 2>/dev/null || echo '')}"
RED="${RED:-$(tput setaf 1 2>/dev/null || echo '')}"
YELLOW="${YELLOW:-$(tput setaf 3 2>/dev/null || echo '')}"
BLUE="${BLUE:-$(tput setaf 4 2>/dev/null || echo '')}"
NC="${NC:-$(tput sgr0 2>/dev/null || echo '')}"

# === Functions ===
# Use MAIN_STATUS_LOG if set (by status.sh), otherwise STANDALONE_LOG_FILE should be used for appending.
# The 'tee -a' part in the original 'log' function might be redundant now,
# but it's safer to keep it as it works for both cases.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [TEST] $*" | tee -a "${MAIN_STATUS_LOG:-/dev/null}"
    # If MAIN_STATUS_LOG isn't set (standalone), tee to /dev/null effectively just echoes to stdout (which is redirected)
}

print_test_result() {
    local icon=$1
    local color=$2
    local test_name=$3
    local result_msg=$4
    local log_level=${5:-INFO}
    echo -e "  ${color}${icon}${NC} ${test_name}: ${result_msg}"
    # Log the result using the unified log function
    log "[$log_level] $test_name: $result_msg"
}

run_test() {
    local test_name=$1
    shift
    local cmd=("$@")

    log "Running test: $test_name"
    log "Command: ${cmd[*]}"

    if timeout 10 "${cmd[@]}" > /dev/null 2>&1; then
        print_test_result "✓" "$GREEN" "$test_name" "PASSED"
        return 0
    else
        local exit_code=$?
        print_test_result "✗" "$RED" "$test_name" "FAILED (Exit code: $exit_code)" "ERROR"
        log "ERROR: Test '$test_name' failed with command: ${cmd[*]}"
        return 1
    fi
}

# --- Service Specific Tests ---

test_orchestrator_functionality() {
    local port=${1:-8001}
    local base_url="http://localhost:$port"

    print_test_result "ℹ" "$BLUE" "Orchestrator ($port)" "Running detailed tests..."
    log "Testing Orchestrator functionality on $base_url"

    # 1. Health Check
    run_test "Health Endpoint" curl -s -f "$base_url/health"

    # 2. Status Endpoint
    run_test "Status Endpoint" curl -s -f "$base_url/status"

    # 3. Task Creation (Simple)
    # Use a lightweight model if available, or a simple prompt
    local test_prompt="Status check: Respond with 'OK' only."
    local test_task_json='{"task_type": "llm_inference", "description": "Status check task", "parameters": {"model": "llama2", "prompt": "'"$test_prompt"'"}}'
    run_test "Task Creation" curl -s -f -X POST -H "Content-Type: application/json" -d "$test_task_json" "$base_url/tasks"
    # Note: Checking task result would require getting the task ID from the response and polling, which is complex for a status check.
    # This test mainly checks if the endpoint accepts the request.
}

test_model_gateway_functionality() {
    local port=${1:-8070}
    local base_url="http://localhost:$port"

    print_test_result "ℹ" "$BLUE" "Model Gateway ($port)" "Running detailed tests..."
    log "Testing Model Gateway functionality on $base_url"

    # 1. Health Check
    run_test "Health Endpoint" curl -s -f "$base_url/health"

    # 2. List Models
    run_test "List Models" curl -s -f "$base_url/models"

    # 3. Simple Generation (if a model is loaded/pulled)
    # This is a bit risky as it consumes resources, but useful for status.
    # We'll use a very short prompt and hope a default model like llama2 is available or pulled.
    local test_prompt="OK"
    local test_gen_json='{"model": "llama2", "prompt": "'"$test_prompt"'", "stream": false}'
    # Use -m 30 to timeout the curl command itself if the generation hangs
    if timeout 30 curl -s -f -m 25 -X POST -H "Content-Type: application/json" -d "$test_gen_json" "$base_url/generate" > /dev/null 2>&1; then
         print_test_result "✓" "$GREEN" "Simple Generation" "PASSED (Model responded)"
         log "INFO: Simple generation test successful."
    else
        local exit_code=$?
        # It's common for this to fail if no model is loaded/pulled, so make it a warning.
        print_test_result "⚠" "$YELLOW" "Simple Generation" "RESULT INCONCLUSIVE (Exit code: $exit_code, might need model pull)" "WARN"
        log "WARN: Simple generation test inconclusive (Exit code: $exit_code). This might be OK if no model is loaded yet."
    fi
}

test_vector_engine_functionality() {
    local port=${1:-8080}
    local base_url="http://localhost:$port"

    print_test_result "ℹ" "$BLUE" "Vector Engine ($port)" "Running detailed tests..."
    log "Testing Vector Engine functionality on $base_url"

    # 1. Basic HTTP Response (as the current Zig server just responds OK)
    # The current implementation in `src/main.zig` just sends a basic JSON response to any request.
    run_test "Basic HTTP Response" curl -s -f "$base_url/"

    # 2. (Future) If a /search endpoint existed, we could test it with dummy data.
    # Example (commented out as endpoint likely doesn't exist yet):
    # local test_search_json='{"type": "search", "vector": [0.1, 0.2, 0.3], "top_k": 1}'
    # run_test "Search Endpoint" curl -s -f -X POST -H "Content-Type: application/json" -d "$test_search_json" "$base_url/search"
}


# === Main Execution ===

log "==== Starting Detailed Service Tests ===="

# --- Determine Ports (Simple method, could be improved) ---
# Orchestrator
ORCHESTRATOR_PORT=""
if [[ -f "$CONFIG_FILE" ]]; then
    # Basic grep/awk to find port, might not be robust for complex YAML
    ORCHESTRATOR_PORT=$(awk '/services:/,/orchestrator:/ { if (/port:/) { gsub(/ /, "", $2); print $2; exit } }' "$CONFIG_FILE" 2>/dev/null || echo "8001")
fi
ORCHESTRATOR_PORT=${ORCHESTRATOR_PORT:-8001} # Default fallback

# Model Gateway
MODEL_GATEWAY_PORT=""
if [[ -f "$CONFIG_FILE" ]]; then
    MODEL_GATEWAY_PORT=$(awk '/services:/,/model_gateway:/ { if (/port:/) { gsub(/ /, "", $2); print $2; exit } }' "$CONFIG_FILE" 2>/dev/null || echo "8070")
fi
MODEL_GATEWAY_PORT=${MODEL_GATEWAY_PORT:-8070}

# Vector Engine
VECTOR_ENGINE_PORT=""
if [[ -f "$CONFIG_FILE" ]]; then
    VECTOR_ENGINE_PORT=$(awk '/services:/,/vector_engine:/ { if (/port:/) { gsub(/ /, "", $2); print $2; exit } }' "$CONFIG_FILE" 2>/dev/null || echo "8080")
fi
VECTOR_ENGINE_PORT=${VECTOR_ENGINE_PORT:-8080}


# --- Run Tests ---
log "Initiating tests for Orchestrator on port $ORCHESTRATOR_PORT"
test_orchestrator_functionality "$ORCHESTRATOR_PORT"

log "Initiating tests for Model Gateway on port $MODEL_GATEWAY_PORT"
test_model_gateway_functionality "$MODEL_GATEWAY_PORT"

log "Initiating tests for Vector Engine on port $VECTOR_ENGINE_PORT"
test_vector_engine_functionality "$VECTOR_ENGINE_PORT"

# --- Tests for Message Broker, Ollama, NATS (Basic) ---
# These are harder to test deeply without specific client tools or complex scripts.
# Message Broker (Go/NATS): Check PID is enough for status.sh, deep test would need NATS client.
# Ollama: Check PID and /api/tags is enough for status.sh, deep test is Model Gateway's job.
# NATS: Check PID is enough for status.sh, deep test would need NATS client.

log "==== Detailed Service Tests Completed ===="

# Provide a final message depending on how the script was run
if [[ -n "${STANDALONE_LOG_FILE:-}" ]]; then
    # When running standalone, this echo goes into the log file due to 'exec' redirection
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Detailed test results for this standalone run are logged to: ${STANDALONE_LOG_FILE}"
    # If you want a confirmation on the terminal when running standalone, uncomment the next line:
    # echo "Standalone test results logged to: ${STANDALONE_LOG_FILE}" >&2
else
    # When called by status.sh, this message goes through status.sh's 'tee'
    echo "Detailed test results were appended to the main status log."
fi
# --- End of script ---