#!/bin/bash

# Enhanced GPU Monitor Script for Kubernetes with Namespace/User Details
# Author: Claude Code
# Description: Lists GPU availability and usage with detailed namespace/user breakdown

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}🖥️  GPU CLUSTER MONITOR (Enhanced)${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo
}

print_section() {
    echo -e "${CYAN}📊 $1${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}"
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

            echo -e "${GREEN}Node: ${BOLD}${WHITE}$node_name${NC}"
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

            echo -e "${GREEN}Node: ${BOLD}${WHITE}$node_name${NC} ${PURPLE}(AMD)${NC}"
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

# Function to get GPU usage by pods with enhanced namespace/user info
get_gpu_usage_enhanced() {
    print_section "GPU USAGE BY NAMESPACE & USER"

    # Create temporary files for tracking
    > /tmp/namespace_usage
    > /tmp/pod_details

    local total_pods=0
    local running_pods=0
    local failed_pods=0

    # Get all pods requesting GPUs (NVIDIA)
    kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.nvidia\\.com/gpu,GPU_LIMITS:.spec.containers[*].resources.limits.nvidia\\.com/gpu,STATUS:.status.phase --no-headers 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"<none>"* ]] || [[ -z "$line" ]]; then
            continue
        fi

        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local node_name=$(echo "$line" | awk '{print $3}')
        local gpu_requests=$(echo "$line" | awk '{print $4}')
        local gpu_limits=$(echo "$line" | awk '{print $5}')
        local pod_status=$(echo "$line" | awk '{print $6}')

        if [[ "$gpu_requests" != "<none>" ]] || [[ "$gpu_limits" != "<none>" ]]; then
            # Get pod owner information
            local owner_info=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "Direct")
            local creation_time=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "Unknown")

            echo -e "${BOLD}${BLUE}📦 Namespace: ${YELLOW}$namespace${NC}"
            echo -e "${GREEN}   Pod: ${WHITE}$pod_name${NC}"
            echo -e "${PURPLE}   Owner: ${WHITE}$owner_info${NC}"
            echo -e "${YELLOW}   Node: ${WHITE}$node_name${NC}"
            echo -e "${CYAN}   GPU Requests: ${WHITE}${gpu_requests:-0}${NC}"
            echo -e "${CYAN}   GPU Limits: ${WHITE}${gpu_limits:-0}${NC}"

            # Color-code status
            case "$pod_status" in
                "Running") echo -e "${GREEN}   ✅ Status: Running${NC}" ;;
                "Failed") echo -e "${RED}   ❌ Status: Failed${NC}" ;;
                "Pending") echo -e "${YELLOW}   ⏳ Status: Pending${NC}" ;;
                *) echo -e "${WHITE}   ❓ Status: $pod_status${NC}" ;;
            esac

            echo -e "${WHITE}   Created: ${creation_time}${NC}"

            # Track namespace usage
            local gpu_used=${gpu_requests:-${gpu_limits:-0}}
            if [[ "$gpu_used" =~ ^[0-9]+$ ]]; then
                if [[ "$pod_status" == "Running" ]]; then
                    echo "$namespace $gpu_used running" >> /tmp/namespace_usage
                else
                    echo "$namespace $gpu_used $pod_status" >> /tmp/namespace_usage
                fi
            fi

            echo
        fi
    done

    # Also check for AMD GPU usage
    kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQUESTS:.spec.containers[*].resources.requests.amd\\.com/gpu,GPU_LIMITS:.spec.containers[*].resources.limits.amd\\.com/gpu,STATUS:.status.phase --no-headers 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == *"<none>"* ]] || [[ -z "$line" ]]; then
            continue
        fi

        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local node_name=$(echo "$line" | awk '{print $3}')
        local gpu_requests=$(echo "$line" | awk '{print $4}')
        local gpu_limits=$(echo "$line" | awk '{print $5}')
        local pod_status=$(echo "$line" | awk '{print $6}')

        if [[ "$gpu_requests" != "<none>" ]] || [[ "$gpu_limits" != "<none>" ]]; then
            local owner_info=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "Direct")

            echo -e "${BOLD}${BLUE}📦 Namespace: ${YELLOW}$namespace${NC} ${PURPLE}(AMD GPU)${NC}"
            echo -e "${GREEN}   Pod: ${WHITE}$pod_name${NC}"
            echo -e "${PURPLE}   Owner: ${WHITE}$owner_info${NC}"
            echo -e "${YELLOW}   Node: ${WHITE}$node_name${NC}"
            echo -e "${CYAN}   GPU Requests: ${WHITE}${gpu_requests:-0}${NC}"
            echo -e "${CYAN}   GPU Limits: ${WHITE}${gpu_limits:-0}${NC}"

            case "$pod_status" in
                "Running") echo -e "${GREEN}   ✅ Status: Running${NC}" ;;
                "Failed") echo -e "${RED}   ❌ Status: Failed${NC}" ;;
                "Pending") echo -e "${YELLOW}   ⏳ Status: Pending${NC}" ;;
                *) echo -e "${WHITE}   ❓ Status: $pod_status${NC}" ;;
            esac

            local gpu_used=${gpu_requests:-${gpu_limits:-0}}
            if [[ "$gpu_used" =~ ^[0-9]+$ ]]; then
                if [[ "$pod_status" == "Running" ]]; then
                    echo "$namespace $gpu_used running" >> /tmp/namespace_usage
                else
                    echo "$namespace $gpu_used $pod_status" >> /tmp/namespace_usage
                fi
            fi

            echo
        fi
    done
}

