#!/usr/bin/env bash
#
# android-emulator — chaîne Android SDK + émulateur pour les tests d'app mobile.
#
# RECETTE DE HOST : à poser sur une machine, pas dans un conteneur. L'émulateur
# exige /dev/kvm (hors de portée d'un conteneur) et l'empreinte disque est de
# 18 à 22 Go — on ne la refait pas à chaque provisionnement de workspace.
#
# Versions relevées dans le projet Gradle généré par `expo prebuild` (Termix
# Mobile), pas supposées :
#   JDK 17 · Gradle 8.14.3 (wrapper, téléchargé par le projet)
#   compileSdk/targetSdk 35 · minSdk 24 · build-tools 35.0.0
#   NDK 27.1.12297006 · CMake 3.22.1 (épinglé par react-native-reanimated)
#   Kotlin 2.0.21
#
# Cette recette installe l'OUTILLAGE. Elle ne compile aucun projet.
# Ré-exécutable sans effet : chaque étape est idempotente.

set -euo pipefail

# ─── Options de la recette (valeurs par défaut = recipe.meta.yaml) ───────────
API="${API_LEVEL:-35}"
IMAGE_VARIANT="${IMAGE_VARIANT:-default}"
AVD_NAME="${AVD_NAME:-termix-test}"
AVD_RAM="${AVD_RAM:-4096}"

BUILD_TOOLS="35.0.0"
NDK="27.1.12297006"
CMAKE="3.22.1"
SYSTEM_IMAGE="system-images;android-${API};${IMAGE_VARIANT};x86_64"
SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ─── Préconditions — AVANT tout téléchargement ───────────────────────────────
# Échouer après avoir tiré 2 Go parce que le disque est trop petit est le
# comportement à éviter : le contrôle passe en premier, et dit laquelle des
# préconditions manque.
step "Préconditions"

[ "$(uname -m)" = "x86_64" ] || fail "architecture $(uname -m) : l'image système x86_64 exige un hôte x86_64"

if [ ! -e /dev/kvm ]; then
  fail "/dev/kvm absent. L'émulateur exige la virtualisation matérielle ; sur une
  VM cela suppose un passthrough CPU 'host' (voir le paramètre CPU_TYPE du script
  de création des VM). Sans lui l'émulateur retombe en émulation logicielle,
  inutilisable pour juger un geste tactile."
fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "  /dev/kvm existe mais n'est pas accessible à $(whoami)."
  echo "  Corriger avec :  sudo usermod -aG kvm \"$(whoami)\" && newgrp kvm"
  fail "pas d'accès à /dev/kvm"
fi
echo "  /dev/kvm : OK"

CPUS="$(nproc)"
MEM_GB="$(free -g | awk '/^Mem:/ {print $2}')"
DISK_GB="$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')"
echo "  cpus=${CPUS} ram=${MEM_GB}G disque-libre=${DISK_GB}G"
[ "$CPUS" -ge 4 ]   || echo "  AVERTISSEMENT : 4 cœurs ou plus recommandés"
[ "$MEM_GB" -ge 8 ] || echo "  AVERTISSEMENT : 8 Go de RAM ou plus recommandés"
# Mesuré : ~3,7 Go de téléchargement, mais 18 à 22 Go une fois décompressé — le
# NDK pèse à lui seul ~5,5 Go, les caches Gradle 3 à 4 Go, et l'AVD grossit à
# l'usage. Le disque est la contrainte, pas la bande passante.
[ "$DISK_GB" -ge 30 ] || fail "~30 Go libres nécessaires (empreinte mesurée 18-22 Go, plus la marge de croissance de l'AVD) ; cette machine en a ${DISK_GB}"

# ─── JDK 17 ──────────────────────────────────────────────────────────────────
step "JDK 17"
if command -v java >/dev/null && java -version 2>&1 | grep -q '"17'; then
  echo "  déjà installé : $(java -version 2>&1 | head -1)"
