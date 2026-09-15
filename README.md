# Burhan Rent-A-Car

Offline-first rental management for a single-owner rent-a-car business.
One universal search box, immutable historical rental numbers, and a
vehicle-inventory library.

**Live demo (web build, temporary test data):** see the *Deployments* panel of
this repository — published to GitHub Pages on every push to `main`.

## Layout

| Path | What it is |
|---|---|
| `lib/`, `test/` | `burhan_rent_a_car_data` — pure-Dart data layer: SQLite schema, CSV import pipeline, rental-number allocation, universal search, outbox/sync scaffolding. No Flutter dependency. |
| `app/` | The Flutter application (Android + web). Depends on the data layer as a path package. |
| `test_data/` | Temporary development CSV. **Not** the production schema — the real CSV replaces it. |
| `docs/` | Data analysis and provisional schema notes. |
| `.github/workflows/` | Tests + GitHub Pages deployment. |

## Rules the code enforces

- Historical rental numbers are imported exactly as-is and never renumbered.
- Gaps in the historical sequence exist as placeholder rows ("No previous
  record available") and are never reused.
- A new rental created offline shows `Pending #` until the backend assigns
  the next permanent number; numbers are never reused, including after a
  soft delete.
- Repeat rentals are never merged; customers are matched conservatively by
  normalized phone, then CNIC — never by name alone.
- Any missing field displays as `N/A`, never blank.

## Development

Pinned to Flutter 3.27.4 / Dart 3.6.2 (the newest whose VM runs on macOS 13).

```sh
# data layer
dart pub get && dart test

# app
cd app && flutter pub get && flutter test
flutter run -d chrome            # local web
flutter build apk --debug        # Android
```

The web build seeds its local database from `app/assets/…test.csv` on first
launch. Cloud sync (Supabase/PostgreSQL) is designed but not yet wired in.
