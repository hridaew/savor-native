#!/usr/bin/env bash
# Optional SHARP instant-preview setup for Savor Native.
# Prefer Python 3.13 (upstream). Falls back to python3 on PATH.
set -euo pipefail

ROOT="${HOME}/.savor-native/sharp"
REPO_URL="https://github.com/apple/ml-sharp.git"
VENV="${ROOT}/venv"
BIN_DIR="${ROOT}/bin"

mkdir -p "${ROOT}" "${BIN_DIR}"

PYTHON=""
for candidate in python3.13 python3; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    PYTHON="$(command -v "${candidate}")"
    break
  fi
done

if [[ -z "${PYTHON}" ]]; then
  echo "No python3 found. Install Python 3.13 (conda recommended) and retry." >&2
  exit 1
fi

echo "Using ${PYTHON}"
"${PYTHON}" -m venv "${VENV}"
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
python -m pip install --upgrade pip

if [[ ! -d "${ROOT}/ml-sharp/.git" ]]; then
  git clone --depth 1 "${REPO_URL}" "${ROOT}/ml-sharp"
fi

python -m pip install -r "${ROOT}/ml-sharp/requirements.txt"
python -m pip install -e "${ROOT}/ml-sharp"

ln -sfn "${VENV}/bin/sharp" "${BIN_DIR}/sharp"

echo ""
echo "SHARP installed."
echo "  Binary: ${BIN_DIR}/sharp"
echo "  Or set SAVOR_SHARP_BIN=${BIN_DIR}/sharp"
echo "First predict downloads model weights into Torch hub cache."
"${BIN_DIR}/sharp" --help | head -20
