#!/usr/bin/env bash

set -euo pipefail


ACTION="${1:-}"

BACKEND_DIR="${BACKEND_DIR:?BACKEND_DIR no definido}"

RUNTIME_DIR="${RUNTIME_DIR:-${GITHUB_WORKSPACE}/runtime}"

APP_PORT="${APP_PORT:-8080}"

PID_FILE="${RUNTIME_DIR}/app.pid"

JAR_PATH_FILE="${RUNTIME_DIR}/jar-path"

LOG_FILE="${RUNTIME_DIR}/application.log"


mkdir -p "${RUNTIME_DIR}"


# ==========================================================
# BUILD
# ==========================================================

build_backend() {

    echo "=========================================="
    echo "          COMPILANDO BACKEND"
    echo "=========================================="

    echo ""
    echo "Repositorio:"
    echo "${BACKEND_REPOSITORY:-unknown}"

    echo ""
    echo "Directorio:"
    echo "${BACKEND_DIR}"

    echo ""


    if [ ! -d "${BACKEND_DIR}" ]; then

        echo "ERROR: No existe el directorio del backend."

        exit 1

    fi


    cd "${BACKEND_DIR}"


    if [ ! -f "pom.xml" ]; then

        echo "ERROR: El repositorio no contiene pom.xml en la raiz."

        exit 1

    fi


    # ------------------------------------------------------
    # Maven Wrapper o Maven del runner
    # ------------------------------------------------------

    if [ -f "./mvnw" ]; then

        echo "Usando Maven Wrapper"

        chmod +x ./mvnw

        ./mvnw \
            --batch-mode \
            clean package \
            -DskipTests

    else

        echo "Usando Maven instalado en el runner"

        mvn \
            --batch-mode \
            clean package \
            -DskipTests

    fi


    echo ""
    echo "Build completado."

}


# ==========================================================
# DETECTAR JAR EJECUTABLE
# ==========================================================

find_executable_jar() {

    echo ""
    echo "=========================================="
    echo "       BUSCANDO JAR EJECUTABLE"
    echo "=========================================="

    cd "${BACKEND_DIR}"


    EXECUTABLE_JARS=()


    while IFS= read -r JAR_FILE; do

        # Ignorar JARs auxiliares

        case "${JAR_FILE}" in

            *-sources.jar|*-javadoc.jar|*.original)
                continue
                ;;

        esac


        MANIFEST=$(
            unzip -p \
                "${JAR_FILE}" \
                META-INF/MANIFEST.MF \
                2>/dev/null \
                || true
        )


        # Spring Boot normalmente contiene Start-Class
        # o un Main-Class ejecutable.

        if echo "${MANIFEST}" \
            | grep -Eq '^(Start-Class|Main-Class):'; then

            EXECUTABLE_JARS+=("${JAR_FILE}")

        fi

    done < <(
        find "${BACKEND_DIR}" \
            -type f \
            -name "*.jar" \
            -path "*/target/*" \
            | sort
    )


    if [ "${#EXECUTABLE_JARS[@]}" -eq 0 ]; then

        echo "ERROR: No se encontro un JAR ejecutable."

        echo ""
        echo "JARs encontrados:"

        find "${BACKEND_DIR}" \
            -type f \
            -name "*.jar" \
            -path "*/target/*" \
            || true

        exit 1

    fi


    if [ "${#EXECUTABLE_JARS[@]}" -gt 1 ]; then

        echo "ERROR: Se encontraron varios JARs ejecutables."

        echo ""
        printf '%s\n' "${EXECUTABLE_JARS[@]}"

        echo ""
        echo "No se puede determinar automaticamente cual ejecutar."

        exit 1

    fi


    JAR_FILE="$(realpath "${EXECUTABLE_JARS[0]}")"


    echo "${JAR_FILE}" > "${JAR_PATH_FILE}"


    echo ""
    echo "JAR detectado:"
    echo "${JAR_FILE}"

}


# ==========================================================
# START
# ==========================================================

