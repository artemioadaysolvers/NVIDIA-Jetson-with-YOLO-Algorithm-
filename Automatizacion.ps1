$ErrorActionPreference = "Stop"

$Jetson = "artemio@192.168.55.1"
$Port = 22

$RemoteScript = @'
#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_HOME="/home/artemio"
REMOTE_ZIP="$REMOTE_HOME/jetson_app_yolo26_3.zip"
STAGE_DIR="$REMOTE_HOME/jetson_app_yolo26_3.new"
APP_DIR="$REMOTE_HOME/jetson_app_yolo26_3"
BACKUP_DIR="$REMOTE_HOME/jetson_app_yolo26_3.previous"

IMAGE="jetson-yolo26:3.0"
CONTAINER="jetson-yolo26"

echo "Extrayendo nuevamente el paquete..."

rm -rf -- "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

python3 -m zipfile -t "$REMOTE_ZIP" >/dev/null
python3 -m zipfile -e "$REMOTE_ZIP" "$STAGE_DIR"

BUILD_DIR="$STAGE_DIR"

if [ ! -f "$BUILD_DIR/Dockerfile" ]; then
    DOCKERFILE="$(
        find "$STAGE_DIR" \
            -mindepth 2 \
            -maxdepth 3 \
            -type f \
            -name Dockerfile \
            -print \
            -quit
    )"

    if [ -z "$DOCKERFILE" ]; then
        echo "ERROR: Dockerfile no encontrado."
        exit 1
    fi

    BUILD_DIR="$(dirname "$DOCKERFILE")"
fi

SOURCE_WHEEL="$BUILD_DIR/wheelhouse/websockets-9.1-cp36-cp36m-manylinux2014_aarch64.whl"
FIXED_WHEEL="$BUILD_DIR/wheelhouse/websockets-9.1-cp36-cp36m-linux_aarch64.whl"

if [ ! -f "$SOURCE_WHEEL" ]; then
    echo "ERROR: no existe el wheel de websockets:"
    echo "$SOURCE_WHEEL"
    ls -la "$BUILD_DIR/wheelhouse"
    exit 1
fi

echo "Corrigiendo la etiqueta del wheel para el pip antiguo de Jetson..."

cp -f "$SOURCE_WHEEL" "$FIXED_WHEEL"

ls -lh \
    "$SOURCE_WHEEL" \
    "$FIXED_WHEEL"

chmod +x \
    "$BUILD_DIR/start_on_jetson.sh" \
    "$BUILD_DIR/scripts/entrypoint.sh"

echo "Construyendo la imagen Docker corregida..."

sudo docker build \
    --build-arg L4T_TAG=r32.7.1 \
    -t "$IMAGE" \
    "$BUILD_DIR"

echo "Comprobando dependencias dentro de Docker..."

sudo docker run \
    --rm \
    --runtime nvidia \
    "$IMAGE" \
    python3 -c \
    'import cv2, cupy, tensorrt, fastapi, uvicorn, websockets; n=cupy.cuda.runtime.getDeviceCount(); assert n > 0; print("OpenCV:", cv2.__version__); print("TensorRT:", tensorrt.__version__); print("WebSockets:", websockets.__version__); print("GPU:", n)'

mkdir -p "$BUILD_DIR/models"

if [ -d "$APP_DIR/models" ]; then
    for CACHE_FILE in \
        "$APP_DIR/models/yolo26n_jetson.engine" \
        "$APP_DIR/models/engine_info.json"
    do
        if [ -f "$CACHE_FILE" ]; then
            sudo cp -p "$CACHE_FILE" "$BUILD_DIR/models/"
        fi
    done
fi

sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

rm -rf -- "$BACKUP_DIR"

if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$BACKUP_DIR"
fi

if [ "$BUILD_DIR" = "$STAGE_DIR" ]; then
    mv "$STAGE_DIR" "$APP_DIR"
else
    mv "$BUILD_DIR" "$APP_DIR"
    rm -rf -- "$STAGE_DIR"
fi

cd "$APP_DIR"