else
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y -qq openjdk-17-jdk unzip curl
  elif command -v dnf >/dev/null; then
    ${SUDO} dnf install -y java-17-openjdk-devel unzip curl
  else
    fail "installer le JDK 17 à la main : ni apt-get ni dnf trouvés"
  fi
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
export JAVA_HOME
echo "  JAVA_HOME=$JAVA_HOME"

# ─── Outils en ligne de commande du SDK ──────────────────────────────────────
step "Android SDK command-line tools"
if [ ! -x "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$SDK_ROOT/cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fsSL "$CMDLINE_TOOLS_URL" -o "$tmp/tools.zip"
  unzip -q "$tmp/tools.zip" -d "$tmp"
  rm -rf "$SDK_ROOT/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$SDK_ROOT/cmdline-tools/latest"
  rm -rf "$tmp"
  echo "  installés dans $SDK_ROOT"
else
  echo "  déjà installés"
fi

export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:$PATH"

# ─── Paquets du SDK ──────────────────────────────────────────────────────────
step "Paquets du SDK (quelques Go au premier passage)"
# Le SDK se télécharge sans compte : les licences s'acceptent via sdkmanager,
# aucun secret n'est requis par cette recette.
yes | sdkmanager --licenses >/dev/null 2>&1 || true
# Le NDK et CMake ne sont PAS optionnels : newArchEnabled=true, et six
# dépendances embarquent du C++ (reanimated, worklets, gesture-handler,
# screens, svg, expo-modules-core). Sans eux le build Gradle échoue à la
# configuration — le piège dans lequel la première version du script est tombée.
sdkmanager --install \
  "platform-tools" \
  "platforms;android-${API}" \
  "build-tools;${BUILD_TOOLS}" \
  "cmake;${CMAKE}" \
  "ndk;${NDK}" \
  "emulator" \
  "${SYSTEM_IMAGE}" >/dev/null
echo "  installés : platform-tools, platforms;android-${API}, build-tools;${BUILD_TOOLS},"
echo "              cmake;${CMAKE}, ndk;${NDK}, emulator, ${SYSTEM_IMAGE}"

# ─── AVD ─────────────────────────────────────────────────────────────────────
step "Image d'émulateur « ${AVD_NAME} »"
if avdmanager list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
  echo "  existe déjà"
else
  echo no | avdmanager create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device "pixel_6" >/dev/null
  cfg="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
  # Un tas plus large et un vrai GPU gardent la WebView assez fluide pour que
  # le geste de défilement ressemble à celui d'un appareil réel.
  {
    echo "hw.ramSize=${AVD_RAM}"
    echo "vm.heapSize=512"
    echo "hw.gpu.enabled=yes"
    echo "hw.gpu.mode=host"
    echo "hw.keyboard=yes"
  } >> "$cfg"
  echo "  créé (pixel_6, ${AVD_RAM} Mo de RAM, GPU hôte)"
fi

# ─── Environnement de shell ──────────────────────────────────────────────────
step "Environnement de shell"
PROFILE="$HOME/.bashrc"
if ! grep -q "ANDROID_SDK_ROOT=$SDK_ROOT" "$PROFILE" 2>/dev/null; then
  {
    echo ""
    echo "# Android SDK (ajouté par la recette android-emulator)"
    echo "export JAVA_HOME=\"$JAVA_HOME\""
    echo "export ANDROID_SDK_ROOT=\"$SDK_ROOT\""
    echo "export ANDROID_HOME=\"$SDK_ROOT\""
    echo "export PATH=\"\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/emulator:\$PATH\""
  } >> "$PROFILE"
  echo "  ajouté à $PROFILE"
else
  echo "  déjà configuré"
fi

cat <<DONE

Outillage Android en place.

  Démarrer l'émulateur (le laisser tourner) :
      emulator -avd ${AVD_NAME} -gpu host &

  Attendre qu'il soit prêt :
      adb wait-for-device shell 'while [ "\$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'

  Depuis l'émulateur, la machine hôte est joignable en 10.0.2.2 — un serveur
  sur localhost:8080 de cette machine devient http://10.0.2.2:8080 pour l'app.

  Le build de l'application est hors périmètre de cette recette : elle installe
  l'outillage, elle ne compile aucun projet.

DONE
