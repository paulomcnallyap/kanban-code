#!/usr/bin/env python3
"""Login OAuth de Notion para el tablero de Kanban Code (fork de Paulo).

Abre Notion en el navegador, recibe el código en http://localhost:8765/callback,
lo cambia por un token y lo guarda en el Keychain (servicio `notion-kanban-token`).
El Client Secret se lee del Keychain (servicio `notion-kanban-oauth`).

Uso:  python3 Scripts/notion-login.py
"""
import base64
import http.server
import json
import secrets
import subprocess
import sys
import urllib.parse
import urllib.request
import webbrowser

CLIENT_ID = "414d872b-594c-8193-8d4b-00378ecf916e"
REDIRECT_URI = "http://localhost:8765/callback"
SECRET_SERVICE = "notion-kanban-oauth"
TOKEN_SERVICE = "notion-kanban-token"


def keychain_get(service: str) -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-w"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"Falta el ítem «{service}» en el Keychain.")
    return out.stdout.strip()


def keychain_set(service: str, value: str) -> None:
    subprocess.run(
        ["security", "add-generic-password", "-U", "-a", subprocess.getoutput("whoami"),
         "-s", service, "-w", value],
        check=True,
    )


def main() -> None:
    client_secret = keychain_get(SECRET_SERVICE)
    state = secrets.token_urlsafe(16)
    result: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] != state:
                self.send_response(400); self.end_headers()
                self.wfile.write(b"state invalido"); return
            result["code"] = q.get("code", [""])[0]
            result["error"] = q.get("error", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("<h2>Listo, ya puedes cerrar esta pestaña.</h2>".encode())

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8765), Handler)
    url = "https://api.notion.com/v1/oauth/authorize?" + urllib.parse.urlencode({
        "client_id": CLIENT_ID, "response_type": "code", "owner": "user",
        "redirect_uri": REDIRECT_URI, "state": state,
    })
    print("Abriendo Notion… elige el Backlog Product Beauty y acepta.")
    webbrowser.open(url)
    while "code" not in result:
        server.handle_request()
    if result.get("error") or not result["code"]:
        sys.exit(f"Notion devolvió error: {result.get('error')}")

    basic = base64.b64encode(f"{CLIENT_ID}:{client_secret}".encode()).decode()
    req = urllib.request.Request(
        "https://api.notion.com/v1/oauth/token",
        data=json.dumps({"grant_type": "authorization_code", "code": result["code"],
                         "redirect_uri": REDIRECT_URI}).encode(),
        headers={"Authorization": f"Basic {basic}", "Content-Type": "application/json",
                 "Notion-Version": "2022-06-28"},
    )
    with urllib.request.urlopen(req) as resp:
        token = json.load(resp)
    keychain_set(TOKEN_SERVICE, json.dumps(token))
    print(f"OK: acceso guardado para «{token.get('workspace_name')}».")


if __name__ == "__main__":
    main()
