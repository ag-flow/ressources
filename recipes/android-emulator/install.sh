#!/usr/bin/env bash
#
# android-emulator — machine de développement Android complète, en un seul script.
#
# RECETTE DE HOST : à poser sur une machine, pas dans un conteneur. L'émulateur
# exige /dev/kvm (hors de portée d'un conteneur) et l'empreinte disque est de
# 18 à 22 Go — on ne la refait pas à chaque provisionnement de workspace.
#
# Couvre de bout en bout : dépendances système, JDK 17, Node >= 20, chaîne
# Android (SDK, NDK, CMake, émulateur, image système), AVD, dépôt et build de
# l'APK, démarrage de l'émulateur, puis installation. À la fin, `adb devices`
# voit un appareil PRÊT et l'app est installée dessus.
#
# DEUX MODES D'AFFICHAGE, et le choix est structurant :
#
#   headless (défaut)  émulateur en -no-window, rendu logiciel. Rien à regarder,
#                      mais rien à installer non plus.
#   écran (--display)  Xvfb + x11vnc + noVNC : l'écran de l'émulateur s'ouvre
#                      dans un navigateur, souris et clavier compris — donc le
#                      défilement à la molette, impossible via adb. Exige les
#                      bibliothèques d'exécution du binaire fenêtré (libpulse0,
#                      libgl1…), que le binaire headless n'utilise pas.
#
# Versions relevées dans le projet Gradle généré par `expo prebuild`, pas
# supposées : JDK 17 · Gradle 8.14.3 · compileSdk/targetSdk 35 · minSdk 24 ·
# build-tools 35.0.0 · NDK 27.1.12297006 · CMake 3.22.1 · Kotlin 2.0.21.
#
# Ré-exécutable sans effet : chaque étape détecte l'existant et sort en succès.
#
# Exécuté par le portail avec `sh`, pas `bash`, shebang ignoré (host_apply.py) —
# et sur Debian `sh` est dash. Rester en syntaxe POSIX : pas de `pipefail`, pas
# de tableaux, pas de `[[ ]]`, pas de substitution de processus.

set -eu

# ─── Options ─────────────────────────────────────────────────────────────────
# Trois niveaux, du moins au plus prioritaire :
#   1. valeurs par défaut ci-dessous
#   2. variables d'environnement — préfixées RECIPE_OPT_* quand le portail les
#      injecte (host_apply.py les exporte ainsi), nues en lancement manuel
#   3. drapeaux de ligne de commande, pour un appel à la main
API="${RECIPE_OPT_API_LEVEL:-${API_LEVEL:-35}}"
IMAGE_VARIANT="${RECIPE_OPT_IMAGE_VARIANT:-${IMAGE_VARIANT:-default}}"
AVD_NAME="${RECIPE_OPT_AVD_NAME:-${AVD_NAME:-termix-test}}"
AVD_RAM="${RECIPE_OPT_AVD_RAM:-${AVD_RAM:-3072}}"
GPU_MODE="${RECIPE_OPT_GPU_MODE:-${GPU_MODE:-swiftshader_indirect}}"
NODE_MAJOR="${RECIPE_OPT_NODE_MAJOR:-${NODE_MAJOR:-20}}"
# L'émulateur tourne sous l'utilisateur membre du groupe kvm, qui n'est pas
# forcément celui qui applique la recette : lancé en root, `$HOME` poserait le
# SDK dans /root, hors de portée de cet utilisateur.
TARGET_USER="${RECIPE_OPT_TARGET_USER:-${TARGET_USER:-$(id -un)}}"
# Mode « écran » : 0 = headless (défaut), 1 = Xvfb + x11vnc + noVNC.
DISPLAY_MODE="${RECIPE_OPT_DISPLAY:-${DISPLAY_MODE:-0}}"
VNC_PASSWORD="${RECIPE_OPT_VNC_PASSWORD:-${VNC_PASSWORD:-}}"
NOVNC_PORT="${RECIPE_OPT_NOVNC_PORT:-${NOVNC_PORT:-6080}}"
# 1440x2700 cadre un profil pixel_6 (1080x2400) avec sa barre d'outils.
SCREEN_SIZE="${RECIPE_OPT_SCREEN_SIZE:-${SCREEN_SIZE:-1440x2700}}"
# Le dépôt à builder est une propriété du WORKSPACE, pas de la recette. Il est
# déclaré `from: workspace.git_url` dans recipe.meta.yaml : le PORTAIL arbitre
# saisie > contexte > défaut, une fois, avant d'assembler la commande distante.
# Le script n'a donc aucune cascade à écrire — il lit son option, point.
REPO_URL="${RECIPE_OPT_REPO_URL:-${REPO_URL:-}}"
REPO_REF="${RECIPE_OPT_REPO_REF:-${REPO_REF:-main}}"
WORKDIR="${RECIPE_OPT_WORKDIR:-${WORKDIR:-}}"
SKIP_ANDROID="${RECIPE_OPT_SKIP_ANDROID:-${SKIP_ANDROID:-0}}"
SKIP_NODE="${RECIPE_OPT_SKIP_NODE:-${SKIP_NODE:-0}}"
SKIP_EMULATOR="${RECIPE_OPT_SKIP_EMULATOR:-${SKIP_EMULATOR:-0}}"
SKIP_BUILD="${RECIPE_OPT_SKIP_BUILD:-${SKIP_BUILD:-0}}"
# Actif par défaut : sur une machine sans écran, c'est un moyen de VOIR l'app
# tourner. Contrepartie assumée — ws-scrcpy ouvre un service de contrôle à
# distance sans authentification (cf. étape dédiée) ; le contenir relève du
# pare-feu. Le mode --display offre une alternative avec mot de passe.
ENABLE_SCRCPY="${RECIPE_OPT_ENABLE_SCRCPY:-${ENABLE_SCRCPY:-1}}"
SCRCPY_PORT="${RECIPE_OPT_SCRCPY_PORT:-${SCRCPY_PORT:-8000}}"
SCRCPY_DIR="${RECIPE_OPT_SCRCPY_DIR:-${SCRCPY_DIR:-}}"

