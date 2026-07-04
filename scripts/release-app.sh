#!/bin/bash
# release-app.sh — publica uma release do app (Android APK + iOS IPA) no GitHub
# Uso: bash scripts/release-app.sh
#
# O script lê a versão de barco_app/pubspec.yaml, cria/empurra a tag
# app-v{versao} e dispara o workflow release-app.yml no GitHub Actions.
# Para publicar uma nova versão: atualize o campo "version:" no pubspec.yaml,
# faça commit + push, depois rode este script.

set -e
cd "$(dirname "$0")/.."

# ── Localiza gh CLI ───────────────────────────────────────────────────────────
GH=""
for candidate in "$(command -v gh 2>/dev/null)" \
                 /opt/homebrew/bin/gh \
                 /usr/local/bin/gh \
                 ~/bin/gh; do
  [ -x "$candidate" ] && GH="$candidate" && break
done
if [ -z "$GH" ]; then
  echo "ERRO: gh CLI não encontrado. Instale com: brew install gh"
  exit 1
fi

# ── Lê versão do pubspec.yaml ─────────────────────────────────────────────────
VERSION=$(grep '^version:' barco_app/pubspec.yaml \
          | sed 's/version:[[:space:]]*//' \
          | cut -d'+' -f1 \
          | tr -d '[:space:]')

if [ -z "$VERSION" ]; then
  echo "ERRO: Não foi possível ler 'version:' de barco_app/pubspec.yaml"
  exit 1
fi

TAG="app-v$VERSION"
echo "==> App Braga Pesca — versão $VERSION  (tag: $TAG)"

# ── Verifica mudanças não comitadas ───────────────────────────────────────────
if ! git diff --quiet || ! git diff --staged --quiet; then
  echo "ERRO: Há mudanças não comitadas. Faça commit e push antes de publicar."
  exit 1
fi

# ── Verifica se já existe release com esse tag ────────────────────────────────
if "$GH" release view "$TAG" &>/dev/null; then
  echo "AVISO: Release $TAG já existe no GitHub."
  read -rp "Deseja deletar e recriar? (s/N): " CONFIRM
  if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo "Cancelado."
    exit 0
  fi
  "$GH" release delete "$TAG" --yes
  git push origin ":refs/tags/$TAG" 2>/dev/null || true
  git tag -d "$TAG" 2>/dev/null || true
fi

# ── Cria e empurra a tag ──────────────────────────────────────────────────────
echo "==> Criando tag $TAG..."
git tag "$TAG"
git push origin "$TAG"

echo ""
echo "==> Tag $TAG enviada com sucesso!"
echo "    O GitHub Actions vai compilar APK + IPA e criar o release automaticamente."
echo "    Acompanhe em: https://github.com/wilianpasternak/ModuloBarco/actions"
