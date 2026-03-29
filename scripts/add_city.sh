#!/usr/bin/env bash
# add_city.sh — Aggiunge una nuova citta al sistema di risorse remote
#
# Automatizza: aggiornamento metadata, packaging, upload risorse cifrate, aggiornamento cities.json
# NON automatizza: copia file nel bundle, aggiornamento codice (alias layer)
#
# Uso:
#   ./scripts/add_city.sh <city_id> <city_name> --province XX --lat N --lon N [opzioni]
#   ./scripts/add_city.sh --all   # Rigenera e carica TUTTE le citta
#
# Esempi:
#   ./scripts/add_city.sh fisciano "Fisciano" --province SA --lat 40.770 --lon 14.793
#   ./scripts/add_city.sh --all
#
# Prerequisiti:
#   - gh (GitHub CLI) installato e autenticato
#   - python3 con pacchetto 'cryptography'
#   - File GeoJSON in mobile_ios/Projects/App/Resources/GeoJSON/{city_id}/
#   - File PDF in mobile_ios/Projects/App/Resources/PDF/{city_name}.pdf

set -euo pipefail

REPO="LuogoSicuro/luogosicuro_mobile_configs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
IOS_GEOJSON_DIR="${WORKSPACE_ROOT}/mobile_ios/Projects/App/Resources/GeoJSON"
IOS_PDF_DIR="${WORKSPACE_ROOT}/mobile_ios/Projects/App/Resources/PDF"
METADATA_FILE="${SCRIPT_DIR}/cities_metadata.json"

GEOJSON_TAG="geojson-v1"
PDF_TAG="pdf-v1"
BOUNDARY_TAG="boundaries-v1"
MANIFEST_TAG="v2.0"

# Opzioni
ALL_MODE=false
PROVINCE=""
LAT=""
LON=""
GEOFENCE_RADIUS="5000"
PDF_FILENAME=""

print_usage() {
  cat <<EOF
Uso: $(basename "$0") <city_id> <city_name> --province XX --lat N --lon N [opzioni]
     $(basename "$0") --all [opzioni]

Opzioni:
  --province XX         Sigla provincia (obbligatorio per nuova citta)
  --lat N               Latitudine centro citta (obbligatorio per nuova citta)
  --lon N               Longitudine centro citta (obbligatorio per nuova citta)
  --radius N            Raggio geofencing in metri (default: 5000)
  --pdf-filename NAME   Nome file PDF senza estensione (default: city_name)
  --geojson-tag TAG     Tag release GeoJSON (default: geojson-v1)
  --pdf-tag TAG         Tag release PDF (default: pdf-v1)
  --boundary-tag TAG    Tag release boundary (default: boundaries-v1)
  --all                 Rigenera e carica TUTTE le citta

Esempio:
  $(basename "$0") fisciano "Fisciano" --province SA --lat 40.770 --lon 14.793
EOF
}

# --- Parse argomenti ---
CITY_ID=""
CITY_NAME=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL_MODE=true; shift ;;
    --province) PROVINCE="$2"; shift 2 ;;
    --lat) LAT="$2"; shift 2 ;;
    --lon) LON="$2"; shift 2 ;;
    --radius) GEOFENCE_RADIUS="$2"; shift 2 ;;
    --pdf-filename) PDF_FILENAME="$2"; shift 2 ;;
    --geojson-tag) GEOJSON_TAG="$2"; shift 2 ;;
    --pdf-tag) PDF_TAG="$2"; shift 2 ;;
    --boundary-tag) BOUNDARY_TAG="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    -*) echo "Opzione sconosciuta: $1"; print_usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ "$ALL_MODE" == false ]]; then
  if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
    echo "ERRORE: servono city_id e city_name"
    print_usage
    exit 1
  fi
  CITY_ID="${POSITIONAL[0]}"
  CITY_NAME="${POSITIONAL[1]}"
  [[ -z "$PDF_FILENAME" ]] && PDF_FILENAME="$CITY_NAME"
fi

# --- Verifica prerequisiti ---
if ! command -v gh &>/dev/null; then
  echo "ERRORE: gh (GitHub CLI) non installato. Installa con: brew install gh"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "ERRORE: gh non autenticato. Esegui: gh auth login"
  exit 1
fi

if ! python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" &>/dev/null; then
  echo "ERRORE: pacchetto 'cryptography' non installato. Esegui: pip3 install cryptography"
  exit 1
fi

# --- Modalita --all ---
if [[ "$ALL_MODE" == true ]]; then
  echo "=== Modalita completa: rigenera e carica TUTTE le citta ==="
  echo ""

  echo "1/3 Packaging risorse..."
  python3 "${SCRIPT_DIR}/package_resources.py" --output-dir "$OUTPUT_DIR"
  echo ""

  echo "2/3 Upload su GitHub Releases..."
  bash "${SCRIPT_DIR}/upload_resources.sh" \
    --geojson-tag "$GEOJSON_TAG" --pdf-tag "$PDF_TAG" \
    --boundary-tag "$BOUNDARY_TAG" --manifest-tag "$MANIFEST_TAG"
  echo ""

  echo "3/3 Completato."
  exit 0
