#!/bin/bash

# Start script for the multi-agent system
# Enhanced with extensive logging

set -e

# === Logging Setup ===
LOG_DIR="logs"
MAIN_LOG="$LOG_DIR/start-system-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STARTUP] $*" | tee -a "$MAIN_LOG"
}

# Function to log errors and exit
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$MAIN_LOG" >&2
    exit 1
}

# Function to log warnings
log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $*" | tee -a "$MAIN_LOG"
}

# Redirect all output to the main log file as well as console
exec >> >(tee -a "$MAIN_LOG") 2>&1

# === Original Colors (for console output) ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
    log "$1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log_warning "$1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log_error "$1"
}

# Function to check if a port is available
check_port() {
    if command -v lsof >/dev/null && lsof -Pi :$1 -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 1 # Port is in use
    else
        return 0 # Port is free
    fi
}

# Function to wait for service to be ready with extensive logging
wait_for_service() {
    local url=$1
    local service_name=$2
    local max_attempts=15
    local attempt=1

    log "Waiting for $service_name to be ready at $url..."
    print_status "Waiting for $service_name to be ready..."
    while [ $attempt -le $max_attempts ]; do
        log "Attempt $attempt/$max_attempts: Checking $url"
        if curl -s -f -m 5 "$url" >/dev/null 2>&1; then
            log "SUCCESS: $service_name is ready at $url"
            print_status "$service_name is ready!"
            return 0
        else
            local exit_code=$?
            log "Attempt $attempt failed. curl exit code: $exit_code"
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    log "WARNING: $service_name took longer than expected to start or is not responding correctly at $url"
    print_warning "$service_name took longer than expected to start"
    return 1
}

# Check dependencies
print_status "Checking dependencies..."
log "Checking for required tools: go, zig, python3"

# Check if Go is installed
if ! command -v go &> /dev/null; then
    print_error "Go is not installed. Please install Go 1.21 or later."
fi

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    print_error "Zig is not installed. Please install Zig 0.11 or later."
fi

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 is not installed. Please install Python 3.9 or later."
fi

# Create build and log directories
log "Creating build and log directories"
mkdir -p build/
mkdir -p logs/

print_status "Starting Multi-Agent Orchestration System..."

# Start NATS server (if available)
print_status "Starting NATS server..."
if command -v nats-server &> /dev/null; then
    if check_port 4222; then
        log "Starting NATS server on port 4222"
        nats-server --jetstream --store_dir ./data/nats > logs/nats.log 2>&1 &
        NATS_PID=$!
        echo $NATS_PID > logs/nats.pid
        log "NATS started with PID $NATS_PID"
        sleep 2
        print_status "NATS started with PID $NATS_PID"
    else
        print_warning "Port 4222 is already in use (NATS might already be running)"
        log "Port 4222 is in use. Assuming NATS is running."
    fi
else
    print_warning "NATS server not found. Message broker will use default NATS connection."
    log "NATS server binary not found. Message broker will attempt default connection."
fi

# Start Ollama (if not already running)
print_status "Checking Ollama..."
if ! pgrep -f ollama >/dev/null; then
    if command -v ollama &> /dev/null; then
        print_status "Starting Ollama..."
        log "Starting Ollama server"
        ollama serve > logs/ollama.log 2>&1 &
        OLLAMA_PID=$!
        echo $OLLAMA_PID > logs/ollama.pid
        log "Ollama started with PID $OLLAMA_PID"
        sleep 3
        print_status "Ollama started with PID $OLLAMA_PID"
        # Pull a default model if it doesn't exist
        # Note: This part might need adjustment based on your default model
        # if ! ollama list | grep -q llama2; then
        #     print_status "Pulling llama2 model (this may take a while)..."
        #     log "Pulling llama2 model"
        #     ollama pull llama2 &
        # fi
    else
        print_warning "Ollama not found. Please install Ollama for LLM functionality."
        log "Ollama binary not found. LLM functionality will be unavailable."
    fi
else
    print_status "Ollama is already running"
    log "Detected running Ollama process. Not starting a new instance."
fi

# Start Vector Engine
print_status "Starting Vector Engine..."
if check_port 8080; then
    log "Starting Vector Engine on port 8080"
    ./build/vector-engine > logs/vector-engine-startup.log 2>&1 &
    VECTOR_PID=$!
    echo $VECTOR_PID > logs/vector-engine.pid
    log "Vector Engine started with PID $VECTOR_PID"
    print_status "Vector Engine started with PID $VECTOR_PID"
    sleep 1
