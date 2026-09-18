"""Run one SQL file against the project database through the pooler.

    SUPABASE_DB_PASSWORD=... python3 deploy/apply_sql.py <file.sql>

For the occasional statement the REST API cannot express (buckets,
storage policies). The password comes from the environment only.
"""
import os
import ssl
import sys

import pg8000

HOST = "aws-0-ap-southeast-1.pooler.supabase.com"
USER = "postgres.oxkebeulfbgcxfaattna"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    password = os.environ.get("SUPABASE_DB_PASSWORD")
    if not password:
        sys.exit("Set SUPABASE_DB_PASSWORD in the environment.")
    sql = open(sys.argv[1]).read()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # the pooler presents Supabase's own CA
    conn = pg8000.connect(host=HOST, port=5432, user=USER, password=password,
                          database="postgres", ssl_context=ctx, timeout=30)
    conn.autocommit = True
    cur = conn.cursor()
    for statement in [s.strip() for s in sql.split(";\n") if s.strip()]:
        cur.execute(statement)
        try:
            rows = cur.fetchall()
            for r in rows:
                print(r)
        except pg8000.exceptions.DatabaseError:
            pass  # statement returned no rows
    conn.close()
    print("done")


if __name__ == "__main__":
    main()
