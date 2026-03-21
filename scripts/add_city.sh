#!/usr/bin/env bash
# add_city.sh — Aggiunge una nuova citta al sistema di risorse remote
#
# Automatizza: packaging, upload risorse cifrate, aggiornamento cities.json
# NON automatizza: copia file nel bundle, aggiornamento codice (fallback list, alias)
#
# Uso:
#   ./scripts/add_city.sh <city_id> <city_name> [opzioni]
#
# Esempi:
#   ./scripts/add_city.sh fisciano "Fisciano"
#   ./scripts/add_city.sh monte_san_giacomo "Monte San Giacomo" --province SA --lat 40.337 --lon 15.328
#   ./scripts/add_city.sh fisciano "Fisciano" --skip-cities-json
#   ./scripts/add_city.sh --all   # Rigenera e carica TUTTE le citta
#
# Prerequisiti:
#   - gh (GitHub CLI) installato e autenticato
#   - python3 con pacchetto 'cryptography'
#   - File GeoJSON in mobile_ios/Projects/App/Resources/GeoJSON/{city_id}/
#   - File PDF in mobile_ios/Projects/App/Resources/PDF/{city_name}.pdf
#   - Mapping PDF aggiunto in package_resources.py (CITY_PDF_MAP)

set -euo pipefail

REPO="LuogoSicuro/luogosicuro_mobile_configs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${SCRIPT_DIR}/output"
IOS_GEOJSON_DIR="${WORKSPACE_ROOT}/mobile_ios/Projects/App/Resources/GeoJSON"
IOS_PDF_DIR="${WORKSPACE_ROOT}/mobile_ios/Projects/App/Resources/PDF"

GEOJSON_TAG="geojson-v1"
PDF_TAG="pdf-v1"
MANIFEST_TAG="v1.0"

# Opzioni
SKIP_CITIES_JSON=false
ALL_MODE=false
PROVINCE=""
LAT=""
LON=""
GEOFENCE_RADIUS="5000"

print_usage() {
  cat <<EOF
Uso: $(basename "$0") <city_id> <city_name> [opzioni]
     $(basename "$0") --all [opzioni]

Opzioni:
  --province XX         Sigla provincia (per cities.json)
  --lat N               Latitudine centro citta
  --lon N               Longitudine centro citta
  --radius N            Raggio geofencing in metri (default: 5000)
  --skip-cities-json    Non aggiornare cities.json (utile se gia aggiornato)
  --geojson-tag TAG     Tag release GeoJSON (default: geojson-v1)
  --pdf-tag TAG         Tag release PDF (default: pdf-v1)
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
    --skip-cities-json) SKIP_CITIES_JSON=true; shift ;;
    --geojson-tag) GEOJSON_TAG="$2"; shift 2 ;;
    --pdf-tag) PDF_TAG="$2"; shift 2 ;;
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
    --geojson-tag "$GEOJSON_TAG" --pdf-tag "$PDF_TAG" --manifest-tag "$MANIFEST_TAG"
  echo ""

  echo "3/3 Completato."
  exit 0
fi

# --- Modalita singola citta ---
echo "=== Aggiunta citta: ${CITY_NAME} (${CITY_ID}) ==="
echo ""

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

# Verifica PDF mapping in package_resources.py
if ! grep -q "\"${CITY_ID}\"" "${SCRIPT_DIR}/package_resources.py"; then
  echo ""
  echo "ERRORE: city_id '${CITY_ID}' non trovato in CITY_PDF_MAP di package_resources.py"
  echo "Aggiungi il mapping prima di procedere:"
  echo "  \"${CITY_ID}\": \"${CITY_NAME}.pdf\","
  exit 1
fi

