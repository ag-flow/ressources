#!/usr/bin/env bash
#
# android-emulator — machine de développement Android complète, en un seul script.
#
# RECETTE DE HOST : à poser sur une machine, pas dans un conteneur. L'émulateur
# exige /dev/kvm (hors de portée d'un conteneur) et l'empreinte disque est de
# 18 à 22 Go — on ne la refait pas à chaque provisionnement de workspace.
#
# Couvre de bout en bout : dépendances système, JDK 17, Node >= 20, chaîne
# Android (SDK, NDK, CMake, émulateur, image système), AVD, démarrage de
# l'émulateur en headless, puis dépôt + premier build. À la fin, `adb devices`
# voit un appareil prêt et l'app est installée dessus.
#
# HEADLESS PAR DÉFAUT. Les VM de test n'ont ni écran ni GPU (`DISPLAY` vide,
# pas de /dev/dri, zéro entrée libGL) : `-gpu host` n'y démarre pas. On rend
# donc en logiciel via swiftshader_indirect, fourni avec le paquet `emulator`.
# --gpu host reste possible sur une machine dotée d'un affichage.
#
# Versions relevées dans le projet Gradle généré par `expo prebuild`, pas
# supposées : JDK 17 · Gradle 8.14.3 · compileSdk/targetSdk 35 · minSdk 24 ·
# build-tools 35.0.0 · NDK 27.1.12297006 · CMake 3.22.1 · Kotlin 2.0.21.
#
# Ré-exécutable sans effet : chaque étape détecte l'existant et sort en succès.
#
# Exécuté par le portail avec `sh`, pas `bash` : rester en syntaxe POSIX.

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
AVD_RAM="${RECIPE_OPT_AVD_RAM:-${AVD_RAM:-4096}}"
GPU_MODE="${RECIPE_OPT_GPU_MODE:-${GPU_MODE:-swiftshader_indirect}}"
HEADLESS="${RECIPE_OPT_HEADLESS:-${HEADLESS:-1}}"
NODE_MAJOR="${RECIPE_OPT_NODE_MAJOR:-${NODE_MAJOR:-20}}"
REPO_URL="${RECIPE_OPT_REPO_URL:-${REPO_URL:-https://github.com/gaelgael5/Termix-mobile.git}}"
REPO_REF="${RECIPE_OPT_REPO_REF:-${REPO_REF:-test/unit-test-foundation}}"
WORKDIR="${RECIPE_OPT_WORKDIR:-${WORKDIR:-$HOME/termix-mobile}}"
SKIP_ANDROID="${RECIPE_OPT_SKIP_ANDROID:-${SKIP_ANDROID:-0}}"
SKIP_NODE="${RECIPE_OPT_SKIP_NODE:-${SKIP_NODE:-0}}"
SKIP_EMULATOR="${RECIPE_OPT_SKIP_EMULATOR:-${SKIP_EMULATOR:-0}}"
SKIP_BUILD="${RECIPE_OPT_SKIP_BUILD:-${SKIP_BUILD:-0}}"
# Drapeau POSITIF, contrairement aux skip_* : ws-scrcpy ouvre un service de
# contrôle à distance SANS authentification (cf. étape dédiée plus bas). On ne
# le pose que si la machine le demande explicitement.
ENABLE_SCRCPY="${RECIPE_OPT_ENABLE_SCRCPY:-${ENABLE_SCRCPY:-0}}"
SCRCPY_PORT="${RECIPE_OPT_SCRCPY_PORT:-${SCRCPY_PORT:-8000}}"
SCRCPY_DIR="${RECIPE_OPT_SCRCPY_DIR:-${SCRCPY_DIR:-$HOME/ws-scrcpy}}"