start_backend() {

    build_backend

    find_executable_jar


    echo ""
    echo "=========================================="
    echo "          LEVANTANDO BACKEND"
    echo "=========================================="


    JAR_FILE="$(cat "${JAR_PATH_FILE}")"


    echo ""
    echo "Puerto:"
    echo "${APP_PORT}"

    echo ""
    echo "JAR:"
    echo "${JAR_FILE}"

    echo ""


    nohup java \
        -jar "${JAR_FILE}" \
        --server.port="${APP_PORT}" \
        > "${LOG_FILE}" 2>&1 &


    APP_PID=$!


    echo "${APP_PID}" > "${PID_FILE}"


    echo "PID: ${APP_PID}"


    sleep 2


    if ! kill -0 "${APP_PID}" 2>/dev/null; then

        echo ""
        echo "ERROR: El backend termino durante el arranque."

        echo ""
        echo "=========================================="
        echo "          APPLICATION LOG"
        echo "=========================================="

        cat "${LOG_FILE}" || true

        exit 1

    fi


    wait_backend

}


# ==========================================================
# WAIT
# ==========================================================

wait_backend() {

    echo ""
    echo "=========================================="
    echo "          ESPERANDO BACKEND"
    echo "=========================================="

    echo ""
    echo "http://127.0.0.1:${APP_PORT}"
    echo ""


    for i in {1..60}; do

        # --------------------------------------------------
        # Primero comprobar que el proceso sigue vivo
        # --------------------------------------------------

        if [ -f "${PID_FILE}" ]; then

            PID="$(cat "${PID_FILE}")"


            if ! kill -0 "${PID}" 2>/dev/null; then

                echo ""
                echo "ERROR: El backend termino inesperadamente."

                echo ""
                cat "${LOG_FILE}" || true

                exit 1

            fi

        fi


        # --------------------------------------------------
        # Cualquier respuesta HTTP significa que el servidor
        # ya esta escuchando.
        #
        # Puede ser 200, 401, 403, 404, etc.
        # --------------------------------------------------

        if curl \
            --silent \
            --show-error \
            --output /dev/null \
            --connect-timeout 2 \
            "http://127.0.0.1:${APP_PORT}/"
        then

            echo ""
            echo "Backend disponible."
            echo ""

            return 0

        fi


        echo "Intento ${i}/60 - backend aun no disponible"


        sleep 2

    done


    echo ""
    echo "ERROR: El backend no respondio dentro del tiempo esperado."

    echo ""
    echo "=========================================="
    echo "          APPLICATION LOG"
    echo "=========================================="

    cat "${LOG_FILE}" || true


    exit 1

}


# ==========================================================
# STOP
# ==========================================================

stop_backend() {

    echo ""
    echo "=========================================="
    echo "          DETENIENDO BACKEND"
    echo "=========================================="


    if [ ! -f "${PID_FILE}" ]; then

        echo "No existe proceso que detener."

        return 0

    fi


    PID="$(cat "${PID_FILE}")"


    if ! kill -0 "${PID}" 2>/dev/null; then

        echo "El proceso ya finalizo."

        rm -f "${PID_FILE}"

        return 0

    fi


    echo "Deteniendo PID ${PID}"


    kill "${PID}" 2>/dev/null || true


    # ------------------------------------------------------
    # Esperar cierre normal
    # ------------------------------------------------------

    for i in {1..10}; do

        if ! kill -0 "${PID}" 2>/dev/null; then

            echo "Backend detenido correctamente."

            rm -f "${PID_FILE}"

            return 0

        fi


        sleep 1

    done


    # ------------------------------------------------------
    # Forzar si sigue vivo
    # ------------------------------------------------------

    echo "Forzando cierre del backend..."


    kill -9 "${PID}" 2>/dev/null || true


    rm -f "${PID_FILE}"


    echo "Backend detenido."

}


# ==========================================================
# MAIN
# ==========================================================

case "${ACTION}" in

    start)

        start_backend
        ;;


    stop)

        stop_backend
        ;;


    *)

        echo "Uso:"
        echo ""
        echo "  ./backend.sh start"
        echo "  ./backend.sh stop"

        exit 1
        ;;

esac