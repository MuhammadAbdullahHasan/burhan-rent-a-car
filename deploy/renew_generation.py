"""Tell every device to drop its local copy and re-download the dataset.

    SUPABASE_EMAIL=... SUPABASE_PASSWORD=... python3 deploy/renew_generation.py

Renews the owner's dataset generation. On its next sync each device sees
the mismatch, releases its local tables and hydrates from scratch. Use
after a load or when a device's local copy is known to be damaged. Any
edit still waiting on a device is lost, so check the sync bar first.
"""
import json
import os
import sys
import urllib.request
import uuid

URL = "https://oxkebeulfbgcxfaattna.supabase.co"
KEY = "sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ"  # client-safe publishable key


def call(method, path, token, body=None, prefer=None):
    req = urllib.request.Request(URL + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("apikey", KEY)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def main():
    email, password = os.environ.get("SUPABASE_EMAIL"), os.environ.get("SUPABASE_PASSWORD")
    if not email or not password:
        sys.exit("Set SUPABASE_EMAIL and SUPABASE_PASSWORD in the environment.")
    req = urllib.request.Request(URL + "/auth/v1/token?grant_type=password", method="POST",
                                 data=json.dumps({"email": email, "password": password}).encode(),
                                 headers={"apikey": KEY, "Content-Type": "application/json"})
    token = json.load(urllib.request.urlopen(req, timeout=30))["access_token"]
    rows = call("GET", "/rest/v1/dataset_generation?select=owner_id,generation", token)
    if not rows:
        sys.exit("No dataset generation row exists yet; run a dataset load first.")
    generation = str(uuid.uuid4())
    call("PATCH", f"/rest/v1/dataset_generation?owner_id=eq.{rows[0]['owner_id']}",
         token, {"generation": generation, "updated_at": "now()"}, prefer="return=minimal")
    print(f"generation {rows[0]['generation']} -> {generation}")
    print("every device re-downloads on its next sync")


if __name__ == "__main__":
    main()
