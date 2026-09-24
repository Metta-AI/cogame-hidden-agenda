"""Deterministic local System One stub for policy protocol smoke tests."""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/systemone"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        choices = request["questions"]["decision"]["criteria"]
        selected = next(iter(choices))
        response = json.dumps({
            "model": "local-stub",
            "answers": {"decision": {
                "type": "choice",
                "choice": selected,
                "confidence": 1,
                "probabilities": {name: int(name == selected) for name in choices},
            }},
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


HTTPServer(("127.0.0.1", 18119), Handler).serve_forever()
