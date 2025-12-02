#!/bin/bash
# Helper script to update ngrok URL in bridge scripts and MQL5 files

if [ -z "$1" ]; then
    echo "Usage: $0 <ngrok_url>"
    echo "Example: $0 https://abc123.ngrok.io"
    exit 1
fi

NGROK_URL="$1"
API_ENDPOINT="${NGROK_URL}/api/signal"

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_CMD="sed -i ''"
else
    SED_CMD="sed -i"
fi

# Update web_bridge_server.py
if [ -f "web_bridge_server.py" ]; then
    $SED_CMD "s|WEB_API_URL = \".*\"|WEB_API_URL = \"${API_ENDPOINT}\"|g" web_bridge_server.py
    echo "✓ Updated web_bridge_server.py"
fi

# Update web_bridge_client.py
if [ -f "web_bridge_client.py" ]; then
    $SED_CMD "s|WEB_API_URL = \".*\"|WEB_API_URL = \"${API_ENDPOINT}\"|g" web_bridge_client.py
    echo "✓ Updated web_bridge_client.py"
fi

# Update SignalSender.mq5
if [ -f "EA/SignalSender.mq5" ]; then
    $SED_CMD "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalSender.mq5
    echo "✓ Updated EA/SignalSender.mq5"
fi

# Update SignalReceiver.mq5
if [ -f "EA/SignalReceiver.mq5" ]; then
    $SED_CMD "s|Ngrok_API_URL = \".*\"|Ngrok_API_URL = \"${API_ENDPOINT}\"|g" EA/SignalReceiver.mq5
    echo "✓ Updated EA/SignalReceiver.mq5"
fi

echo "✅ All scripts and EAs updated with: ${API_ENDPOINT}"

