#!/bin/bash
set -e

# Localiza o executável gh (Homebrew não está no PATH do terminal PlatformIO)
GH=$(command -v gh 2>/dev/null || echo "")
if [ -z "$GH" ]; then
  for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh ~/bin/gh; do
    [ -x "$candidate" ] && GH="$candidate" && break
  done
fi
if [ -z "$GH" ]; then
  echo "ERRO: gh CLI não encontrado. Instale com: brew install gh"
  exit 1
fi

# Lê a versão definida no firmware
VERSION=$(grep '#define FIRMWARE_VERSION' src/main.cpp | grep -o '"[^"]*"' | tr -d '"')

if [ -z "$VERSION" ]; then
  echo "ERRO: Não foi possível ler FIRMWARE_VERSION de src/main.cpp"
  exit 1
fi

echo "==> Versão do firmware: v$VERSION"

# Verifica se a release já existe
if "$GH" release view "v$VERSION" &>/dev/null; then
  echo "AVISO: Release v$VERSION já existe no GitHub."
  read -p "Deseja substituir? (s/N): " CONFIRM
  if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Cancelado."
    exit 0
  fi
  "$GH" release delete "v$VERSION" --yes
fi

# Compila o firmware
echo "==> Compilando firmware com PlatformIO..."
pio run

BIN=".pio/build/esp32/firmware.bin"
if [ ! -f "$BIN" ]; then
  echo "ERRO: Arquivo $BIN não encontrado após compilação."
  exit 1
fi

echo "==> Tamanho do firmware: $(du -h "$BIN" | cut -f1)"

# Cria a release no GitHub e faz upload do .bin
echo "==> Criando release v$VERSION no GitHub..."
"$GH" release create "v$VERSION" "$BIN" \
  --title "Firmware Braga Pesca v$VERSION" \
  --notes "## Firmware v$VERSION

### Instalação via OTA
No app Braga Pesca: **Config → Verificar atualização → Atualizar**

### Instalação manual
Use o PlatformIO ou esptool para gravar o \`firmware.bin\` diretamente."

echo ""
echo "==> Release v$VERSION publicada com sucesso!"
echo "    https://github.com/wilianpasternak/ModuloBarco/releases/tag/v$VERSION"
