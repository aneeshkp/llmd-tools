#!/bin/bash

# Gateway Inference Extension (GIE) CRD and Provider Checker
# Checks for required CRDs, namespaces, and providers

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}🔍 Gateway Inference Extension (GIE) Infrastructure Check${NC}"
echo -e "${WHITE}Cluster: $(kubectl config current-context)${NC}"
echo

# Function to check CRD existence and details
check_crd() {
    local crd_name="$1"
    local display_name="$2"

    if kubectl get crd "$crd_name" >/dev/null 2>&1; then
        local version=$(kubectl get crd "$crd_name" -o jsonpath='{.spec.versions[*].name}' 2>/dev/null | tr ' ' ',')
        local group=$(kubectl get crd "$crd_name" -o jsonpath='{.spec.group}' 2>/dev/null)
        echo -e "  ✅ ${GREEN}$display_name${NC} (${group}) - versions: $version"
        return 0
    else
        echo -e "  ❌ ${RED}$display_name${NC} - NOT INSTALLED"
        return 1
    fi
}

# Function to check namespace and resources
check_namespace_resources() {
    local namespace="$1"
    local resource_type="$2"
    local display_name="$3"

    if kubectl get ns "$namespace" >/dev/null 2>&1; then
        local count=$(kubectl get "$resource_type" -n "$namespace" --no-headers 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            echo -e "    📦 ${YELLOW}$display_name${NC} in namespace: ${CYAN}$namespace${NC} ($count resources)"
            kubectl get "$resource_type" -n "$namespace" --no-headers 2>/dev/null | head -3 | sed 's/^/      /'
            [ "$count" -gt 3 ] && echo "      ... and $((count-3)) more"
        fi
    fi
}

# Function to get provider info
get_provider_info() {
    local namespace="$1"
    local label_selector="$2"
    local provider_name="$3"

    if kubectl get ns "$namespace" >/dev/null 2>&1; then
        local pods=$(kubectl get pods -n "$namespace" $label_selector --no-headers 2>/dev/null | head -1)
        if [ -n "$pods" ]; then
            local image=$(echo "$pods" | awk '{print $2}' | cut -d':' -f1)
            echo -e "    🏢 ${GREEN}Provider: $provider_name${NC} (image: $image)"
        fi
    fi
}

echo -e "${BOLD}${YELLOW}1️⃣  Gateway API CRDs${NC}"
gateway_api_installed=false

if check_crd "gateways.gateway.networking.k8s.io" "Gateways"; then gateway_api_installed=true; fi
if check_crd "httproutes.gateway.networking.k8s.io" "HTTPRoutes"; then gateway_api_installed=true; fi
if check_crd "grpcroutes.gateway.networking.k8s.io" "GRPCRoutes"; then gateway_api_installed=true; fi
if check_crd "gatewayclasses.gateway.networking.k8s.io" "GatewayClasses"; then gateway_api_installed=true; fi

echo

echo -e "${BOLD}${YELLOW}2️⃣  Inference Extension CRDs${NC}"
inference_ext_installed=false

if check_crd "inferencepools.inference.networking.x-k8s.io" "InferencePools"; then inference_ext_installed=true; fi
if check_crd "inferenceroutes.inference.networking.x-k8s.io" "InferenceRoutes"; then inference_ext_installed=true; fi
if check_crd "inferencebackends.inference.networking.x-k8s.io" "InferenceBackends"; then inference_ext_installed=true; fi

echo

echo -e "${BOLD}${YELLOW}3️⃣  llm-d Specific CRDs${NC}"
llmd_installed=false

check_crd "modelservices.llm-d.ai" "ModelServices" && llmd_installed=true
check_crd "inferenceschedulers.llm-d.ai" "InferenceSchedulers" && llmd_installed=true

echo

echo -e "${BOLD}${YELLOW}4️⃣  Gateway Providers${NC}"

# Check Istio
echo -e "${WHITE}🔍 Checking Istio...${NC}"
if kubectl get crd gateways.networking.istio.io >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Istio CRDs found${NC}"
    check_namespace_resources "istio-system" "pods" "Istio Control Plane"
    get_provider_info "istio-system" "--selector=app=istiod" "Istio"
else
    echo -e "  ❌ ${RED}Istio - NOT INSTALLED${NC}"
fi

echo

# Check Kong
echo -e "${WHITE}🔍 Checking Kong...${NC}"
if kubectl get crd kongplugins.configuration.konghq.com >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Kong CRDs found${NC}"
    check_namespace_resources "kong" "pods" "Kong Gateway"
    get_provider_info "kong" "--selector=app=kong" "Kong"
else
    echo -e "  ❌ ${RED}Kong - NOT INSTALLED${NC}"
fi

echo

# Check Envoy Gateway
echo -e "${WHITE}🔍 Checking Envoy Gateway...${NC}"
if kubectl get crd envoyproxies.gateway.envoyproxy.io >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Envoy Gateway CRDs found${NC}"
    check_namespace_resources "envoy-gateway-system" "pods" "Envoy Gateway"
    get_provider_info "envoy-gateway-system" "--selector=control-plane=envoy-gateway" "Envoy Gateway"
else
    echo -e "  ❌ ${RED}Envoy Gateway - NOT INSTALLED${NC}"
fi

echo

# Check NGINX
echo -e "${WHITE}🔍 Checking NGINX...${NC}"
if kubectl get crd nginxgateways.gateway.nginx.org >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}NGINX Gateway CRDs found${NC}"
    check_namespace_resources "nginx-gateway" "pods" "NGINX Gateway"
    get_provider_info "nginx-gateway" "--selector=app=nginx-gateway" "NGINX"
