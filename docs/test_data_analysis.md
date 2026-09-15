# Test CSV Analysis & Provisional Schema

Source: `test_data/burhan_rent_a_car_temporary_test.csv` — **temporary/development data
only.** Every field mapping and index here is marked provisional and must be
revalidated once the real CSV arrives (per plan §7/§9).

---

## 1. CSV Analysis

**28 columns, 55 data rows.**

```
Rental#, Date, Time, Name, Contact#, CNIC, License#, Lic. City,
Ref. Name, Ref. Cont#, Relation, Book Days, Rcv Date, Rcv Time,
Vehicle#, Chassis#, Engine#, Company, Model #, Make, Hors Pwr,
Color, Reg. Year, Ins. Due On, Balance, Amount, Remarks, Status
```

**Types/formats observed:**
- `Rental#` — integer, 1..60, gaps present (see below). No duplicates.
- `Date`, `Rcv Date`, `Ins. Due On` — `YYYY-MM-DD`, all valid, no bad rows.
- `Time`, `Rcv Time` — free text `"10:30 AM"` / `"06:00 PM"`, not ISO.
- `Contact#` — 11-digit local mobile, no `+92`/dashes.
- `CNIC` — `#####-#######-#` format.
- `Book Days` — integer, **does not always equal** `Rcv Date − Date`
  (e.g. rental #12: Feb 1 → Feb 5 = 4 elapsed days, `Book Days` = 3). Likely test-data
  noise, but flag for confirmation: is `Book Days` the authoritative billed duration,
  or should duration always be computed from the two dates?
- `Balance`, `Amount` — plain integers (no currency symbol/commas in this file — real
  CSV may differ).
- `Status` — only two values seen: `Open` (14), `Closed` (41).

**Missing/blank values:**
| Column | Blank | Literal `"N/A"` |
|---|---|---|
| Contact# | 2 rows | 0 |
| CNIC | 2 rows | 0 |
| Ref. Name / Ref. Cont# / Relation | 1 row (all three, same row) | 12 rows (all three, same rows) |
| Remarks | 1 row | 0 |

**Data-quality issue #1 — inconsistent "missing" representation:** the `Ref.*`
columns are sometimes truly empty and sometimes the literal string `"N/A"` for the
same meaning (no reference given). Import must treat both as NULL, not just blanks.

**Data-quality issue #2 — confusing automotive column naming:** header order is
`Company, Model #, Make, Hors Pwr`, but the data is `Toyota, Corolla, GLi 1.3, 130` —
i.e. `Company` = brand, `Model #` = model **name** (not a numeric code), `Make` =
trim/variant string, `Hors Pwr` = numeric horsepower. This is the reverse of normal
`Make`/`Model` convention. **Must confirm real column meaning/order before finalizing
the vehicles schema** — do not assume this naming holds.

**Rental-number gaps:** min 1, max 60, present = 55 → **missing: 4, 11, 25, 40, 55**
(exactly 5 gaps, no duplicates). These become placeholder rows.

**Repeated customers (by phone):** 10 distinct customers across 55 rentals — e.g.
Billa Khan (03001234567) appears **9 times** (rentals 1, 12, 13, 23, 27, 34, 43, 45,
56), Ahmed Raza (03111234567) **6 times**, down to Hamza Sheikh **3 times**. Matches
10 distinct CNICs — phone and CNIC agree 1:1 in this sample.

**Repeated vehicles:** only **3 distinct vehicles** across 55 rentals — `KHI-123` (22
rentals), `KHI-789` (17), `KHI-654` (16). Each vehicle's attribute set (chassis,
engine, company/model/trim/hp, color, reg year, insurance-due date) is **fully
consistent** across every rental row that references it — confirms these are true
vehicle-level attributes, not per-rental data, so `Ins. Due On` belongs on `vehicles`,
not `rentals`.

**Customer attribute consistency issue:** two customers have the *same identity*
(same name, same License#) appear with CNIC/phone blank in some rows but filled in
others:
- Fahad Khan (LIC1006): CNIC blank in rental #18, present (`42201-6789012-6`) in
  others.
- Haris Malik (LIC1010): CNIC blank in rental #44, present (`42201-0123456-0`) in
  others.
- Hamza Sheikh: `Contact#` blank in rentals #16 and #37, present in others; CNIC is
  present and consistent in all his rows, so CNIC dedupe correctly re-links him.

This is exactly the "conservative dedupe with backfill" case the spec anticipated —
phone is primary, CNIC is the fallback, and a customer record should backfill a field
from any row that has it.

**License# as a candidate tertiary identifier:** in this sample, `License#` is stable
per customer even in the two rows above where CNIC is blank — worth carrying as a
third fallback dedupe key once the real CSV confirms it's reliably populated. Not
adopted as a rule yet, provisional only.

---

## 2. Mapping to Entities

- **customers** — one row per distinct person, keyed by normalized phone → CNIC
  fallback. Fields: full_name, phone, CNIC, license_no, license_city.
- **vehicles** — one row per distinct registration, confirmed safe to dedupe on
  `Vehicle#` since attributes are consistent per vehicle in this sample. Fields:
  registration, chassis#, engine#, company, model, trim ("Make" column — pending
  naming confirmation), horsepower, color, reg_year, insurance_due_on.
