/// Local SQLite schema for the offline data layer.
///
/// This mirrors the provisional schema in docs/test_data_analysis.md. Fields
/// marked [P] there (vehicle trim/model naming, license fields, book_days
/// vs. computed duration, status value set) are expected to be revalidated
/// once the real CSV is available — the column *names* here are chosen to be
/// business-meaning-based (e.g. `trim`, `model_name`) rather than copied
/// verbatim from the temp CSV's confusing header names, so a remap only
/// touches the import mapper, not this schema.
library;

const schemaVersion = 2;

const List<String> createTableStatements = [
  '''
  CREATE TABLE customers (
    id                  TEXT PRIMARY KEY,
    full_name           TEXT,
    phone               TEXT,
    phone_normalized    TEXT,
    cnic                TEXT,
    cnic_normalized     TEXT,
    license_no          TEXT,
    license_city        TEXT,
    possible_duplicate  INTEGER NOT NULL DEFAULT 0,
    is_deleted          INTEGER NOT NULL DEFAULT 0,
    version             INTEGER NOT NULL DEFAULT 1,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_customers_phone ON customers(phone_normalized)',
  'CREATE INDEX idx_customers_cnic ON customers(cnic_normalized)',
  'CREATE INDEX idx_customers_name ON customers(full_name COLLATE NOCASE)',
  '''
  CREATE TABLE vehicles (
    id                  TEXT PRIMARY KEY,
    registration_no     TEXT,
    registration_norm   TEXT UNIQUE,
    chassis_no          TEXT,
    engine_no           TEXT,
    company             TEXT,
    model_name          TEXT,
    trim                TEXT,
    horsepower          TEXT,
    color               TEXT,
    reg_year            INTEGER,
    insurance_due_on    TEXT,
    is_deleted          INTEGER NOT NULL DEFAULT 0,
    version             INTEGER NOT NULL DEFAULT 1,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_vehicles_reg ON vehicles(registration_norm)',
  '''
  CREATE TABLE rentals (
    id                  TEXT PRIMARY KEY,
    rental_no           INTEGER UNIQUE,
    is_placeholder      INTEGER NOT NULL DEFAULT 0,
    customer_id         TEXT REFERENCES customers(id),
    vehicle_id          TEXT REFERENCES vehicles(id),
    start_date          TEXT,
    start_time          TEXT,
    end_date            TEXT,
    end_time            TEXT,
    book_days           INTEGER,
    amount              REAL,
    balance             REAL,
    status              TEXT,
    remarks             TEXT,
    ref_name            TEXT,
    ref_contact         TEXT,
    ref_relation        TEXT,
    is_deleted          INTEGER NOT NULL DEFAULT 0,
    version             INTEGER NOT NULL DEFAULT 1,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_rentals_customer ON rentals(customer_id)',
  'CREATE INDEX idx_rentals_vehicle ON rentals(vehicle_id)',
  'CREATE INDEX idx_rentals_start ON rentals(start_date)',
  // Key/value store for local state that plays the role the backend will
  // later own authoritatively — today only the rental-number counter.
  // See RentalNumberAllocator: seeded to MAX(rental_no) WHERE NOT
  // is_placeholder, then only ever incremented, so placeholders can never
  // leak into future numbering and reinstall/restart can never reset it
  // (the counter lives in the same durable SQLite file as the data).
  '''
  CREATE TABLE app_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
  ''',
  // Persistent outbox: every offline mutation is queued here in the same
  // transaction as the entity write, so it survives app restart. A future
  // real sync engine replaces `_LocalSyncStandIn` but keeps this table.
  '''
  CREATE TABLE sync_queue (
    id           TEXT PRIMARY KEY,
    entity_type  TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    operation    TEXT NOT NULL,
    payload      TEXT,
    status       TEXT NOT NULL DEFAULT 'pending',
    retry_count  INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT,
    created_at   TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_sync_queue_status ON sync_queue(status)',
  ...attachmentsTableStatements,
];

/// Photos attached to a record -- today the handwritten rental agreement.
/// Bytes live in the row rather than on the filesystem so one database
/// file is the whole backup, the same snapshot export/restore covers them,
/// and web (no filesystem) behaves identically. A small thumbnail is stored
/// alongside so lists never decode the full image. Kept out of `rentals`
/// so rental queries never touch image bytes.
///
/// Schema version 2. Also applied by `onUpgrade` for databases created at
/// version 1.
const List<String> attachmentsTableStatements = [
  '''
  CREATE TABLE attachments (
    id           TEXT PRIMARY KEY,
    entity_type  TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    kind         TEXT NOT NULL,
    mime_type    TEXT,
    image        BLOB NOT NULL,
    thumbnail    BLOB,
    is_deleted   INTEGER NOT NULL DEFAULT 0,
    version      INTEGER NOT NULL DEFAULT 1,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
  )
  ''',
  'CREATE INDEX idx_attachments_entity ON attachments(entity_type, entity_id, kind)',
];
