"""Upload the prepared agreement photos to the owner's private bucket.

    SUPABASE_EMAIL=... SUPABASE_PASSWORD=... \
        python3 deploy/upload_agreement_photos.py [--prune] [--again a.jpg,b.jpg] <prepared-folder>

--prune deletes objects in the owner's folder that the prepared folder no
longer has (after the owner drops or renames a photo). --again re-sends the
named objects even though they exist (their content changed).

<prepared-folder> is the output of prepare_agreement_photos.py. Every
`<rental_no>.jpg` / `<rental_no>-N.jpg` in it goes to
`agreements/<owner_id>/<name>`. Idempotent: uploads overwrite, so a
re-run after a failure just fills the gaps. Files whose number is above
the highest rental on the server are reported and skipped -- a photo can
only belong to a rental that exists. Credentials come from the
environment only.
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

URL = "https://oxkebeulfbgcxfaattna.supabase.co"
KEY = "sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ"  # client-safe publishable key
BUCKET = "agreements"
WORKERS = 8


class Session:
    def __init__(self, email, password):
        self.email, self.password = email, password
        self.lock = threading.Lock()
        self.sign_in()

    def sign_in(self):
        body = json.dumps({"email": self.email, "password": self.password}).encode()
        req = urllib.request.Request(
            URL + "/auth/v1/token?grant_type=password", data=body, method="POST",
            headers={"apikey": KEY, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            auth = json.load(resp)
        self.token = auth["access_token"]
        self.uid = auth["user"]["id"]
        self.expires = time.time() + auth.get("expires_in", 3600) - 120

    def bearer(self):
        with self.lock:
            if time.time() > self.expires:
                self.sign_in()
            return self.token


def request(session, method, path, data=None, headers=None):
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("apikey", KEY)
    req.add_header("Authorization", "Bearer " + session.bearer())
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def upload(session, folder, name):
    with open(os.path.join(folder, name), "rb") as f:
        data = f.read()
    for attempt in range(3):
        try:
            request(session, "POST", f"/storage/v1/object/{BUCKET}/{session.uid}/{name}",
                    data=data, headers={"Content-Type": "image/jpeg",
                                        "x-upsert": "true"})
            return name, None
        except urllib.error.HTTPError as e:
            err = f"{e.code}: {e.read().decode(errors='replace')[:200]}"
            if e.code in (401, 429, 500, 502, 503, 504) and attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            return name, err
        except (urllib.error.URLError, ConnectionError, TimeoutError,
                OSError) as e:  # socket.timeout is an OSError
            if attempt < 2:
                time.sleep(2 * (attempt + 1))
                continue
            return name, str(e)


def main():
    args = sys.argv[1:]
    prune = "--prune" in args
    again = set()
    if "--again" in args:
        i = args.index("--again")
        again = set(args[i + 1].split(","))
        del args[i:i + 2]
    args = [a for a in args if a != "--prune"]
    if len(args) != 1:
        sys.exit(__doc__)
    sys.argv = [sys.argv[0], args[0]]
    email = os.environ.get("SUPABASE_EMAIL")
    password = os.environ.get("SUPABASE_PASSWORD")
    if not email or not password:
        sys.exit("Set SUPABASE_EMAIL and SUPABASE_PASSWORD in the environment.")
    folder = sys.argv[1]
    session = Session(email, password)

    top = request(session, "GET",
                  "/rest/v1/rentals?select=rental_no&order=rental_no.desc&limit=1")
    highest = top[0]["rental_no"] if top else 0
    print(f"owner {session.uid}, highest rental on the server: #{highest}")

    # Resume: whatever is already in the owner's folder is not sent again.
    present = set()
    offset = 0
    while True:
        page = request(session, "POST", f"/storage/v1/object/list/{BUCKET}",
                       data=json.dumps({"prefix": session.uid, "limit": 1000,
                                        "offset": offset}).encode(),
                       headers={"Content-Type": "application/json"}) or []
        present.update(o["name"] for o in page)
        if len(page) < 1000:
            break
        offset += 1000
    print(f"already in the bucket: {len(present)}")

    names = sorted(n for n in os.listdir(folder) if n.endswith(".jpg"))
    if prune:
        stale = sorted(present - set(names))
        if stale:
            request(session, "DELETE", f"/storage/v1/object/{BUCKET}",
                    data=json.dumps({"prefixes": [f"{session.uid}/{n}" for n in stale]}).encode(),
                    headers={"Content-Type": "application/json"})
            for n in stale:
                print(f"  deleted {n}")
    todo, skipped = [], []
    for n in names:
        no = int(re.match(r"(\d+)", n).group(1))
        if n in present and n not in again:
            continue
        (todo if 1 <= no <= highest else skipped).append(n)
    for n in skipped:
        print(f"  skipped {n}: no rental with that number")
    print(f"to upload: {len(todo)}")

    done, failed = 0, []
    with ThreadPoolExecutor(WORKERS) as pool:
        futures = [pool.submit(upload, session, folder, n) for n in todo]
        for fut in as_completed(futures):
            name, err = fut.result()
            if err:
                failed.append((name, err))
            else:
                done += 1
            if (done + len(failed)) % 500 == 0:
                print(f"  {done + len(failed)}/{len(todo)}", flush=True)
    print(f"{done} uploaded, {len(failed)} failed, {len(skipped)} skipped")
    for name, err in failed:
        print(f"  FAILED {name}: {err}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
