#!/bin/bash

# Quick GPU "who is using" command
# Shows clean summary of GPU usage by user/namespace

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}🔍 WHO IS USING GPUs - $(kubectl config current-context)${NC}"
echo

# Quick cluster stats
total_gpus=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | awk '{sum += $1} END {print sum+0}')
echo -e "${WHITE}📊 Total GPUs in cluster: ${GREEN}$total_gpus${NC}"

# Show GPU distribution by node
echo
echo -e "${BOLD}${YELLOW}🖥️  GPU Nodes Distribution:${NC}"

# Check if cluster has any GPU nodes
gpu_nodes=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[].status.capacity' | grep -c "nvidia.com/gpu" 2>/dev/null || echo "0")

if [ "$gpu_nodes" -eq 0 ]; then
    echo -e "${RED}⚠️  No GPU nodes found in this cluster${NC}"
    echo -e "${WHITE}💡 Available clusters:${NC}"
    kubectl config get-contexts | grep -E "^\*|NAME" | head -5
    echo
else
    printf "%-15s %5s %9s %6s %8s\n" "NODE" "GPUs" "AVAILABLE" "USED" "STATUS"
    printf "%-15s %5s %9s %6s %8s\n" "----" "----" "---------" "----" "------"

    kubectl get nodes -o json 2>/dev/null | jq -r '
      .items[] |
      select(.status.capacity | has("nvidia.com/gpu")) |
      {
        name: .metadata.name,
        total: .status.capacity."nvidia.com/gpu",
        allocatable: .status.allocatable."nvidia.com/gpu"
      } |
      "\(.name) \(.total) \(.allocatable)"
    ' | while read -r node total allocatable; do
    if [ -n "$node" ]; then
        # Get GPU usage for this node - improved parsing
        used_gpus=$(kubectl describe node "$node" 2>/dev/null | \
            awk '/Allocated resources:/,/Events:/ {
                if ($0 ~ /nvidia\.com\/gpu/) {
                    gsub(/[^0-9]/, "", $2)
                    print $2
                    exit
                }
            }')
        used_gpus=${used_gpus:-0}

        available=$((allocatable - used_gpus))

        # Determine status and format output
        if [ "$used_gpus" -eq 0 ]; then
            status_text="idle"
            printf "%-15s %5s %9s %6s " "$node" "$total" "$available" "$used_gpus"
            echo -e "${GREEN}$status_text${NC}"
        elif [ "$available" -gt 0 ]; then
            status_text="partial"
            printf "%-15s %5s %9s %6s " "$node" "$total" "$available" "$used_gpus"
            echo -e "${YELLOW}$status_text${NC}"
        else
            status_text="full"
            printf "%-15s %5s %9s %6s " "$node" "$total" "$available" "$used_gpus"
            echo -e "${RED}$status_text${NC}"
        fi
    fi
    done
fi

echo

# Get unique workloads (group by job/deployment to avoid duplicates)
echo -e "${WHITE}📋 Current GPU workloads:${NC}"
kubectl get pods --all-namespaces \
    -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,GPU:.spec.containers[*].resources.requests.nvidia\.com/gpu,STATUS:.status.phase,PRIORITY:.spec.priority" \
    --no-headers 2>/dev/null | \
awk '
$3 != "<none>" && $3 != "" && $3 ~ /^[0-9]+$/ {
    # Extract job/deployment base name (remove pod suffix)
    sub(/-[a-z0-9]{5,10}(-[a-z0-9]{5})?$/, "", $2)

    # Create unique key for workload type
    key = $1 "|" $2 "|" $3 "|" $5

    # Track status counts for each workload
    workloads[key] = $1 "|" $2 "|" $3 "|" $5
    status_count[key ":" $4]++

    if ($4 == "Running") {
        running_gpus[key] += $3
    }
    total_gpus[key] += $3
}
END {
    for (key in workloads) {
        split(workloads[key], parts, "|")
        ns = parts[1]
        name = parts[2]
        gpu = parts[3]
        priority = parts[4]

        # Count statuses
        running = status_count[key ":Running"] + 0
        failed = status_count[key ":Failed"] + 0
        pending = status_count[key ":Pending"] + 0

        # Determine primary status
        if (running > 0) {
            status_icon = "🟢"
            status_text = running "✅"
        } else if (pending > 0) {
            status_icon = "🟡"
            status_text = pending "⏳"
        } else {
            status_icon = "🔴"
            status_text = failed "❌"
        }

        # Format priority
        if (priority >= 1000000) {
            priority_info = "(high)"
        } else if (priority >= 0) {
            priority_info = "(system)"
        } else {
            priority_info = "(low)"
        }

        printf "%s %-30s %2d GPUs %-8s %s\n", \
               status_icon, \
               substr(ns "/" name, 1, 29), \
               gpu, \
               priority_info, \
               status_text
    }
}'

echo
echo -e "${BOLD}💡 Summary by namespace:${NC}"
kubectl get pods --all-namespaces \
    -o custom-columns="NS:.metadata.namespace,GPU:.spec.containers[*].resources.requests.nvidia\.com/gpu,STATUS:.status.phase" \
    --no-headers 2>/dev/null | \
awk '
BEGIN {
    total_running = 0; total_requested = 0
}
$2 != "<none>" && $2 != "" && $2 ~ /^[0-9]+$/ {
    # Only count non-failed pods in the "requested" total
    if ($3 != "Failed" && $3 != "Succeeded") {
        ns_total[$1] += $2
        total_requested += $2
    }
    if ($3 == "Running") {
        ns_running[$1] += $2
        total_running += $2
    }
}
END {
    for (ns in ns_total) {
        running = (ns in ns_running) ? ns_running[ns] : 0
        printf "  %-25s %2d/%2d GPUs (%s)\n", ns, running, ns_total[ns], (running > 0 ? "active" : "inactive")
    }
    printf "\n  CLUSTER TOTAL: %d/%d GPUs running/requested\n", total_running, total_requested
}'