#!/usr/bin/env bash
# upload_resources.sh — Carica tutte le risorse cifrate su GitHub Releases
#
# Uso:
#   ./scripts/upload_resources.sh [--geojson-tag TAG] [--pdf-tag TAG] [--manifest-tag TAG]
#
# Default: geojson-v1, pdf-v1, v1.0 (manifest)
#
# Prerequisiti:
#   - gh (GitHub CLI) installato e autenticato
#   - File .enc e manifest.json in scripts/output/

set -euo pipefail

REPO="LuogoSicuro/luogosicuro_mobile_configs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"

GEOJSON_TAG="geojson-v1"
PDF_TAG="pdf-v1"
MANIFEST_TAG="v1.0"

# Parse argomenti
while [[ $# -gt 0 ]]; do
  case "$1" in
    --geojson-tag) GEOJSON_TAG="$2"; shift 2 ;;
    --pdf-tag) PDF_TAG="$2"; shift 2 ;;
    --manifest-tag) MANIFEST_TAG="$2"; shift 2 ;;
    *) echo "Argomento sconosciuto: $1"; exit 1 ;;
  esac
done

# Verifica prerequisiti
if ! command -v gh &>/dev/null; then
  echo "ERRORE: gh (GitHub CLI) non installato. Installa con: brew install gh"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "ERRORE: gh non autenticato. Esegui: gh auth login"
  exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "ERRORE: directory output non trovata: ${OUTPUT_DIR}"
  echo "Esegui prima: python3 scripts/package_resources.py"
  exit 1
fi

# Raccogli file
GEOJSON_FILES=("${OUTPUT_DIR}"/*.geojson.deflate.enc)
PDF_FILES=("${OUTPUT_DIR}"/*.pdf.enc)
MANIFEST_FILE="${OUTPUT_DIR}/manifest.json"

if [[ ! -f "${GEOJSON_FILES[0]}" ]]; then
  echo "ERRORE: nessun file .geojson.deflate.enc trovato in ${OUTPUT_DIR}"
  exit 1
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "ERRORE: manifest.json non trovato in ${OUTPUT_DIR}"
  exit 1
fi

echo "=== Upload risorse su GitHub Releases ==="
echo "Repository: ${REPO}"
echo "GeoJSON tag: ${GEOJSON_TAG} (${#GEOJSON_FILES[@]} file)"
echo "PDF tag: ${PDF_TAG} (${#PDF_FILES[@]} file)"
echo "Manifest tag: ${MANIFEST_TAG}"
echo ""

# --- GeoJSON ---
echo "--- GeoJSON (${GEOJSON_TAG}) ---"

# Crea la release se non esiste
if ! gh release view "$GEOJSON_TAG" --repo "$REPO" &>/dev/null; then
  echo "Creo release ${GEOJSON_TAG}..."
  gh release create "$GEOJSON_TAG" \
    --repo "$REPO" \
    --title "GeoJSON ${GEOJSON_TAG#geojson-}" \
    --notes "Encrypted GeoJSON bundles for all cities"
fi

for f in "${GEOJSON_FILES[@]}"; do
  echo "  Upload $(basename "$f")..."
  gh release upload "$GEOJSON_TAG" "$f" --repo "$REPO" --clobber
done

# --- PDF ---
echo ""
echo "--- PDF (${PDF_TAG}) ---"

if ! gh release view "$PDF_TAG" --repo "$REPO" &>/dev/null; then
  echo "Creo release ${PDF_TAG}..."
  gh release create "$PDF_TAG" \
    --repo "$REPO" \
    --title "PDF ${PDF_TAG#pdf-}" \
    --notes "Encrypted PDF plans for all cities"
fi

for f in "${PDF_FILES[@]}"; do
  echo "  Upload $(basename "$f")..."
  gh release upload "$PDF_TAG" "$f" --repo "$REPO" --clobber
done

# --- Manifest ---
echo ""
echo "--- Manifest (${MANIFEST_TAG}) ---"

if ! gh release view "$MANIFEST_TAG" --repo "$REPO" &>/dev/null; then
  echo "Creo release ${MANIFEST_TAG}..."
  gh release create "$MANIFEST_TAG" \
    --repo "$REPO" \
    --title "Config ${MANIFEST_TAG}" \
    --notes "Configuration files (cities.json, manifest.json)"
fi

echo "  Upload manifest.json..."
gh release upload "$MANIFEST_TAG" "$MANIFEST_FILE" --repo "$REPO" --clobber

echo ""
echo "=== Upload completato ==="
echo ""
echo "Verifica URL:"
FIRST_GEOJSON=$(basename "${GEOJSON_FILES[0]}")
echo "  curl -sI \"https://github.com/${REPO}/releases/download/${GEOJSON_TAG}/${FIRST_GEOJSON}\" | head -3"
echo "  curl -sI \"https://github.com/${REPO}/releases/download/${MANIFEST_TAG}/manifest.json\" | head -3"