echo "Iniciando la aplicación..."

JETSON_IMAGE="$IMAGE" \
JETSON_BUILD_IMAGE="$IMAGE" \
JETSON_CONTAINER="$CONTAINER" \
CAMERA_SOURCE=auto \
CAMERA_WIDTH=640 \
CAMERA_HEIGHT=480 \
CAMERA_FPS=15 \
YOLO_CONF=0.25 \
YOLO_NMS=0.45 \
TRT_FP16=1 \
TRT_WORKSPACE_MB=512 \
JPEG_QUALITY=75 \
bash ./start_on_jetson.sh

echo "Esperando la compilación del motor TensorRT..."

READY=0

for ATTEMPT in $(seq 1 450); do
    HEALTH="$(
        python3 -c \
        'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/api/health", timeout=2).read().decode("utf-8"))' \
        2>/dev/null || true
    )"

    if [ -n "$HEALTH" ]; then
        READY=1
        break
    fi

    STATE="$(
        sudo docker inspect \
            -f '{{.State.Status}}' \
            "$CONTAINER" \
            2>/dev/null || true
    )"

    case "$STATE" in
        exited|dead)
            echo "ERROR: el contenedor se detuvo."
            sudo docker logs --tail 200 "$CONTAINER" 2>&1 || true
            exit 1
            ;;
    esac

    if [ $((ATTEMPT % 15)) -eq 0 ]; then
        echo "Esperando TensorRT: $((ATTEMPT * 2)) segundos..."
        sudo docker logs --tail 10 "$CONTAINER" 2>&1 || true
    fi

    sleep 2
done

if [ "$READY" != "1" ]; then
    echo "ERROR: el servidor no respondió."
    sudo docker logs --tail 200 "$CONTAINER" 2>&1 || true
    exit 1
fi

echo "Servidor funcionando:"
echo "$HEALTH"

BROWSER="$(
    command -v chromium-browser ||
    command -v chromium ||
    true
)"

USER_ID="$(id -u)"
DISPLAY_VALUE=""

for X_SOCKET in /tmp/.X11-unix/X*; do
    if [ -S "$X_SOCKET" ]; then
        DISPLAY_VALUE=":${X_SOCKET##*/X}"
        break
    fi
done

XAUTH_FILE=""

for CANDIDATE in \
    "$REMOTE_HOME/.Xauthority" \
    "/run/user/$USER_ID/gdm/Xauthority"
do
    if [ -f "$CANDIDATE" ]; then
        XAUTH_FILE="$CANDIDATE"
        break
    fi
done

if [
    -n "$BROWSER" ] &&
    [ -n "$DISPLAY_VALUE" ] &&
    [ -n "$XAUTH_FILE"
]; then
    nohup env \
        DISPLAY="$DISPLAY_VALUE" \
        XAUTHORITY="$XAUTH_FILE" \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        "$BROWSER" \
        --new-window \
        --start-fullscreen \
        --no-first-run \
        --disable-session-crashed-bubble \
        "http://127.0.0.1:8000" \
        >"$REMOTE_HOME/yolo26_chromium.log" \
        2>&1 </dev/null &
fi

echo
echo "Aplicación: http://192.168.55.1:8000"
echo "Estado:     http://192.168.55.1:8000/api/health"
echo "Logs:       sudo docker logs -f $CONTAINER"
'@

$RemoteScript = $RemoteScript -replace "`r`n", "`n"
$Bytes = [Text.Encoding]::UTF8.GetBytes($RemoteScript)
$Encoded = [Convert]::ToBase64String($Bytes)
$Command = "printf '%s' '$Encoded' | base64 -d | bash"

& ssh.exe `
    -tt `
    -4 `
    -o ConnectTimeout=30 `
    -o ServerAliveInterval=15 `
    -o ServerAliveCountMax=8 `
    -p $Port `
    $Jetson `
    $Command

if ($LASTEXITCODE -ne 0) {
    throw "Falló la instalación corregida."
}

Start-Process "http://192.168.55.1:8000"

