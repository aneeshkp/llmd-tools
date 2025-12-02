#!/bin/bash

# Kubernetes Port Forward Script
# Usage: ./portforward.sh [service_pattern] [local_port] [namespace] [remote_port]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

show_usage() {
    echo -e "${BOLD}${CYAN}🚪 Kubernetes Port Forward Helper${NC}"
    echo
    echo "Usage:"
    echo "  $0 [service_pattern] [local_port] [namespace] [remote_port] [options]"
    echo "  $0 [service_pattern] [namespace] [options]                  # Auto-detect ports"
    echo "  $0 --list                                                   # List active forwards"
    echo "  $0 --kill [port]                                           # Kill port forward"
    echo
    echo "Options:"
    echo "  -b, --background       Run port forward in background"
    echo "  --list                 List active port forwards"
    echo "  --kill [port]          Kill port forward(s)"
    echo "  --kill-all             Kill all port forwards"
    echo
    echo "Examples:"
    echo "  $0 gateway 8000 llm-d-test 80       # Forward gateway:80 to localhost:8000"
    echo "  $0 gateway 8000 llm-d-test -b       # Run in background"
    echo "  $0 gateway llm-d-test --background  # Auto-detect and run in background"
    echo "  $0 --list                           # Show active forwards"
    echo "  $0 --kill 8000                      # Kill port forward on 8000"
    echo
    echo "Environment variables:"
    echo "  NAMESPACE  - Default namespace if not specified"
}

# PID file location
PID_DIR="/tmp/portforward_pids"
mkdir -p "$PID_DIR"

