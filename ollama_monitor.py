import requests
import time
import json
import logging
import threading
import sqlite3
import os
import re
from datetime import datetime
from flask import Flask, request, jsonify, Response
from waitress import serve

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    filename='ollama_monitor.log'
)
logger = logging.getLogger('ollama_monitor')

# Configure Settings
OLLAMA_HOST = "http://localhost:11434"
WEB_HOST = "0.0.0.0"
WEB_PORT = 8080
DB_FILE = "ollama_metrics.db"

class OllamaMetricsDB:
    def __init__(self, db_file=DB_FILE):
        """Initialize database connection"""
        self.db_file = db_file
        self._create_tables()
    
    def _create_tables(self):
        """Create required tables if they do not exist"""
        conn = sqlite3.connect(self.db_file)
        cursor = conn.cursor()
        
        # Settings table for active model and cookies
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        ''')
        
        # Cloud usage limits table
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS cloud_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            session_used_percent REAL,
            session_reset_text TEXT,
            weekly_used_percent REAL,
            weekly_reset_text TEXT,
            balance_remaining REAL,
            session_details_json TEXT DEFAULT '{}',
            weekly_details_json TEXT DEFAULT '{}'
        )
        ''')
        
        # Proxy request logs table (optional legacy compatibility)
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS request_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            client_ip TEXT,
            model_name TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER,
            response_time REAL,
            status_code INTEGER,
            endpoint TEXT
        )
        ''')
        
        # Migration for details columns in older databases
        try:
            cursor.execute("ALTER TABLE cloud_usage ADD COLUMN session_details_json TEXT DEFAULT '{}'")
        except sqlite3.OperationalError:
            pass
        try:
            cursor.execute("ALTER TABLE cloud_usage ADD COLUMN weekly_details_json TEXT DEFAULT '{}'")
        except sqlite3.OperationalError:
            pass
        
        conn.commit()
        conn.close()
        
    def get_setting(self, key):
        """Get value for a configuration key"""
        conn = sqlite3.connect(self.db_file)
        cursor = conn.cursor()
        cursor.execute("SELECT value FROM settings WHERE key=?", (key,))
        row = cursor.fetchone()
        conn.close()
        return row[0] if row else None
        
    def save_setting(self, key, value):
        """Save or replace a configuration key-value pair"""
        conn = sqlite3.connect(self.db_file)
        cursor = conn.cursor()
        cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, value))
        conn.commit()
        conn.close()
        
    def set_active_model(self, model_name):
        """Record the currently active model and timestamp"""
        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()
            now_str = datetime.now().isoformat()
            cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('active_model', ?)", (model_name,))
            cursor.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('active_timestamp', ?)", (now_str,))
            conn.commit()
            conn.close()
        except Exception as e:
            logger.error(f"Failed to set active model in DB: {e}")
            
    def save_request_log(self, log_data):
        """Save a proxied request log"""
        try:
            conn = sqlite3.connect(self.db_file)
            cursor = conn.cursor()
            cursor.execute('''
            INSERT INTO request_logs (
                timestamp, client_ip, model_name, input_tokens, 
                output_tokens, response_time, status_code, endpoint
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                log_data['timestamp'],
                log_data['client_ip'],
                log_data['model_name'],
                log_data['input_tokens'],
                log_data['output_tokens'],
                log_data['response_time'],
                log_data['status_code'],
                log_data['endpoint']
            ))
            conn.commit()
            conn.close()
        except Exception as e:
            logger.error(f"Failed to save request log: {e}")
            
    def save_cloud_usage(self, session_pct, session_reset, weekly_pct, weekly_reset, balance, session_details="{}", weekly_details="{}"):
        """Save scraped cloud usage statistics"""
        conn = sqlite3.connect(self.db_file)
        cursor = conn.cursor()
        
        # Migrations for safety
        try:
            cursor.execute("ALTER TABLE cloud_usage ADD COLUMN session_details_json TEXT DEFAULT '{}'")
            cursor.execute("ALTER TABLE cloud_usage ADD COLUMN weekly_details_json TEXT DEFAULT '{}'")
            conn.commit()
        except sqlite3.OperationalError:
            pass
            
        cursor.execute('''
        INSERT INTO cloud_usage (
            timestamp, session_used_percent, session_reset_text,
            weekly_used_percent, weekly_reset_text, balance_remaining,
            session_details_json, weekly_details_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', (
            datetime.now().isoformat(),
            session_pct,
            session_reset,
            weekly_pct,
            weekly_reset,
            balance,
            session_details,
            weekly_details
        ))
        conn.commit()
        conn.close()
        
    def get_latest_cloud_usage(self):
        """Get the latest recorded cloud usage entry"""
        conn = sqlite3.connect(self.db_file)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM cloud_usage ORDER BY id DESC LIMIT 1")
        row = cursor.fetchone()
        result = dict(row) if row else None
        conn.close()
        return result

# Flask Application
app = Flask(__name__)

def auto_extract_cookie():
    """Attempt to extract the ollama.com session cookie automatically from Chrome"""
    try:
        from pycookiecheat import chrome_cookies
        cookies = chrome_cookies('https://ollama.com/settings')
        if cookies and '__Secure-session' in cookies:
            cookie_str = f"__Secure-session={cookies['__Secure-session']}"
            if 'aid' in cookies:
                cookie_str += f"; aid={cookies['aid']}"
            logger.info("Successfully extracted ollama.com session cookie from Chrome.")
            return cookie_str
    except Exception as e:
        logger.debug(f"Failed to auto-extract Chrome cookie: {e}")
    return None

def parse_cloud_settings_page(html_text):
    """Parse usage metrics, resets, and per-model request segments from ollama.com settings HTML"""
    from bs4 import BeautifulSoup
    import re
    import json
    
    soup = BeautifulSoup(html_text, 'html.parser')
    lines = [l.strip() for l in soup.get_text(separator='\n').split('\n') if l.strip()]
    
    session_pct = 0.0
    session_reset = ""
    weekly_pct = 0.0
    weekly_reset = ""
    balance = 0.0
    
    for i, line in enumerate(lines):
        if "session usage" in line.lower():
            pct_m = re.search(r'(\d+(?:\.\d+)?)\s*%\s*(?:used)?', line, re.IGNORECASE)
            if pct_m: session_pct = float(pct_m.group(1))
            for j in range(i+1, min(i+6, len(lines))):
                nxt = lines[j]
                m = re.search(r'(\d+(?:\.\d+)?)\s*%\s*(?:used)?', nxt, re.IGNORECASE)
                if m and not session_pct: session_pct = float(m.group(1))
                if "resets in" in nxt.lower() and not session_reset: session_reset = nxt
                
        if "weekly usage" in line.lower():
            pct_m = re.search(r'(\d+(?:\.\d+)?)\s*%\s*(?:used)?', line, re.IGNORECASE)
            if pct_m: weekly_pct = float(pct_m.group(1))
            for j in range(i+1, min(i+6, len(lines))):
                nxt = lines[j]
                m = re.search(r'(\d+(?:\.\d+)?)\s*%\s*(?:used)?', nxt, re.IGNORECASE)
                if m and not weekly_pct: weekly_pct = float(m.group(1))
                if "resets in" in nxt.lower() and not weekly_reset: weekly_reset = nxt
                
        if "balance remaining" in line.lower():
            if i + 1 < len(lines):
                nxt = lines[i+1]
                bal_m = re.search(r'\$\s*(\d+(?:\.\d+)?)', nxt)
                if bal_m:
                    balance = float(bal_m.group(1))
                    
    session_models = {}
    weekly_models = {}
    
    usage_tracks = soup.find_all(attrs={"data-usage-track": True})
    if len(usage_tracks) >= 2:
        for btn in usage_tracks[0].find_all('button', attrs={"data-model": True}):
            model = btn.get('data-model')
            try:
                reqs = int(btn.get('data-requests', 0))
            except:
                reqs = 0
            if model and reqs > 0:
                session_models[model] = reqs
                
        for btn in usage_tracks[1].find_all('button', attrs={"data-model": True}):
            model = btn.get('data-model')
            try:
                reqs = int(btn.get('data-requests', 0))
            except:
                reqs = 0
            if model and reqs > 0:
                weekly_models[model] = reqs
                
    return (session_pct, session_reset, weekly_pct, weekly_reset, balance, 
            json.dumps(session_models), json.dumps(weekly_models))

def run_cloud_scraper(db_file):
    """Background thread to regularly scrape cloud usage statistics"""
    db = OllamaMetricsDB(db_file)
    while True:
        cookie = db.get_setting('session_cookie')
        
        # Auto-extract from Chrome if no cookie exists yet
        if not cookie:
            cookie = auto_extract_cookie()
            if cookie:
                db.save_setting('session_cookie', cookie)
                
        if cookie:
            try:
                headers = {
                    'Cookie': cookie,
                    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
                }
                r = requests.get('https://ollama.com/settings', headers=headers, timeout=10)
                
                # If cookie is expired/invalid, try to re-extract automatically
                if r.status_code != 200 or "signin" in r.url:
                    logger.info("Session cookie expired. Attempting to re-extract from Chrome...")
                    new_cookie = auto_extract_cookie()
                    if new_cookie and new_cookie != cookie:
                        cookie = new_cookie
                        db.save_setting('session_cookie', cookie)
                        headers['Cookie'] = cookie
                        r = requests.get('https://ollama.com/settings', headers=headers, timeout=10)
                        
                if r.status_code == 200 and "signin" not in r.url:
                    (s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det) = parse_cloud_settings_page(r.text)
                    db.save_cloud_usage(s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det)
                    logger.info(f"Scraped cloud usage: Session {s_pct}%, Weekly {w_pct}%")
                else:
                    logger.error(f"Failed to scrape settings: HTTP {r.status_code} (URL: {r.url})")
            except Exception as e:
                logger.error(f"Exception during cloud scraping: {e}")
        time.sleep(60)

# API Endpoints
@app.route('/api/cloud/usage', methods=['GET'])
def api_cloud_usage():
    db = OllamaMetricsDB()
    usage = db.get_latest_cloud_usage()
    if usage:
        return jsonify(usage)
    else:
        return jsonify({
            "session_used_percent": 0.0,
            "session_reset_text": "No data",
            "weekly_used_percent": 0.0,
            "weekly_reset_text": "No data",
            "balance_remaining": 0.0,
            "session_details_json": "{}",
            "weekly_details_json": "{}"
        })

@app.route('/api/cloud/cookie', methods=['POST'])
def api_cloud_cookie():
    db = OllamaMetricsDB()
    data = request.get_json(silent=True) or {}
    cookie = data.get('cookie', '')
    db.save_setting('session_cookie', cookie)
    
    def scrape_now():
        try:
            headers = {
                'Cookie': cookie,
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            }
            r = requests.get('https://ollama.com/settings', headers=headers, timeout=10)
            if r.status_code == 200 and "signin" not in r.url:
                (s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det) = parse_cloud_settings_page(r.text)
                db.save_cloud_usage(s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det)
                logger.info(f"Immediate scrape successful: Session {s_pct}%, Weekly {w_pct}%")
        except Exception as e:
            logger.error(f"Error in immediate scrape: {e}")
            
    threading.Thread(target=scrape_now, daemon=True).start()
    return jsonify({"status": "success", "message": "Cookie saved and scraper triggered"})

@app.route('/api/cloud/autodetect', methods=['POST'])
def api_cloud_autodetect():
    db = OllamaMetricsDB()
    cookie = auto_extract_cookie()
    if cookie:
        db.save_setting('session_cookie', cookie)
        
        def scrape_now():
            try:
                headers = {
                    'Cookie': cookie,
                    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
                }
                r = requests.get('https://ollama.com/settings', headers=headers, timeout=10)
                if r.status_code == 200 and "signin" not in r.url:
                    (s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det) = parse_cloud_settings_page(r.text)
                    db.save_cloud_usage(s_pct, s_reset, w_pct, w_reset, bal, s_det, w_det)
            except Exception as e:
                logger.error(f"Error in autodetect scrape: {e}")
        
        threading.Thread(target=scrape_now, daemon=True).start()
        return jsonify({"status": "success", "cookie": cookie})
    else:
        return jsonify({"status": "error", "message": "Could not find ollama.com cookie in Chrome. Make sure you are logged into ollama.com in Google Chrome."}), 400

# Proxy Route to Intercept Active Model requests
@app.route('/ollama/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def proxy_ollama(path):
    logger.info(f"Proxy request received for path: {path}")
    db = OllamaMetricsDB()
    start_time = time.time()
    client_ip = request.remote_addr
    
    url = f"{OLLAMA_HOST}/{path}"
    headers = {key: value for (key, value) in request.headers.items() if key.lower() != 'host'}
    
    try:
        json_data = None
        is_api_trackable = False
        model_name = ""
        is_stream = False
        
        if request.method == 'POST':
            json_data = request.get_json(silent=True)
            if not json_data:
                try:
                    json_data = json.loads(request.get_data())
                except Exception as e:
                    logger.debug(f"Could not parse raw request body: {e}")
            if json_data:
                model_name = json_data.get('model', '')
                is_stream = json_data.get('stream', False)
                logger.info(f"Parsed proxy request payload: model={model_name}, stream={is_stream}")
                if path in ['api/generate', 'api/chat', 'v1/chat/completions']:
                    is_api_trackable = True
                    if model_name:
                        db.set_active_model(model_name)
        
        resp_stream = (path in ['api/pull', 'api/push', 'api/generate', 'api/chat', 'v1/chat/completions']) or is_stream
        
        if request.method == 'GET':
            resp = requests.get(url, headers=headers, params=request.args, stream=resp_stream)
        elif request.method == 'POST':
            if json_data:
                resp = requests.post(url, headers=headers, json=json_data, stream=resp_stream)
            else:
                resp = requests.post(url, headers=headers, data=request.get_data(), stream=resp_stream)
        elif request.method == 'PUT':
            resp = requests.put(url, headers=headers, data=request.get_data(), stream=resp_stream)
        elif request.method == 'DELETE':
            resp = requests.delete(url, headers=headers, stream=resp_stream)
        else:
            return jsonify({"error": "Method not allowed"}), 405

        is_chunked = 'chunked' in resp.headers.get('Transfer-Encoding', '').lower()
        should_stream_back = resp_stream or is_chunked
        
        if should_stream_back:
            def generate():
                nonlocal start_time
                buffer = ""
                input_tokens = 0
                output_tokens = 0
                full_content = b""
                
                for chunk in resp.iter_content(chunk_size=4096):
                    if chunk:
                        yield chunk
                        if is_api_trackable and model_name:
                            db.set_active_model(model_name)
                        if is_api_trackable:
                            if is_stream:
                                buffer += chunk.decode('utf-8', errors='ignore')
                                while "\n" in buffer:
                                    line, buffer = buffer.split("\n", 1)
                                    line = line.strip()
                                    if not line:
                                        continue
                                    if line.startswith("data: "):
                                        data_str = line[6:]
                                        if data_str == "[DONE]":
                                            continue
                                        try:
                                            data_json = json.loads(data_str)
                                            usage = data_json.get("usage")
                                            if usage:
                                                input_tokens = usage.get("prompt_tokens", 0)
                                                output_tokens = usage.get("completion_tokens", 0)
                                        except:
                                            pass
                                    else:
                                        try:
                                            data_json = json.loads(line)
                                            if "prompt_eval_count" in data_json:
                                                input_tokens = data_json.get("prompt_eval_count", 0)
                                            if "eval_count" in data_json:
                                                output_tokens = data_json.get("eval_count", 0)
                                        except:
                                            pass
                            else:
                                full_content += chunk
                
                if is_api_trackable and not is_stream and full_content:
                    try:
                        resp_json = json.loads(full_content.decode('utf-8', errors='ignore'))
                        if path == 'v1/chat/completions':
                            usage = resp_json.get("usage", {})
                            input_tokens = usage.get("prompt_tokens", 0)
                            output_tokens = usage.get("completion_tokens", 0)
                        else:
                            input_tokens = resp_json.get("prompt_eval_count", 0)
                            output_tokens = resp_json.get("eval_count", 0)
                    except Exception as e:
                        logger.error(f"Error parsing non-streamed API response: {e}")
                
                if is_api_trackable:
                    if input_tokens == 0 and output_tokens == 0:
                        if json_data:
                            input_tokens = len(str(json_data.get('prompt', '')).split()) + len(str(json_data.get('messages', '')).split())
                        if not is_stream and full_content:
                            output_tokens = len(full_content.split())
                            
                    try:
                        local_db = OllamaMetricsDB()
                        log_data = {
                            "timestamp": datetime.now().isoformat(),
                            "client_ip": client_ip,
                            "model_name": model_name,
                            "input_tokens": input_tokens,
                            "output_tokens": output_tokens,
                            "response_time": time.time() - start_time,
                            "status_code": resp.status_code,
                            "endpoint": f"/{path}"
                        }
                        local_db.save_request_log(log_data)
                    except Exception as e:
                        logger.error(f"Failed to log request to DB: {e}")
            
            excluded_headers = ['content-length', 'transfer-encoding', 'connection', 'keep-alive']
            response_headers = [(name, value) for (name, value) in resp.headers.items() 
                                if name.lower() not in excluded_headers]
            return Response(generate(), status=resp.status_code, headers=response_headers)
        
        else:
            response_headers = [(name, value) for (name, value) in resp.headers.items()]
            return resp.content, resp.status_code, response_headers
            
    except Exception as e:
        logger.error(f"Proxy request exception: {str(e)}")
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    # Ensure database tables exist
    db = OllamaMetricsDB()
    
    # Start the cloud usage scraper in the background
    threading.Thread(target=run_cloud_scraper, args=(DB_FILE,), daemon=True).start()
    
    try:
        logger.info(f"Ollama Usage Monitor Daemon starting on http://{WEB_HOST}:{WEB_PORT}")
        serve(app, host=WEB_HOST, port=WEB_PORT, threads=10)
    except KeyboardInterrupt:
        logger.info("Received interrupt signal, shutting down...")
    except Exception as e:
        logger.critical(f"Application crash: {str(e)}")