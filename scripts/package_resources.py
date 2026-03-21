#!/usr/bin/env python3
"""
Package GeoJSON and PDF resources for luogoSICURO remote delivery.

For each city:
- GeoJSON: bundles all .geojson files into a single JSON dict, raw-deflate compresses, encrypts with AES-256-GCM
- PDF: encrypts the PDF file with AES-256-GCM

Outputs:
- {cityId}.geojson.deflate.enc  (encrypted deflate-compressed JSON bundle)
- {cityId}.pdf.enc              (encrypted PDF)
- manifest.json                 (version manifest with SHA-256 hashes)

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
WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
IOS_GEOJSON_DIR = WORKSPACE_ROOT / "mobile_ios" / "Projects" / "App" / "Resources" / "GeoJSON"
IOS_PDF_DIR = WORKSPACE_ROOT / "mobile_ios" / "Projects" / "App" / "Resources" / "PDF"

# City ID → PDF filename mapping
CITY_PDF_MAP = {
    "contrada": "Contrada.pdf",
    "vallesaccarda": "Vallesaccarda.pdf",
    "novi_velia": "Novi Velia.pdf",
    "perito": "Perito.pdf",
    "san_nicola_baronia": "San Nicola Baronia.pdf",
    "lacco_ameno": "Lacco Ameno.pdf",
}


def encrypt_data(plaintext: bytes) -> bytes:
    """Encrypt with AES-256-GCM. Returns nonce (12 bytes) + ciphertext + tag."""
    nonce = os.urandom(12)
    aesgcm = AESGCM(ENCRYPTION_KEY)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)
    return nonce + ciphertext


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    # Using raw deflate (wbits=-15) for compatibility with Apple's Compression framework
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


def package_pdf(city_id: str, output_dir: Path) -> Optional[dict]:
    """Encrypt a city's PDF file."""
    pdf_name = CITY_PDF_MAP.get(city_id)
    if not pdf_name:
        print(f"  WARNING: No PDF mapping for {city_id}")
        return None

    pdf_path = IOS_PDF_DIR / pdf_name
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


def main():
    parser = argparse.ArgumentParser(description="Package luogoSICURO resources for remote delivery")
    parser.add_argument("--output-dir", default=str(WORKSPACE_ROOT / "scripts" / "output"),
                        help="Output directory for encrypted files and manifest")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not IOS_GEOJSON_DIR.exists():
        print(f"ERROR: GeoJSON directory not found: {IOS_GEOJSON_DIR}")
        sys.exit(1)

    # Discover city directories
    city_dirs = sorted([d for d in IOS_GEOJSON_DIR.iterdir() if d.is_dir()])
    if not city_dirs:
        print(f"ERROR: No city directories found in {IOS_GEOJSON_DIR}")
        sys.exit(1)

    # Fetch existing city names from the current cities.json if it exists
    existing_cities = []

    manifest = {
        "version": 2,
        "cities": [],
        "geojson": {},
        "pdf": {},
    }

    print(f"Packaging {len(city_dirs)} cities...\n")

    for city_dir in city_dirs:
        city_id = city_dir.name
        print(f"[{city_id}]")

        # GeoJSON
        geojson_entry = package_geojson(city_id, city_dir, output_dir)
        if geojson_entry:
            manifest["geojson"][city_id] = geojson_entry

        # PDF
        pdf_entry = package_pdf(city_id, output_dir)
        if pdf_entry:
            manifest["pdf"][city_id] = pdf_entry

        print()

    # City names for backward compatibility
    city_name_map = {v.replace(".pdf", ""): k for k, v in CITY_PDF_MAP.items()}
    manifest["cities"] = [CITY_PDF_MAP[d.name].replace(".pdf", "") for d in city_dirs if d.name in CITY_PDF_MAP]

    # Write manifest
    manifest_path = output_dir / "manifest.json"
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)

    print(f"Manifest written to: {manifest_path}")
    print(f"Encrypted files in: {output_dir}")

    # Summary
    total_geojson = sum(e["sizeBytes"] for e in manifest["geojson"].values())
    total_pdf = sum(e["sizeBytes"] for e in manifest["pdf"].values())
    print(f"\nTotal: {total_geojson / 1024 / 1024:.1f} MB GeoJSON + {total_pdf / 1024 / 1024:.1f} MB PDF "
          f"= {(total_geojson + total_pdf) / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