usage() {
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

  --user NOM          utilisateur qui possédera le SDK et lancera l'émulateur
                      (défaut : l'appelant). Il est ajouté au groupe kvm.
  --display           mode « écran » : Xvfb + x11vnc + noVNC, émulateur fenêtré.
                      Exige --vnc-password. Défaut : headless.
  --vnc-password MDP  mot de passe VNC — obligatoire avec --display
  --novnc-port PORT   port web de noVNC (défaut 6080) ; seul port exposé
  --screen-size WxH   résolution de l'affichage virtuel (défaut 1440x2700)
  --skip-android      ne pas installer JDK/SDK/NDK/AVD
  --skip-node         ne pas installer Node
  --skip-emulator     ne pas démarrer l'émulateur
  --skip-build        ne pas cloner le dépôt ni builder l'app
  --no-scrcpy         ne pas installer ws-scrcpy (installé par défaut : écran de
                      l'émulateur dans un navigateur — AUCUNE authentification,
                      le service écoute sur toutes les interfaces)
  --scrcpy            forcer son installation
  --scrcpy-port PORT  port d'écoute de ws-scrcpy (défaut 8000)
  --scrcpy-dir CHEMIN où installer ws-scrcpy (défaut ~/ws-scrcpy)
  --gpu MODE          rendu : swiftshader_indirect (défaut, logiciel) | host
                      (passthrough GPU — exige /dev/dri sur la machine)
  --avd NOM           nom de l'AVD (défaut termix-test)
  --api NIVEAU        niveau d'API Android (défaut 35)
  --node MAJEURE      version majeure de Node (défaut 20, minimum 20)
  --repo URL          dépôt de l'app à builder
  --ref REF           branche ou tag à cloner
  --dir CHEMIN        répertoire de travail du dépôt
  -h, --help          cette aide

Les mêmes réglages passent en variables d'environnement (API_LEVEL, GPU_MODE,
SKIP_BUILD…), ou en RECIPE_OPT_* quand le portail applique la recette — un
appel sans argument est donc parfaitement valide.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --user)          TARGET_USER="$2"; shift 2 ;;
        --display)       DISPLAY_MODE=1; shift ;;
        --vnc-password)  VNC_PASSWORD="$2"; shift 2 ;;
        --novnc-port)    NOVNC_PORT="$2"; shift 2 ;;
        --screen-size)   SCREEN_SIZE="$2"; shift 2 ;;
        --skip-android)  SKIP_ANDROID=1; shift ;;
        --skip-node)     SKIP_NODE=1; shift ;;
        --skip-emulator) SKIP_EMULATOR=1; shift ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        --scrcpy)        ENABLE_SCRCPY=1; shift ;;
        --no-scrcpy)     ENABLE_SCRCPY=0; shift ;;
        --scrcpy-port)   SCRCPY_PORT="$2"; shift 2 ;;
        --scrcpy-dir)    SCRCPY_DIR="$2"; shift 2 ;;
        --gpu)           GPU_MODE="$2"; shift 2 ;;
        --avd)           AVD_NAME="$2"; shift 2 ;;
        --api)           API="$2"; shift 2 ;;
        --node)          NODE_MAJOR="$2"; shift 2 ;;
        --repo)          REPO_URL="$2"; shift 2 ;;
        --ref)           REPO_REF="$2"; shift 2 ;;
        --dir)           WORKDIR="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "option inconnue : $1" >&2; usage >&2; exit 2 ;;
    esac
done

BUILD_TOOLS="35.0.0"
NDK="27.1.12297006"
CMAKE="3.22.1"
SYSTEM_IMAGE="system-images;android-${API};${IMAGE_VARIANT};x86_64"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
VERIFY_URL="https://raw.githubusercontent.com/ag-flow/ressources/refs/heads/main/recipes/android-emulator/verify-scroll-gestures.sh"
PROFILE_D="/etc/profile.d/android.sh"

step() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ─── Élévation de privilèges ─────────────────────────────────────────────────
# `sudo` peut manquer sur une Debian minimale exécutée en root : appeler la
# commande directement plutôt que d'échouer alors qu'on a déjà tous les droits.
# Une variable `SUDO=""` ne suffirait pas — `${SUDO} -E bash` deviendrait
# `-E bash` et échouerait. D'où une fonction.
if [ "$(id -u)" -eq 0 ]; then
    run_root() { "$@"; }