- **rentals** — one row per CSV row, `rental_no` = `Rental#` exactly. Fields:
  customer_id, vehicle_id, start_date, start_time, end_date, end_time, book_days,
  amount, balance, status, remarks, plus embedded reference-person fields
  (`ref_name`, `ref_contact`, `ref_relation`).
- **No separate "references" entity needed.** The `Ref.*` columns describe a
  guarantor/reference person *for that specific rental transaction*, not a reusable,
  searchable entity in their own right (never asked for in search requirements) — so
  they're stored as plain columns on `rentals`, not a fourth table. Revisit only if
  the real CSV shows references need their own search/history (e.g. the same
  reference person needs to be looked up across rentals).

---

## 3. Provisional Test-DB Schema

All fields carry a **[P]** where the mapping is provisional pending the real CSV.

```sql
CREATE TABLE customers (
  id                UUID PRIMARY KEY,
  full_name         TEXT,
  phone             TEXT,
  phone_normalized  TEXT,              -- digits only, indexed
  cnic              TEXT,
  cnic_normalized   TEXT,              -- digits only, indexed
  license_no        TEXT,              -- [P] tertiary dedupe candidate
  license_city      TEXT,              -- [P]
  is_deleted        INTEGER DEFAULT 0,
  version           INTEGER DEFAULT 1,
  created_at        TEXT,
  updated_at        TEXT
);
CREATE INDEX idx_customers_phone ON customers(phone_normalized);
CREATE INDEX idx_customers_cnic  ON customers(cnic_normalized);
CREATE INDEX idx_customers_name  ON customers(full_name COLLATE NOCASE);

CREATE TABLE vehicles (
  id                UUID PRIMARY KEY,
  registration_no   TEXT,
  registration_norm TEXT UNIQUE,       -- uppercase, no separators, indexed
  chassis_no        TEXT,              -- [P]
  engine_no         TEXT,              -- [P]
  company           TEXT,              -- [P] "brand" per this sample (Toyota/Honda)
  model_name        TEXT,              -- [P] "Model #" column — holds a name, not a code
  trim              TEXT,              -- [P] "Make" column — holds trim/variant
  horsepower        TEXT,              -- [P]
  color             TEXT,
  reg_year          INTEGER,           -- [P]
  insurance_due_on  TEXT,              -- vehicle-level, confirmed by consistency check
  is_deleted        INTEGER DEFAULT 0,
  version           INTEGER DEFAULT 1,
  created_at        TEXT,
  updated_at        TEXT
);
CREATE INDEX idx_vehicles_reg ON vehicles(registration_norm);

CREATE TABLE rentals (
  id                UUID PRIMARY KEY,       -- sync identity
  rental_no         INTEGER UNIQUE,         -- CSV's original number, immutable, NULL = pending
  is_placeholder    INTEGER DEFAULT 0,      -- gap-filled row, no source data
  customer_id       UUID REFERENCES customers(id),
  vehicle_id        UUID REFERENCES vehicles(id),
  start_date        TEXT,
  start_time        TEXT,                  -- [P] raw "10:30 AM" — confirm real format
  end_date          TEXT,
  end_time          TEXT,                  -- [P]
  book_days         INTEGER,               -- [P] source value; see Book Days note above
  amount            REAL,
  balance            REAL,
  status            TEXT,                  -- [P] only "Open"/"Closed" seen — confirm full value set
  remarks           TEXT,
  ref_name          TEXT,                  -- blank + literal "N/A" both normalized to NULL
  ref_contact       TEXT,
  ref_relation      TEXT,
  is_deleted        INTEGER DEFAULT 0,
  version           INTEGER DEFAULT 1,
  created_at        TEXT,
  updated_at        TEXT
);
CREATE INDEX idx_rentals_customer ON rentals(customer_id);
CREATE INDEX idx_rentals_vehicle  ON rentals(vehicle_id);
CREATE INDEX idx_rentals_start    ON rentals(start_date);
```

**Import normalization rules confirmed by this file:**
- Blank string AND literal `"N/A"` (any case) → `NULL` at import — both appear in
  `Ref.*` columns for the same meaning.