# Functions for process management
list_forwards() {
    echo -e "${BOLD}${CYAN}📋 Active Port Forwards${NC}"
    echo
    if [ "$(ls -A "$PID_DIR" 2>/dev/null)" ]; then
        printf "%-6s %-20s %-15s %-10s %s\n" "PORT" "SERVICE" "NAMESPACE" "PID" "STATUS"
        printf "%-6s %-20s %-15s %-10s %s\n" "----" "-------" "---------" "---" "------"
        for pid_file in "$PID_DIR"/*; do
            if [ -f "$pid_file" ]; then
                local info
                info=$(cat "$pid_file")
                local pid port service namespace
                pid=$(echo "$info" | cut -d: -f1)
                port=$(echo "$info" | cut -d: -f2)
                service=$(echo "$info" | cut -d: -f3)
                namespace=$(echo "$info" | cut -d: -f4)

                if kill -0 "$pid" 2>/dev/null; then
                    printf "%-6s %-20s %-15s %-10s %s\n" "$port" "$service" "$namespace" "$pid" "Running"
                else
                    printf "%-6s %-20s %-15s %-10s %s\n" "$port" "$service" "$namespace" "$pid" "Dead"
                    rm -f "$pid_file"
                fi
            fi
        done
    else
        echo -e "${YELLOW}No active port forwards found${NC}"
    fi
}

kill_forward() {
    local target_port="$1"

    if [ -z "$target_port" ]; then
        echo -e "${RED}❌ Please specify port to kill${NC}"
        exit 1
    fi

    local killed=false
    for pid_file in "$PID_DIR"/*; do
        if [ -f "$pid_file" ]; then
            local info port pid
            info=$(cat "$pid_file")
            port=$(echo "$info" | cut -d: -f2)
            pid=$(echo "$info" | cut -d: -f1)

            if [ "$port" = "$target_port" ]; then
                if kill "$pid" 2>/dev/null; then
                    echo -e "${GREEN}✅ Killed port forward on port $port (PID $pid)${NC}"
                    killed=true
                else
                    echo -e "${YELLOW}⚠️  Process $pid already dead${NC}"
                fi
                rm -f "$pid_file"
            fi
        fi
    done

    if [ "$killed" = false ]; then
        echo -e "${RED}❌ No port forward found on port $target_port${NC}"
    fi
}

kill_all_forwards() {
    echo -e "${YELLOW}🛑 Killing all port forwards...${NC}"
    for pid_file in "$PID_DIR"/*; do
        if [ -f "$pid_file" ]; then
            local info pid port
            info=$(cat "$pid_file")
            pid=$(echo "$info" | cut -d: -f1)
            port=$(echo "$info" | cut -d: -f2)

            if kill "$pid" 2>/dev/null; then
                echo -e "${GREEN}✅ Killed port forward on port $port${NC}"
            fi
            rm -f "$pid_file"
        fi
    done
    echo -e "${GREEN}🎉 All port forwards killed${NC}"
}

# Parse arguments with flags
background_mode=false
service_pattern=""
local_port=""
namespace=""
remote_port=""

# Handle special commands first - check for no args BEFORE accessing $1
if [ $# -eq 0 ]; then
    show_usage
    exit 0
elif [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
elif [[ "$1" == "--list" ]]; then
    list_forwards
    exit 0
elif [[ "$1" == "--kill" ]]; then
    kill_forward "${2:-}"
    exit 0
elif [[ "$1" == "--kill-all" ]]; then
    kill_all_forwards
    exit 0
fi

# Parse main arguments and flags
args=()
for arg in "$@"; do
    case $arg in
        -b|--background)
            background_mode=true
            ;;
        -*)
            echo -e "${RED}❌ Unknown option: $arg${NC}"
            show_usage
            exit 1
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

# Set positional arguments from parsed args (excluding flags)
service_pattern="${args[0]:-}"
arg_count=${#args[@]}

# Parse remaining arguments
if [ $arg_count -eq 2 ]; then
    # Two args: pattern + (port OR namespace)
    if [[ "${args[1]}" =~ ^[0-9]+$ ]]; then
        local_port="${args[1]}"
        namespace="${NAMESPACE:-}"
    else
        namespace="${args[1]}"
    fi
elif [ $arg_count -eq 3 ]; then
    # Three args: pattern + port + namespace OR pattern + namespace + port
    if [[ "${args[1]}" =~ ^[0-9]+$ ]]; then
        local_port="${args[1]}"
        namespace="${args[2]}"
    else
        namespace="${args[1]}"
        local_port="${args[2]}"
    fi
elif [ $arg_count -eq 4 ]; then
    # Four args: pattern + local_port + namespace + remote_port
    local_port="${args[1]}"
    namespace="${args[2]}"
    remote_port="${args[3]}"
else
    namespace="${NAMESPACE:-}"
fi

# Validate namespace
if [ -z "$namespace" ]; then
    echo -e "${RED}❌ Namespace not provided${NC}"
    echo -e "${WHITE}Please provide namespace via:${NC}"
    echo "  - Command line: $0 $service_pattern <namespace>"
    echo "  - Environment:  export NAMESPACE=<namespace>"
    exit 1
fi

echo -e "${BOLD}${CYAN}🔍 Searching for services matching: ${YELLOW}$service_pattern${NC}"
echo -e "${WHITE}Namespace: ${CYAN}$namespace${NC}"
echo

# Find services
services_output=$(kubectl get svc -n "$namespace" --no-headers 2>/dev/null | grep -E "$service_pattern" | head -5)

if [ -z "$services_output" ]; then
    echo -e "${RED}❌ No services found matching pattern: $service_pattern${NC}"
    echo
    echo -e "${WHITE}💡 Available services in namespace $namespace:${NC}"
    kubectl get svc -n "$namespace" --no-headers 2>/dev/null | awk '{print "  " $1}' | head -10
    exit 1
fi

# Select service if multiple found
service_count=$(echo "$services_output" | wc -l)
if [ "$service_count" -eq 1 ]; then
    selected_service=$(echo "$services_output" | awk '{print $1}')
    service_ports=$(echo "$services_output" | awk '{print $5}')
else
    echo -e "${YELLOW}📋 Multiple services found:${NC}"
    echo "$services_output" | nl -w2 -s': ' | awk '{print "  " $0}'
    echo
    read -p "Select service number (1-$service_count): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$service_count" ]; then
        selected_line=$(echo "$services_output" | sed -n "${choice}p")
        selected_service=$(echo "$selected_line" | awk '{print $1}')
        service_ports=$(echo "$selected_line" | awk '{print $5}')
    else
        echo -e "${RED}❌ Invalid selection${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}📡 Selected service: ${BOLD}$selected_service${NC}"
echo -e "${WHITE}Available ports: ${CYAN}$service_ports${NC}"

# Parse ports and determine forwarding
if [ -z "$remote_port" ]; then
    # Auto-detect remote port
    if [[ "$service_ports" =~ ([0-9]+)/TCP ]]; then
        remote_port="${BASH_REMATCH[1]}"
    else
        echo -e "${YELLOW}⚠️  Could not auto-detect port from: $service_ports${NC}"
        echo -e "${WHITE}Please specify remote port manually${NC}"
        exit 1
    fi
fi

if [ -z "$local_port" ]; then
    # Use same port as remote
    local_port="$remote_port"
fi

echo -e "${BLUE}🚪 Port forwarding: localhost:${BOLD}$local_port${NC}${BLUE} -> $selected_service:${BOLD}$remote_port${NC}"

# Check if port is already in use
if netstat -tuln 2>/dev/null | grep -q ":$local_port "; then
    echo -e "${YELLOW}⚠️  Port $local_port is already in use${NC}"

    # Check if it's a kubectl port-forward process
    kubectl_pids=$(lsof -ti :$local_port 2>/dev/null | xargs ps -p 2>/dev/null | grep kubectl | awk '{print $1}' | grep -v PID || true)

    if [ -n "$kubectl_pids" ]; then
        echo -e "${WHITE}Found kubectl port-forward process(es): ${CYAN}$kubectl_pids${NC}"
        read -p "Kill existing kubectl port-forward and retry? (y/n): " kill_choice
        if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}🛑 Killing kubectl port-forward processes...${NC}"
            echo "$kubectl_pids" | xargs kill 2>/dev/null || true
            sleep 1
            echo -e "${GREEN}✅ Processes killed${NC}"
        else
            echo -e "${CYAN}⏭️  Cancelled${NC}"
            exit 1
        fi
    else
        echo -e "${WHITE}Port is used by non-kubectl process${NC}"
        read -p "Continue anyway? (y/n): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Start port forwarding
if [ "$background_mode" = true ]; then
    echo -e "${GREEN}🚀 Starting port forward in background...${NC}"

    # Start kubectl port-forward in background
    kubectl port-forward "svc/$selected_service" "$local_port:$remote_port" -n "$namespace" >/dev/null 2>&1 &
    pf_pid=$!

    # Give it a moment to start
    sleep 2

    # Check if the process is still running
    if kill -0 "$pf_pid" 2>/dev/null; then
        # Save PID info
        echo "$pf_pid:$local_port:$selected_service:$namespace" > "$PID_DIR/port_$local_port.pid"
        echo -e "${GREEN}✅ Port forward started successfully${NC}"
        echo -e "${WHITE}   PID: ${CYAN}$pf_pid${NC}"
        echo -e "${WHITE}   Access: ${CYAN}http://localhost:$local_port${NC}"
        echo -e "${WHITE}   To stop: ${YELLOW}$0 --kill $local_port${NC}"
        echo -e "${WHITE}   To list: ${YELLOW}$0 --list${NC}"
    else
        echo -e "${RED}❌ Failed to start port forward${NC}"
        exit 1
    fi
else
    echo -e "${WHITE}Press Ctrl+C to stop${NC}"
    echo
    kubectl port-forward "svc/$selected_service" "$local_port:$remote_port" -n "$namespace"
fi