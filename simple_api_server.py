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

# Store account monitoring data
accounts_data = {}  # {account_id: {balance, trades, last_update, etc}}
accounts_lock = threading.Lock()

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

@app.route('/api/account/status', methods=['POST'])
def receive_account_status():
    """Δέχεται account status από SignalReceiver instances"""
    global accounts_data
    
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "No data provided"}), 400
        
        account_id = data.get('account_id') or data.get('account_number')
        if not account_id:
            return jsonify({"error": "account_id required"}), 400
        
        with accounts_lock:
            accounts_data[str(account_id)] = {
                "account_id": account_id,
                "account_name": data.get('account_name', 'Unknown'),
                "balance": data.get('balance', 0),
                "equity": data.get('equity', 0),
                "open_trades": data.get('open_trades', []),
                "daily_profit": data.get('daily_profit', 0),
                "is_running": data.get('is_running', False),
                "last_update": datetime.now().isoformat(),
                "magic_number": data.get('magic_number', 0),
                "server": data.get('server', 'Unknown')
            }
        
        print(f"  📊 Account {account_id} status updated")
        return jsonify({"status": "ok", "account_id": account_id}), 200
        
    except Exception as e:
        print(f"✗ Error receiving account status: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/api/accounts', methods=['GET'])
def get_all_accounts():
    """Επιστρέφει όλα τα accounts"""
    global accounts_data
    
    with accounts_lock:
        # Clean up old accounts (not updated in last 5 minutes)
        current_time = datetime.now()
        accounts_to_remove = []
        
        for account_id, account_data in accounts_data.items():
            last_update_str = account_data.get('last_update', '')
            if last_update_str:
                try:
                    last_update = datetime.fromisoformat(last_update_str)
                    if (current_time - last_update).total_seconds() > 300:  # 5 minutes
                        accounts_to_remove.append(account_id)
                except:
                    pass
        
        for account_id in accounts_to_remove:
            del accounts_data[account_id]
        
        return jsonify({
            "accounts": list(accounts_data.values()),
            "total": len(accounts_data)
        }), 200

@app.route('/dashboard', methods=['GET'])
def dashboard():
    """Web dashboard για monitoring"""
    return '''
<!DOCTYPE html>
<html lang="el">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MT5 Signal Receiver - Monitoring Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
        }
        h1 {
            color: white;
            text-align: center;
            margin-bottom: 30px;
            font-size: 2.5em;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        .stats-bar {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            text-align: center;
        }
        .stat-card h3 {
            color: #667eea;
            font-size: 0.9em;
            margin-bottom: 10px;
        }
        .stat-card .value {
            font-size: 2em;
            font-weight: bold;
            color: #333;
        }
        .accounts-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(400px, 1fr));
            gap: 20px;
        }
        .account-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.2s;
        }
        .account-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 6px 12px rgba(0,0,0,0.15);
        }
        .account-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
            padding-bottom: 15px;
            border-bottom: 2px solid #f0f0f0;
        }
        .account-name {
            font-size: 1.3em;
            font-weight: bold;
            color: #333;
        }
        .status-badge {
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.8em;
            font-weight: bold;
        }
        .status-running {
            background: #4CAF50;
            color: white;
        }
        .status-stopped {
            background: #f44336;
            color: white;
        }
        .account-info {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
            margin-bottom: 15px;
        }
        .info-item {
            display: flex;
            flex-direction: column;
        }
        .info-label {
            font-size: 0.8em;
            color: #666;
            margin-bottom: 5px;
        }
        .info-value {
            font-size: 1.1em;
            font-weight: bold;
            color: #333;
        }
        .profit-positive { color: #4CAF50; }
        .profit-negative { color: #f44336; }
        .trades-list {
            margin-top: 15px;
        }
        .trades-list h4 {
            color: #667eea;
            margin-bottom: 10px;
            font-size: 0.9em;
        }
        .trade-item {
            background: #f9f9f9;
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 8px;
            font-size: 0.9em;
        }
        .trade-item strong {
            color: #667eea;
        }
        .refresh-btn {
            position: fixed;
            bottom: 30px;
            right: 30px;
            background: #4CAF50;
            color: white;
            border: none;
            padding: 15px 25px;
            border-radius: 50px;
            font-size: 1em;
            cursor: pointer;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
            transition: background 0.3s;
        }
        .refresh-btn:hover {
            background: #45a049;
        }
        .no-accounts {
            text-align: center;
            color: white;
            font-size: 1.5em;
            padding: 50px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>📊 MT5 Signal Receiver - Monitoring Dashboard</h1>
        
        <div class="stats-bar" id="statsBar">
            <!-- Stats will be populated by JavaScript -->
        </div>
        
        <div class="accounts-grid" id="accountsGrid">
            <!-- Accounts will be populated by JavaScript -->
        </div>
        
        <div class="no-accounts" id="noAccounts" style="display: none;">
            ⏳ Δεν υπάρχουν accounts συνδεδεμένα...
        </div>
    </div>
    
    <button class="refresh-btn" onclick="loadAccounts()">🔄 Refresh</button>
    
    <script>
        function formatNumber(num) {
            return new Intl.NumberFormat('el-GR', { 
                minimumFractionDigits: 2, 
                maximumFractionDigits: 2 
            }).format(num);
        }
        
        function formatDate(dateStr) {
            if (!dateStr) return 'N/A';
            const date = new Date(dateStr);
            return date.toLocaleString('el-GR');
        }
        
        function loadAccounts() {
            fetch('/api/accounts')
                .then(response => response.json())
                .then(data => {
                    const accounts = data.accounts || [];
                    
                    // Update stats
                    const totalAccounts = accounts.length;
                    const runningAccounts = accounts.filter(a => a.is_running).length;
                    const totalTrades = accounts.reduce((sum, a) => sum + (a.open_trades?.length || 0), 0);
                    const totalDailyProfit = accounts.reduce((sum, a) => sum + (a.daily_profit || 0), 0);
                    
                    document.getElementById('statsBar').innerHTML = `
                        <div class="stat-card">
                            <h3>Σύνολο Accounts</h3>
                            <div class="value">${totalAccounts}</div>
                        </div>
                        <div class="stat-card">
                            <h3>Ενεργά Accounts</h3>
                            <div class="value">${runningAccounts}</div>
                        </div>
                        <div class="stat-card">
                            <h3>Ανοιχτά Trades</h3>
                            <div class="value">${totalTrades}</div>
                        </div>
                        <div class="stat-card">
                            <h3>Συνολικό Daily Profit</h3>
                            <div class="value ${totalDailyProfit >= 0 ? 'profit-positive' : 'profit-negative'}">
                                ${formatNumber(totalDailyProfit)} €
                            </div>
                        </div>
                    `;
                    
                    // Update accounts grid
                    if (accounts.length === 0) {
                        document.getElementById('accountsGrid').style.display = 'none';
                        document.getElementById('noAccounts').style.display = 'block';
                    } else {
                        document.getElementById('accountsGrid').style.display = 'grid';
                        document.getElementById('noAccounts').style.display = 'none';
                        
                        document.getElementById('accountsGrid').innerHTML = accounts.map(account => {
                            const trades = account.open_trades || [];
                            const tradesHtml = trades.length > 0 
                                ? trades.map(trade => `
                                    <div class="trade-item">
                                        <strong>${trade.symbol}</strong> ${trade.type} | 
                                        Volume: ${trade.volume} | 
                                        Entry: ${formatNumber(trade.entry_price)} | 
                                        Profit: <span class="${trade.profit >= 0 ? 'profit-positive' : 'profit-negative'}">
                                            ${formatNumber(trade.profit)} €
                                        </span>
                                    </div>
                                `).join('')
                                : '<div class="trade-item">Δεν υπάρχουν ανοιχτά trades</div>';
                            
                            return `
                                <div class="account-card">
                                    <div class="account-header">
                                        <div class="account-name">${account.account_name || 'Account ' + account.account_id}</div>
                                        <span class="status-badge ${account.is_running ? 'status-running' : 'status-stopped'}">
                                            ${account.is_running ? '▶️ Running' : '⏸️ Stopped'}
                                        </span>
                                    </div>
                                    <div class="account-info">
                                        <div class="info-item">
                                            <span class="info-label">Account ID</span>
                                            <span class="info-value">${account.account_id}</span>
                                        </div>
                                        <div class="info-item">
                                            <span class="info-label">Server</span>
                                            <span class="info-value">${account.server || 'N/A'}</span>
                                        </div>
                                        <div class="info-item">
                                            <span class="info-label">Balance</span>
                                            <span class="info-value">${formatNumber(account.balance || 0)} €</span>
                                        </div>
                                        <div class="info-item">
                                            <span class="info-label">Equity</span>
                                            <span class="info-value">${formatNumber(account.equity || 0)} €</span>
                                        </div>
                                        <div class="info-item">
                                            <span class="info-label">Daily Profit</span>
                                            <span class="info-value ${account.daily_profit >= 0 ? 'profit-positive' : 'profit-negative'}">
                                                ${formatNumber(account.daily_profit || 0)} €
                                            </span>
                                        </div>
                                        <div class="info-item">
                                            <span class="info-label">Last Update</span>
                                            <span class="info-value">${formatDate(account.last_update)}</span>
                                        </div>
                                    </div>
                                    <div class="trades-list">
                                        <h4>Ανοιχτά Trades (${trades.length})</h4>
                                        ${tradesHtml}
                                    </div>
                                </div>
                            `;
                        }).join('');
                    }
                })
                .catch(error => {
                    console.error('Error loading accounts:', error);
                    document.getElementById('accountsGrid').innerHTML = 
                        '<div class="no-accounts">❌ Σφάλμα φόρτωσης δεδομένων</div>';
                });
        }
        
        // Auto-refresh every 10 seconds
        loadAccounts();
        setInterval(loadAccounts, 10000);
    </script>
</body>
</html>
    ''', 200

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

