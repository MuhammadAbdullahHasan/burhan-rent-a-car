"""Note on the rentals whose scanned agreement is a blank or cancelled form.

    SUPABASE_EMAIL=... SUPABASE_PASSWORD=... python3 deploy/mark_agreement_forms.py

The owner's archive labels some scans "Blank" or "Cancelled". Each of
those photos stays on its rental number; this puts a first line of
"Cancelled" or "Blank agreement" in the rental's remarks so the record
says what the scan shows. Runs as the owner over the same REST path the
app uses, bumping the version so every device picks the change up.
Idempotent: a rental already marked is left alone.
"""
import json
import os
import sys
import urllib.request

URL = "https://oxkebeulfbgcxfaattna.supabase.co"
KEY = "sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ"  # client-safe publishable key

CANCELLED = [8671, 8684, 8694, 8698, 8708, 8754, 8773, 8785, 8790]
BLANK = [8552, 8633, 8644, 8651, 8777, 8861, 8891, 8914, 8915, 8953]


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

    for label, numbers in (("Cancelled", CANCELLED), ("Blank agreement", BLANK)):
        rows = call("GET", "/rest/v1/rentals?select=id,rental_no,remarks,version"
                    f"&rental_no=in.({','.join(map(str, numbers))})", token)
        for r in rows:
            remarks = r["remarks"] or ""
            if remarks.lower().startswith(label.split()[0].lower()):
                print(f"  #{r['rental_no']}: already marked")
                continue
            new = label if not remarks else f"{label}\n{remarks}"
            call("PATCH", f"/rest/v1/rentals?id=eq.{r['id']}", token,
                 {"remarks": new, "version": r["version"] + 1, "updated_at": "now()"},
                 prefer="return=minimal")
            print(f"  #{r['rental_no']}: {label}")


if __name__ == "__main__":
    main()