usage() {
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

  --skip-android      ne pas installer JDK/SDK/NDK/AVD
  --skip-node         ne pas installer Node
  --skip-emulator     ne pas démarrer l'émulateur
  --skip-build        ne pas cloner le dépôt ni builder l'app
  --scrcpy            installer ws-scrcpy : écran de l'émulateur dans un
                      navigateur (désactivé par défaut — AUCUNE authentification,
                      le service écoute sur toutes les interfaces)
  --scrcpy-port PORT  port d'écoute de ws-scrcpy (défaut 8000)
  --scrcpy-dir CHEMIN où installer ws-scrcpy (défaut ~/ws-scrcpy)
  --gpu MODE          rendu : swiftshader_indirect (défaut, logiciel) | host
                      (passthrough GPU — exige /dev/dri sur la machine)
  --window            afficher une fenêtre (exige un serveur X ; défaut : sans)
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
        --skip-android)  SKIP_ANDROID=1; shift ;;
        --skip-node)     SKIP_NODE=1; shift ;;
        --skip-emulator) SKIP_EMULATOR=1; shift ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        --scrcpy)        ENABLE_SCRCPY=1; shift ;;
        --scrcpy-port)   SCRCPY_PORT="$2"; shift 2 ;;
        --scrcpy-dir)    SCRCPY_DIR="$2"; shift 2 ;;
        --gpu)           GPU_MODE="$2"; shift 2 ;;
        --window)        HEADLESS=0; shift ;;
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
SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
VERIFY_URL="https://raw.githubusercontent.com/ag-flow/ressources/refs/heads/main/recipes/android-emulator/verify-scroll-gestures.sh"
EMULATOR_LOG="$HOME/.android/emulator-${AVD_NAME}.log"

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

# ─── Préconditions — AVANT tout téléchargement ───────────────────────────────
# Échouer après avoir tiré 2 Go parce que le disque est trop petit est le
# comportement à éviter : le contrôle passe en premier, et dit laquelle des
# préconditions manque.
step "Préconditions"

[ "$(uname -m)" = "x86_64" ] || fail "architecture $(uname -m) : l'image système x86_64 exige un hôte x86_64"

if [ ! -e /dev/kvm ]; then
    fail "/dev/kvm absent. L'émulateur exige la virtualisation matérielle ; sur une
  VM cela suppose un passthrough CPU 'host' et le nesting actif sur l'hôte."
fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "  /dev/kvm existe mais n'est pas accessible à $(id -un)." >&2
    echo "  Corriger avec :  sudo usermod -aG kvm \"\$(id -un)\"  puis REDÉMARRER la machine" >&2
    echo "  (un changement de groupe ne prend pas sur une session déjà ouverte)." >&2
    fail "pas d'accès en lecture/écriture à /dev/kvm"
fi
echo "  /dev/kvm : accessible en lecture/écriture"

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

# Rendu et affichage sont deux choses distinctes : une VM peut très bien avoir un
# GPU en passthrough SANS écran. Coupler les deux obligerait une telle machine à
# ouvrir une fenêtre qu'elle ne peut pas afficher.
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
        if [ ! -r /dev/dri ]; then
            echo "  AVERTISSEMENT : /dev/dri existe mais n'est pas lisible par $(id -un)" >&2
            echo "  — probable appartenance au groupe 'render' ou 'video'." >&2
        fi
        echo "  rendu : host (passthrough GPU) — $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
        ;;
    *)
        fail "mode GPU inconnu : ${GPU_MODE} (attendu swiftshader_indirect ou host)"
        ;;
esac

if [ "$HEADLESS" = "1" ]; then
    echo "  affichage : aucun (-no-window)"
elif [ -z "${DISPLAY:-}" ]; then
    fail "--window demandé mais DISPLAY est vide : aucun serveur d'affichage sur cette machine"
else
    echo "  affichage : DISPLAY=${DISPLAY}"
fi

# ─── Dépendances système ─────────────────────────────────────────────────────
# INCONDITIONNEL. Les poser dans la branche `else` du test JDK — comme le
# faisait le script d'origine — laisse une machine avec JDK 17 déjà installé
# sans `unzip`, et l'étape des command-line tools casse bien plus loin.
step "Dépendances système"
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    run_root apt-get update -qq
    run_root apt-get install -y -qq unzip curl ca-certificates git
    PKG=apt
elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y unzip curl ca-certificates git
    PKG=dnf
