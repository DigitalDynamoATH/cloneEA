#!/usr/bin/env python3
"""
Simple API Server - Τρέχει στο web (VPS ή cloud)
Δέχεται signals από το bridge server και τα δίνει στο client
"""
from flask import Flask, request, jsonify
from datetime import datetime
import threading
import sys
from werkzeug.formparser import parse_form_data

app = Flask(__name__)

# Configure Flask to handle form data even with incorrect Content-Type
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max

# Middleware to force form parsing for form-encoded data
@app.before_request
def force_form_parsing():
    """Force Flask to parse form data even if Content-Type is incorrect"""
    if request.method == 'POST' and request.content_type:
        # If Content-Type suggests form-encoded but Flask hasn't parsed it
        if 'application/x-www-form-urlencoded' in request.content_type:
            # Access request.form to trigger Flask's form parser
            # This ensures form data is available even if Content-Type was set incorrectly
            try:
                _ = request.form  # Trigger form parsing
            except Exception:
                pass  # Ignore parsing errors, we'll handle manually

# Custom logging for HTTP requests
@app.before_request
def log_request_info():
    """Log incoming requests"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]  # Include milliseconds
    print(f"\n{'='*70}")
    print(f"[{timestamp}] 📥 INCOMING REQUEST")
    print(f"  Method: {request.method}")
    print(f"  Route:  {request.path}")
    print(f"  From:   {request.remote_addr}")
    
    if request.args:
        print(f"  Query:  {dict(request.args)}")
    
    if request.is_json:
        data = request.get_json()
        if data and 'signal' in data:
            signal = data.get('signal', '')
            print(f"  📨 Signal received:")
            print(f"     {signal[:100]}..." if len(signal) > 100 else f"     {signal}")
    
    print(f"{'='*70}")

@app.after_request
def log_response_info(response):
    """Log outgoing responses"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]
    status_code = response.status_code
    
    if status_code == 200:
        status_icon = "✅"
        status_text = "OK"
    elif status_code == 204:
        status_icon = "ℹ️"
        status_text = "NO CONTENT"
    elif status_code >= 400:
        status_icon = "❌"
        status_text = f"ERROR {status_code}"
    else:
        status_icon = "⚠️"
        status_text = f"STATUS {status_code}"
    
    print(f"[{timestamp}] {status_icon} RESPONSE: {status_code} {status_text}")
    
    # Show response data if available
    try:
        if response.is_json:
            data = response.get_json()
            if data and 'id' in data:
                print(f"  📤 Signal ID: {data.get('id')}")
            if data and 'status' in data:
                print(f"  Status: {data.get('status')}")
    except:
        pass
    
    print(f"{'='*70}\n")
    sys.stdout.flush()  # Force immediate output
    return response

# Store latest signal and history
latest_signal = None
signal_counter = 0
signal_history = []  # Store last 10 signals for debugging
signal_lock = threading.Lock()
MAX_HISTORY = 10

@app.route('/api/signal', methods=['POST'])
def receive_signal():
    """Δέχεται signal από το bridge server"""
    global latest_signal, signal_counter
    
    try:
        signal = None
        raw_data = None
        
        # Debug: Log what we're receiving
        print(f"  📥 Content-Type: {request.content_type}")
        print(f"  📥 Content-Length: {request.content_length}")
        
        # Try JSON first
        if request.is_json or request.content_type == 'application/json':
            data = request.get_json(silent=True, force=True)
            if data:
                signal = data.get('signal')
                print(f"  📥 Parsed as JSON: {signal[:80] if signal else 'None'}...")
        
        # If not JSON, try form-encoded (MT5 WebRequest sometimes sends form-encoded)
        if not signal:
            # Force Flask to parse form data by accessing request.form
            # This triggers Flask's form parser even if Content-Type is set incorrectly
            try:
                # Access form dict to trigger parsing
                form_dict = dict(request.form)
                if form_dict and 'signal' in form_dict:
                    signal = form_dict['signal']
                    print(f"  📥 Parsed from request.form: {signal[:80] if signal else 'None'}...")
            except Exception as e:
                print(f"  ⚠️  request.form parsing failed: {e}")
            
            # If still no signal, try query parameters
            if not signal and request.args and 'signal' in request.args:
                signal = request.args.get('signal')
                print(f"  📥 Parsed from request.args: {signal[:80] if signal else 'None'}...")
            
            # If still no signal, parse raw data manually
            if not signal:
                # Get raw data (this might be empty if Flask already consumed it)
                raw_data = request.get_data(as_text=True, cache=True)
                print(f"  📥 Raw data length: {len(raw_data) if raw_data else 0}")
                print(f"  📥 Raw data preview: {raw_data[:200] if raw_data else 'EMPTY'}...")
                
                if raw_data:
                    # Parse form-encoded: signal=ACTION=OPEN|SYMBOL=...
                    # Handle both URL-encoded and plain form data
                    from urllib.parse import unquote_plus, parse_qs
                    
                    # Try parse_qs first (handles form-encoded properly)
                    try:
                        parsed = parse_qs(raw_data, keep_blank_values=True)
                        if 'signal' in parsed and parsed['signal']:
                            signal = parsed['signal'][0]  # Get first value
                            # URL decode the signal (parse_qs may not decode everything)
                            signal = unquote_plus(signal)
                            print(f"  📥 Parsed from parse_qs: {signal[:80]}...")
                    except Exception as e:
                        print(f"  ⚠️  parse_qs failed: {e}")
                    
                    # If parse_qs didn't work, try manual parsing
                    if not signal:
                        if 'signal=' in raw_data:
                            # Extract signal value
                            signal_part = raw_data.split('signal=')[1]
                            # Remove any trailing & or other params
                            if '&' in signal_part:
                                signal_part = signal_part.split('&')[0]
                            # URL decode (handles + as space, % encoding, etc.)
                            # This handles: %20=space, %3D==, %7C=|, %26=&, etc.
                            signal = unquote_plus(signal_part)
                            print(f"  📥 Parsed manually from raw_data: {signal[:80]}...")
                        elif raw_data.strip():
                            # Try to parse as plain text signal (already decoded)
                            signal = raw_data.strip()
                            print(f"  📥 Using raw_data as signal: {signal[:80]}...")
        
        if not signal:
            error_info = {
                "error": "No signal provided",
                "content_type": request.content_type,
                "content_length": request.content_length,
                "has_form": bool(request.form),
                "form_keys": list(request.form.keys()) if request.form else [],
                "has_args": bool(request.args),
                "args_keys": list(request.args.keys()) if request.args else [],
                "raw_data_length": len(raw_data) if raw_data else 0,
                "raw_data_preview": raw_data[:200] if raw_data else ""
            }
            print(f"  ❌ Failed to parse signal. Debug info: {error_info}")
            return jsonify(error_info), 400
        
        with signal_lock:
            signal_counter += 1
            latest_signal = {
                "id": signal_counter,
                "signal": signal,
                "timestamp": datetime.now().isoformat()
            }
            # Add to history
            signal_history.append(latest_signal.copy())
            if len(signal_history) > MAX_HISTORY:
                signal_history.pop(0)
        
        print(f"  💾 Signal #{signal_counter} stored in memory")
        print(f"  📊 Total signals received: {signal_counter}")
        print(f"  📝 Signal content: {signal[:100]}...")
        return jsonify({"status": "ok", "id": signal_counter}), 200
        
    except Exception as e:
        import traceback
        print(f"✗ Error: {e}")
        print(f"  Content-Type: {request.content_type}")
        print(f"  Raw data: {request.get_data(as_text=True)[:200]}")
        print(f"  Traceback: {traceback.format_exc()}")
        return jsonify({"error": str(e), "content_type": request.content_type}), 500

