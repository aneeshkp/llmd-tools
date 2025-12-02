#!/bin/bash

# Simple GPU Usage Table for Kubernetes
# Shows who is using GPUs in a clean table format

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

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}🖥️  GPU USAGE TABLE - $(kubectl config current-context)${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo
}

show_gpu_table() {
    echo -e "${BOLD}${CYAN}📊 GPU Usage by Namespace & User${NC}"
    echo

    # Table headers
    printf "${BOLD}%-25s %-15s %-8s %-8s %-8s %-10s %-12s${NC}\n" \
           "NAMESPACE" "USER/OWNER" "GPU_REQ" "GPU_LIM" "PRIORITY" "STATUS" "NODE"
    echo -e "${CYAN}$(printf '─%.0s' {1..100})${NC}"

    # Get running pods with GPU requests and priority
    kubectl get pods --all-namespaces \
        -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,GPU_REQ:.spec.containers[*].resources.requests.nvidia\.com/gpu,GPU_LIM:.spec.containers[*].resources.limits.nvidia\.com/gpu,STATUS:.status.phase,PRIORITY:.spec.priority,PRIORITY_CLASS:.spec.priorityClassName" \
        --no-headers 2>/dev/null | \
    while IFS= read -r line; do
        if [[ "$line" == *"<none>"* ]] || [[ -z "$line" ]]; then
            continue
        fi

        local namespace=$(echo "$line" | awk '{print $1}')
        local pod_name=$(echo "$line" | awk '{print $2}')
        local node_name=$(echo "$line" | awk '{print $3}')
        local gpu_req=$(echo "$line" | awk '{print $4}')
        local gpu_lim=$(echo "$line" | awk '{print $5}')
        local status=$(echo "$line" | awk '{print $6}')
        local priority=$(echo "$line" | awk '{print $7}')
        local priority_class=$(echo "$line" | awk '{print $8}')

        if [[ "$gpu_req" != "<none>" ]] || [[ "$gpu_lim" != "<none>" ]]; then
            # Get owner info - try to extract meaningful user/owner name
            local owner=$(kubectl get pod "$pod_name" -n "$namespace" \
                -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")

            if [[ -z "$owner" ]]; then
                owner=$(kubectl get pod "$pod_name" -n "$namespace" \
                    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null | \
                    cut -d'-' -f1-3 || echo "direct")
            fi

            # Shorten node name for display
            local short_node=${node_name:0:10}

            # Format priority display
            local priority_display=""
            if [[ "$priority" != "<none>" ]] && [[ -n "$priority" ]]; then
                if [[ "$priority_class" != "<none>" ]] && [[ -n "$priority_class" ]]; then
                    # Color code system priority classes
                    case "$priority_class" in
                        "system-"*) priority_display="${YELLOW}$priority${NC}" ;;
                        *) priority_display="${WHITE}$priority${NC}" ;;
                    esac
                else
                    priority_display="${WHITE}$priority${NC}"
                fi
            else
                priority_display="${WHITE}0${NC}"
            fi

            # Color code status
            case "$status" in
                "Running")  status_colored="${GREEN}✅Run${NC}" ;;
                "Failed")   status_colored="${RED}❌Fail${NC}" ;;
                "Pending")  status_colored="${YELLOW}⏳Pend${NC}" ;;
                *)          status_colored="${WHITE}${status:0:4}${NC}" ;;
            esac

            printf "%-25s %-15s %-8s %-8s %-16s %-18s %-12s\n" \
                   "${namespace:0:24}" \
                   "${owner:0:14}" \
                   "${gpu_req:-0}" \
                   "${gpu_lim:-0}" \
                   "$(echo -e "$priority_display")" \
                   "$(echo -e "$status_colored")" \
                   "$short_node"
        fi
    done
}

