#!/bin/bash
# Master script - Εκκινεί όλα τα services του bridge system

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# PIDs storage
PIDS=()

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping all services...${NC}"
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    echo -e "${GREEN}All services stopped.${NC}"
    exit 0
}

trap cleanup INT TERM

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}MT5 Signal Bridge - Master Startup${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Check if ngrok is installed
if ! command -v ngrok &> /dev/null; then
    echo -e "${RED}❌ ngrok not found!${NC}"
    echo "Install ngrok: https://ngrok.com/download"
    echo "Or: brew install ngrok/ngrok/ngrok (Mac)"
    exit 1
fi

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}❌ Python3 not found!${NC}"
    exit 1
fi

# Setup virtual environment
if [ -d "venv" ]; then
    echo -e "${GREEN}✅ Activating virtual environment...${NC}"
    source venv/bin/activate
    PYTHON_CMD="python"
    PIP_CMD="pip"
else
    echo -e "${YELLOW}⚠️  Virtual environment not found. Creating...${NC}"
    python3 -m venv venv
    source venv/bin/activate
    PYTHON_CMD="python"
    PIP_CMD="pip"
    
    # Install dependencies
    if [ -f "requirements.txt" ]; then
        echo -e "${BLUE}📦 Installing dependencies from requirements.txt...${NC}"
        pip install -r requirements.txt
    else
        echo -e "${YELLOW}⚠️  requirements.txt not found. Installing manually...${NC}"
        pip install flask requests
    fi
fi

# Check dependencies
if ! $PYTHON_CMD -c "import flask" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Flask not installed. Installing...${NC}"
    $PIP_CMD install flask
fi

if ! $PYTHON_CMD -c "import requests" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  requests not installed. Installing...${NC}"
    $PIP_CMD install requests
fi

echo -e "${GREEN}✅ Dependencies OK${NC}"
echo ""

# Ask what to run
echo -e "${BLUE}What would you like to start?${NC}"
echo "1) API Server + Ngrok (Required - Mac)"
echo ""
read -p "Enter choice [1]: " choice

case $choice in
    1)
        echo ""
        echo -e "${BLUE}==========================================${NC}"
        echo -e "${BLUE}Starting API Server + Ngrok...${NC}"
        echo -e "${BLUE}==========================================${NC}"
        echo ""
        
        # Start API server
        echo -e "${GREEN}[1/2] Starting API Server...${NC}"
        $PYTHON_CMD simple_api_server.py > /tmp/api_server.log 2>&1 &
        API_PID=$!
        PIDS+=($API_PID)
        sleep 2
        
        # Start ngrok
        echo -e "${GREEN}[2/2] Starting ngrok tunnel...${NC}"
        ngrok http 8080 > /tmp/ngrok.log 2>&1 &
        NGROK_PID=$!
        PIDS+=($NGROK_PID)
        sleep 3
        
        # Get ngrok URL
        echo ""
        echo -e "${YELLOW}Getting ngrok URL...${NC}"
        sleep 2
        NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | $PYTHON_CMD -c "import sys, json; data=json.load(sys.stdin); urls=[t['public_url'] for t in data['tunnels'] if t['proto']=='https']; print(urls[0] if urls else '')" 2>/dev/null || echo "")
        
        if [ -z "$NGROK_URL" ]; then
            echo -e "${RED}❌ Could not get ngrok URL automatically.${NC}"
            echo -e "${YELLOW}Manual: Open http://localhost:4040 and copy the HTTPS URL${NC}"
            NGROK_URL="https://YOUR_NGROK_URL.ngrok.io"
        else
            echo -e "${GREEN}✅ Ngrok URL: ${NGROK_URL}${NC}"
            
            # Auto-update bridge scripts and MQL5 files
            echo -e "${BLUE}Updating EAs with ngrok URL...${NC}"
            API_ENDPOINT="${NGROK_URL}/api/signal"
            
            # Update SignalSender.mq5
            if [ -f "EA/SignalSender.mq5" ]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalSender.mq5
                else
                    sed -i "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalSender.mq5
                fi
                echo -e "${GREEN}✓ Updated EA/SignalSender.mq5${NC}"
            fi
            
            # Update SignalReceiver.mq5
            if [ -f "EA/SignalReceiver.mq5" ]; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalReceiver.mq5
                else
                    sed -i "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalReceiver.mq5
                fi
                echo -e "${GREEN}✓ Updated EA/SignalReceiver.mq5${NC}"
            fi
        fi
        
        echo ""
        echo -e "${BLUE}==========================================${NC}"
        echo -e "${GREEN}Services running:${NC}"
        echo "  - API Server: PID $API_PID (port 8080)"
        echo "  - Ngrok: PID $NGROK_PID"
        echo "  - Ngrok Web UI: http://localhost:4040"
        echo ""
        echo ""
        echo -e "${YELLOW}⚠️  IMPORTANT:${NC}"
        echo -e "${YELLOW}   1. Add API URL to MT5 allowed list:${NC}"
        echo -e "${YELLOW}      Tools -> Options -> Expert Advisors -> 'Allow WebRequest for listed URL'${NC}"
        echo -e "${YELLOW}      Add: ${NGROK_URL}${NC}"
        echo -e "${YELLOW}   2. Compile and attach SignalSender.mq5 on VPS MT5${NC}"
        echo -e "${YELLOW}   3. Compile and attach SignalReceiver.mq5 on Mac MT5${NC}"
        echo ""
        echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"
        echo -e "${BLUE}==========================================${NC}"
        ;;
        
    *)
        echo -e "${RED}Invalid choice!${NC}"
        exit 1
        ;;
esac

# Wait for user interrupt
wait