elif command -v sudo >/dev/null 2>&1; then
    run_root() { sudo "$@"; }
else
    fail "ni root ni sudo : impossible d'installer les paquets système"
fi

# ─── Utilisateur cible ───────────────────────────────────────────────────────
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || fail "utilisateur inconnu : ${TARGET_USER}"
SDK_ROOT="${ANDROID_SDK_ROOT:-$TARGET_HOME/Android/Sdk}"
[ -n "$SCRCPY_DIR" ] || SCRCPY_DIR="$TARGET_HOME/ws-scrcpy"
EMULATOR_LOG="$TARGET_HOME/.android/emulator-${AVD_NAME}.log"

# Exécute un script sous l'utilisateur cible. `su -` ouvre un shell de login,
# qui source /etc/profile.d/android.sh — l'environnement Android est donc en
# place sans qu'on ait à le réinjecter dans chaque commande.
run_as_target() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        sh "$1"
    else
        chmod 0755 "$1"
        run_root su - "$TARGET_USER" -c "sh '$1'"
    fi
}

# ─── Préconditions — AVANT tout téléchargement ───────────────────────────────
# Échouer après avoir tiré 2 Go parce que le disque est trop petit est le
# comportement à éviter : le contrôle passe en premier, et dit laquelle des
# préconditions manque.
step "Préconditions"

echo "  utilisateur cible : ${TARGET_USER} (${TARGET_HOME})"

[ "$(uname -m)" = "x86_64" ] || fail "architecture $(uname -m) : l'image système x86_64 exige un hôte x86_64"

if [ ! -e /dev/kvm ]; then
    fail "/dev/kvm absent. L'émulateur exige la virtualisation matérielle ; sur une
  VM cela suppose un passthrough CPU 'host' et le nesting actif sur l'hôte."
fi
# L'appartenance au groupe est PAR UTILISATEUR : tester l'accès de l'appelant ne
# dit rien de celui qui lancera l'émulateur. C'est ce dernier qui compte.
KVM_GROUP="$(stat -c %G /dev/kvm)"
echo "  /dev/kvm : présent (groupe ${KVM_GROUP})"

# Le disque se mesure sur le système de fichiers du HOME cible, pas sur celui de
# l'appelant : les deux diffèrent dès que le script tourne en root.
CPUS="$(nproc)"
MEM_GB="$(free -g | awk '/^Mem:/ {print $2}')"
DISK_GB="$(df -BG --output=avail "$TARGET_HOME" | tail -1 | tr -dc '0-9')"
echo "  cpus=${CPUS} ram=${MEM_GB}G disque-libre=${DISK_GB}G (sur ${TARGET_HOME})"
[ "$CPUS" -ge 4 ]   || echo "  AVERTISSEMENT : 4 cœurs ou plus recommandés"
[ "$MEM_GB" -ge 8 ] || echo "  AVERTISSEMENT : 8 Go de RAM ou plus recommandés"
# Mesuré : ~3,7 Go de téléchargement, mais 18 à 22 Go une fois décompressé — le
# NDK pèse à lui seul ~5,5 Go, les caches Gradle 3 à 4 Go, et l'AVD grossit à
# l'usage. Le disque est la contrainte, pas la bande passante.
[ "$DISK_GB" -ge 30 ] || fail "~30 Go libres nécessaires (empreinte mesurée 18-22 Go, plus la marge de croissance de l'AVD) ; ${TARGET_HOME} en a ${DISK_GB}"

# Rendu et affichage sont deux choses distinctes : une VM peut très bien avoir un
# GPU en passthrough SANS écran.
case "$GPU_MODE" in
    swiftshader_indirect)
        echo "  rendu : swiftshader_indirect (logiciel, aucun GPU requis)"
        ;;
    host)
        # Vérifié ICI, avec les autres préconditions : découvrir l'absence de GPU
        # au démarrage de l'émulateur, c'est-à-dire après 20 Go de
        # téléchargement, est exactement ce qu'on cherche à éviter.
        [ -d /dev/dri ] || fail "--gpu host demandé mais /dev/dri est absent : aucun GPU n'est exposé à
  cette machine. Vérifier le passthrough GPU côté hyperviseur, ou rester sur
  swiftshader_indirect (rendu logiciel, sans GPU)."
        echo "  rendu : host (passthrough GPU) — $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
        ;;
    *)
        fail "mode GPU inconnu : ${GPU_MODE} (attendu swiftshader_indirect ou host)"
        ;;
esac

if [ "$DISPLAY_MODE" = "1" ]; then
    # Pas de valeur par défaut : un écran sans mot de passe sur un réseau
    # d'entreprise est un accès ouvert à la machine.
    [ -n "$VNC_PASSWORD" ] || fail "--display exige --vnc-password : un écran noVNC sans mot de passe
  est un accès ouvert à cette machine."
    echo "$SCREEN_SIZE" | grep -Eq '^[0-9]+x[0-9]+$' || fail "--screen-size attend la forme LARGEURxHAUTEUR (ex. 1440x2700), reçu : ${SCREEN_SIZE}"
    echo "  affichage : mode écran, noVNC sur ${NOVNC_PORT}, ${SCREEN_SIZE}"
