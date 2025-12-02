#!/bin/bash

# Quick Pod Logs and Operations Script
# Usage: ./podlogs.sh [pattern] [namespace] [operation]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Default patterns for common llm-d pods
PATTERNS=(
    "decode:ms-.*-decode"
    "prefill:ms-.*-prefill"
    "scheduler:.*scheduler.*"
    "inference:.*inference.*"
    "vllm:.*vllm.*"
    "modelservice:.*modelservice.*"
    "envoy:.*envoy.*"
)

show_usage() {
    echo -e "${BOLD}${CYAN}📋 Pod Logs Quick Access${NC}"
    echo
    echo "Usage:"
    echo "  $0 [pattern] [namespace] [operation] [follow]"
    echo "  $0 [pattern] [operation] [follow]           # Uses current/default namespace"
    echo
    echo "Quick shortcuts:"
    echo "  $0 decode                              # Find decode pods and show logs"
    echo "  $0 decode llm-d-test                   # Find decode pods in llm-d-test namespace"
    echo "  $0 decode llm-d-test logs follow       # Follow decode logs in namespace"
    echo "  $0 prefill                             # Find prefill pods and show logs"
    echo "  $0 scheduler                           # Find scheduler pods and show logs"
    echo
    echo "Operations:"
    echo "  logs [follow]      # Show logs (default), use 'follow' for -f"
    echo "  describe          # Describe pod"
    echo "  exec              # Execute shell in pod"
    echo "  delete            # Delete pod"
    echo "  yaml              # Show pod YAML"
    echo
    echo "Examples:"
    echo "  $0 decode logs follow                  # Follow decode pod logs"
    echo "  $0 decode llm-d-test logs follow       # Follow decode logs in specific namespace"
    echo "  $0 scheduler describe                  # Describe scheduler pod"
    echo "  $0 inference llm-d-test exec           # Shell into inference pod in namespace"
}

# Function to find pods by pattern
find_pods() {
    local pattern="$1"
    local namespace="${2:-}"

    # Check if it's a predefined pattern
    for preset in "${PATTERNS[@]}"; do
        if [[ "$preset" == "$pattern:"* ]]; then
            pattern="${preset#*:}"
            break
        fi
    done

    local cmd="kubectl get pods"
    if [ -n "$namespace" ]; then
        cmd="$cmd -n $namespace"
    else
        cmd="$cmd --all-namespaces"
    fi

    # Find matching pods
    $cmd --no-headers 2>/dev/null | grep -E "$pattern" | head -10
}

# Function to select pod from multiple matches
select_pod() {
    local pods_output="$1"

    # Filter out empty lines and count real pods
    local cleaned_pods=$(echo "$pods_output" | grep -v '^$' | head -10)
    local pod_count=$(echo "$cleaned_pods" | wc -l)

    if [ "$pod_count" -eq 0 ]; then
        echo -e "${RED}❌ No pods found${NC}" >&2
        return 1
    elif [ "$pod_count" -eq 1 ]; then
        echo "$cleaned_pods"
        return 0
    else
        echo -e "${YELLOW}📋 Multiple pods found:${NC}" >&2
        echo "$cleaned_pods" | nl -w2 -s': ' >&2
        echo >&2
        read -p "Select pod number (1-$pod_count): " choice >&2

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$pod_count" ]; then
            echo "$cleaned_pods" | sed -n "${choice}p"
            return 0
        else
            echo -e "${RED}❌ Invalid selection${NC}" >&2
            return 1
        fi
    fi
}

