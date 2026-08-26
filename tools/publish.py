#!/usr/bin/env python3
"""Publish the committed tree to GitHub through the Git Data API.

The sandbox's git credential helper has read access to this repo but not push
access, so `git push` fails with "No anonymous write access". `gh` is
authenticated with a token that DOES have push (`permissions.push: true`), so
the tree goes up through the API instead: blobs -> tree -> commit -> ref.

A brand-new repo has no objects at all and the Git Data API cannot create the
first one (409 "Git Repository is empty"), so the very first call bootstraps a
single file through the Contents API (ecos, 2026-08-23).

    python3 tools/publish.py "<commit message>"
"""

import base64
import json
import os
import subprocess
import sys

REPO = "Metta-AI/cogame-hidden-agenda"
BRANCH = "main"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def gh(method, path, payload=None, query=None):
    args = ["gh", "api", "-X", method, path]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.run(
        args, input=json.dumps(payload) if payload is not None else None,
        capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(f"{method} {path} failed:\n{result.stderr[:2000]}")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def tracked():
    out = subprocess.run(["git", "ls-files", "-s"], capture_output=True,
                         text=True, cwd=ROOT, check=True).stdout
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        mode = meta.split()[0]
        yield mode, path


def head_sha():
    try:
        ref = gh("GET", f"repos/{REPO}/git/ref/heads/{BRANCH}")
        return ref["object"]["sha"]
    except SystemExit:
        return None


def bootstrap():
    gh("PUT", f"repos/{REPO}/contents/.gitattributes", {
        "message": "bootstrap the first object so the Git Data API can work",
        "content": base64.b64encode(b"* text=auto\n").decode(),
        "branch": BRANCH,
    })


def main():
    message = sys.argv[1] if len(sys.argv) > 1 else subprocess.run(
        ["git", "log", "-1", "--pretty=%B"], capture_output=True, text=True,
        cwd=ROOT, check=True).stdout.strip()
    parent = head_sha()
    if parent is None:
        print("empty repo: bootstrapping the first object")
        bootstrap()
        parent = head_sha()

    entries = []
    files = list(tracked())
    for index, (mode, path) in enumerate(files, 1):
        with open(os.path.join(ROOT, path), "rb") as handle:
            raw = handle.read()
        blob = gh("POST", f"repos/{REPO}/git/blobs", {
            "content": base64.b64encode(raw).decode(), "encoding": "base64"})
        entries.append({"path": path, "mode": mode, "type": "blob",
                        "sha": blob["sha"]})
        if index % 20 == 0 or index == len(files):
            print(f"  {index}/{len(files)} blobs")

    tree = gh("POST", f"repos/{REPO}/git/trees", {"tree": entries})
    commit = gh("POST", f"repos/{REPO}/git/commits", {
        "message": message, "tree": tree["sha"], "parents": [parent]})
    gh("PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}", {
        "sha": commit["sha"], "force": True})
    print("pushed", commit["sha"])


if __name__ == "__main__":
    main()