else
    fail "ni apt-get ni dnf : distribution non prise en charge (Debian et Ubuntu visées)"
fi
echo "  unzip, curl, ca-certificates, git en place"

# ─── JDK 17 ──────────────────────────────────────────────────────────────────
if [ "$SKIP_ANDROID" = "1" ]; then
    step "Chaîne Android — ignorée (--skip-android)"
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
    export JAVA_HOME
    echo "  JAVA_HOME=$JAVA_HOME"
fi

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

if [ "$SKIP_ANDROID" != "1" ]; then
    # ─── Outils en ligne de commande du SDK ──────────────────────────────────
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
fi

export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:$PATH"

if [ "$SKIP_ANDROID" != "1" ]; then
    # ─── Paquets du SDK ──────────────────────────────────────────────────────
    step "Paquets du SDK (quelques Go au premier passage)"
    # Le SDK se télécharge sans compte : les licences s'acceptent via
    # sdkmanager, aucun secret n'est requis par cette recette.
    yes | sdkmanager --licenses >/dev/null 2>&1 || true
    # Le NDK et CMake ne sont PAS optionnels : newArchEnabled=true, et six
    # dépendances embarquent du C++ (reanimated, worklets, gesture-handler,
    # screens, svg, expo-modules-core). Sans eux le build Gradle échoue à la
    # configuration — le piège dans lequel la première version est tombée.
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

    # ─── AVD ─────────────────────────────────────────────────────────────────
    step "Image d'émulateur « ${AVD_NAME} »"
    if avdmanager list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}$"; then
        echo "  existe déjà"
        # La config n'est écrite qu'à la création : sans cette reprise, rejouer
        # le script avec --gpu host sur une machine qui a gagné un GPU ne
        # changerait rien, et l'AVD resterait en rendu logiciel sans le dire.
        cfg="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
        if [ -f "$cfg" ] && ! grep -q "^hw.gpu.mode=${GPU_MODE}$" "$cfg"; then
            sed -i "s/^hw\.gpu\.mode=.*/hw.gpu.mode=${GPU_MODE}/" "$cfg"
            grep -q '^hw.gpu.mode=' "$cfg" || echo "hw.gpu.mode=${GPU_MODE}" >> "$cfg"
            echo "  rendu de l'AVD aligné sur ${GPU_MODE}"
        fi
    else
        echo no | avdmanager create avd \
            --name "$AVD_NAME" \
            --package "$SYSTEM_IMAGE" \
            --device "pixel_6" >/dev/null
        cfg="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
        {
            echo "hw.ramSize=${AVD_RAM}"
            echo "vm.heapSize=512"
            echo "hw.gpu.enabled=yes"
            echo "hw.gpu.mode=${GPU_MODE}"
            echo "hw.keyboard=yes"
        } >> "$cfg"
        echo "  créé (pixel_6, ${AVD_RAM} Mo de RAM, gpu ${GPU_MODE})"
    fi
fi

# ─── Environnement de shell ──────────────────────────────────────────────────
step "Environnement de shell"
PROFILE="$HOME/.bashrc"
if ! grep -q "ANDROID_SDK_ROOT=$SDK_ROOT" "$PROFILE" 2>/dev/null; then
    {
        echo ""
        echo "# Android SDK (ajouté par la recette android-emulator)"
        [ -n "${JAVA_HOME:-}" ] && echo "export JAVA_HOME=\"$JAVA_HOME\""
        echo "export ANDROID_SDK_ROOT=\"$SDK_ROOT\""
        echo "export ANDROID_HOME=\"$SDK_ROOT\""
        echo "export PATH=\"\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/emulator:\$PATH\""
    } >> "$PROFILE"
    echo "  ajouté à $PROFILE"
else
    echo "  déjà configuré"
fi

# ─── Démarrage de l'émulateur ────────────────────────────────────────────────
# `-no-window` : aucune fenêtre à afficher — indépendant du mode de rendu, une
#                machine avec GPU en passthrough n'a pas forcément d'écran.
# `-gpu MODE`   : swiftshader_indirect (logiciel) ou host (GPU de la machine).
# `-no-snapshot`: démarrage déterministe, pas de reprise d'un état précédent.
if [ "$SKIP_EMULATOR" = "1" ]; then
    step "Émulateur — démarrage ignoré (--skip-emulator)"