# Function to perform operation on pod
perform_operation() {
    local pod_line="$1"
    local operation="$2"
    local follow="${3:-}"
    local target_namespace="${4:-}"

    # Parse namespace and pod name
    local namespace pod_name

    # Check if we're using --all-namespaces format (has namespace in first column)
    local field_count=$(echo "$pod_line" | awk '{print NF}')

    if [ "$field_count" -ge 5 ] && [ -z "$target_namespace" ]; then
        # All-namespaces format: NAMESPACE NAME READY STATUS RESTARTS AGE
        namespace=$(echo "$pod_line" | awk '{print $1}')
        pod_name=$(echo "$pod_line" | awk '{print $2}')
    else
        # Single namespace format: NAME READY STATUS RESTARTS AGE
        namespace="${target_namespace:-${NAMESPACE:-default}}"
        pod_name=$(echo "$pod_line" | awk '{print $1}')
    fi

    echo -e "${CYAN}🎯 Operating on pod: ${BOLD}$pod_name${NC} ${CYAN}in namespace: ${BOLD}$namespace${NC}"
    echo

    case "$operation" in
        "logs")
            local follow_flag=""
            if [ "$follow" = "follow" ] || [ "$follow" = "-f" ]; then
                follow_flag="-f"
                echo -e "${GREEN}📜 Following logs (Ctrl+C to stop)...${NC}"
            else
                echo -e "${GREEN}📜 Showing recent logs...${NC}"
            fi
            kubectl logs "$pod_name" -n "$namespace" $follow_flag
            ;;
        "describe")
            echo -e "${GREEN}📋 Describing pod...${NC}"
            kubectl describe pod "$pod_name" -n "$namespace"
            ;;
        "exec")
            echo -e "${GREEN}🚀 Opening shell in pod...${NC}"
            kubectl exec -it "$pod_name" -n "$namespace" -- /bin/bash 2>/dev/null || \
            kubectl exec -it "$pod_name" -n "$namespace" -- /bin/sh
            ;;
        "delete")
            echo -e "${YELLOW}⚠️  About to delete pod: $pod_name${NC}"
            read -p "Are you sure? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                kubectl delete pod "$pod_name" -n "$namespace"
                echo -e "${GREEN}✅ Pod deleted${NC}"
            else
                echo -e "${CYAN}⏭️  Cancelled${NC}"
            fi
            ;;
        "yaml")
            echo -e "${GREEN}📄 Pod YAML...${NC}"
            kubectl get pod "$pod_name" -n "$namespace" -o yaml
            ;;
        *)
            echo -e "${RED}❌ Unknown operation: $operation${NC}"
            show_usage
            return 1
            ;;
    esac
}

# Main script
if [ $# -eq 0 ] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Parse arguments with flexible order
pattern="$1"
namespace=""
operation="logs"
follow=""

# Check if second argument looks like a namespace (contains letters/numbers/hyphens)
if [ $# -ge 2 ]; then
    if [[ "$2" =~ ^[a-zA-Z0-9-]+$ ]] && [[ ! "$2" =~ ^(logs|describe|exec|delete|yaml|follow)$ ]]; then
        # Second argument is namespace
        namespace="$2"
        operation="${3:-logs}"
        follow="${4:-}"
    else
        # Second argument is operation
        operation="$2"
        follow="${3:-}"
    fi
fi

# Use provided namespace or fall back to NAMESPACE env var or default
target_namespace="${namespace:-${NAMESPACE:-}}"

echo -e "${BOLD}${CYAN}🔍 Searching for pods matching: ${YELLOW}$pattern${NC}"
if [ -n "$target_namespace" ]; then
    echo -e "${WHITE}Namespace: ${CYAN}$target_namespace${NC}"
fi

# Find pods
pods_output=$(find_pods "$pattern" "$target_namespace")

if [ -z "$pods_output" ]; then
    echo -e "${RED}❌ No pods found matching pattern: $pattern${NC}"
    echo
    echo -e "${WHITE}💡 Try these patterns:${NC}"
    for preset in "${PATTERNS[@]}"; do
        name="${preset%%:*}"
        echo "  $name"
    done
    exit 1
fi

# Select pod
selected_pod=$(select_pod "$pods_output")
if [ $? -ne 0 ]; then
    exit 1
fi

# Perform operation
perform_operation "$selected_pod" "$operation" "$follow" "$target_namespace"