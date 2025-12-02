#!/bin/bash

# GPU Monitor Script for Kubernetes
# Author: Claude Code
# Description: Lists GPU availability and usage across Kubernetes cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}🖥️  GPU CLUSTER MONITOR${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
}

print_section() {
    echo -e "${CYAN}📊 $1${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..50})${NC}"
}

# Function to get GPU nodes and their capacity
get_gpu_nodes() {
    print_section "GPU NODES OVERVIEW"

    local total_gpus=0
    local gpu_nodes=0

    # Get all nodes with GPU resources
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local node_name=$(echo "$line" | awk '{print $1}')
            local gpu_count=$(echo "$line" | awk '{print $2}')

            echo -e "${GREEN}Node: ${WHITE}$node_name${NC}"
            echo -e "${YELLOW}  Total GPUs: ${WHITE}$gpu_count${NC}"

            # Get node details
            local node_info=$(kubectl describe node "$node_name" 2>/dev/null | grep -E "(nvidia.com/gpu|amd.com/gpu)" || true)
            if [[ -n "$node_info" ]]; then
                echo -e "${PURPLE}  GPU Details:${NC}"
                echo "$node_info" | sed 's/^/    /'
            fi

            total_gpus=$((total_gpus + gpu_count))
            gpu_nodes=$((gpu_nodes + 1))
            echo
        fi
    done < <(kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.nvidia\\.com/gpu --no-headers 2>/dev/null | grep -v "<none>" || true)

    # Also check for AMD GPUs
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local node_name=$(echo "$line" | awk '{print $1}')
            local gpu_count=$(echo "$line" | awk '{print $2}')

            echo -e "${GREEN}Node: ${WHITE}$node_name${NC} ${PURPLE}(AMD)${NC}"
            echo -e "${YELLOW}  Total GPUs: ${WHITE}$gpu_count${NC}"

            total_gpus=$((total_gpus + gpu_count))
            gpu_nodes=$((gpu_nodes + 1))
            echo
        fi
    done < <(kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.amd\\.com/gpu --no-headers 2>/dev/null | grep -v "<none>" || true)

    echo -e "${CYAN}📈 Summary:${NC}"
    echo -e "${WHITE}  Total GPU Nodes: ${GREEN}$gpu_nodes${NC}"
    echo -e "${WHITE}  Total GPUs Available: ${GREEN}$total_gpus${NC}"
    echo

    # Return total GPUs for later calculation
    echo "$total_gpus" > /tmp/total_gpus
}

# Function to get GPU usage by pods
get_gpu_usage() {
    print_section "GPU USAGE BY PODS"

    local used_gpus=0
    local pod_count=0

    # Get all pods requesting GPUs
    kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.nvidia\\.com/gpu,GPU_LIMITS:.spec.containers[*].resources.limits.nvidia\\.com/gpu --no-headers 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"<none>"* ]] || [[ -z "$line" ]]; then
            continue
        fi

        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local node_name=$(echo "$line" | awk '{print $3}')
        local gpu_requests=$(echo "$line" | awk '{print $4}')
        local gpu_limits=$(echo "$line" | awk '{print $5}')

        if [[ "$gpu_requests" != "<none>" ]] || [[ "$gpu_limits" != "<none>" ]]; then
            echo -e "${GREEN}Pod: ${WHITE}$namespace/$pod_name${NC}"
            echo -e "${YELLOW}  Node: ${WHITE}$node_name${NC}"
            echo -e "${PURPLE}  GPU Requests: ${WHITE}${gpu_requests:-0}${NC}"
            echo -e "${PURPLE}  GPU Limits: ${WHITE}${gpu_limits:-0}${NC}"

            # Get pod status
            local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo -e "${CYAN}  Status: ${WHITE}$pod_status${NC}"

            # Count used GPUs (use requests if available, otherwise limits)
            local gpu_used=${gpu_requests:-${gpu_limits:-0}}
            if [[ "$gpu_used" =~ ^[0-9]+$ ]] && [[ "$pod_status" == "Running" ]]; then
                used_gpus=$((used_gpus + gpu_used))
            fi

            pod_count=$((pod_count + 1))
            echo
        fi
    done

    # Also check for AMD GPU usage
    kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.amd\\.com/gpu,GPU_LIMITS:.spec.containers[*].resources.limits.amd\\.com/gpu --no-headers 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"<none>"* ]] || [[ -z "$line" ]]; then
            continue
        fi

        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local node_name=$(echo "$line" | awk '{print $3}')
        local gpu_requests=$(echo "$line" | awk '{print $4}')
        local gpu_limits=$(echo "$line" | awk '{print $5}')

        if [[ "$gpu_requests" != "<none>" ]] || [[ "$gpu_limits" != "<none>" ]]; then
            echo -e "${GREEN}Pod: ${WHITE}$namespace/$pod_name${NC} ${PURPLE}(AMD)${NC}"
            echo -e "${YELLOW}  Node: ${WHITE}$node_name${NC}"
            echo -e "${PURPLE}  GPU Requests: ${WHITE}${gpu_requests:-0}${NC}"
            echo -e "${PURPLE}  GPU Limits: ${WHITE}${gpu_limits:-0}${NC}"

            # Get pod status
            local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo -e "${CYAN}  Status: ${WHITE}$pod_status${NC}"

            pod_count=$((pod_count + 1))
            echo
        fi
    done

    echo -e "${CYAN}📊 Usage Summary:${NC}"
    echo -e "${WHITE}  Pods using GPUs: ${GREEN}$pod_count${NC}"
    echo
}

