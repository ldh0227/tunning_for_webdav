import http.server
import socketserver
import base64
import os
import sys
from datetime import datetime

# Configuration
PORT = 8000
USERNAME = "testuser"
PASSWORD = "testpassword"
REALM = "WebDAV Test Realm"

class WebDAVishHandler(http.server.SimpleHTTPRequestHandler):
    
    # Store username for logging
    username_for_log = "-"
    
    def log_request(self, code='-', size='-'):
        """
        Override the default log_request to implement W3C-style logging.
        """
        try:
            # W3C format: date time c-ip cs-method cs-uri-stem sc-status cs(User-Agent) cs-username
            user_agent = self.headers.get('user-agent', '-')
            now = datetime.now()
            
            log_entry = (
                f"{now.strftime('%Y-%m-%d %H:%M:%S')} {self.client_address[0]} {self.command} {self.path} "
                f"{code} \"{user_agent}\" {self.username_for_log}"
            )
            sys.stderr.write(log_entry + "\n")
        except Exception:
            # In case of any logging errors, fall back to the default logger to not crash the server
            super().log_request(code, size)

    def do_HEAD(self):
        # Reset username for each request
        self.username_for_log = "-"

        # Basic Authentication Check
        auth_header = self.headers.get("Authorization")
        if not self.authenticate(auth_header):
            self.send_response(401, "Unauthorized")
            self.send_header("WWW-Authenticate", f'Basic realm="{REALM}"')
            self.end_headers()
            return

        # Simple logic: Respond 200 OK for any path under /evidence/, 404 otherwise
        if self.path.startswith("/evidence/"):
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def authenticate(self, auth_header):
        if auth_header is None:
            self.username_for_log = "-"
            return False
        
        try:
            scheme, encoded_credentials = auth_header.split(" ", 1)
            if scheme.lower() == "basic":
                decoded_credentials = base64.b64decode(encoded_credentials).decode("utf-8")
                input_username, input_password = decoded_credentials.split(":", 1)
                
                if input_username == USERNAME and input_password == PASSWORD:
                    self.username_for_log = input_username # Store username for logging
                    return True
        except Exception:
            pass # Malformed header or other error
        
        self.username_for_log = "invalid_user"
        return False

class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    pass

# Start the server
def run_server():
    try:
        # Use the multi-threaded server
        with ThreadingTCPServer(("", PORT), WebDAVishHandler) as httpd:
            print(f"Serving at port {PORT}")
            print(f"Credentials: {USERNAME}/{PASSWORD}")
            print("\n# W3C Log Format:")
            print("# date time c-ip cs-method cs-uri-stem sc-status cs(User-Agent) cs-username")
            print("# -------------------------------------------------------------------------")
            httpd.serve_forever()
    except OSError as e:
        if e.errno == 48 or e.errno == 98: # Address already in use on macOS / Linux
            print(f"ERROR: Port {PORT} is already in use. Please stop any other service using this port or change the PORT in the script.")
        else:
            print(f"An OS error occurred: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_server()
