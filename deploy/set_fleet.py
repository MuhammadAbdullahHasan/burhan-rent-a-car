"""Set which vehicles are the owner's working fleet.

    SUPABASE_EMAIL=... SUPABASE_PASSWORD=... \
        python3 deploy/set_fleet.py [--apply] <plate> [<plate> ...]

Without --apply it only reports what it would change. Plates are matched
the way the app matches them: letters and digits only, case-insensitive,
so "BKY-391", "bky 391" and "BKY391" are the same vehicle. Every vehicle
not named is moved to the past records; nothing is deleted and no rental
is touched. A plate that matches no vehicle is reported, never created.

Credentials come from the environment only.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

URL = "https://oxkebeulfbgcxfaattna.supabase.co"
KEY = "sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ"  # client-safe publishable key


def call(method, path, body=None, token=None, prefer=None):
    req = urllib.request.Request(URL + path, method=method)
    req.add_header("apikey", KEY)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if prefer:
        req.add_header("Prefer", prefer)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urllib.request.urlopen(req, data, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode(errors='replace')}")


def norm(plate):
    return re.sub(r"[^A-Za-z0-9]", "", plate or "").upper()


def main():
    args = [a for a in sys.argv[1:] if a != "--apply"]
    apply = "--apply" in sys.argv
    if not args:
        sys.exit(__doc__)
    wanted = {norm(a) for a in args}

    email, password = os.environ.get("SUPABASE_EMAIL"), os.environ.get("SUPABASE_PASSWORD")
    if not email or not password:
        sys.exit("Set SUPABASE_EMAIL and SUPABASE_PASSWORD in the environment.")
    _, auth = call("POST", "/auth/v1/token?grant_type=password",
                   {"email": email, "password": password})
    token = auth["access_token"]

    _, rows = call("GET", "/rest/v1/vehicles?select=id,registration_no,in_fleet"
                          "&is_deleted=eq.false&limit=5000", token=token)
    print(f"{len(rows)} vehicles on the server")

    by_norm = {}
    for r in rows:
        by_norm.setdefault(norm(r["registration_no"]), []).append(r)

    missing = sorted(w for w in wanted if w not in by_norm)
    if missing:
        print(f"!! no vehicle for: {', '.join(missing)}")

    to_fleet, to_past = [], []
    for r in rows:
        should = norm(r["registration_no"]) in wanted
        if bool(r["in_fleet"]) != should:
            (to_fleet if should else to_past).append(r)

    print(f"into the fleet : {len(to_fleet)}  {[r['registration_no'] for r in to_fleet]}")
    print(f"into the past  : {len(to_past)}")
    if not apply:
        print("\n(dry run -- pass --apply to write)")
        return

    for rowset, value in ((to_fleet, True), (to_past, False)):
        for r in rowset:
            call("PATCH", f"/rest/v1/vehicles?id=eq.{r['id']}",
                 {"in_fleet": value}, token=token, prefer="return=minimal")
    print(f"done: {len(to_fleet)} in the fleet, {len(to_past)} moved to past")


if __name__ == "__main__":
    main()
