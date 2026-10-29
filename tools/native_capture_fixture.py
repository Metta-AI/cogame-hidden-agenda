"""Bounded five-seat production HTTP/WS fixture; synthetic IDs are never teacher receipts."""

import argparse
import asyncio
import base64
import hashlib
import json
import os
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

import websockets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--mode", choices=["red", "off", "on", "mixed", "sink"], required=True
    )
    parser.add_argument(
        "--ownership-case",
        choices=[
            "missing",
            "silent",
            "malformed",
            "legit",
            "disconnect",
            "external",
            "race",
        ],
    )
    parser.add_argument("--race-pairs", type=int, default=0)
    args = parser.parse_args()
    assert 0 <= args.race_pairs <= 10
    assert args.ownership_case == "race" or args.race_pairs == 0
    assert args.ownership_case != "race" or args.race_pairs > 0
    assert args.ownership_case is None or args.mode == "on"
    out = args.output.resolve()
    out.mkdir(exist_ok=False)
    started = time.monotonic()
    lock = threading.Lock()
    calls = []
    per_seat = [0] * 5

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            size = int(self.headers["Content-Length"])
            assert size < 65536
            raw = self.rfile.read(size)
            req = json.loads(raw)
            seat = int(self.headers["X-Coworld-Player-Slot"])
            with lock:
                per_seat[seat] += 1
                number = per_seat[seat]
                assert sum(per_seat) <= 20
            meeting = "· MEETING " in req["messages"][0]["content"]
            action = {
                "plan": [{"job": "hold"}],
                "hunch": "fixture",
                "notes": f"PRIVATE_NOTE_{seat}",
            }
            if meeting:
                action.update(vote="PINK", switch=None, say=f"seat {seat}")
            text = json.dumps(action)
            status = 200
            if args.mode == "mixed":
                if seat == 0 and number == 1:
                    text = "not JSON"
                elif seat == 1:
                    action["plan"] = [{"job": "hold extra"}]
                    text = json.dumps(action)
                elif seat == 2:
                    action["notes"] = "🙂" * 300
                    text = json.dumps(action, ensure_ascii=False)
                elif seat == 3:
                    text = text[:-1] + ',"ignored":"\\ud800","notes":"duplicate"}'
                elif seat == 4:
                    status = 500
            response = json.dumps(
                {
                    "content": [{"type": "text", "text": text}],
                    "stop_reason": "end_turn",
                    "usage": {"input_tokens": 10, "output_tokens": 10},
                }
            ).encode()
            uid = str(uuid5(NAMESPACE_URL, f"hidden-agenda-local:{seat}:{number}"))
            with lock:
                calls.append(
                    {
                        "seat": seat,
                        "number": number,
                        "request_b64": base64.b64encode(raw).decode(),
                        "response_b64": base64.b64encode(response).decode(),
                        "status": status,
                        "UUID": uid,
                        "synthetic": True,
                    }
                )
                (out / "http.json").write_text(
                    json.dumps(calls, ensure_ascii=True, indent=2)
                )
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("X-Softmax-Llm-Call-Id", uid)
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format: str, *args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    config = {
        "seed": 37,
        "impostorSlot": 4,
        "tokens": [f"local-{s}" for s in range(5)],
        "players": [{"name": f"seat{s}"} for s in range(5)],
    }
    if args.ownership_case:
        # These are exact keys accepted by sim_config.update, not CLI aliases.
        config.update(
            maxTicks=600,
            maxDecisionBatches=3,
            llmTimeoutSeconds=1,
            minBatchSeconds=1,
            episodeTimeoutSeconds=30,
            playerConnectTimeoutSeconds=10 if args.ownership_case == "race" else 2,
            shutdownGraceSeconds=0,
        )
    (out / "config.json").write_text(json.dumps(config))
    (out / "http.json").write_text("[]")
    env = {
        k: os.environ[k] for k in ["PATH", "HOME", "TMPDIR", "LANG"] if k in os.environ
    }
    env.update(
        COGAME_CONFIG_URI=(out / "config.json").as_uri(),
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_RESULTS_URI=(out / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(out / "replay.json").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
        COWORLD_LLM_MODEL="local-fixture",
        COWORLD_EPISODE_ID="local-hidden-" + args.mode,
        COWORLD_GAME_NAME="hidden_agenda",
        COWORLD_GAME_VERSION="fixture",
        COWORLD_SOURCE_REVISION="workingtree-sha256:"
        + hashlib.sha256(
            b"".join(p.read_bytes() for p in sorted(Path("src").rglob("*.nim")))
        ).hexdigest(),
    )
    if args.mode != "off":
        env["COGAME_SAVE_TRAJECTORY_URI"] = (out / "trajectory.jsonl").as_uri()
    if args.mode == "sink":
        (out / "trajectory.jsonl").write_text("EXISTING_PRIVATE_SINK")
    child = None
    frames = [[] for _ in range(5)]
    try:
        with (
            (out / "game.stdout").open("xb") as stdout,
            (out / "game.stderr").open("xb") as stderr,
        ):
            child = subprocess.Popen(
                [str(args.binary.resolve())], env=env, stdout=stdout, stderr=stderr
            )

            async def seats():
                async def connect(seat):
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            return await websockets.connect(
                                f"ws://127.0.0.1:{port}/player?slot={seat}&token=local-{seat}"
                            )
                        except OSError:
                            assert time.monotonic() < deadline
                            await asyncio.sleep(0.03 if args.ownership_case else 0.05)

                if args.ownership_case == "race":
                    race = []
                    # At most ten paired attempts here; RED+GREEN total <=20.
                    for pair in range(args.race_pairs):

                        async def contender():
                            try:
                                ws = await connect(0)
                                try:
                                    raw = await asyncio.wait_for(ws.recv(), 0.3)
                                    return ws, json.loads(raw).get("type") == "welcome"
                                except (
                                    TimeoutError,
                                    websockets.exceptions.ConnectionClosed,
                                ):
                                    return ws, False
                            except websockets.exceptions.InvalidHandshake as error:
                                # mummy emits a reason-less 409 status line.
                                # websockets calls that InvalidMessage, not InvalidStatus.
                                cause = error
                                messages = []
                                while cause is not None:
                                    messages.append(str(cause))
                                    cause = cause.__cause__
                                assert any("409" in text for text in messages), messages
                                return None, False

                        both = await asyncio.gather(contender(), contender())
                        race.append({"pair": pair, "welcomed": [x[1] for x in both]})
                        for ws, _ in both:
                            if ws is not None:
                                await ws.close()
                        await asyncio.sleep(0.02)
                    (out / "race.json").write_text(json.dumps(race, indent=2))

                async def play(seat):
                    if args.ownership_case == "missing" and seat != 1:
                        return
                    ws = await connect(seat)
                    async with ws:
                        prompt = {
                            "type": "prompt",
                            "prompt": f"OPERATOR_PRIVATE_SEAT_{seat}",
                        }
                        if args.ownership_case:
                            if args.ownership_case == "external" and seat == 0:
                                prompt = {"type": "register", "control": "external"}
                            elif seat != 0 or args.ownership_case not in (
                                "legit",
                                "disconnect",
                            ):
                                prompt["scripted"] = "miner"
                        silent = args.ownership_case == "silent"
                        malformed = args.ownership_case == "malformed" and seat == 0
                        if not silent:
                            await ws.send(
                                "{broken" if malformed else json.dumps(prompt)
                            )
                        async for raw in ws:
                            raw = raw.decode() if isinstance(raw, bytes) else raw
                            message = json.loads(raw)
                            frames[seat].append(message)
                            if message.get("type") == "welcome" and not silent:
                                await ws.send(
                                    "{broken" if malformed else json.dumps(prompt)
                                )
                            assert (
                                "roles" not in message and "impostorSlot" not in message
                            )
                            assert all(
                                f"OPERATOR_PRIVATE_SEAT_{other}" not in raw
                                for other in range(5)
                                if other != seat
                            )
                            if (
                                args.ownership_case == "disconnect"
                                and seat == 0
                                and calls
                            ):
                                await ws.close()
                                return
                            if message.get("type") == "final":
                                return

                async with asyncio.timeout(45 if args.ownership_case else 65):
                    await asyncio.gather(*(play(s) for s in range(5)))

            asyncio.run(seats())
            child.wait(timeout=max(1, 75 - (time.monotonic() - started)))
        assert child.returncode == 0
        results = json.loads((out / "results.json").read_text())
        replay = json.loads((out / "replay.json").read_text())
        assert results == replay["results"] and results["reason"] == "complete"
        if args.ownership_case:
            expected_finals = (
                [1]
                if args.ownership_case == "missing"
                else [1, 2, 3, 4]
                if args.ownership_case == "disconnect"
                else list(range(5))
            )
            assert all(
                any(f.get("type") == "final" for f in frames[seat])
                for seat in expected_finals
            )
            replay_config = replay["config"]
            for key in ("maxTicks",):
                assert replay_config[key] == config[key], (key, replay_config)
            if args.ownership_case in (
                "missing",
                "silent",
                "malformed",
                "external",
                "race",
            ):
                assert len(calls) == 0
            else:
                assert calls and all(call["seat"] == 0 for call in calls)
            if args.ownership_case == "race":
                assert all(
                    sum(pair["welcomed"]) <= 1
                    for pair in json.loads((out / "race.json").read_text())
                )
        else:
            assert all(any(f.get("type") == "final" for f in group) for group in frames)
        (out / "player-frames.json").write_text(json.dumps(frames))
        assert (
            sum(p.stat().st_size for p in out.rglob("*") if p.is_file()) < 8 * 1024**2
        )
        (out / "fixture-result.json").write_text(
            json.dumps(
                {
                    "status": "PASS complete native HTTP/WS fixture",
                    "mode": args.mode,
                    "ownership_case": args.ownership_case,
                    "results": results,
                    "calls": len(calls),
                    "per_seat": per_seat,
                    "elapsed_seconds": time.monotonic() - started,
                    "trajectory_exists": (out / "trajectory.jsonl").exists(),
                    "provider_calls": 0,
                },
                indent=2,
            )
        )
        if args.mode == "red":
            assert not (out / "trajectory.jsonl").exists(), (
                "baseline RED expects missing capture"
            )
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


if __name__ == "__main__":
    main()