fi

# --- Modalita singola citta ---
echo "=== Aggiunta citta: ${CITY_NAME} (${CITY_ID}) ==="
echo ""

# Verifica parametri obbligatori
if [[ -z "$PROVINCE" || -z "$LAT" || -z "$LON" ]]; then
  echo "ERRORE: --province, --lat e --lon sono obbligatori per una nuova citta"
  print_usage
  exit 1
fi

# Verifica file sorgente
CITY_GEOJSON_DIR="${IOS_GEOJSON_DIR}/${CITY_ID}"
if [[ ! -d "$CITY_GEOJSON_DIR" ]]; then
  echo "ERRORE: directory GeoJSON non trovata: ${CITY_GEOJSON_DIR}"
  echo "Copia i file GeoJSON in questa directory prima di procedere."
  exit 1
fi

GEOJSON_COUNT=$(find "$CITY_GEOJSON_DIR" -name "*.geojson" | wc -l | tr -d ' ')
if [[ "$GEOJSON_COUNT" -eq 0 ]]; then
  echo "ERRORE: nessun file .geojson trovato in ${CITY_GEOJSON_DIR}"
  exit 1
fi
echo "  GeoJSON: ${GEOJSON_COUNT} file trovati"

# Verifica PDF esiste
if [[ ! -f "${IOS_PDF_DIR}/${PDF_FILENAME}.pdf" ]]; then
  echo "ERRORE: PDF non trovato: ${IOS_PDF_DIR}/${PDF_FILENAME}.pdf"
  exit 1
fi
echo "  PDF: ${PDF_FILENAME}.pdf trovato"

# --- Step 1: Aggiorna cities_metadata.json ---
echo ""
echo "1/5 Aggiornamento cities_metadata.json..."

if python3 -c "
import json
with open('${METADATA_FILE}') as f:
    data = json.load(f)
if any(c['id'] == '${CITY_ID}' for c in data):
    exit(0)
exit(1)
" 2>/dev/null; then
  echo "  '${CITY_ID}' gia presente in cities_metadata.json"
else
  python3 -c "
import json
with open('${METADATA_FILE}') as f:
    data = json.load(f)
data.append({
    'id': '${CITY_ID}',
    'name': '${CITY_NAME}',
    'province': '${PROVINCE}',
    'latitude': ${LAT},
    'longitude': ${LON},
    'geofenceRadius': ${GEOFENCE_RADIUS},
    'pdfFileName': '${PDF_FILENAME}'
})
with open('${METADATA_FILE}', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print('  Aggiunto a cities_metadata.json')
"
fi

# --- Step 2: Package ---
echo ""
echo "2/5 Packaging risorse cifrate..."
python3 "${SCRIPT_DIR}/package_resources.py" --output-dir "$OUTPUT_DIR"

# Verifica output
if [[ ! -f "${OUTPUT_DIR}/${CITY_ID}.geojson.deflate.enc" ]]; then
  echo "ERRORE: file GeoJSON cifrato non generato"
  exit 1
fi

# --- Step 3: Upload ---
echo ""
echo "3/5 Upload su GitHub Releases..."
bash "${SCRIPT_DIR}/upload_resources.sh" \
  --geojson-tag "$GEOJSON_TAG" --pdf-tag "$PDF_TAG" \
  --boundary-tag "$BOUNDARY_TAG" --manifest-tag "$MANIFEST_TAG"

# --- Step 4: Riepilogo ---
echo ""
echo "=== Completato ==="
echo ""
echo "Risorse remote caricate per: ${CITY_NAME} (${CITY_ID})"
echo ""
echo "Prossimi step manuali (se non ancora fatti):"
echo "  1. Copia GeoJSON nel bundle iOS (gia fatto se hai preparato i file)"
echo "  2. Copia GeoJSON nel bundle Android (app/src/main/assets/geojson/${CITY_ID}/)"
echo "  3. Verifica alias layer (LayerRepository.swift + CityRepository.kt)"
echo "  4. Build e test su entrambe le piattaforme"
echo ""
echo "NOTA: Non serve aggiornare fallback list o layer allowlist!"
echo "      L'app scarica automaticamente i metadati dal cities.json remoto."
echo ""
echo "URL di verifica:"
echo "  GeoJSON:  https://github.com/${REPO}/releases/download/${GEOJSON_TAG}/${CITY_ID}.geojson.deflate.enc"
echo "  PDF:      https://github.com/${REPO}/releases/download/${PDF_TAG}/${CITY_ID}.pdf.enc"
echo "  Boundary: https://github.com/${REPO}/releases/download/${BOUNDARY_TAG}/${CITY_ID}.boundary.enc"
echo "  Manifest: https://github.com/${REPO}/releases/download/${MANIFEST_TAG}/manifest.json"
echo "  Cities:   https://github.com/${REPO}/releases/download/${MANIFEST_TAG}/cities.json"