else
    step "Démarrage de l'émulateur « ${AVD_NAME} »"
    adb start-server >/dev/null 2>&1 || true
    if adb devices | grep -q "^emulator-.*device$"; then
        echo "  un émulateur tourne déjà"
    else
        mkdir -p "$(dirname "$EMULATOR_LOG")"
        EMU_ARGS="-no-audio -no-boot-anim -no-snapshot -gpu $GPU_MODE"
        if [ "$HEADLESS" = "1" ]; then
            EMU_ARGS="$EMU_ARGS -no-window"
        fi
        # shellcheck disable=SC2086
        nohup emulator -avd "$AVD_NAME" $EMU_ARGS >"$EMULATOR_LOG" 2>&1 &
        echo "  lancé en arrière-plan, journal : $EMULATOR_LOG"

        echo "  attente de sys.boot_completed (jusqu'à 10 min)..."
        adb wait-for-device
        i=0
        while [ "$i" -lt 300 ]; do
            BOOTED="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
            [ "$BOOTED" = "1" ] && break
            sleep 2
            i=$((i + 1))
        done
        [ "${BOOTED:-}" = "1" ] || fail "l'émulateur n'a pas fini de démarrer — voir $EMULATOR_LOG"
        echo "  démarré : $(adb devices | grep '^emulator-' | head -1)"
    fi
fi

# ─── Dépôt et premier build ──────────────────────────────────────────────────
if [ "$SKIP_BUILD" = "1" ]; then
    step "Dépôt et build — ignorés (--skip-build)"
else
    step "Dépôt ${REPO_URL} (${REPO_REF})"
    if [ -d "$WORKDIR/.git" ]; then
        echo "  déjà cloné dans $WORKDIR"
    else
        git clone --branch "$REPO_REF" "$REPO_URL" "$WORKDIR"
        echo "  cloné dans $WORKDIR"
    fi
    cd "$WORKDIR"

    step "Dépendances npm"
    npm ci

    step "Build Android et installation sur l'émulateur"
    # `prebuild` génère le projet Gradle ; il faut qu'il existe pour pouvoir
    # restreindre les ABI juste après.
    if [ ! -d android ]; then
        npx expo prebuild --platform android --no-install
    fi
    # Une seule ABI au lieu de quatre : le build et la sortie sont divisés par
    # environ quatre, et l'émulateur x86_64 est la seule cible ici.
    if [ -f android/gradle.properties ]; then
        sed -i 's/^reactNativeArchitectures=.*/reactNativeArchitectures=x86_64/' android/gradle.properties
        echo "  ABI restreinte à x86_64"
    fi
    npx expo run:android
fi

