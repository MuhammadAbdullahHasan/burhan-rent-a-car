"""Normalise the owner's agreement-photo archive for upload.

    python3 deploy/prepare_agreement_photos.py <archive-folder> <out-folder>

Input: the folder of photos named by rental number as the owner kept them
(`9286.jpeg`, `9288.jpg`, `1320 (2).jpeg`, `8552 Blank.jpeg`,
`7186.jpeg.crdownload.jpg`, sub-folders from inner zips, ...).

Output: `<rental_no>.jpg` for the first photo of a rental and
`<rental_no>-2.jpg`, `-3` ... for further distinct photos of the same
number, every one re-encoded to at most 1600 px on the long side (JPEG
q85, orientation baked in), which is what the app itself produces for a
new photo. Identical duplicates (same bytes under two names) collapse to
one. Files that are empty, unreadable or not named by a number are
reported and skipped -- never guessed at; so are names listed in
PHOTO_EXCLUDE (comma-separated), the owner's explicit drop list.

Writes `<out-folder>/manifest.json`: object name -> source file, so the
upload can be checked and re-run.
"""
import hashlib
import json
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor

from PIL import Image, ImageOps

# 1600/q85 is what the app produces for a new photo. On the free Supabase
# plan (1 GB of storage) the archive only fits at 1200/q70 (~830 MB), still
# readable for an A4 agreement; override with PHOTO_MAX_SIDE / PHOTO_QUALITY.
MAX_SIDE = int(os.environ.get("PHOTO_MAX_SIDE", 1600))
QUALITY = int(os.environ.get("PHOTO_QUALITY", 85))
NAME = re.compile(r"^(\d+)")


def collect(root):
    """(rental_no, path) for every candidate file, sorted so the plain
    `N.jpeg` comes before `N (2).jpeg` and the `.jpg` before the `.jpeg`."""
    found, skipped = [], []
    exclude = {n.strip() for n in os.environ.get("PHOTO_EXCLUDE", "").split(",") if n.strip()}
    for dirpath, _, names in os.walk(root):
        for name in names:
            path = os.path.join(dirpath, name)
            if name.startswith(".") or name.lower().endswith(".zip"):
                continue
            if name in exclude:
                skipped.append((path, "excluded by the owner"))
                continue
            m = NAME.match(name)
            if not m:
                skipped.append((path, "not named by a rental number"))
                continue
            if os.path.getsize(path) == 0:
                skipped.append((path, "empty file"))
                continue
            no = int(m.group(1))
            variant = 0 if re.fullmatch(r"\d+\.\w+", name) else 1
            found.append((no, variant, name.lower(), path))
    found.sort()
    return found, skipped


def convert(args):
    src, dst = args
    try:
        with Image.open(src) as im:
            im = ImageOps.exif_transpose(im)
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            im.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
            im.save(dst, "JPEG", quality=QUALITY, optimize=True)
        return dst, None
    except Exception as e:  # unreadable image
        return dst, f"{src}: {e}"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    found, skipped = collect(root)

    # Group by number; drop byte-identical copies; number the rest.
    jobs, manifest = [], {}
    by_no = {}
    for no, _, _, path in found:
        by_no.setdefault(no, []).append(path)
    for no, paths in sorted(by_no.items()):
        seen, distinct = set(), []
        for p in paths:
            h = hashlib.md5(open(p, "rb").read()).hexdigest()
            if h in seen:
                skipped.append((p, f"identical to another photo of #{no}"))
                continue
            seen.add(h)
            distinct.append(p)
        for i, p in enumerate(distinct):
            obj = f"{no}.jpg" if i == 0 else f"{no}-{i + 1}.jpg"
            manifest[obj] = os.path.relpath(p, root)
            jobs.append((p, os.path.join(out, obj)))

    errors = []
    with ProcessPoolExecutor() as pool:
        for i, (dst, err) in enumerate(pool.map(convert, jobs, chunksize=16), 1):
            if err:
                errors.append(err)
                manifest.pop(os.path.basename(dst), None)
            if i % 500 == 0:
                print(f"  {i}/{len(jobs)}", flush=True)

    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=0, sort_keys=True)
    total = sum(os.path.getsize(os.path.join(out, o)) for o in manifest)
    print(f"{len(manifest)} photos for {len(by_no)} rentals, "
          f"{total / 1e6:.0f} MB after re-encoding")
    for path, why in skipped:
        print(f"  skipped {os.path.relpath(path, root)}: {why}")
    for err in errors:
        print(f"  FAILED {err}")


if __name__ == "__main__":
    main()
