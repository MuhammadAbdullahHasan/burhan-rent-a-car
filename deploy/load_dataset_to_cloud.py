#!/usr/bin/env python3
"""One-time bulk load of an imported dataset into the Supabase project.

This is the "bulk load directly against Postgres" path of the locked spec
(section 7): run the Dart import pipeline into a SQLite file first, then
push every customer, vehicle and rental from that file to the cloud as the
owner. Devices never seed themselves; they pull from here.

    dart run bin/import_report.dart <csv> build/dataset.db
    SUPABASE_EMAIL=... SUPABASE_PASSWORD=... \\
        python3 deploy/load_dataset_to_cloud.py build/dataset.db

Refuses to run if the cloud already holds any rental, so it can never
overwrite real records -- unless --replace is given, which first deletes
every attachment, rental, vehicle and customer the owner has in the cloud
(used once, to swap the development dataset for the real history). Devices
notice the new dataset generation and re-download in full.
Credentials come from the environment only.
"""
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request
import uuid

URL = "https://oxkebeulfbgcxfaattna.supabase.co"
KEY = "sb_publishable_YVCUYvjXYsObRg6vZmxybQ_fdg6CpXZ"  # client-safe publishable key
BATCH = 200


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
        with urllib.request.urlopen(req, data) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        sys.exit(f"{method} {path} -> {e.code}: {raw}")


def as_bool(v):
    return v == 1


def rows(db, table):
    cur = db.execute(f"select * from {table}")
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def main():
    args = [a for a in sys.argv[1:] if a != "--replace"]
    replace = "--replace" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    email = os.environ.get("SUPABASE_EMAIL")
    password = os.environ.get("SUPABASE_PASSWORD")
    if not email or not password:
        sys.exit("Set SUPABASE_EMAIL and SUPABASE_PASSWORD in the environment.")

    db = sqlite3.connect(args[0])
    customers = rows(db, "customers")
    vehicles = rows(db, "vehicles")
    rentals = rows(db, "rentals")
    for r in customers:
        r["possible_duplicate"] = as_bool(r["possible_duplicate"])
        r["is_deleted"] = as_bool(r["is_deleted"])
    for r in vehicles:
        r["is_deleted"] = as_bool(r["is_deleted"])
    for r in rentals:
        r["is_placeholder"] = as_bool(r["is_placeholder"])
        r["is_deleted"] = as_bool(r["is_deleted"])

    _, auth = call("POST", "/auth/v1/token?grant_type=password",
                   {"email": email, "password": password})
    token = auth["access_token"]

    _, existing = call("GET", "/rest/v1/rentals?select=id&limit=1", token=token)
    if existing and not replace:
        sys.exit("The cloud already holds rentals; refusing to bulk-load over them "
                 "(pass --replace to wipe them first).")
    if replace:
        # Children before parents (attachments -> rentals -> customers/vehicles).
        for table in ("attachments", "rentals", "vehicles", "customers"):
            _, before = call("GET", f"/rest/v1/{table}?select=id", token=token)
            call("DELETE", f"/rest/v1/{table}?id=not.is.null", token=token,
                 prefer="return=minimal")
            _, after = call("GET", f"/rest/v1/{table}?select=id&limit=1", token=token)
            if after:
                sys.exit(f"{table}: rows remain after delete; stopping.")
            print(f"{table}: {len(before)} old rows deleted")

    for table, data in (("customers", customers), ("vehicles", vehicles),
                        ("rentals", rentals)):
        for i in range(0, len(data), BATCH):
            call("POST", f"/rest/v1/{table}", data[i:i + BATCH], token=token,
                 prefer="resolution=merge-duplicates,return=minimal")
        print(f"{table}: {len(data)} rows loaded")

    _, check = call("GET", "/rest/v1/rentals?select=rental_no&order=rental_no.desc&limit=1",
                    token=token)
    print(f"highest rental number on the server: #{check[0]['rental_no']}")

    # A new generation makes every device let go of whatever copy it holds
    # and download this dataset in full.
    generation = str(uuid.uuid4())
    _, existing_gen = call("GET", "/rest/v1/dataset_generation?select=owner_id", token=token)
    if existing_gen:
        call("PATCH", f"/rest/v1/dataset_generation?owner_id=eq.{existing_gen[0]['owner_id']}",
             {"generation": generation, "updated_at": "now()"}, token=token,
             prefer="return=minimal")
    else:
        call("POST", "/rest/v1/dataset_generation", {"generation": generation},
             token=token, prefer="return=minimal")
    print(f"dataset generation: {generation}")


if __name__ == "__main__":
    main()