# Function to show detailed GPU allocation
show_gpu_allocation() {
    print_section "DETAILED GPU ALLOCATION"

    # Get total GPUs from previous calculation
    local total_gpus=0
    if [[ -f /tmp/total_gpus ]]; then
        total_gpus=$(cat /tmp/total_gpus)
    fi

    # Calculate used GPUs from running pods
    local used_gpus=0

    # NVIDIA GPUs
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != *"<none>"* ]]; then
            local namespace=$(echo "$line" | awk '{print $1}')
            local pod_name=$(echo "$line" | awk '{print $2}')
            local gpu_requests=$(echo "$line" | awk '{print $4}')
            local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

            if [[ "$pod_status" == "Running" ]] && [[ "$gpu_requests" =~ ^[0-9]+$ ]]; then
                used_gpus=$((used_gpus + gpu_requests))
            fi
        fi
    done < <(kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.nvidia\\.com/gpu --no-headers 2>/dev/null || true)

    # AMD GPUs
    while IFS= read -r line; do
        if [[ -n "$line" && "$line" != *"<none>"* ]]; then
            local namespace=$(echo "$line" | awk '{print $1}')
            local pod_name=$(echo "$line" | awk '{print $2}')
            local gpu_requests=$(echo "$line" | awk '{print $4}')
            local pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

            if [[ "$pod_status" == "Running" ]] && [[ "$gpu_requests" =~ ^[0-9]+$ ]]; then
                used_gpus=$((used_gpus + gpu_requests))
            fi
        fi
    done < <(kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.amd\\.com/gpu --no-headers 2>/dev/null || true)

    local available_gpus=$((total_gpus - used_gpus))

    echo -e "${WHITE}📊 GPU Allocation Summary:${NC}"
    echo -e "${GREEN}  ✅ Total GPUs: $total_gpus${NC}"
    echo -e "${RED}  🔴 Used GPUs: $used_gpus${NC}"
    echo -e "${YELLOW}  💛 Available GPUs: $available_gpus${NC}"

    if [[ $total_gpus -gt 0 ]]; then
        local usage_percentage=$((used_gpus * 100 / total_gpus))
        echo -e "${PURPLE}  📈 Usage: $usage_percentage%${NC}"

        # Visual bar
        local bar_length=20
        local filled=$((usage_percentage * bar_length / 100))
        local empty=$((bar_length - filled))

        printf "  ${WHITE}["
        for ((i=0; i<filled; i++)); do printf "${RED}█${NC}"; done
        for ((i=0; i<empty; i++)); do printf "${GREEN}░${NC}"; done
        echo -e "${WHITE}]${NC}"
    fi

    echo

    # Cleanup temp file
    rm -f /tmp/total_gpus
}

# Function to show resource quotas and limits
show_resource_quotas() {
    print_section "RESOURCE QUOTAS & LIMITS"

    # Check for resource quotas
    local quotas=$(kubectl get resourcequota --all-namespaces --no-headers 2>/dev/null || true)
    if [[ -n "$quotas" ]]; then
        echo -e "${GREEN}Resource Quotas:${NC}"
        kubectl get resourcequota --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,GPU_HARD:.spec.hard.nvidia\\.com/gpu,GPU_USED:.status.used.nvidia\\.com/gpu --no-headers 2>/dev/null | while IFS= read -r line; do
            if [[ "$line" != *"<none>"* ]] && [[ -n "$line" ]]; then
                echo "  $line"
            fi
        done
        echo
    else
        echo -e "${YELLOW}No GPU resource quotas found${NC}"
        echo
    fi
}

# Main function
main() {
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl not found. Please install kubectl first.${NC}"
        exit 1
    fi

    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}❌ Cannot access Kubernetes cluster. Check your kubeconfig.${NC}"
        exit 1
    fi

    print_header

    echo -e "${GREEN}🔗 Current Context: ${WHITE}$(kubectl config current-context)${NC}"
    echo -e "${GREEN}🕐 Timestamp: ${WHITE}$(date)${NC}"
    echo

    get_gpu_nodes
    get_gpu_usage
    show_gpu_allocation
    show_resource_quotas

    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}✅ GPU monitoring complete!${NC}"
    echo -e "${BLUE}================================${NC}"
}

# Run the script
main "$@"