# Function to show namespace GPU summary
show_namespace_summary() {
    print_section "GPU USAGE BY NAMESPACE"

    if [[ ! -f /tmp/namespace_usage ]] || [[ ! -s /tmp/namespace_usage ]]; then
        echo -e "${YELLOW}No GPU usage data found${NC}"
        echo
        return
    fi

    declare -A namespace_running
    declare -A namespace_total
    declare -A namespace_status

    # Process namespace usage data
    while read -r namespace gpus status; do
        if [[ "$status" == "running" ]]; then
            namespace_running["$namespace"]=$((${namespace_running["$namespace"]:-0} + $gpus))
        fi
        namespace_total["$namespace"]=$((${namespace_total["$namespace"]:-0} + $gpus))
        if [[ -z "${namespace_status["$namespace"]:-}" ]]; then
            namespace_status["$namespace"]="$status"
        else
            namespace_status["$namespace"]="${namespace_status["$namespace"]},$status"
        fi
    done < /tmp/namespace_usage

    local total_running=0
    local total_requested=0

    echo -e "${BOLD}${WHITE}Namespace${NC} ${CYAN}│${NC} ${BOLD}${WHITE}Running GPUs${NC} ${CYAN}│${NC} ${BOLD}${WHITE}Total Requested${NC} ${CYAN}│${NC} ${BOLD}${WHITE}Status Summary${NC}"
    echo -e "${CYAN}$(printf '─%.0s' {1..80})${NC}"

    for namespace in "${!namespace_total[@]}"; do
        local running=${namespace_running["$namespace"]:-0}
        local total=${namespace_total["$namespace"]:-0}

        printf "${YELLOW}%-20s${NC} ${CYAN}│${NC} ${GREEN}%-12s${NC} ${CYAN}│${NC} ${WHITE}%-15s${NC} ${CYAN}│${NC} " \
               "$namespace" "$running" "$total"

        # Count status types
        local statuses="${namespace_status["$namespace"]}"
        local running_count=$(echo "$statuses" | tr ',' '\n' | grep -c "running" || echo "0")
        local failed_count=$(echo "$statuses" | tr ',' '\n' | grep -c "Failed" || echo "0")
        local pending_count=$(echo "$statuses" | tr ',' '\n' | grep -c "Pending" || echo "0")

        if [[ $running_count -gt 0 ]]; then
            echo -ne "${GREEN}✅$running_count Running${NC}"
        fi
        if [[ $failed_count -gt 0 ]]; then
            echo -ne " ${RED}❌$failed_count Failed${NC}"
        fi
        if [[ $pending_count -gt 0 ]]; then
            echo -ne " ${YELLOW}⏳$pending_count Pending${NC}"
        fi
        echo

        total_running=$((total_running + running))
        total_requested=$((total_requested + total))
    done

    echo -e "${CYAN}$(printf '─%.0s' {1..80})${NC}"
    echo -e "${BOLD}${WHITE}TOTAL${NC} ${CYAN}│${NC} ${BOLD}${GREEN}$total_running${NC} ${CYAN}│${NC} ${BOLD}${WHITE}$total_requested${NC} ${CYAN}│${NC}"
    echo
}