else
    echo "  affichage : headless (-no-window)"
fi

# Le dépôt est EXIGÉ dès lors qu'on doit builder — et exigé ici, avant le
# moindre octet téléchargé. Couvre la machine SANS workspace rattaché : ni saisie
# ni héritage ne fournissent d'URL, et le portail ne considère pas ce cas comme
# une erreur. C'est donc à la recette de refuser.
if [ "$SKIP_BUILD" != "1" ] && [ -z "$REPO_URL" ]; then
    fail "aucun dépôt à builder : cette machine n'est rattachée à aucun workspace
  dont hériter le dépôt. Renseigner l'option 'repo_url', ou mettre 'skip_build'
  à 1 pour n'installer que l'outillage."
fi
if [ "$SKIP_BUILD" != "1" ]; then
    echo "  dépôt : ${REPO_URL}${REPO_REF:+ (${REPO_REF})}"
fi

# ─── Dépendances système ─────────────────────────────────────────────────────
# INCONDITIONNEL. Les poser dans la branche `else` du test JDK — comme le
# faisait le script d'origine — laisse une machine avec JDK 17 déjà installé
# sans `unzip`, et l'étape des command-line tools casse bien plus loin.
step "Dépendances système"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    PKG=apt
    run_root apt-get update -qq
    run_root apt-get install -y -qq unzip curl ca-certificates git
elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
    run_root dnf install -y unzip curl ca-certificates git
else
    fail "ni apt-get ni dnf : distribution non prise en charge (Debian et Ubuntu visées)"
fi
echo "  unzip, curl, ca-certificates, git en place"

if [ "$DISPLAY_MODE" = "1" ]; then
    # Le binaire fenêtré de l'émulateur est lié à libpulse, GL/EGL et X ; le
    # binaire headless ne l'est pas. Sans ces paquets, l'échec survient AU
    # LANCEMENT — donc après les 3,7 Go de téléchargement, le pire moment :
    #   qemu-system-x86_64: error while loading shared libraries: libpulse.so.0
    step "Pile d'affichage (mode écran)"
    if [ "$PKG" = apt ]; then
        run_root apt-get install -y -qq \
            libpulse0 libgl1 libglu1-mesa libegl1 libxkbcommon-x11-0 libnss3 libasound2 \
            xvfb x11vnc novnc websockify
    else
        run_root dnf install -y \
            pulseaudio-libs mesa-libGL mesa-libGLU mesa-libEGL libxkbcommon-x11 nss alsa-lib \
            xorg-x11-server-Xvfb x11vnc novnc python3-websockify
    fi
    echo "  bibliothèques du binaire fenêtré + xvfb, x11vnc, novnc, websockify"
fi

# ─── JDK 17 ──────────────────────────────────────────────────────────────────
if [ "$SKIP_ANDROID" = "1" ]; then
    step "Chaîne Android — ignorée (--skip-android)"
    JAVA_HOME="${JAVA_HOME:-}"
else
    step "JDK 17"
    if command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q '"17'; then
        echo "  déjà installé : $(java -version 2>&1 | head -1)"
    elif [ "$PKG" = apt ]; then
        run_root apt-get install -y -qq openjdk-17-jdk
    else
        run_root dnf install -y java-17-openjdk-devel
    fi
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    echo "  JAVA_HOME=$JAVA_HOME"
fi
export JAVA_HOME

# ─── Node >= 20 ──────────────────────────────────────────────────────────────
# Debian 12 ne propose que Node 18, et Expo 54 exige >= 20 : le paquet système
# ne convient pas, on passe par NodeSource. On contrôle la VERSION, pas la
# seule présence — c'est le piège du script d'origine.
if [ "$SKIP_NODE" = "1" ]; then
    step "Node — ignoré (--skip-node)"
else
    step "Node >= ${NODE_MAJOR}"
    NODE_OK=0
    if command -v node >/dev/null 2>&1; then
        CURRENT="$(node -v | sed 's/^v//' | cut -d. -f1)"
        if [ "$CURRENT" -ge "$NODE_MAJOR" ] 2>/dev/null; then
            NODE_OK=1
            echo "  déjà installé : $(node -v)"
        else
            echo "  $(node -v) trop ancienne — installation de la ${NODE_MAJOR}.x"
        fi
    fi
    if [ "$NODE_OK" = "0" ]; then
        if [ "$PKG" = apt ]; then
            NS="$(mktemp)"
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$NS"
            run_root bash "$NS"
            rm -f "$NS"
            run_root apt-get install -y -qq nodejs
        else
            run_root dnf module install -y "nodejs:${NODE_MAJOR}"
        fi
        command -v node >/dev/null 2>&1 || fail "Node introuvable après installation"
        CURRENT="$(node -v | sed 's/^v//' | cut -d. -f1)"
        [ "$CURRENT" -ge "$NODE_MAJOR" ] || fail "Node $(node -v) installé, ${NODE_MAJOR}+ attendu"
        echo "  installé : $(node -v)"
    fi
