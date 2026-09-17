# Rental agreement photos: bringing in the archive

The owner holds roughly **7,200 agreement photos at 100–150 KB each,
about 0.9 GB**. This note records how the app stores photos today, why
that cannot absorb the archive as-is, and the design to move to.

## How photos are stored today

* A photo taken in the app is straightened, resized to 1600 px on its
  long side (JPEG q85) and given a small thumbnail (`agreement_photo.dart`).
* Both are stored **inline as base64 in the `attachments` row** — in
  Postgres and in every device's SQLite — and every device downloads
  every photo during sync (`_attachmentBatchSize` = 20 per request).

This is fine for a few hundred photos. For the archive it is not:

| | Today's design with 7,200 photos | Limit |
|---|---|---|
| Postgres size | ≈ 1.2 GB (base64 inflates 33 %) | Free plan: 500 MB DB |
| Each phone's SQLite | ≈ 1.2 GB, all downloaded on first sync | Slow, fills the phone |
| Web (IndexedDB) | ≈ 1.2 GB in the browser | Browsers evict it |

## Target design

1. **Full-size photos go to Supabase Storage**, a private bucket
   `agreements`, one object per attachment at
   `<owner_id>/<rental_id>/<attachment_id>.jpg`. The existing
   `backups` bucket already shows the pattern: a storage policy that
   only lets `auth.uid()` read or write inside its own top-level folder.
2. **The `attachments` table keeps only metadata and the thumbnail**
   (≈ 8–15 KB each → ~100 MB for the archive, well inside the DB limit):
   `id, owner_id, entity_type, entity_id, kind, mime_type, storage_path,
   byte_size, thumbnail_base64, created_at, updated_at, version,
   is_deleted, synced_at`. `image_base64` is dropped.
3. **Devices sync metadata + thumbnails as they do now** and fetch the
   full photo **on demand** when the owner opens it, through a signed URL
   (short-lived, per request), caching it locally with an LRU cap.
4. **Upload path in the app**: save locally → queue → upload the JPEG to
   storage → then upsert the metadata row (so a row never points at a
   missing object). A failed upload stays queued, as today.
5. **Bulk import of the archive** (one-off script, run from the Mac):
   * input: a folder of photos whose file names carry the rental number
     (`1234.jpg`, `1234-2.jpg`, …) — to be confirmed against the real
     files;
   * for each file: match the rental by number, re-encode to 1600 px q85
     (typically 60–110 KB), cut the thumbnail, upload the object, insert
     the metadata row; skip and report anything that does not match a
     rental;
   * idempotent: re-running skips objects that already exist.

## Plan and hosting

* Storage: 7,200 × ~90 KB ≈ **650 MB** after re-encoding. The free plan
  allows 1 GB of storage, so it fits, but leaves little headroom; the
  **Pro plan ($25/month: 8 GB DB, 100 GB storage, daily backups, no
  project pausing)** is the right home for a business's records. On the
  free plan a project that is not used for a week is paused.
* Egress: opening a photo costs one download; thumbnails ride along with
  sync. Well inside either plan's allowance.

## Order of work

1. Storage bucket + policy in `supabase_migration.sql`.
2. Schema change (`storage_path`, drop `image_base64`) in both the local
   SQLite schema and Postgres, with a data migration for the photos
   already stored inline.
3. Sync engine: metadata-only pull; upload-then-upsert push.
4. Viewer: signed-URL fetch with local cache.
5. Import script; dry run against a sample of the archive first.

Roughly two working days end to end, plus the archive upload itself
(≈ 1–2 hours for 650 MB).