else
    print_warning "Port 8080 is already in use"
    log "Port 8080 is in use. Cannot start Vector Engine."
fi

# Start Message Broker
print_status "Starting Message Broker..."
# Note: Message broker connects to NATS (usually 4222), it doesn't necessarily need its own port checked like 8090
# unless it exposes an API. The Go code doesn't seem to expose one.
log "Starting Message Broker (connects to NATS)"
./build/message-broker > logs/message-broker-startup.log 2>&1 &
BROKER_PID=$!
echo $BROKER_PID > logs/message-broker.pid
log "Message Broker started with PID $BROKER_PID"
print_status "Message Broker started with PID $BROKER_PID"
sleep 1

# Start Model Gateway
# --- CRITICAL FIX: Use the port from system.yaml or the correct hardcoded value ---
MODEL_GATEWAY_PORT=8070 # Hardcoded based on your system.yaml. Ideally, parse it.
# MODEL_GATEWAY_PORT=$(awk '/services:/,/model_gateway:/ { if (/port:/) { gsub(/ /, "", $2); print $2; exit } }' shared/configs/system.yaml 2>/dev/null || echo "8070")
log "Starting Model Gateway on port $MODEL_GATEWAY_PORT"
print_status "Starting Model Gateway..."
if check_port $MODEL_GATEWAY_PORT; then
    cd services/model-gateway
    source venv/bin/activate
    # Redirect Model Gateway's own logs to its specific log file
    python app.py > ../../logs/model-gateway-app.log 2>&1 &
    deactivate
    cd ../..
    MODEL_GATEWAY_PID=$!
    echo $MODEL_GATEWAY_PID > logs/model-gateway.pid
    log "Model Gateway started with PID $MODEL_GATEWAY_PID"
    print_status "Model Gateway started with PID $MODEL_GATEWAY_PID"
    sleep 1
else
    print_warning "Model Gateway port ($MODEL_GATEWAY_PORT) is already in use"
    log "Model Gateway port ($MODEL_GATEWAY_PORT) is in use. Cannot start."
fi

# Start Orchestrator
log "Starting Orchestrator on port 8001"
print_status "Starting Orchestrator..."
if check_port 8001; then
    cd services/orchestrator
    source venv/bin/activate
    # Redirect Orchestrator's own logs to its specific log file
    python app.py > ../../logs/orchestrator-app.log 2>&1 &
    deactivate
    cd ../..
    ORCHESTRATOR_PID=$!
    echo $ORCHESTRATOR_PID > logs/orchestrator.pid
    log "Orchestrator started with PID $ORCHESTRATOR_PID"
    print_status "Orchestrator started with PID $ORCHESTRATOR_PID"
    sleep 1
else
    print_warning "Orchestrator port (8001) is already in use"
    log "Orchestrator port (8001) is in use. Cannot start."
fi

# --- CRITICAL FIX: Wait for services using the correct ports ---
# Wait for services to be ready using the corrected ports
log "Initiating service readiness checks..."
wait_for_service "http://localhost:8001/health" "Orchestrator"
# Use the corrected Model Gateway port
wait_for_service "http://localhost:${MODEL_GATEWAY_PORT}/health" "Model Gateway"
# Basic check for Vector Engine (it responds to any path with JSON)
wait_for_service "http://localhost:8080/" "Vector Engine"

print_status ""
print_status "🚀 System startup process completed."
print_status "   🧠 Orchestrator: http://localhost:8001"
# Use the corrected Model Gateway port
print_status "   🤖 Model Gateway: http://localhost:${MODEL_GATEWAY_PORT}"
print_status "   🧭 Vector Engine: http://localhost:8080"
print_status ""
print_status "Useful commands:"
print_status "   📊 Check status: ./shared/scripts/status.sh"
print_status "   🧪 Test system: ./shared/scripts/test-system.sh"
print_status "   ⏹️ Stop system: ./shared/scripts/stop-system.sh"
print_status ""
print_status "Startup log file: $MAIN_LOG"
print_status "Service log files are in the logs/ directory"
log "=== Start System Script Completed ==="