else
    echo -e "  ❌ ${RED}NGINX Gateway - NOT INSTALLED${NC}"
fi

echo

echo -e "${BOLD}${YELLOW}5️⃣  llm-d Infrastructure${NC}"

# Check llm-d namespaces
echo -e "${WHITE}🔍 llm-d related namespaces:${NC}"
kubectl get ns | grep -E "(llm-d|inference|vllm)" | while read ns rest; do
    echo -e "  📁 ${CYAN}$ns${NC}"
    # Check for common llm-d resources
    for resource in "deployments" "services" "configmaps"; do
        count=$(kubectl get $resource -n "$ns" --no-headers 2>/dev/null | wc -l)
        [ "$count" -gt 0 ] && echo -e "    └── $resource: $count"
    done
done

echo

echo -e "${BOLD}${YELLOW}6️⃣  GatewayClasses (if Gateway API installed)${NC}"
if [ "$gateway_api_installed" = true ]; then
    kubectl get gatewayclasses 2>/dev/null | head -10 | while read line; do
        if [[ "$line" =~ ^NAME ]]; then
            echo -e "  ${BOLD}$line${NC}"
        else
            echo -e "  $line"
        fi
    done
else
    echo -e "  ${RED}Gateway API not installed${NC}"
fi

echo

# Summary
echo -e "${BOLD}${CYAN}📋 SUMMARY${NC}"
echo -e "${BOLD}Gateway API Status:${NC} $([ "$gateway_api_installed" = true ] && echo -e "${GREEN}✅ Installed${NC}" || echo -e "${RED}❌ Not Installed${NC}")"
echo -e "${BOLD}Inference Extension Status:${NC} $([ "$inference_ext_installed" = true ] && echo -e "${GREEN}✅ Installed${NC}" || echo -e "${RED}❌ Not Installed${NC}")"
echo -e "${BOLD}llm-d CRDs Status:${NC} $([ "$llmd_installed" = true ] && echo -e "${GREEN}✅ Installed${NC}" || echo -e "${RED}❌ Not Installed${NC}")"

echo

# Recommendations
echo -e "${BOLD}${CYAN}💡 RECOMMENDATIONS${NC}"
if [ "$gateway_api_installed" = false ]; then
    echo -e "  🔧 ${YELLOW}Install Gateway API CRDs${NC}: kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
fi

if [ "$inference_ext_installed" = false ]; then
    echo -e "  🔧 ${YELLOW}Install Inference Extension${NC}: Check llm-d documentation for inference extension installation"
fi

# Detect specific gateway implementations
echo
echo -e "${BOLD}${YELLOW}7️⃣  Gateway Implementation Detection${NC}"

istio_detected=false
envoy_detected=false
kong_detected=false
nginx_detected=false
kgateway_available=false

if kubectl get crd gateways.networking.istio.io >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Istio Gateway implementation detected${NC}"
    istio_detected=true
fi

if kubectl get crd envoyproxies.gateway.envoyproxy.io >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Envoy Gateway implementation detected${NC}"
    envoy_detected=true
fi

if kubectl get crd kongplugins.configuration.konghq.com >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}Kong Gateway implementation detected${NC}"
    kong_detected=true
fi

if kubectl get crd nginxgateways.gateway.nginx.org >/dev/null 2>&1; then
    echo -e "  ✅ ${GREEN}NGINX Gateway implementation detected${NC}"
    nginx_detected=true
fi

# Check if Gateway API is available but no specific implementation is detected
if [ "$gateway_api_installed" = true ] && [ "$istio_detected" = false ] && [ "$envoy_detected" = false ] && [ "$kong_detected" = false ] && [ "$nginx_detected" = false ]; then
    echo -e "  ✅ ${YELLOW}Generic Gateway API available (kgateway)${NC}"
    echo -e "    ${WHITE}Standard Gateway API CRDs found without specific implementation${NC}"
    kgateway_available=true
fi

if [ "$gateway_api_installed" = false ]; then
    echo -e "  ❌ ${RED}No Gateway API implementation detected${NC}"
fi

# Check what helmfile environment to use
echo
echo -e "${BOLD}${CYAN}🎯 HELMFILE ENVIRONMENT SUGGESTIONS${NC}"
if [ "$istio_detected" = true ]; then
    echo -e "  📋 ${GREEN}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e istio${NC} (Istio detected)"
elif [ "$envoy_detected" = true ]; then
    echo -e "  📋 ${GREEN}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e envoy${NC} (Envoy Gateway detected)"
elif [ "$kong_detected" = true ]; then
    echo -e "  📋 ${GREEN}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e kong${NC} (Kong detected)"
elif [ "$nginx_detected" = true ]; then
    echo -e "  📋 ${GREEN}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e nginx${NC} (NGINX detected)"
elif [ "$kgateway_available" = true ]; then
    echo -e "  📋 ${YELLOW}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e kgateway${NC} (Generic Gateway API)"
    echo -e "    ${WHITE}Note: Requires a GatewayClass to be configured${NC}"
else
    echo -e "  📋 ${CYAN}Use: helmfile apply -n ${TARGET_NAMESPACE:-\$NAMESPACE} -e standalone${NC} (No gateway provider - use standalone)"
fi