# Function to show detailed GPU allocation
show_gpu_allocation_enhanced() {
    print_section "DETAILED GPU ALLOCATION"

    # Get total GPUs from previous calculation
    local total_gpus=0
    if [[ -f /tmp/total_gpus ]]; then
        total_gpus=$(cat /tmp/total_gpus)
    fi

    # Calculate used GPUs from running pods
    local used_gpus=0
    local requested_gpus=0

    # Count running GPUs
    if [[ -f /tmp/namespace_usage ]]; then
        while read -r namespace gpus status; do
            if [[ "$status" == "running" ]]; then
                used_gpus=$((used_gpus + gpus))
            fi
            requested_gpus=$((requested_gpus + gpus))
        done < /tmp/namespace_usage
    fi

    local available_gpus=$((total_gpus - used_gpus))
    local pending_gpus=$((requested_gpus - used_gpus))

    echo -e "${WHITE}🎯 GPU Allocation Overview:${NC}"
    echo -e "${GREEN}  ✅ Total GPUs in Cluster: ${BOLD}$total_gpus${NC}"
    echo -e "${BLUE}  🔵 Currently Running: ${BOLD}$used_gpus${NC}"
    echo -e "${RED}  🔴 Pending/Failed: ${BOLD}$pending_gpus${NC}"
    echo -e "${YELLOW}  💛 Available for New Workloads: ${BOLD}$available_gpus${NC}"

    if [[ $total_gpus -gt 0 ]]; then
        local usage_percentage=$((used_gpus * 100 / total_gpus))
        local pending_percentage=$((pending_gpus * 100 / total_gpus))
        echo -e "${PURPLE}  📈 Utilization: ${BOLD}$usage_percentage%${NC} (Running) + ${BOLD}$pending_percentage%${NC} (Pending/Failed)"

        # Enhanced visual bar
        local bar_length=30
        local filled=$((usage_percentage * bar_length / 100))
        local pending_filled=$((pending_percentage * bar_length / 100))
        local empty=$((bar_length - filled - pending_filled))

        printf "  ${WHITE}Progress: ["
        for ((i=0; i<filled; i++)); do printf "${GREEN}█${NC}"; done
        for ((i=0; i<pending_filled; i++)); do printf "${RED}█${NC}"; done
        for ((i=0; i<empty; i++)); do printf "${WHITE}░${NC}"; done
        echo -e "${WHITE}] ${GREEN}Running${NC} ${RED}Pending/Failed${NC} ${WHITE}Available${NC}"
    fi

    echo

    # Cleanup temp files
    rm -f /tmp/total_gpus /tmp/namespace_usage
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

    echo -e "${GREEN}🔗 Current Context: ${BOLD}${WHITE}$(kubectl config current-context)${NC}"
    echo -e "${GREEN}🏷️  Current Namespace: ${WHITE}$(kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}' 2>/dev/null || echo 'default')${NC}"
    echo -e "${GREEN}🕐 Timestamp: ${WHITE}$(date)${NC}"
    echo

    get_gpu_nodes
    get_gpu_usage_enhanced
    show_namespace_summary
    show_gpu_allocation_enhanced

    echo -e "${BLUE}============================================${NC}"
    echo -e "${GREEN}✅ Enhanced GPU monitoring complete!${NC}"
    echo -e "${BLUE}============================================${NC}"
}

# Run the script
main "$@"