show_namespace_summary() {
    echo
    echo -e "${BOLD}${CYAN}📈 Summary by Namespace${NC}"
    echo

    printf "${BOLD}%-25s %-12s %-12s %-12s${NC}\n" \
           "NAMESPACE" "RUNNING" "TOTAL_REQ" "STATUS"
    echo -e "${CYAN}$(printf '─%.0s' {1..65})${NC}"

    # Create temporary file for namespace summary
    > /tmp/ns_summary

    kubectl get pods --all-namespaces \
        -o custom-columns="NS:.metadata.namespace,GPU:.spec.containers[*].resources.requests.nvidia\.com/gpu,STATUS:.status.phase" \
        --no-headers 2>/dev/null | \
    while read -r ns gpu status; do
        if [[ "$gpu" != "<none>" ]] && [[ -n "$gpu" ]] && [[ "$gpu" =~ ^[0-9]+$ ]]; then
            echo "$ns $gpu $status" >> /tmp/ns_summary
        fi
    done

    # Process summary
    if [[ -f /tmp/ns_summary ]] && [[ -s /tmp/ns_summary ]]; then
        declare -A ns_running
        declare -A ns_total
        declare -A ns_failed

        while read -r ns gpu status; do
            ns_total["$ns"]=$((${ns_total["$ns"]:-0} + gpu))
            if [[ "$status" == "Running" ]]; then
                ns_running["$ns"]=$((${ns_running["$ns"]:-0} + gpu))
            elif [[ "$status" == "Failed" ]]; then
                ns_failed["$ns"]=$((${ns_failed["$ns"]:-0} + gpu))
            fi
        done < /tmp/ns_summary

        for ns in "${!ns_total[@]}"; do
            local running=${ns_running["$ns"]:-0}
            local total=${ns_total["$ns"]:-0}
            local failed=${ns_failed["$ns"]:-0}

            local status_summary=""
            if [[ $running -gt 0 ]]; then
                status_summary+="${GREEN}$running✅${NC}"
            fi
            if [[ $failed -gt 0 ]]; then
                [[ -n "$status_summary" ]] && status_summary+=" "
                status_summary+="${RED}$failed❌${NC}"
            fi

            printf "%-25s %-12s %-12s %s\n" \
                   "${ns:0:24}" \
                   "$running" \
                   "$total" \
                   "$(echo -e "$status_summary")"
        done
    fi

    rm -f /tmp/ns_summary
}

show_cluster_overview() {
    echo
    echo -e "${BOLD}${CYAN}🎯 Cluster Overview${NC}"
    echo

    local total_nodes=$(kubectl get nodes -o custom-columns=GPU:.status.capacity.nvidia\.com/gpu --no-headers 2>/dev/null | grep -v "<none>" | wc -l)
    local total_gpus=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | awk '{sum += $1} END {print sum+0}')

    # Count running GPU pods
    local running_gpus=0
    kubectl get pods --all-namespaces \
        -o custom-columns="GPU:.spec.containers[*].resources.requests.nvidia\.com/gpu,STATUS:.status.phase" \
        --no-headers 2>/dev/null | \
    while read -r gpu status; do
        if [[ "$gpu" != "<none>" ]] && [[ -n "$gpu" ]] && [[ "$gpu" =~ ^[0-9]+$ ]] && [[ "$status" == "Running" ]]; then
            running_gpus=$((running_gpus + gpu))
        fi
    done

    echo -e "${GREEN}🖥️  GPU Nodes: ${WHITE}$total_nodes${NC}"
    echo -e "${GREEN}🔢 Total GPUs: ${WHITE}$total_gpus${NC}"
    echo -e "${BLUE}🚀 Running GPUs: ${WHITE}$running_gpus${NC}"
    echo -e "${YELLOW}💡 Available GPUs: ${WHITE}$((total_gpus - running_gpus))${NC}"

    if [[ $total_gpus -gt 0 ]]; then
        local usage_pct=$((running_gpus * 100 / total_gpus))
        echo -e "${PURPLE}📊 Utilization: ${WHITE}${usage_pct}%${NC}"
    fi
}

main() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}❌ kubectl not found${NC}"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}❌ Cannot access cluster${NC}"
        exit 1
    fi

    print_header
    show_cluster_overview
    echo
    show_gpu_table
    show_namespace_summary

    echo
    echo -e "${BLUE}================================================${NC}"
    echo -e "${GREEN}✅ GPU table complete - $(date)${NC}"
    echo -e "${BLUE}================================================${NC}"
}

main "$@"