@app.route('/api/signal', methods=['GET'])
def get_signal():
    """Επιστρέφει το τελευταίο signal"""
    global latest_signal
    
    last_id = request.args.get('last_id', type=int)
    
    with signal_lock:
        if latest_signal and latest_signal["id"] != last_id:
            print(f"  📤 Returning signal #{latest_signal['id']} to client")
            print(f"  📝 Signal: {latest_signal.get('signal', '')[:80]}...")
            return jsonify(latest_signal), 200
    
    print(f"  ℹ️  No new signal (client last_id: {last_id}, server latest: {latest_signal['id'] if latest_signal else 'None'})")
    return jsonify({"message": "No new signal"}), 204

@app.route('/', methods=['GET'])
def root():
    """Root endpoint - API information"""
    return jsonify({
        "service": "MT5 Signal Bridge API",
        "version": "1.0",
        "endpoints": {
            "POST /api/signal": "Receive signals from SignalSender",
            "GET /api/signal": "Get latest signal for SignalReceiver",
            "GET /api/signals/history": "Get signal history",
            "GET /health": "Health check"
        },
        "status": "running"
    }), 200

@app.route('/health', methods=['GET'])
def health():
    """Health check"""
    print(f"  💚 Health check - Server is running")
    print(f"  📊 Total signals received: {signal_counter}")
    return jsonify({
        "status": "ok",
        "server": "MT5 Signal Bridge API",
        "signals_received": signal_counter,
        "latest_signal_id": latest_signal["id"] if latest_signal else None
    }), 200

@app.route('/api/signals/history', methods=['GET'])
def get_signal_history():
    """Επιστρέφει το history των signals για debugging"""
    global signal_history, latest_signal
    
    with signal_lock:
        return jsonify({
            "latest": latest_signal,
            "history": signal_history,
            "total_received": signal_counter
        }), 200

if __name__ == '__main__':
    print("=" * 50)
    print("Simple API Server Started")
    print("Endpoints:")
    print("  POST /api/signal - Receive signal from bridge server")
    print("  GET  /api/signal - Get latest signal (for client)")
    print("  GET  /api/signals/history - Get signal history (for debugging)")
    print("  GET  /health - Health check")
    print("=" * 50)
    print("\n⚠️  IMPORTANT: Start ngrok in another terminal:")
    print("   ngrok http 8080")
    print("   Then copy the HTTPS URL (e.g., https://abc123.ngrok.io)")
    print("   Update WEB_API_URL in web_bridge_server.py and web_bridge_client.py")
    print("=" * 50)
    print("\nServer running on http://localhost:8080")
    print("Waiting for ngrok tunnel...\n")
    
    # Disable Flask's default request logging (we use our custom one)
    import logging
    log = logging.getLogger('werkzeug')
    log.setLevel(logging.ERROR)
    
    print("\n" + "=" * 70)
    print("🚀 API SERVER STARTED")
    print("=" * 70)
    print(f"📍 Listening on: http://0.0.0.0:8080")
    print(f"🌐 Public URL: (via ngrok)")
    print(f"📡 Endpoints:")
    print(f"   POST /api/signal        - Receive signals from Bridge Server")
    print(f"   GET  /api/signal        - Get latest signal (for Bridge Client)")
    print(f"   GET  /api/signals/history - Get signal history")
    print(f"   GET  /health            - Health check")
    print(f"   GET  /                  - API info")
    print("=" * 70)
    print("⏳ Waiting for requests...\n")
    
    # Get port from environment variable (for Render/Heroku) or use default 8080
    import os
    port = int(os.environ.get('PORT', 8080))
    
    # Run on all interfaces, using PORT from environment or default 8080
    app.run(host='0.0.0.0', port=port, debug=False)

