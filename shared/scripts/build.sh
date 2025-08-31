#!/bin/bash

# Build script for the multi-agent system
set -e

echo "Building Multi-Agent Orchestration System..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
print_status "Checking dependencies..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    print_error "Go is not installed. Please install Go 1.21 or later."
    exit 1
fi

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    print_error "Zig is not installed. Please install Zig 0.11 or later."
    exit 1
fi

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 is not installed. Please install Python 3.9 or later."
    exit 1
fi

# Create build directory
mkdir -p build/
mkdir -p logs/

# Build Go services
print_status "Building message broker (Go)..."
cd services/message-broker

# Initialize go module if it doesn't exist
if [ ! -f "go.mod" ]; then
    go mod init agentic-system/message-broker
fi

go mod tidy
go build -o ../../build/message-broker .
cd ../..

# Build Zig services
print_status "Building vector engine (Zig)..."
cd services/vector-engine

# Create zig build file if it doesn't exist
if [ ! -f "build.zig" ]; then
    cat > build.zig << 'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vector-engine",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the vector engine");
    run_step.dependOn(&run_cmd.step);
}
EOF
fi

# Create src directory if it doesn't exist
mkdir -p src/

zig build -Doptimize=ReleaseFast
cp zig-out/bin/vector-engine ../../build/
cd ../..

# Setup Python services
print_status "Setting up Python services..."

# Model Gateway
print_status "Setting up Model Gateway..."
cd services/model-gateway
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
cd ../..

# Orchestrator
print_status "Setting up Orchestrator..."
cd services/orchestrator
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
cd ../..

print_status "Build completed successfully!"
print_status "Binaries are in the build/ directory"
print_status ""
print_status "Next steps:"
print_status "1. Install Ollama: curl -fsSL https://ollama.ai/install.sh | sh"
print_status "2. Install NATS: sudo pacman -S nats-server (or download from nats.io)"
print_status "3. Run: ./shared/scripts/start-system.sh"