- `Contact#`/`CNIC` blank on a row does **not** mean the customer lacks it — check the
  other identifier and backfill from any other row for the same matched customer.

---

## 4. Entity Relationships

```
customers 1 ──< rentals >── 1 vehicles
```
- 10 customers, 3 vehicles, 60 rentals (55 real + 5 placeholders) in this test set.
- Repeat rentals for the same customer+vehicle pair (common in this data — e.g. Billa
  Khan rents `KHI-123` in #1, #12, #13, #27, #34, #45...) stay as **separate rows**,
  never merged — confirms the "never collapse rentals" rule against real repeat
  patterns, not just the hypothetical example in the spec.

---

## 5. Search / Index Plan (this test data)

| Query shape | Matches against | Example |
|---|---|---|
| Pure digits, in range 1–60 | `rentals.rental_no` exact | `"23"` → Rental #23 (Billa Khan, KHI-654) |
| 11-digit / digit-heavy | `customers.phone_normalized` exact→partial | `"03001234567"` → Billa Khan, 9 rentals |
| CNIC-shaped (has dashes/13 digits) | `customers.cnic_normalized` | `"42201-1234567-1"` → Billa Khan |
| Letters+digits, plate-shaped | `vehicles.registration_norm` | `"KHI-123"` → vehicle + all 22 rentals |
| Letters only | `customers.full_name LIKE '%q%' NOCASE` | `"Billa"` → Billa Khan profile |

A query like `"23"` is genuinely ambiguous in real data (could be a rental number or
part of a phone) — both checks run; exact `rental_no` match is ranked first per spec
priority rules, phone partial-match results (if any) still show below it.

---

## 6. Test Cases (run against this exact CSV)

| # | Case | Expected result |
|---|---|---|
| 1 | Exact rental search `"23"` | Only Rental #23: Billa Khan, KHI-654, Open |
| 2 | Customer history search `"Billa"` | Billa Khan profile, 9 rentals: 1,12,13,23,27,34,43,45,56 |
| 3 | Vehicle history search `"KHI-123"` | Vehicle detail, 22 linked rentals across 8+ customers |
| 4 | Repeated customer | Billa Khan's 9 rentals all resolve to **one** `customer_id`, none duplicated |
| 5 | Repeated vehicle | `KHI-123`'s 22 rentals all resolve to **one** `vehicle_id` |
| 6 | Missing historical number | Rental `#4`, `#11`, `#25`, `#40`, `#55` each show "No previous record available" |
| 7 | Blank field → N/A | Rental #24 → Remarks shows "N/A"; Rental #18 → customer CNIC shows "N/A" on that row but the merged customer profile shows the real CNIC from another row |
| 8 | Create new rental offline | Saved locally, shown as "Pending #<uuid-prefix>", queued in outbox |
| 9 | Sync new rental | Backend assigns `rental_no = 61` (max real = 60, gaps excluded from seed but irrelevant here since 60 is real) |
| 10 | Edit offline → sync | Edit Rental #58 balance while offline; after sync, `version` incremented, no duplicate row created |
| 11 | Delete/soft-delete → sync | Soft-delete Rental #10 offline; after sync, `is_deleted=1` remotely, `rental_no 10` never reappears/reused |
| 12 | Backup/export | Export after import → summary shows 55 real + 5 placeholder = 60 rentals, 10 customers, 3 vehicles |
| 13 | Restore | Restore onto a clean install → same counts, Rental #23 still Billa Khan/KHI-654, no duplicates (UUID upsert) |
| 14 | App restart while unsynced | Create rental offline → force-quit app → reopen → outbox item still pending, "Pending #" still shown → reconnect → syncs to next real number |

---

## 7. Exact Implementation Order — Next Step

Do **not** start the Flutter UI or Supabase yet. Validate the data logic first, since
it's the highest-risk part of the whole spec:

1. Build the local SQLite schema above as the app's `data/` layer (schema + a
   `CustomerRepository`/`VehicleRepository`/`RentalRepository`), independent of any
   UI.
2. Implement the CSV import pipeline (parse → normalize → dedupe → gap-fill →
   transactional insert) as a standalone, testable unit.
3. Run it against `test_data/burhan_rent_a_car_temporary_test.csv` and assert every
   case in §6 (counts, gap placeholders, dedupe correctness, N/A rendering).
4. Only after §6 passes cleanly, scaffold the Flutter app shell (3-section nav) and
   wire it to this already-validated data layer.
5. Supabase/Postgres schema mirroring happens once the **real** CSV confirms the
   provisional `[P]` fields above — no need to stand up the backend to validate local
   import logic.
