#!/bin/bash

# vLLM Inference Testing Script
# Usage: ./test_inference.sh [port] [host]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Default values
DEFAULT_PORT=8000
DEFAULT_HOST="localhost"

# Parse arguments
PORT="${1:-$DEFAULT_PORT}"
HOST="${2:-$DEFAULT_HOST}"
BASE_URL="http://$HOST:$PORT"

show_usage() {
    echo -e "${BOLD}${CYAN}🧠 vLLM Inference Testing Tool${NC}"
    echo
    echo "Usage:"
    echo "  $0 [port] [host]"
    echo
    echo "Examples:"
    echo "  $0                           # Test localhost:8000"
    echo "  $0 8080                      # Test localhost:8080"
    echo "  $0 8000 192.168.1.100        # Test remote host"
    echo
    echo "This script will:"
    echo "  1. 🔍 Discover available models"
    echo "  2. 📋 List models for selection"
    echo "  3. 💬 Run inference with your prompt"
    echo "  4. 📄 Display formatted results"
}

if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

echo -e "${BOLD}${CYAN}🧠 vLLM Inference Testing Tool${NC}"
echo -e "${WHITE}Testing endpoint: ${CYAN}$BASE_URL${NC}"
echo

# Function to test if service is reachable
test_connection() {
    echo -e "${BLUE}🔗 Testing connection to $BASE_URL...${NC}"
    if curl -s --connect-timeout 5 "$BASE_URL/health" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Service is reachable${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  /health endpoint not found, trying /v1/models directly...${NC}"
        return 0  # Continue anyway, some services don't have /health
    fi
}

# Function to get models
get_models() {
    echo -e "${BLUE}🔍 Discovering available models...${NC}" >&2
    echo -e "${WHITE}Running: ${CYAN}curl $BASE_URL/v1/models${NC}" >&2
    echo >&2

    local models_response
    if ! models_response=$(curl -s --connect-timeout 10 "$BASE_URL/v1/models" 2>/dev/null); then
        echo -e "${RED}❌ Failed to connect to $BASE_URL/v1/models${NC}" >&2
        echo -e "${WHITE}💡 Make sure:${NC}" >&2
        echo "  - The service is running" >&2
        echo "  - Port forwarding is active: kubectl port-forward svc/service-name $PORT:80" >&2
        echo "  - The correct port ($PORT) is being used" >&2
        return 1
    fi

    echo -e "${YELLOW}📄 Raw response (formatted with jq):${NC}" >&2
    if command -v jq >/dev/null 2>&1; then
        echo "$models_response" | jq . >&2
    else
        echo "$models_response" >&2
        echo -e "${YELLOW}⚠️  Install jq for better JSON formatting${NC}" >&2
    fi
    echo >&2

    # Extract model IDs/names with better error handling
    local model_list
    echo -e "${BLUE}🔍 Parsing available models...${NC}" >&2

    if command -v jq >/dev/null 2>&1; then
        # Try different ways to extract model names with jq
        if model_list=$(echo "$models_response" | jq -r '.data[]?.id // .data[]?.model // .data[]?.name // empty' 2>/dev/null | grep -v "null" | sort -u); then
            if [ -n "$model_list" ]; then
                echo -e "${GREEN}✅ Found models:${NC}" >&2
                local count=1
                while IFS= read -r model; do
                    echo -e "  ${count}: ${CYAN}$model${NC}" >&2
                    ((count++))
                done <<< "$model_list"
                echo >&2
                echo "$model_list"  # Return for further processing (stdout only)
                return 0
            fi
        fi

        # Fallback: try to extract any string that looks like a model
        if model_list=$(echo "$models_response" | jq -r '.data[] | (.id // .model // .name // (.root // "unknown"))' 2>/dev/null | grep -v "null" | sort -u); then
            if [ -n "$model_list" ]; then
                echo -e "${GREEN}✅ Found models (fallback parsing):${NC}" >&2
                local count=1
                while IFS= read -r model; do
                    echo -e "  ${count}: ${CYAN}$model${NC}" >&2
                    ((count++))
                done <<< "$model_list"
                echo >&2
                echo "$model_list"
                return 0
            fi
        fi
    else
        # No jq available, use grep/sed
        if echo "$models_response" | grep -q '"id":'; then
            model_list=$(echo "$models_response" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | sort -u)
            if [ -n "$model_list" ]; then
                echo -e "${GREEN}✅ Found models (no jq):${NC}" >&2
                echo "$model_list" | nl -w2 -s': ' | sed 's/^/  /' >&2
                echo >&2
                echo "$model_list"
                return 0
            fi
        fi
    fi

    echo -e "${RED}❌ Could not parse any models from response${NC}" >&2
    echo -e "${WHITE}Raw response was:${NC}" >&2
    echo "$models_response" >&2
    return 1
}

# Function to select model
select_model() {
    local models="$1"
    local model_count
    model_count=$(echo "$models" | wc -l)

    if [ "$model_count" -eq 1 ]; then
        echo "$models"
        return 0
    fi

    echo -e "${YELLOW}📋 Multiple models available. Please select:${NC}"
    echo "$models" | nl -w2 -s': ' | sed 's/^/  /'
    echo
    read -p "Select model number (1-$model_count): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$model_count" ]; then
        echo "$models" | sed -n "${choice}p"
        return 0
    else
        echo -e "${RED}❌ Invalid selection${NC}"
        return 1
    fi
}

