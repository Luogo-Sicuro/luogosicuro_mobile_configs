#!/usr/bin/env python3
"""
Package GeoJSON, PDF, and boundary resources for luogoSICURO remote delivery.

For each city:
- GeoJSON: bundles all .geojson files into a single JSON dict, raw-deflate compresses, encrypts with AES-256-GCM
- PDF: encrypts the PDF file with AES-256-GCM
- Boundary: encrypts confini_comunali.geojson with AES-256-GCM (no compression)

Outputs:
- {cityId}.geojson.deflate.enc  (encrypted deflate-compressed JSON bundle)
- {cityId}.pdf.enc              (encrypted PDF)
- {cityId}.boundary.enc         (encrypted boundary GeoJSON)
- manifest.json                 (version manifest with SHA-256 hashes)
- cities.json                 (v2 city catalog with full metadata)

Usage:
    python3 package_resources.py [--output-dir ./output]
"""

import argparse
import hashlib
import json
import os
import sys
import zlib
from pathlib import Path
from typing import Optional

# AES-256-GCM encryption via cryptography library (pip install cryptography)
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:
    print("ERROR: 'cryptography' package required. Install with: pip3 install cryptography")
    sys.exit(1)

# --- Encryption key (XOR-obfuscated, same as in app binaries) ---
_KEY_PART1 = bytes([
    0xC2, 0x43, 0xEB, 0x10, 0xC0, 0x88, 0xA1, 0x04,
    0x4F, 0xDA, 0xFF, 0x54, 0xCA, 0xAA, 0x57, 0xD3,
    0x48, 0x16, 0x74, 0xE8, 0x71, 0x73, 0xA6, 0x02,
    0x59, 0xC1, 0x03, 0x6E, 0x42, 0xBF, 0x48, 0x6A,
])
_KEY_PART2 = bytes([
    0x9A, 0xF1, 0x77, 0xD1, 0x50, 0xED, 0x29, 0x33,
    0x5D, 0x79, 0x02, 0x3E, 0x0B, 0x5B, 0x73, 0xBC,
    0x42, 0x93, 0x7E, 0xE1, 0x3D, 0xDD, 0xA2, 0x36,
    0xA8, 0x5D, 0x94, 0xFB, 0x3F, 0x9E, 0x57, 0xBC,
])
ENCRYPTION_KEY = bytes(a ^ b for a, b in zip(_KEY_PART1, _KEY_PART2))

# --- Paths (relative to workspace root) ---
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_ROOT = SCRIPT_DIR.parent.parent
IOS_GEOJSON_DIR = WORKSPACE_ROOT / "mobile_ios" / "Projects" / "App" / "Resources" / "GeoJSON"
IOS_PDF_DIR = WORKSPACE_ROOT / "mobile_ios" / "Projects" / "App" / "Resources" / "PDF"
CITIES_METADATA_FILE = SCRIPT_DIR / "cities_metadata.json"


