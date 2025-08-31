#!/bin/bash

# Enhanced Status Script for the Multi-Agent System
# Provides detailed status and basic functionality checks

set -euo pipefail # Exit on error, undefined vars, pipe failures

# === Configuration ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Fix PROJECT_ROOT calculation: Go up two levels from scripts directory
# shared/scripts -> shared -> (project root)
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
LOG_DIR="$PROJECT_ROOT/logs"
CONFIG_FILE="$PROJECT_ROOT/shared/configs/system.yaml"

# === Logging Setup ===
# Main log file for this status check run
MAIN_STATUS_LOG="$LOG_DIR/status-$(date +%Y%m%d-%H%M%S).log"
# Redirect all output (stdout and stderr) to the log file AND display on console
exec > >(tee -a "$MAIN_STATUS_LOG") 2>&1

# Function to add timestamped logs (useful if you want logs within functions to also go to the main file)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUS] $*" # This output goes through 'tee'
}

# === Colors ===
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Functions ===

print_header() {
    echo -e "${BLUE}==== $1 ====${NC}"
    log "HEADER: $1"
}

print_status() {
    local icon=$1
    local color=$2
    local message=$3
    local log_level=${4:-INFO} # Default log level is INFO
    echo -e "${color}${icon}${NC} ${message}"
    log "[$log_level] $message" # Ensure messages are also logged via the 'tee' mechanism
}

print_service_status() {
    local service_name=$1
    local pid_file="$LOG_DIR/${service_name}.pid"
    local url=$2
    local test_details=${3:-""} # Optional details string

    log "Checking status for $service_name (PID file: $pid_file, URL: $url)"

    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        log "Found PID: $pid"
        if kill -0 "$pid" 2>/dev/null; then
            log "Process $pid is running."
            if [ -n "$url" ] && timeout 5 curl -s -f -o /dev/null "$url"; then
                log "Health check URL $url responded successfully."
                print_status "✓" "$GREEN" "$service_name (PID: $pid) - Running & Responsive ${test_details}"
            else
                log "WARN: Process running but health check failed or URL not provided."
                print_status "⚠" "$YELLOW" "$service_name (PID: $pid) - Running but not responsive ${test_details}" "WARN"
            fi
        else
            log "ERROR: Process $pid not found (stale PID file)."
            print_status "✗" "$RED" "$service_name - Process not found (stale PID file)" "ERROR"
        fi
    else
        log "INFO: No PID file found for $service_name."
        print_status "✗" "$RED" "$service_name - Not running (no PID file)"
    fi
}

# Extract port from system.yaml (basic parsing)
extract_port() {
    local service_key=$1
    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "WARN: Config file '$CONFIG_FILE' not found. Using default ports."
        case "$service_key" in
            "orchestrator") echo "8001" ;;
            "model_gateway") echo "8070" ;; # Use underscore as in YAML
            "vector_engine") echo "8080" ;;
            *) echo "" ;;
        esac
        return
    fi
    # This is a simple extraction, might need improvement for complex YAML
    # Adjust grep pattern to match the YAML structure (underscores)
    local pattern=""
    case "$service_key" in
        "model_gateway") pattern="model_gateway" ;;
        "vector_engine") pattern="vector_engine" ;;
        *) pattern="$service_key" ;; # orchestrator etc.
    esac

    grep -A 5 "  ${pattern}:" "$CONFIG_FILE" | grep "port:" | awk '{print $2}' | head -n 1
}


# === Main Execution ===

log "=== Starting Enhanced System Status Check ==="

print_header "System Overview"
echo "Log File: $MAIN_STATUS_LOG"
echo "Project Root: $PROJECT_ROOT"
echo "Configuration File: $CONFIG_FILE"
echo ""

print_header "Core Service Status"

# Extract ports from config, adjusting keys for YAML structure
ORCHESTRATOR_PORT=$(extract_port "orchestrator")
# The YAML uses underscores
MODEL_GATEWAY_PORT=$(extract_port "model_gateway")
VECTOR_ENGINE_PORT=$(extract_port "vector_engine")
MESSAGE_BROKER_PORT=$(extract_port "message_broker")

# Check core services with basic status
print_service_status "orchestrator" "http://localhost:${ORCHESTRATOR_PORT:-8001}/health"
print_service_status "model-gateway" "http://localhost:${MODEL_GATEWAY_PORT:-8070}/health"
print_service_status "vector-engine" "http://localhost:${VECTOR_ENGINE_PORT:-8080}" # No /health, just port check
print_service_status "message-broker" "" # No standard URL check defined, relies on PID
print_service_status "ollama" "http://localhost:11434" # Standard Ollama port
print_service_status "nats" "" # NATS health check is complex, relies on PID for now

print_header "Detailed Service Tests"

# Run detailed tests using the helper script
log "Running detailed service tests..."
if [[ -x "$SCRIPT_DIR/test-service.sh" ]]; then
    log "Executing $SCRIPT_DIR/test-service.sh"
    # Pass the main log file path to the helper script
    MAIN_STATUS_LOG="$MAIN_STATUS_LOG" "$SCRIPT_DIR/test-service.sh" || log "WARN: Detailed tests script encountered issues or failed."
else
    log "WARN: Detailed test script '$SCRIPT_DIR/test-service.sh' not found or not executable."
    print_status "!" "$YELLOW" "Detailed tests script not found. Skipping advanced checks."
fi

print_header "System Status Summary"
echo "Status check completed. Detailed logs are in: $MAIN_STATUS_LOG"
log "=== System Status Check Completed ==="