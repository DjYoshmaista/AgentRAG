#!/bin/bash

# Test script for the multi-agent system
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Test function
test_endpoint() {
    local url=$1
    local description=$2
    local method=${3:-GET}
    local data=$4
    
    print_status "Testing $description..."
    
    if [ "$method" = "POST" ]; then
        response=$(curl -s -w "%{http_code}" -H "Content-Type: application/json" -X POST -d "$data" "$url")
    else
        response=$(curl -s -w "%{http_code}" "$url")
    fi
    
    http_code="${response: -3}"
    body="${response%???}"
    
    if [ "$http_code" -eq 200 ]; then
        print_status "✓ $description - OK"
        return 0
    else
        print_error "✗ $description - Failed (HTTP $http_code)"
        echo "Response: $body"
        return 1
    fi
}

print_status "Testing Multi-Agent Orchestration System..."

# Test health endpoints
test_endpoint "http://localhost:8001/health" "Orchestrator Health"
test_endpoint "http://localhost:8000/health" "Model Gateway Health"

# Test system status
test_endpoint "http://localhost:8001/status" "System Status"

# Test model listing
test_endpoint "http://localhost:8000/models" "Model Listing"

# Test task creation
task_data='{"task_type": "llm_inference", "description": "Test task", "parameters": {"model": "llama2", "prompt": "Hello, world!"}}'
test_endpoint "http://localhost:8001/tasks" "Task Creation" "POST" "$task_data"

print_status "Basic system tests completed!"
