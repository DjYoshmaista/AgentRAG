#!/bin/bash

# Stop script for the multi-agent system
set -e

GREEN='\033[0;32m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Function to stop service by PID file
stop_service() {
    local service_name=$1
    local pid_file="logs/${service_name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 $pid 2>/dev/null; then
            print_status "Stopping $service_name (PID: $pid)..."
            kill $pid
            rm -f "$pid_file"
        else
            print_status "$service_name was not running"
            rm -f "$pid_file"
        fi
    else
        print_status "No PID file found for $service_name"
    fi
}

print_status "Stopping Multi-Agent Orchestration System..."

# Stop all services
stop_service "orchestrator"
stop_service "model-gateway"
stop_service "message-broker"
stop_service "vector-engine"
stop_service "ollama"
stop_service "nats"

# Kill any remaining processes
pkill -f "python.*app.py" 2>/dev/null || true
pkill -f "vector-engine" 2>/dev/null || true
pkill -f "message-broker" 2>/dev/null || true

print_status "All services stopped"