# Function to get user prompt
get_prompt() {
    echo -e "${BLUE}💬 Enter your prompt:${NC}" >&2
    echo -e "${WHITE}(Type your prompt and press Enter)${NC}" >&2
    echo -e "${WHITE}(For multiline prompts, type 'MULTI' first, then end with 'END')${NC}" >&2

    local prompt=""
    local line

    read -r line

    if [[ "$line" == "MULTI" ]]; then
        echo -e "${YELLOW}📝 Multiline mode - type your prompt, then 'END' on a new line:${NC}" >&2
        prompt=""
        while read -r line; do
            if [[ "$line" == "END" ]]; then
                break
            fi
            if [ -n "$prompt" ]; then
                prompt="$prompt"$'\n'"$line"
            else
                prompt="$line"
            fi
        done
    else
        # Single line prompt
        prompt="$line"
    fi

    if [ -z "$prompt" ]; then
        echo -e "${YELLOW}⚠️  Empty prompt, using default: 'Hello, how are you?'${NC}" >&2
        prompt="Hello, how are you?"
    fi

    echo "$prompt"  # Only the prompt goes to stdout
}

# Function to run inference
run_inference() {
    local model="$1"
    local prompt="$2"

    echo -e "${BLUE}🚀 Running inference...${NC}"
    echo -e "${WHITE}Model: ${CYAN}$model${NC}"
    echo -e "${WHITE}Prompt: ${CYAN}${prompt:0:100}...${NC}"
    echo

    # Try different inference endpoints
    local endpoints=("/v1/completions" "/v1/chat/completions" "/generate")
    local inference_data
    local response

    for endpoint in "${endpoints[@]}"; do
        echo -e "${BLUE}🔄 Trying $BASE_URL$endpoint...${NC}"

        if [[ "$endpoint" == "/v1/chat/completions" ]]; then
            # Use jq to properly escape JSON
            if command -v jq >/dev/null 2>&1; then
                inference_data=$(jq -n \
                    --arg model "$model" \
                    --arg content "$prompt" \
                    '{
                        "model": $model,
                        "messages": [{"role": "user", "content": $content}],
                        "max_tokens": 150,
                        "temperature": 0.7
                    }')
            else
                # Fallback: manual escaping (basic)
                escaped_prompt=$(echo "$prompt" | sed 's/"/\\"/g' | sed "s/'/\\'/g")
                inference_data=$(cat <<EOF
{
    "model": "$model",
    "messages": [
        {"role": "user", "content": "$escaped_prompt"}
    ],
    "max_tokens": 150,
    "temperature": 0.7
}
EOF
)
            fi
        else
            # Use jq for completions endpoint too
            if command -v jq >/dev/null 2>&1; then
                inference_data=$(jq -n \
                    --arg model "$model" \
                    --arg prompt "$prompt" \
                    '{
                        "model": $model,
                        "prompt": $prompt,
                        "max_tokens": 150,
                        "temperature": 0.7
                    }')
            else
                # Fallback: manual escaping
                escaped_prompt=$(echo "$prompt" | sed 's/"/\\"/g' | sed "s/'/\\'/g")
                inference_data=$(cat <<EOF
{
    "model": "$model",
    "prompt": "$escaped_prompt",
    "max_tokens": 150,
    "temperature": 0.7
}
EOF
)
            fi
        fi

        if response=$(curl -s --connect-timeout 30 -X POST \
            -H "Content-Type: application/json" \
            -d "$inference_data" \
            "$BASE_URL$endpoint" 2>/dev/null); then

            echo -e "${GREEN}✅ Success with $endpoint${NC}"
            break
        else
            echo -e "${YELLOW}⚠️  Failed with $endpoint${NC}"
        fi
    done

    if [ -z "$response" ]; then
        echo -e "${RED}❌ All inference endpoints failed${NC}"
        return 1
    fi

    echo -e "${YELLOW}📄 Raw response:${NC}"
    if command -v jq >/dev/null 2>&1; then
        # Test if response is valid JSON
        if echo "$response" | jq . >/dev/null 2>&1; then
            echo "$response" | jq .
        else
            echo -e "${YELLOW}⚠️  Response is not valid JSON, showing raw:${NC}"
            echo "$response"
        fi
    else
        echo "$response"
        echo -e "${YELLOW}⚠️  Install jq for better JSON formatting${NC}"
    fi
    echo

    # Extract and format the generated text
    echo -e "${GREEN}🎯 Generated Response:${NC}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Try to extract text from different response formats
    local generated_text
    if generated_text=$(echo "$response" | jq -r '.choices[0].text // .choices[0].message.content // .generated_text // empty' 2>/dev/null); then
        if [ -n "$generated_text" ]; then
            echo "$generated_text"
        else
            echo -e "${YELLOW}⚠️  Could not extract generated text from response${NC}"
            echo "$response"
        fi
    else
        echo -e "${YELLOW}⚠️  Response format not recognized, showing raw response:${NC}"
        echo "$response"
    fi

    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Main script execution
main() {
    # Test connection
    test_connection

    # Get available models
    echo -e "${BOLD}${YELLOW}Step 1: Getting available models${NC}"
    local models
    if ! models=$(get_models); then
        exit 1
    fi

    # Ask if user wants to run inference
    echo
    echo -e "${BOLD}${YELLOW}Step 2: Inference test${NC}"
    read -p "Do you want to run inference? (y/n): " run_inference_choice

    if [[ "$run_inference_choice" =~ ^[Yy]$ ]]; then
        # Select model
        echo
        echo -e "${BOLD}${YELLOW}Step 3: Model selection${NC}"
        local selected_model
        if ! selected_model=$(select_model "$models"); then
            exit 1
        fi
        echo -e "${GREEN}Selected model: $selected_model${NC}"

        # Get prompt
        echo
        echo -e "${BOLD}${YELLOW}Step 4: Prompt input${NC}"
        local user_prompt
        user_prompt=$(get_prompt)
        echo -e "${GREEN}✅ Captured prompt: ${CYAN}$user_prompt${NC}"

        # Run inference
        echo
        echo -e "${BOLD}${YELLOW}Step 5: Running inference${NC}"
        run_inference "$selected_model" "$user_prompt"

        echo
        echo -e "${BOLD}${GREEN}🎉 Inference test completed!${NC}"

        # Ask if user wants to test again
        echo
        read -p "Test another prompt? (y/n): " test_again
        if [[ "$test_again" =~ ^[Yy]$ ]]; then
            echo
            echo -e "${CYAN}🔄 Running another test...${NC}"
            echo
            user_prompt=$(get_prompt)
            run_inference "$selected_model" "$user_prompt"
        fi
    else
        echo -e "${CYAN}ℹ️  Skipping inference test${NC}"
    fi

    echo
    echo -e "${BOLD}${CYAN}✨ Testing complete!${NC}"
}

# Run main function
main "$@"