fi

# ─── Accès à /dev/kvm pour l'utilisateur cible ───────────────────────────────
step "Accès à /dev/kvm pour ${TARGET_USER}"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$KVM_GROUP"; then
    echo "  déjà membre du groupe ${KVM_GROUP}"
else
    run_root usermod -aG "$KVM_GROUP" "$TARGET_USER"
    echo "  ajouté au groupe ${KVM_GROUP}"
    echo "  (effectif à la prochaine ouverture de session de cet utilisateur)"
fi

# ─── Environnement de shell ──────────────────────────────────────────────────
# /etc/profile.d, PAS ~/.bashrc. Le ~/.profile de Debian source bien ~/.bashrc,
# mais celui-ci commence par la garde `case $- in *i*) ;; *) return;; esac` :
# en shell NON INTERACTIF il sort avant d'atteindre les exports. Résultat, tout
# marche à la main et rien ne marche depuis une recette, une commande distante
# ou une CI — avec `adb: command not found` comme seul indice, qui n'oriente pas
# vers la cause. Posé ICI, avant les étapes qui tournent sous `su -`, pour
# qu'elles en héritent.
step "Environnement de shell"
ENV_TMP="$(mktemp)"
{
    echo "# Android SDK — posé par la recette android-emulator, ne pas éditer à la main."
    [ -n "${JAVA_HOME:-}" ] && echo "export JAVA_HOME=\"${JAVA_HOME}\""
    echo "export ANDROID_SDK_ROOT=\"${SDK_ROOT}\""
    echo "export ANDROID_HOME=\"${SDK_ROOT}\""
    echo 'export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"'
} > "$ENV_TMP"
run_root cp "$ENV_TMP" "$PROFILE_D"
run_root chmod 0644 "$PROFILE_D"
rm -f "$ENV_TMP"
echo "  écrit dans ${PROFILE_D}"

# Le script lui-même en a besoin tout de suite.
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:$PATH"