def encrypt_data(plaintext: bytes) -> bytes:
    """Encrypt with AES-256-GCM. Returns nonce (12 bytes) + ciphertext + tag."""
    nonce = os.urandom(12)
    aesgcm = AESGCM(ENCRYPTION_KEY)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    return nonce + ciphertext


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_cities_metadata() -> list:
    """Load city metadata from cities_metadata.json."""
    if not CITIES_METADATA_FILE.exists():
        print(f"WARNING: {CITIES_METADATA_FILE} not found, PDF mapping will be limited")
        return []
    with open(CITIES_METADATA_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def package_geojson(city_id: str, city_dir: Path, output_dir: Path) -> Optional[dict]:
    """Bundle all .geojson files for a city into a single encrypted archive."""
    geojson_files = sorted(city_dir.glob("*.geojson"))
    if not geojson_files:
        print(f"  WARNING: No .geojson files in {city_dir}")
        return None

    # Build dict: {filename_without_ext: parsed_geojson}
    bundle = {}
    prefix = f"{city_id}_"
    for f in geojson_files:
        name = f.stem  # e.g. "contrada_rischio_frane"
        # Strip city prefix if present
        if name.startswith(prefix):
            name = name[len(prefix):]
        with open(f, "r", encoding="utf-8") as fh:
            bundle[name] = json.load(fh)

    # Serialize → raw deflate compress → encrypt
    json_bytes = json.dumps(bundle, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = compressor.compress(json_bytes) + compressor.flush()
    encrypted = encrypt_data(compressed)

    out_path = output_dir / f"{city_id}.geojson.deflate.enc"
    out_path.write_bytes(encrypted)

    raw_size = sum(f.stat().st_size for f in geojson_files)
    print(f"  GeoJSON: {len(geojson_files)} files, {raw_size / 1024:.0f} KB raw → "
          f"{len(compressed) / 1024:.0f} KB deflate → {len(encrypted) / 1024:.0f} KB encrypted")

    return {
        "version": 1,
        "sha256": sha256_hex(encrypted),
        "sizeBytes": len(encrypted),
    }


def package_pdf(city_id: str, pdf_filename: str, output_dir: Path) -> Optional[dict]:
    """Encrypt a city's PDF file."""
    pdf_path = IOS_PDF_DIR / f"{pdf_filename}.pdf"
    if not pdf_path.exists():
        print(f"  WARNING: PDF not found: {pdf_path}")
        return None

    plaintext = pdf_path.read_bytes()
    encrypted = encrypt_data(plaintext)

    out_path = output_dir / f"{city_id}.pdf.enc"
    out_path.write_bytes(encrypted)

    print(f"  PDF: {len(plaintext) / 1024:.0f} KB raw → {len(encrypted) / 1024:.0f} KB encrypted")

    return {
        "version": 1,
        "sha256": sha256_hex(encrypted),
        "sizeBytes": len(encrypted),
    }


def package_boundary(city_id: str, city_dir: Path, output_dir: Path) -> Optional[dict]:
    """Encrypt the confini_comunali.geojson as a standalone boundary file (no compression)."""
    # Try both naming conventions
    boundary_file = None
    for name in [f"{city_id}_confini_comunali.geojson", f"{city_id}_confine_comunale.geojson",
                 "confini_comunali.geojson", "confine_comunale.geojson"]:
        candidate = city_dir / name
        if candidate.exists():
            boundary_file = candidate
            break

    if boundary_file is None:
        print(f"  WARNING: No boundary file found for {city_id}")
        return None

    plaintext = boundary_file.read_bytes()
    encrypted = encrypt_data(plaintext)

    out_path = output_dir / f"{city_id}.boundary.enc"
    out_path.write_bytes(encrypted)

    print(f"  Boundary: {len(plaintext) / 1024:.0f} KB raw → {len(encrypted) / 1024:.0f} KB encrypted")

    return {
        "version": 1,
        "sha256": sha256_hex(encrypted),
        "sizeBytes": len(encrypted),
    }


def main():
    parser = argparse.ArgumentParser(description="Package luogoSICURO resources for remote delivery")
    parser.add_argument("--output-dir", default=str(SCRIPT_DIR / "output"),
                        help="Output directory for encrypted files and manifest")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not IOS_GEOJSON_DIR.exists():
        print(f"ERROR: GeoJSON directory not found: {IOS_GEOJSON_DIR}")
        sys.exit(1)

    # Load city metadata
    cities_metadata = load_cities_metadata()
    metadata_by_id = {m["id"]: m for m in cities_metadata}

    # Discover city directories
    city_dirs = sorted([d for d in IOS_GEOJSON_DIR.iterdir() if d.is_dir()])
    if not city_dirs:
        print(f"ERROR: No city directories found in {IOS_GEOJSON_DIR}")
        sys.exit(1)

    manifest = {
        "version": 2,
        "cities": [],
        "geojson": {},
        "pdf": {},
    }

    # cities.json entries
    cities_v2_entries = []

    print(f"Packaging {len(city_dirs)} cities...\n")

    for city_dir in city_dirs:
        city_id = city_dir.name
        print(f"[{city_id}]")

        meta = metadata_by_id.get(city_id, {})
        pdf_filename = meta.get("pdfFileName", "")

        # GeoJSON
        geojson_entry = package_geojson(city_id, city_dir, output_dir)
        if geojson_entry:
            manifest["geojson"][city_id] = geojson_entry

        # PDF
        if pdf_filename:
            pdf_entry = package_pdf(city_id, pdf_filename, output_dir)
            if pdf_entry:
                manifest["pdf"][city_id] = pdf_entry

        # Boundary
        boundary_info = package_boundary(city_id, city_dir, output_dir)

        # Build v2 city entry
        if meta:
            city_entry = {
                "id": city_id,
                "name": meta["name"],
                "province": meta["province"],
                "latitude": meta["latitude"],
                "longitude": meta["longitude"],
                "geofenceRadius": meta.get("geofenceRadius", 5000),
                "pdfFileName": meta.get("pdfFileName"),
                "hasPlan": True,
            }
            if boundary_info:
                city_entry["boundaryVersion"] = boundary_info["version"]
                city_entry["boundarySha256"] = boundary_info["sha256"]
                city_entry["boundarySizeBytes"] = boundary_info["sizeBytes"]
            cities_v2_entries.append(city_entry)

        print()

    # City names for backward compatibility (v1 apps)
    manifest["cities"] = [e["name"] for e in cities_v2_entries]

    # Write manifest.json
    manifest_path = output_dir / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    # Write cities.json
    cities_json = {
        "version": 2,
        "cityNames": [e["name"] for e in cities_v2_entries],
        "cities": cities_v2_entries,
    }
    cities_json_path = output_dir / "cities.json"
    with open(cities_json_path, "w", encoding="utf-8") as f:
        json.dump(cities_json, f, indent=2, ensure_ascii=False)

    print(f"Manifest written to: {manifest_path}")
    print(f"Cities catalog written to: {cities_json_path}")
    print(f"Encrypted files in: {output_dir}")

    # Summary
    total_geojson = sum(e["sizeBytes"] for e in manifest["geojson"].values())
    total_pdf = sum(e["sizeBytes"] for e in manifest["pdf"].values())
    boundary_files = list(output_dir.glob("*.boundary.enc"))
    total_boundary = sum(f.stat().st_size for f in boundary_files)
    print(f"\nTotal: {total_geojson / 1024 / 1024:.1f} MB GeoJSON + {total_pdf / 1024 / 1024:.1f} MB PDF "
          f"+ {total_boundary / 1024:.0f} KB boundaries "
          f"= {(total_geojson + total_pdf + total_boundary) / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