# Verifica PDF esiste
PDF_FILE=$(python3 -c "
import sys; sys.path.insert(0, '${SCRIPT_DIR}')
from package_resources import CITY_PDF_MAP
print(CITY_PDF_MAP.get('${CITY_ID}', ''))
" 2>/dev/null || echo "")

if [[ -z "$PDF_FILE" ]]; then
  echo "ATTENZIONE: impossibile leggere il mapping PDF. Verifico manualmente..."
  PDF_FILE="${CITY_NAME}.pdf"
fi

if [[ ! -f "${IOS_PDF_DIR}/${PDF_FILE}" ]]; then
  echo "ERRORE: PDF non trovato: ${IOS_PDF_DIR}/${PDF_FILE}"
  exit 1
fi
echo "  PDF: ${PDF_FILE} trovato"

# --- Step 1: Package ---
echo ""
echo "1/4 Packaging risorse cifrate..."
python3 "${SCRIPT_DIR}/package_resources.py" --output-dir "$OUTPUT_DIR"

# Verifica output
if [[ ! -f "${OUTPUT_DIR}/${CITY_ID}.geojson.deflate.enc" ]]; then
  echo "ERRORE: file GeoJSON cifrato non generato"
  exit 1
fi
if [[ ! -f "${OUTPUT_DIR}/${CITY_ID}.pdf.enc" ]]; then
  echo "ERRORE: file PDF cifrato non generato"
  exit 1
fi

# --- Step 2: Upload GeoJSON ---
echo ""
echo "2/4 Upload GeoJSON cifrato..."

if ! gh release view "$GEOJSON_TAG" --repo "$REPO" &>/dev/null; then
  gh release create "$GEOJSON_TAG" --repo "$REPO" \
    --title "GeoJSON ${GEOJSON_TAG#geojson-}" \
    --notes "Encrypted GeoJSON bundles"
fi

gh release upload "$GEOJSON_TAG" \
  "${OUTPUT_DIR}/${CITY_ID}.geojson.deflate.enc" \
  --repo "$REPO" --clobber

# --- Step 3: Upload PDF ---
echo ""
echo "3/4 Upload PDF cifrato..."

if ! gh release view "$PDF_TAG" --repo "$REPO" &>/dev/null; then
  gh release create "$PDF_TAG" --repo "$REPO" \
    --title "PDF ${PDF_TAG#pdf-}" \
    --notes "Encrypted PDF plans"
fi

gh release upload "$PDF_TAG" \
  "${OUTPUT_DIR}/${CITY_ID}.pdf.enc" \
  --repo "$REPO" --clobber

# --- Step 4: Upload manifest + cities.json ---
echo ""
echo "4/4 Aggiornamento manifest e cities.json..."

if ! gh release view "$MANIFEST_TAG" --repo "$REPO" &>/dev/null; then
  gh release create "$MANIFEST_TAG" --repo "$REPO" \
    --title "Config ${MANIFEST_TAG}" \
    --notes "Configuration files"
fi

gh release upload "$MANIFEST_TAG" \
  "${OUTPUT_DIR}/manifest.json" \
  --repo "$REPO" --clobber

# Aggiornamento cities.json
if [[ "$SKIP_CITIES_JSON" == false ]]; then
  echo ""
  echo "  Aggiornamento cities.json..."

  TMPDIR_WORK=$(mktemp -d)
  trap "rm -rf '$TMPDIR_WORK'" EXIT

  # Scarica cities.json corrente
  CITIES_FILE="${TMPDIR_WORK}/cities.json"
  if gh release download "$MANIFEST_TAG" --pattern "cities.json" --repo "$REPO" --dir "$TMPDIR_WORK" 2>/dev/null; then
    echo "  cities.json scaricato"
  else
    echo "  cities.json non trovato, creo nuovo file"
    echo '{"cities":[]}' > "$CITIES_FILE"
  fi

  # Verifica se la citta esiste gia
  if python3 -c "
import json, sys
with open('${CITIES_FILE}') as f:
    data = json.load(f)
cities = data if isinstance(data, list) else data.get('cities', [])
# Cerca per nome (puo essere stringa o oggetto)
for c in cities:
    name = c if isinstance(c, str) else c.get('name', '')
    if name == '${CITY_NAME}':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
    echo "  '${CITY_NAME}' gia presente in cities.json, skip"
  else
    # Aggiungi la nuova citta
    if [[ -n "$LAT" && -n "$LON" && -n "$PROVINCE" ]]; then
      # Formato completo con metadati
      python3 -c "
import json
with open('${CITIES_FILE}') as f:
    data = json.load(f)
cities = data if isinstance(data, list) else data.get('cities', [])
# Se e' un array di stringhe, aggiungi come stringa
if cities and isinstance(cities[0], str):
    cities.append('${CITY_NAME}')
else:
    cities.append({
        'id': '${CITY_ID}',
        'name': '${CITY_NAME}',
        'province': '${PROVINCE}',
        'latitude': ${LAT},
        'longitude': ${LON},
        'geofenceRadius': ${GEOFENCE_RADIUS},
        'hasPlan': True
    })
if isinstance(data, list):
    data = cities
else:
    data['cities'] = cities
with open('${CITIES_FILE}', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    else
      # Formato semplice (solo nome)
      python3 -c "
import json
with open('${CITIES_FILE}') as f:
    data = json.load(f)
cities = data if isinstance(data, list) else data.get('cities', [])
if isinstance(cities[0], str) if cities else True:
    cities.append('${CITY_NAME}')
if isinstance(data, list):
    data = cities
else:
    data['cities'] = cities
with open('${CITIES_FILE}', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    fi

    gh release upload "$MANIFEST_TAG" "$CITIES_FILE" --repo "$REPO" --clobber
    echo "  cities.json aggiornato con '${CITY_NAME}'"
  fi
fi

# --- Riepilogo ---
echo ""
echo "=== Completato ==="
echo ""
echo "Risorse remote caricate per: ${CITY_NAME} (${CITY_ID})"
echo ""
echo "Prossimi step manuali (se non ancora fatti):"
echo "  1. Aggiorna fallback list iOS (CityModels.swift → mockCities)"
echo "  2. Aggiorna fallback list Android (cities_manifest.json in assets)"
echo "  3. Copia GeoJSON nel bundle Android (app/src/main/assets/geojson/${CITY_ID}/)"
echo "  4. Verifica alias layer (LayerRepository.swift + CityRepository.kt)"
echo "  5. Build e test su entrambe le piattaforme"
echo ""
echo "URL di verifica:"
echo "  GeoJSON: https://github.com/${REPO}/releases/download/${GEOJSON_TAG}/${CITY_ID}.geojson.deflate.enc"
echo "  PDF:     https://github.com/${REPO}/releases/download/${PDF_TAG}/${CITY_ID}.pdf.enc"
echo "  Manifest: https://github.com/${REPO}/releases/download/${MANIFEST_TAG}/manifest.json"