STAGE_DIR="$(mktemp -d)"
chmod 0755 "$STAGE_DIR"
cleanup() { rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

# ─── Chaîne Android, sous l'utilisateur cible ────────────────────────────────
if [ "$SKIP_ANDROID" != "1" ]; then
    step "Chaîne Android (quelques Go au premier passage)"
    cat > "$STAGE_DIR/sdk.sh" <<STAGE
set -eu
SDK_ROOT="$SDK_ROOT"
export ANDROID_SDK_ROOT="\$SDK_ROOT" ANDROID_HOME="\$SDK_ROOT"
export PATH="\$SDK_ROOT/cmdline-tools/latest/bin:\$SDK_ROOT/platform-tools:\$SDK_ROOT/emulator:\$PATH"

if [ ! -x "\$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
    mkdir -p "\$SDK_ROOT/cmdline-tools"
    tmp="\$(mktemp -d)"
    curl -fsSL "$CMDLINE_TOOLS_URL" -o "\$tmp/tools.zip"
    unzip -q "\$tmp/tools.zip" -d "\$tmp"
    rm -rf "\$SDK_ROOT/cmdline-tools/latest"
    mv "\$tmp/cmdline-tools" "\$SDK_ROOT/cmdline-tools/latest"
    rm -rf "\$tmp"
    echo "  command-line tools installés dans \$SDK_ROOT"
else
    echo "  command-line tools déjà installés"
fi

# Le SDK se télécharge sans compte : les licences s'acceptent via sdkmanager,
# aucun secret n'est requis par cette recette.
yes | sdkmanager --licenses >/dev/null 2>&1 || true
# Le NDK et CMake ne sont PAS optionnels : newArchEnabled=true, et six
# dépendances embarquent du C++ (reanimated, worklets, gesture-handler,
# screens, svg, expo-modules-core). Sans eux le build Gradle échoue à la
# configuration.
sdkmanager --install \\
    "platform-tools" \\
    "platforms;android-$API" \\
    "build-tools;$BUILD_TOOLS" \\
    "cmake;$CMAKE" \\
    "ndk;$NDK" \\
    "emulator" \\
    "$SYSTEM_IMAGE" >/dev/null
echo "  paquets du SDK en place"

# ─── AVD ─────────────────────────────────────────────────────────────────────
CFG="\$HOME/.android/avd/${AVD_NAME}.avd/config.ini"

# avdmanager écrit DÉJÀ hw.gpu.enabled et hw.gpu.mode à la création, avec des
# espaces autour du '=' (« hw.gpu.mode = swiftshader_indirect »). Un \`>>\`
# aveugle créerait une SECONDE occurrence de chaque clé, d'une graphie
# différente : le comportement d'un config.ini à clés dupliquées n'est pas
# garanti. On remplace si la clé existe, on ajoute sinon.
avd_set() {
    k="\$1"; v="\$2"
    if grep -Eq "^[[:space:]]*\$(echo "\$k" | sed 's/\./\\\\./g')[[:space:]]*=" "\$CFG"; then
        sed -i -E "s|^[[:space:]]*\$(echo "\$k" | sed 's/\./\\\\./g')[[:space:]]*=.*|\$k = \$v|" "\$CFG"
    else
        echo "\$k = \$v" >> "\$CFG"
    fi
}

if avdmanager list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}\$"; then
    echo "  AVD « ${AVD_NAME} » existe déjà"
else
    echo no | avdmanager create avd --name "${AVD_NAME}" \\
        --package "$SYSTEM_IMAGE" --device "pixel_6" >/dev/null
    echo "  AVD « ${AVD_NAME} » créé (pixel_6)"
fi

# Appliqué dans les DEUX cas : rejouer le script avec d'autres options doit
# réaligner un AVD existant, sinon la modification serait silencieusement sans
# effet.
avd_set "hw.ramSize"    "$AVD_RAM"
avd_set "vm.heapSize"   "512"
avd_set "hw.gpu.enabled" "yes"
avd_set "hw.gpu.mode"   "$GPU_MODE"
avd_set "hw.keyboard"   "yes"
echo "  config.ini aligné (ram=$AVD_RAM, gpu=$GPU_MODE)"
STAGE
    run_as_target "$STAGE_DIR/sdk.sh"
fi

# ─── Dépôt et build de l'APK ─────────────────────────────────────────────────
#
# LE BUILD PASSE AVANT LE DÉMARRAGE DE L'ÉMULATEUR, et c'est délibéré.
#
# Dans l'ordre inverse — celui de la première version — l'émulateur et le démon
# Gradle vivent en même temps : sur une machine de 8 Go, l'OOM killer tranche.
# Constaté sur host-106-1 : `expo run:android` a échoué sur
# `CommandError: Failed to get properties for device (emulator-5554)`, l'AVD
# étant mort pendant le build. En séparant, les deux pics ne se superposent plus.
if [ "$SKIP_BUILD" = "1" ]; then
    step "Dépôt et build — ignorés (--skip-build)"
else
    [ -n "$WORKDIR" ] || WORKDIR="$TARGET_HOME/$(basename "$REPO_URL" .git)"
    step "Dépôt ${REPO_URL}${REPO_REF:+ (${REPO_REF})} et build de l'APK"
    cat > "$STAGE_DIR/build.sh" <<STAGE
set -eu
export ANDROID_SDK_ROOT="$SDK_ROOT" ANDROID_HOME="$SDK_ROOT" JAVA_HOME="${JAVA_HOME:-}"
export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:\$PATH"

if [ -d "$WORKDIR/.git" ]; then
    echo "  déjà cloné dans $WORKDIR"
elif [ -n "$REPO_REF" ]; then
    git clone --branch "$REPO_REF" "$REPO_URL" "$WORKDIR"
else
    git clone "$REPO_URL" "$WORKDIR"
fi
cd "$WORKDIR"

echo "  npm ci"
npm ci

if [ ! -d android ]; then
    echo "  expo prebuild"
    npx expo prebuild --platform android --no-install
fi
# Une seule ABI au lieu de quatre : le build et la sortie sont divisés par
# environ quatre, et l'émulateur x86_64 est la seule cible ici.
if [ -f android/gradle.properties ]; then
    sed -i 's/^reactNativeArchitectures=.*/reactNativeArchitectures=x86_64/' android/gradle.properties
fi

echo "  gradlew assembleDebug (10 à 20 min au premier passage)"
cd android && ./gradlew --no-daemon assembleDebug
STAGE
    run_as_target "$STAGE_DIR/build.sh"
    APK="$(find "$WORKDIR/android" -path '*/outputs/apk/debug/*.apk' -type f 2>/dev/null | head -1 || true)"
    [ -n "$APK" ] || fail "build terminé mais aucun APK trouvé sous ${WORKDIR}/android/**/outputs/apk/debug/"
    echo "  APK : $APK"
fi

# ─── Démarrage de l'émulateur ────────────────────────────────────────────────
#
# Mode headless : `-no-window`, rien d'autre à poser.
# Mode écran    : Xvfb fournit un affichage virtuel, l'émulateur tourne FENÊTRÉ
#                 dedans, x11vnc l'expose en VNC restreint à la loopback, et
#                 websockify sert noVNC sur le seul port ouvert. Le VNC brut
#                 reste injoignable depuis le réseau — c'est ce qui évite
#                 d'ouvrir un second protocole non chiffré.
#
# `-no-snapshot` a été retiré : il imposait un démarrage à froid à chaque
# lancement (75 s en headless, 130 s en fenêtré). Les instantanés ramènent les
# redémarrages suivants à quelques secondes.
if [ "$SKIP_EMULATOR" = "1" ]; then
    step "Émulateur — démarrage ignoré (--skip-emulator)"
else
    step "Démarrage de l'émulateur « ${AVD_NAME} »"
    cat > "$STAGE_DIR/run.sh" <<STAGE
set -eu
export ANDROID_SDK_ROOT="$SDK_ROOT" ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:\$PATH"
mkdir -p "\$HOME/.android"

adb start-server >/dev/null 2>&1 || true
if adb devices | grep -q "^emulator-.*device\$"; then
    echo "  un émulateur tourne déjà"
else
    EMU_ARGS="-no-audio -no-boot-anim -gpu $GPU_MODE"
    if [ "$DISPLAY_MODE" = "1" ]; then
        # Affichage virtuel : sans lui, le binaire fenêtré n'a rien où dessiner.
        if ! pgrep -f "Xvfb :1" >/dev/null 2>&1; then
            nohup Xvfb :1 -screen 0 ${SCREEN_SIZE}x24 -ac >"\$HOME/.android/xvfb.log" 2>&1 &
            sleep 2
        fi
        export DISPLAY=:1
        echo "  Xvfb :1 (${SCREEN_SIZE}x24)"
    else
        EMU_ARGS="\$EMU_ARGS -no-window"
    fi
    # shellcheck disable=SC2086
    nohup emulator -avd "${AVD_NAME}" \$EMU_ARGS >"$EMULATOR_LOG" 2>&1 &
    echo "  lancé en arrière-plan, journal : $EMULATOR_LOG"
fi

# Rendre la main quand l'appareil est PRÊT, pas quand il est lancé : c'est
# l'absence de cette attente qui avait produit
# « adb: device 'emulator-5554' not found » au build.
echo "  attente de sys.boot_completed (jusqu'à 10 min)..."
adb wait-for-device
i=0
BOOTED=""
while [ "\$i" -lt 300 ]; do
    BOOTED="\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [ "\$BOOTED" = "1" ] && break
    sleep 2
    i=\$((i + 1))
done
[ "\$BOOTED" = "1" ] || { echo "l'émulateur n'a pas fini de démarrer — voir $EMULATOR_LOG" >&2; exit 1; }
echo "  prêt : \$(adb devices | grep '^emulator-' | head -1)"

if [ "$DISPLAY_MODE" = "1" ]; then
    mkdir -p "\$HOME/.vnc"
    x11vnc -storepasswd "$VNC_PASSWORD" "\$HOME/.vnc/passwd" >/dev/null 2>&1
    chmod 0600 "\$HOME/.vnc/passwd"
    if ! pgrep -f "x11vnc -display :1" >/dev/null 2>&1; then
        nohup x11vnc -display :1 -rfbauth "\$HOME/.vnc/passwd" -forever -shared \\
              -rfbport 5901 -localhost -noxdamage >"\$HOME/.android/x11vnc.log" 2>&1 &
        sleep 1
    fi
    if ! pgrep -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1; then
        NOVNC_WEB=/usr/share/novnc
        [ -d "\$NOVNC_WEB" ] || NOVNC_WEB=/usr/share/webapps/novnc
        nohup websockify --web="\$NOVNC_WEB" 0.0.0.0:${NOVNC_PORT} localhost:5901 \\
              >"\$HOME/.android/websockify.log" 2>&1 &
        sleep 1
    fi
    echo "  écran publié : x11vnc en -localhost sur 5901, noVNC sur ${NOVNC_PORT}"
fi
STAGE
    run_as_target "$STAGE_DIR/run.sh"
fi

# ─── Installation de l'APK sur l'émulateur ───────────────────────────────────
if [ -n "${APK:-}" ] && [ "$SKIP_EMULATOR" != "1" ]; then
    step "Installation sur l'émulateur"
    cat > "$STAGE_DIR/install-apk.sh" <<STAGE
set -eu
export ANDROID_SDK_ROOT="$SDK_ROOT" ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/platform-tools:$SDK_ROOT/build-tools/$BUILD_TOOLS:\$PATH"

# Contrôle explicite AVANT d'installer : si l'émulateur a disparu entre-temps,
# on veut le dire clairement plutôt que de laisser adb rendre une erreur obscure
# sur un device fantôme.
ALIVE="\$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
if [ "\$ALIVE" != "1" ]; then
    echo "l'émulateur ne répond plus au moment d'installer. Cause la plus fréquente :" >&2
    echo "mémoire insuffisante — l'AVD est à $AVD_RAM Mo. Baisser 'avd_ram' et rejouer." >&2
    echo "Journal : $EMULATOR_LOG" >&2
    exit 1
fi

adb install -r "$APK"
echo "  installé : \$(basename "$APK")"

# Lancement de l'app si le nom de paquet est lisible. Étape de confort : son
# échec ne remet pas en cause l'installation.
if command -v aapt2 >/dev/null 2>&1; then
    PKG_NAME="\$(aapt2 dump packagename "$APK" 2>/dev/null | tr -d '\r' || true)"
    if [ -n "\$PKG_NAME" ]; then
        adb shell monkey -p "\$PKG_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \\
            && echo "  lancée : \$PKG_NAME" \\
            || echo "  AVERTISSEMENT : \$PKG_NAME installée mais non lancée." >&2
    fi
fi
STAGE
    run_as_target "$STAGE_DIR/install-apk.sh"
elif [ -n "${APK:-}" ]; then
    step "Installation — ignorée (aucun émulateur démarré)"
    echo "  APK disponible : $APK"
fi

# ─── ws-scrcpy — écran de l'émulateur dans un navigateur ─────────────────────
#
# AVERTISSEMENT, repris du README du projet : « There is no authorization on any
# level » et « There is no encryption between browser and node.js server ». Le
# serveur écoute sur TOUTES les interfaces et son schéma de configuration
# (Configuration.d.ts) n'expose aucune adresse d'écoute — impossible de le
# restreindre à la loopback par configuration. Contenir l'exposition demande une
# règle de pare-feu, hors périmètre de cette recette.
#
# Le mode --display offre l'alternative : noVNC, lui, a un mot de passe et
# n'expose qu'un seul port, le VNC brut restant sur la loopback.
if [ "$ENABLE_SCRCPY" = "1" ]; then
    step "ws-scrcpy (interface web, port ${SCRCPY_PORT})"
    if [ "$PKG" = apt ]; then
        run_root apt-get install -y -qq build-essential python3
    else
        run_root dnf install -y gcc-c++ make python3
    fi
    cat > "$STAGE_DIR/scrcpy.sh" <<STAGE
set -eu
if [ -d "$SCRCPY_DIR/.git" ]; then
    echo "  déjà cloné dans $SCRCPY_DIR"
else
    git clone https://github.com/NetrisTV/ws-scrcpy.git "$SCRCPY_DIR"
fi
cd "$SCRCPY_DIR"
[ -d node_modules ] || npm install
# Format vérifié sur config.example.yaml : une liste \`server\` avec \`secure\` et
# \`port\`. runApplTracker coupe la découverte iOS, sans objet ici.
{
    echo "runGoogTracker: true"
    echo "runApplTracker: false"
    echo "server:"
    echo "  - secure: false"
    echo "    port: ${SCRCPY_PORT}"
} > "$SCRCPY_DIR/config.yaml"
STAGE
    run_as_target "$STAGE_DIR/scrcpy.sh"

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        # Un service : sans lui, ws-scrcpy meurt avec le shell qui a lancé la
        # recette — le portail ferme sa session SSH dès la fin du script.
        UNIT_TMP="$(mktemp)"
        {
            echo "[Unit]"
            echo "Description=ws-scrcpy — ecran de l'emulateur Android dans un navigateur"
            echo "After=network.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            echo "User=${TARGET_USER}"
            echo "WorkingDirectory=${SCRCPY_DIR}"
            echo "Environment=WS_SCRCPY_CONFIG=${SCRCPY_DIR}/config.yaml"
            echo "Environment=ANDROID_SDK_ROOT=${SDK_ROOT}"
            echo "Environment=ANDROID_HOME=${SDK_ROOT}"
            echo "Environment=PATH=${SDK_ROOT}/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "ExecStart=$(command -v npm) start"
            echo "Restart=on-failure"
            echo "RestartSec=5"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } > "$UNIT_TMP"
        run_root cp "$UNIT_TMP" /etc/systemd/system/ws-scrcpy.service
        rm -f "$UNIT_TMP"
        run_root systemctl daemon-reload
        run_root systemctl enable ws-scrcpy.service >/dev/null 2>&1 || true
        run_root systemctl restart ws-scrcpy.service
        echo "  service ws-scrcpy actif"
    else
        echo "  AVERTISSEMENT : systemd absent — ws-scrcpy non persistant." >&2
    fi
    echo "  côté émulateur, choisir « proxy over adb » dans la liste des interfaces"
fi

# ─── Script de vérification des gestes ───────────────────────────────────────
# Le portail ne transfère QUE install.sh (host_apply.py encode un seul fichier)
# : on récupère le script de test depuis la galerie plutôt que de l'embarquer,
# pour éviter deux copies qui divergent.
step "Script de vérification des gestes"
VERIFY_DEST="$TARGET_HOME/verify-scroll-gestures.sh"
if curl -fsSL "$VERIFY_URL" -o "$VERIFY_DEST" 2>/dev/null; then
    chmod +x "$VERIFY_DEST"
    run_root chown "$TARGET_USER" "$VERIFY_DEST" 2>/dev/null || true
    echo "  déposé dans $VERIFY_DEST"
else
    echo "  AVERTISSEMENT : $VERIFY_URL introuvable — étape ignorée." >&2
fi

cat <<DONE

Machine de développement Android prête.

  Utilisateur    : ${TARGET_USER}
  SDK            : ${SDK_ROOT}
  Rendu          : ${GPU_MODE}
  Journal        : ${EMULATOR_LOG}
DONE

if [ "$DISPLAY_MODE" = "1" ]; then
    cat <<DONE
  Écran          : http://<cette-machine>:${NOVNC_PORT}/vnc.html
                   (mot de passe VNC ; seul ce port est exposé, le VNC brut
                   reste sur la loopback — trafic NON chiffré, réseau local)
DONE
else
    echo "  Écran          : aucun (mode headless — --display pour noVNC)"
fi

if [ "$ENABLE_SCRCPY" = "1" ]; then
    echo "  ws-scrcpy      : http://<cette-machine>:${SCRCPY_PORT} (SANS authentification)"
fi

cat <<DONE

  Vérifier les gestes de défilement :
      ${VERIFY_DEST}

  Depuis l'émulateur, la machine hôte est joignable en 10.0.2.2 — un serveur
  sur localhost:8080 de cette machine devient http://10.0.2.2:8080 pour l'app.

DONE