# ─── ws-scrcpy — écran de l'émulateur dans un navigateur ─────────────────────
#
# Utile sur une machine sans écran : l'émulateur tourne en -no-window, ws-scrcpy
# diffuse son écran en H.264 sur WebSocket et renvoie les clics et glissements
# comme des événements tactiles réels.
#
# AVERTISSEMENT, repris du README du projet : « There is no authorization on any
# level » et « There is no encryption between browser and node.js server ». Le
# serveur écoute sur TOUTES les interfaces et son schéma de configuration
# (Configuration.d.ts) n'expose aucune adresse d'écoute — impossible de le
# restreindre à la loopback par configuration. Qui atteint ce port pilote
# l'émulateur, transfère des fichiers et ouvre un shell, sans mot de passe.
# Contenir l'exposition demande une règle de pare-feu, hors périmètre de cette
# recette. D'où un drapeau POSITIF, désactivé par défaut.
if [ "$ENABLE_SCRCPY" = "1" ]; then
    step "ws-scrcpy (interface web, port ${SCRCPY_PORT})"

    # node-gyp compile des modules natifs : outils de build indispensables.
    if [ "$PKG" = apt ]; then
        run_root apt-get install -y -qq build-essential python3
    else
        run_root dnf install -y gcc-c++ make python3
    fi

    if [ -d "$SCRCPY_DIR/.git" ]; then
        echo "  déjà cloné dans $SCRCPY_DIR"
    else
        git clone https://github.com/NetrisTV/ws-scrcpy.git "$SCRCPY_DIR"
        echo "  cloné dans $SCRCPY_DIR"
    fi

    cd "$SCRCPY_DIR"
    if [ -d node_modules ]; then
        echo "  dépendances déjà installées"
    else
        npm install
    fi

    # Format vérifié sur config.example.yaml : une liste `server`, chaque entrée
    # portant `secure` et `port`. `runApplTracker` coupe la découverte iOS, sans
    # objet ici et source d'erreurs au démarrage.
    {
        echo "runGoogTracker: true"
        echo "runApplTracker: false"
        echo "server:"
        echo "  - secure: false"
        echo "    port: ${SCRCPY_PORT}"
    } > "$SCRCPY_DIR/config.yaml"

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        # Un service : sans lui, ws-scrcpy meurt avec le shell qui a lancé la
        # recette — le portail ferme sa session SSH dès la fin du script.
        {
            echo "[Unit]"
            echo "Description=ws-scrcpy — ecran de l'emulateur Android dans un navigateur"
            echo "After=network.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            echo "User=$(id -un)"
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
        } | run_root tee /etc/systemd/system/ws-scrcpy.service >/dev/null
        run_root systemctl daemon-reload
        run_root systemctl enable ws-scrcpy.service >/dev/null 2>&1 || true
        run_root systemctl restart ws-scrcpy.service
        echo "  service ws-scrcpy actif"
    else
        echo "  AVERTISSEMENT : systemd absent — lancement en arrière-plan, non persistant." >&2
        WS_SCRCPY_CONFIG="$SCRCPY_DIR/config.yaml" nohup npm start \
            > "$HOME/.ws-scrcpy.log" 2>&1 &
    fi

    echo "  interface : http://<adresse-de-cette-machine>:${SCRCPY_PORT}"
    echo "  côté émulateur, choisir « proxy over adb » dans la liste des interfaces"
    echo "  — le serveur embarqué n'écoute que sur l'interface interne de l'émulateur."
fi

# ─── Script de vérification des gestes ───────────────────────────────────────
# Le portail ne transfère QUE install.sh (host_apply.py encode un seul fichier)
# : on récupère le script de test depuis la galerie plutôt que de l'embarquer,
# pour éviter deux copies qui divergent. Étape optionnelle, sans conséquence si
# le réseau la refuse.
step "Script de vérification des gestes"
VERIFY_DEST="$HOME/verify-scroll-gestures.sh"
if curl -fsSL "$VERIFY_URL" -o "$VERIFY_DEST" 2>/dev/null; then
    chmod +x "$VERIFY_DEST"
    echo "  déposé dans $VERIFY_DEST"
else
    echo "  AVERTISSEMENT : $VERIFY_URL introuvable — étape ignorée." >&2
fi

cat <<DONE

Machine de développement Android prête.

  Émulateur      : $(adb devices 2>/dev/null | grep '^emulator-' | head -1 || echo 'non démarré')
  SDK            : ${SDK_ROOT}
  Rendu          : ${GPU_MODE}$([ "$HEADLESS" = "1" ] && echo " (sans fenêtre)" || echo " (avec fenêtre)")
  Journal        : ${EMULATOR_LOG}
  Interface web  : $([ "$ENABLE_SCRCPY" = "1" ] && echo "http://<cette-machine>:${SCRCPY_PORT} (ws-scrcpy, SANS authentification)" || echo "non installée (--scrcpy pour l'ajouter)")

  Vérifier les gestes de défilement :
      ${VERIFY_DEST}

  Depuis l'émulateur, la machine hôte est joignable en 10.0.2.2 — un serveur
  sur localhost:8080 de cette machine devient http://10.0.2.2:8080 pour l'app.

DONE
