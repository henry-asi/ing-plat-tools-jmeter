#!/usr/bin/env bash

set -euo pipefail


# ==========================================================
# CONFIGURACION
# ==========================================================

# load  = carga constante (comportamiento original)
# stress = escalones de usuarios hasta encontrar el limite

TEST_TYPE="${TEST_TYPE:-load}"

JMETER_VERSION="${JMETER_VERSION:-5.6.3}"

APP_PORT="${APP_PORT:-8080}"

THREADS="${THREADS:-100}"

RAMPUP="${RAMPUP:-30}"

DURATION="${DURATION:-120}"

REQUESTS_JSON="${REQUESTS_JSON:?REQUESTS_JSON no definido}"


MAX_ERROR_RATE="${MAX_ERROR_RATE:-5}"

MAX_AVG_RESPONSE_TIME="${MAX_AVG_RESPONSE_TIME:-2000}"

MAX_P95_RESPONSE_TIME="${MAX_P95_RESPONSE_TIME:-4000}"


# Solo se usan cuando TEST_TYPE=stress

START_THREADS="${START_THREADS:-50}"

STEP_THREADS="${STEP_THREADS:-50}"

MAX_THREADS="${MAX_THREADS:-400}"

STEP_RAMPUP="${STEP_RAMPUP:-10}"

STEP_DURATION="${STEP_DURATION:-60}"

RECOVERY_DURATION="${RECOVERY_DURATION:-60}"

MAX_STAGES=20

MAX_TOTAL_SECONDS=1500


RUNTIME_DIR="${RUNTIME_DIR:-${GITHUB_WORKSPACE}/runtime}"

RESULT_DIR="${RESULT_DIR:-${GITHUB_WORKSPACE}/results}"

TOOLS_DIR="${GITHUB_WORKSPACE}/.tools"


JMETER_HOME="${TOOLS_DIR}/apache-jmeter-${JMETER_VERSION}"

JMETER_BIN="${JMETER_HOME}/bin/jmeter"

JMX_FILE="${RUNTIME_DIR}/generated-stress-test.jmx"


mkdir -p "${RUNTIME_DIR}"


# ==========================================================
# XML ESCAPE
# ==========================================================

xml_escape() {

    local VALUE="$1"

    jq \
        --null-input \
        --raw-output \
        --arg value "${VALUE}" \
        '$value | @html'

}


# ==========================================================
# VALIDAR JSON
# ==========================================================

validate_requests() {

    echo "=========================================="
    echo "          VALIDANDO REQUESTS"
    echo "=========================================="


    if ! echo "${REQUESTS_JSON}" | jq empty >/dev/null 2>&1; then

        echo "ERROR: requests_json no contiene JSON valido."

        exit 1

    fi


    TYPE=$(
        echo "${REQUESTS_JSON}" \
            | jq -r 'type'
    )


    if [ "${TYPE}" != "array" ]; then

        echo "ERROR: requests_json debe ser un array."

        exit 1

    fi


    REQUEST_COUNT=$(
        echo "${REQUESTS_JSON}" \
            | jq 'length'
    )


    if [ "${REQUEST_COUNT}" -eq 0 ]; then

        echo "ERROR: Debe existir al menos un endpoint."

        exit 1

    fi


    # ------------------------------------------------------
    # Validar estructura de cada request
    # ------------------------------------------------------

    if ! echo "${REQUESTS_JSON}" | jq -e '

        all(
            .[];

            (.path | type == "string")

            and

            (.path | startswith("/"))

            and

            (
                (.method // "GET" | ascii_upcase)
                |
                IN(
                    "GET",
                    "POST",
                    "PUT",
                    "PATCH",
                    "DELETE"
                )
            )

            and

            (
                (.headers == null)
                or
                (.headers | type == "object")
            )
        )

    ' >/dev/null; then

        echo "ERROR: Uno o mas requests tienen formato invalido."

        echo ""
        echo "Formato esperado:"

        echo '
[
  {
    "name": "Accounts",
    "method": "GET",
    "path": "/api/accounts"
  }
]'

        exit 1

    fi


    echo ""
    echo "Requests encontrados: ${REQUEST_COUNT}"

    echo ""


    echo "${REQUESTS_JSON}" \
        | jq -r '

            .[]

            |

            "- \(.method // "GET") \(.path)"

        '

}


# ==========================================================
# VALIDAR TIPO DE PRUEBA
# ==========================================================

validate_test_type() {

    case "${TEST_TYPE}" in

        load|stress)
            ;;

        *)
            echo "ERROR: test_type debe ser 'load' o 'stress' (recibido: '${TEST_TYPE}')."

            exit 1
            ;;

    esac

}


# ==========================================================
# VALIDAR Y CALCULAR ESCALONES (solo stress)
# ==========================================================

validate_stress_config() {

    echo ""
    echo "=========================================="
    echo "      VALIDANDO CONFIGURACION STRESS"
    echo "=========================================="


    local NAME

    for NAME in \
        START_THREADS \
        STEP_THREADS \
        MAX_THREADS \
        STEP_RAMPUP \
        STEP_DURATION \
        RECOVERY_DURATION
    do

        if ! [[ "${!NAME}" =~ ^[0-9]+$ ]]; then

            echo "ERROR: ${NAME} debe ser un entero positivo (recibido: '${!NAME}')."

            exit 1

        fi

    done


    if [ "${START_THREADS}" -lt 1 ] || [ "${STEP_THREADS}" -lt 1 ]; then

        echo "ERROR: start_threads y step_threads deben ser mayores que 0."

        exit 1

    fi


    if [ "${MAX_THREADS}" -lt "${START_THREADS}" ]; then

        echo "ERROR: max_threads (${MAX_THREADS}) no puede ser menor que start_threads (${START_THREADS})."

        exit 1

    fi


    if [ $((STEP_DURATION - STEP_RAMPUP)) -lt 10 ]; then

        echo "ERROR: step_duration debe superar a step_rampup en al menos 10 s,"
        echo "       para tener datos estables en cada escalon."

        exit 1

    fi


    if [ "${RECOVERY_DURATION}" -lt 10 ]; then

        echo "ERROR: recovery_duration debe ser de al menos 10 s."

        exit 1

    fi


    local STAGES=$(( (MAX_THREADS - START_THREADS + STEP_THREADS - 1) / STEP_THREADS + 1 ))

    if [ "${STAGES}" -gt "${MAX_STAGES}" ]; then

        echo "ERROR: la configuracion genera ${STAGES} escalones (maximo ${MAX_STAGES})."
        echo "       Aumenta step_threads o reduce max_threads."

        exit 1

    fi


    compute_stages


    if [ "${TOTAL_DURATION}" -gt "${MAX_TOTAL_SECONDS}" ]; then

        echo "ERROR: la prueba duraria ${TOTAL_DURATION}s (maximo ${MAX_TOTAL_SECONDS}s)."
        echo "       Reduce step_duration, recovery_duration o el numero de escalones."

        exit 1

    fi


    echo ""
    echo "Escalones:  ${STAGE_COUNT}"
    echo "Usuarios:   ${STAGE_USERS[*]}"
    echo "Duracion:   ${TOTAL_DURATION}s (${STAGE_COUNT} x ${STEP_DURATION}s + ${RECOVERY_DURATION}s de recuperacion)"

}


compute_stages() {

    STAGE_USERS=()

    local USERS="${START_THREADS}"


    while true; do

        if [ "${USERS}" -ge "${MAX_THREADS}" ]; then

            STAGE_USERS+=("${MAX_THREADS}")

            break

        fi

        STAGE_USERS+=("${USERS}")

        USERS=$((USERS + STEP_THREADS))

    done


    STAGE_COUNT="${#STAGE_USERS[@]}"

    STAGES_END=$((STAGE_COUNT * STEP_DURATION))

    TOTAL_DURATION=$((STAGES_END + RECOVERY_DURATION))

}


# ==========================================================
# INSTALAR JMETER
# ==========================================================

install_jmeter() {

    if [ -x "${JMETER_BIN}" ]; then

        echo ""
        echo "JMeter ${JMETER_VERSION} ya esta instalado."

        return 0

    fi


    echo ""
    echo "=========================================="
    echo "           INSTALANDO JMETER"
    echo "=========================================="


    mkdir -p "${TOOLS_DIR}"


    cd "${TOOLS_DIR}"


    ARCHIVE="apache-jmeter-${JMETER_VERSION}.tgz"


    echo ""
    echo "Descargando Apache JMeter ${JMETER_VERSION}..."


    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --output "${ARCHIVE}" \
        "https://archive.apache.org/dist/jmeter/binaries/${ARCHIVE}"


    echo "Descargando checksum..."


    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --output "${ARCHIVE}.sha512" \
        "https://archive.apache.org/dist/jmeter/binaries/${ARCHIVE}.sha512"


    echo "Verificando integridad..."


    sha512sum --check "${ARCHIVE}.sha512"


    echo "Descomprimiendo..."


    tar -xzf "${ARCHIVE}"


    rm -f \
        "${ARCHIVE}" \
        "${ARCHIVE}.sha512"


    if [ ! -x "${JMETER_BIN}" ]; then

        echo "ERROR: JMeter no pudo instalarse."

        exit 1

    fi


    echo ""
    echo "JMeter instalado correctamente."

    echo ""


    "${JMETER_BIN}" --version

}


# ==========================================================
# GENERAR HEADER MANAGER
# ==========================================================

generate_headers() {

    local REQUEST="$1"

    local BODY="$2"


    local HEADERS


    HEADERS=$(
        echo "${REQUEST}" \
            | jq -c '.headers // {}'
    )


    # ------------------------------------------------------
    # Si existe body y no se especifico Content-Type,
    # agregar application/json automaticamente.
    # ------------------------------------------------------

    if [ -n "${BODY}" ]; then

        HAS_CONTENT_TYPE=$(
            echo "${HEADERS}" \
                | jq '
                    [
                        keys[]
                        |
                        ascii_downcase
                    ]
                    |
                    any(. == "content-type")
                '
        )


        if [ "${HAS_CONTENT_TYPE}" != "true" ]; then

            HEADERS=$(
                echo "${HEADERS}" \
                    | jq \
                        '. + {"Content-Type":"application/json"}'
            )

        fi

    fi


    HEADER_COUNT=$(
        echo "${HEADERS}" \
            | jq 'length'
    )


    if [ "${HEADER_COUNT}" -eq 0 ]; then

        return 0

    fi


    cat >> "${JMX_FILE}" <<'EOF'
                    <HeaderManager
                        guiclass="HeaderPanel"
                        testclass="HeaderManager"
                        testname="HTTP Headers"
                        enabled="true">

                        <collectionProp name="HeaderManager.headers">
EOF


    while IFS=$'\t' read -r HEADER_NAME HEADER_VALUE; do

        HEADER_NAME_ESCAPED="$(xml_escape "${HEADER_NAME}")"

        HEADER_VALUE_ESCAPED="$(xml_escape "${HEADER_VALUE}")"


        cat >> "${JMX_FILE}" <<EOF
                            <elementProp
                                name=""
                                elementType="Header">

                                <stringProp name="Header.name">${HEADER_NAME_ESCAPED}</stringProp>

                                <stringProp name="Header.value">${HEADER_VALUE_ESCAPED}</stringProp>

                            </elementProp>
EOF

    done < <(

        echo "${HEADERS}" \
            | jq -r '

                to_entries[]

                |

                [
                    .key,
                    (.value | tostring)
                ]

                |

                @tsv

            '

    )


    cat >> "${JMX_FILE}" <<'EOF'
                        </collectionProp>

                    </HeaderManager>

                    <hashTree/>
EOF

}


# ==========================================================
# GENERAR REQUEST
# ==========================================================

generate_request() {

    local REQUEST="$1"

    local INDEX="$2"


    METHOD=$(
        echo "${REQUEST}" \
            | jq -r '(.method // "GET") | ascii_upcase'
    )


    PATH_VALUE=$(
        echo "${REQUEST}" \
            | jq -r '.path'
    )


    NAME=$(
        echo "${REQUEST}" \
            | jq -r '
                .name
                //
                (
                    (.method // "GET" | ascii_upcase)
                    + " "
                    + .path
                )
            '
    )


    HAS_BODY=$(
        echo "${REQUEST}" \
            | jq 'has("body")'
    )


    BODY=""


    if [ "${HAS_BODY}" = "true" ]; then

        BODY=$(
            echo "${REQUEST}" \
                | jq -r '

                    if (.body | type) == "string"
                    then
                        .body
                    else
                        (.body | tojson)
                    end

                '
        )

    fi


    NAME_ESCAPED="$(xml_escape "${NAME}")"

    PATH_ESCAPED="$(xml_escape "${PATH_VALUE}")"


    # ------------------------------------------------------
    # HTTP Arguments
    # ------------------------------------------------------

    if [ -n "${BODY}" ]; then

        BODY_ESCAPED="$(xml_escape "${BODY}")"


        ARGUMENTS_XML=$(cat <<EOF
                            <elementProp
                                name=""
                                elementType="HTTPArgument">

                                <boolProp name="HTTPArgument.always_encode">false</boolProp>

                                <stringProp name="Argument.value">${BODY_ESCAPED}</stringProp>

                                <stringProp name="Argument.metadata">=</stringProp>

                                <boolProp name="HTTPArgument.use_equals">true</boolProp>

                            </elementProp>
EOF
)

        POST_BODY_RAW="true"

    else

        ARGUMENTS_XML=""

        POST_BODY_RAW="false"

    fi


    # ------------------------------------------------------
    # HTTP Sampler
    # ------------------------------------------------------

    cat >> "${JMX_FILE}" <<EOF

                <HTTPSamplerProxy
                    guiclass="HttpTestSampleGui"
                    testclass="HTTPSamplerProxy"
                    testname="${NAME_ESCAPED}"
                    enabled="true">

                    <elementProp
                        name="HTTPsampler.Arguments"
                        elementType="Arguments">

                        <collectionProp name="Arguments.arguments">

${ARGUMENTS_XML}

                        </collectionProp>

                    </elementProp>

                    <stringProp name="HTTPSampler.domain">127.0.0.1</stringProp>

                    <stringProp name="HTTPSampler.port">${APP_PORT}</stringProp>

                    <stringProp name="HTTPSampler.protocol">http</stringProp>

                    <stringProp name="HTTPSampler.path">${PATH_ESCAPED}</stringProp>

                    <stringProp name="HTTPSampler.method">${METHOD}</stringProp>

                    <boolProp name="HTTPSampler.follow_redirects">true</boolProp>

                    <boolProp name="HTTPSampler.auto_redirects">false</boolProp>

                    <boolProp name="HTTPSampler.use_keepalive">true</boolProp>

                    <boolProp name="HTTPSampler.DO_MULTIPART_POST">false</boolProp>

                    <boolProp name="HTTPSampler.postBodyRaw">${POST_BODY_RAW}</boolProp>

                    <stringProp name="HTTPSampler.connect_timeout">5000</stringProp>

                    <stringProp name="HTTPSampler.response_timeout">30000</stringProp>

                </HTTPSamplerProxy>

                <hashTree>
EOF


    generate_headers \
        "${REQUEST}" \
        "${BODY}"


    cat >> "${JMX_FILE}" <<'EOF'

                </hashTree>
EOF

}


# ==========================================================
# GENERAR JMX
# ==========================================================

write_thread_group() {

    local GROUP_NAME="$1"

    local GROUP_THREADS="$2"

    local GROUP_RAMP="$3"

    local GROUP_DURATION="$4"

    local GROUP_DELAY="$5"


    local GROUP_NAME_ESCAPED

    GROUP_NAME_ESCAPED="$(xml_escape "${GROUP_NAME}")"


    cat >> "${JMX_FILE}" <<EOF

            <ThreadGroup
                guiclass="ThreadGroupGui"
                testclass="ThreadGroup"
                testname="${GROUP_NAME_ESCAPED}"
                enabled="true">

                <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>

                <elementProp
                    name="ThreadGroup.main_controller"
                    elementType="LoopController"
                    guiclass="LoopControlPanel"
                    testclass="LoopController"
                    testname="Loop Controller">

                    <boolProp name="LoopController.continue_forever">true</boolProp>

                    <stringProp name="LoopController.loops">-1</stringProp>

                </elementProp>

                <stringProp name="ThreadGroup.num_threads">${GROUP_THREADS}</stringProp>

                <stringProp name="ThreadGroup.ramp_time">${GROUP_RAMP}</stringProp>

                <boolProp name="ThreadGroup.scheduler">true</boolProp>

                <stringProp name="ThreadGroup.duration">${GROUP_DURATION}</stringProp>

                <stringProp name="ThreadGroup.delay">${GROUP_DELAY}</stringProp>

                <boolProp name="ThreadGroup.same_user_on_next_iteration">true</boolProp>

            </ThreadGroup>

            <hashTree>
EOF


    INDEX=0


    while IFS= read -r REQUEST; do

        INDEX=$((INDEX + 1))


        generate_request \
            "${REQUEST}" \
            "${INDEX}"


    done < <(

        echo "${REQUESTS_JSON}" \
            | jq -c '.[]'

    )


    cat >> "${JMX_FILE}" <<'EOF'

            </hashTree>
EOF

}


# ----------------------------------------------------------
# Stress: un grupo de usuarios por escalon.
#
# Los grupos se acumulan: el escalon N empieza (N-1) x
# STEP_DURATION segundos despues del inicio y suma sus usuarios
# a los anteriores. Todos menos el primero terminan al final del
# ultimo escalon; el primero sigue durante la recuperacion.
# ----------------------------------------------------------

generate_stress_groups() {

    local STAGE=1

    local PREVIOUS_USERS=0

    local USERS ADDED DELAY GROUP_DURATION


    for USERS in "${STAGE_USERS[@]}"; do

        ADDED=$((USERS - PREVIOUS_USERS))

        PREVIOUS_USERS="${USERS}"

        DELAY=$(( (STAGE - 1) * STEP_DURATION ))


        if [ "${STAGE}" -eq 1 ]; then

            GROUP_DURATION="${TOTAL_DURATION}"

        else

            GROUP_DURATION=$((STAGES_END - DELAY))

        fi


        write_thread_group \
            "Stage ${STAGE} (+${ADDED} users)" \
            "${ADDED}" \
            "${STEP_RAMPUP}" \
            "${GROUP_DURATION}" \
            "${DELAY}"


        STAGE=$((STAGE + 1))

    done

}


generate_jmx() {

    echo ""
    echo "=========================================="
    echo "        GENERANDO TEST PLAN JMETER"
    echo "=========================================="


    rm -f "${JMX_FILE}"


    cat > "${JMX_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<jmeterTestPlan
    version="1.2"
    properties="5.0"
    jmeter="${JMETER_VERSION}">

    <hashTree>

        <TestPlan
            guiclass="TestPlanGui"
            testclass="TestPlan"
            testname="Centralized Stress Test"
            enabled="true">

            <stringProp name="TestPlan.comments">
                Generated automatically by centralized performance pipeline
            </stringProp>

            <boolProp name="TestPlan.functional_mode">false</boolProp>

            <boolProp name="TestPlan.tearDown_on_shutdown">true</boolProp>

            <boolProp name="TestPlan.serialize_threadgroups">false</boolProp>

            <elementProp
                name="TestPlan.user_defined_variables"
                elementType="Arguments"
                guiclass="ArgumentsPanel"
                testclass="Arguments"
                testname="User Defined Variables">

                <collectionProp name="Arguments.arguments"/>

            </elementProp>

        </TestPlan>

        <hashTree>
EOF


    if [ "${TEST_TYPE}" = "stress" ]; then

        generate_stress_groups

    else

        write_thread_group \
            "Stress Users" \
            "${THREADS}" \
            "${RAMPUP}" \
            "${DURATION}" \
            "0"

    fi


    cat >> "${JMX_FILE}" <<'EOF'

        </hashTree>

    </hashTree>

</jmeterTestPlan>
EOF


    echo ""
    echo "Test Plan generado:"
    echo "${JMX_FILE}"

    echo ""
    echo "Requests generados: ${INDEX}"

}


# ==========================================================
# EJECUTAR JMETER
# ==========================================================

run_jmeter() {

    echo ""
    echo "=========================================="
    echo "          EJECUTANDO ${TEST_TYPE^^} TEST"
    echo "=========================================="

    echo ""
    echo "Backend:"
    echo "${BACKEND_REPOSITORY:-unknown}"

    if [ "${TEST_TYPE}" = "stress" ]; then

        echo ""
        echo "Escalones de usuarios:"
        echo "${STAGE_USERS[*]}"

        echo ""
        echo "Ramp-up por escalon:"
        echo "${STEP_RAMPUP}s"

        echo ""
        echo "Duracion por escalon:"
        echo "${STEP_DURATION}s"

        echo ""
        echo "Recuperacion:"
        echo "${RECOVERY_DURATION}s"

        echo ""
        echo "Duracion total:"
        echo "${TOTAL_DURATION}s"

        # El reporte HTML de una prueba larga necesita mas memoria
        export HEAP="${HEAP:--Xms1g -Xmx3g}"

    else

        echo ""
        echo "Usuarios concurrentes:"
        echo "${THREADS}"

        echo ""
        echo "Ramp-up:"
        echo "${RAMPUP}s"

        echo ""
        echo "Duracion:"
        echo "${DURATION}s"

    fi

    echo ""


    rm -rf "${RESULT_DIR}"


    mkdir -p "${RESULT_DIR}"


    "${JMETER_BIN}" \
        -n \
        -t "${JMX_FILE}" \
        \
        -Jaggregate_rpt_pct1=90 \
        -Jaggregate_rpt_pct2=95 \
        -Jaggregate_rpt_pct3=99 \
        \
        -Jjmeter.save.saveservice.output_format=csv \
        -Jjmeter.save.saveservice.print_field_names=true \
        \
        -l "${RESULT_DIR}/results.jtl" \
        -j "${RESULT_DIR}/jmeter.log" \
        \
        -e \
        -o "${RESULT_DIR}/report"


    echo ""
    echo "JMeter finalizado."

}


# ==========================================================
# QUALITY GATE
# ==========================================================

validate_results() {

    echo ""
    echo "=========================================="
    echo "          VALIDANDO RESULTADOS"
    echo "=========================================="


    STATISTICS="${RESULT_DIR}/report/statistics.json"


    if [ ! -f "${STATISTICS}" ]; then

        echo "ERROR: No existe statistics.json"

        exit 1

    fi


    TOTAL_REQUESTS=$(
        jq -r \
            '.Total.sampleCount // 0' \
            "${STATISTICS}"
    )


    TOTAL_ERRORS=$(
        jq -r \
            '.Total.errorCount // 0' \
            "${STATISTICS}"
    )


    ERROR_RATE=$(
        jq -r \
            '.Total.errorPct // 0' \
            "${STATISTICS}"
    )


    AVG_RESPONSE_TIME=$(
        jq -r \
            '.Total.meanResTime // 0' \
            "${STATISTICS}"
    )


    P95_RESPONSE_TIME=$(
        jq -r \
            '.Total.pct2ResTime // 0' \
            "${STATISTICS}"
    )


    THROUGHPUT=$(
        jq -r \
            '.Total.throughput // 0' \
            "${STATISTICS}"
    )


    echo ""
    echo "=========================================="
    echo "             RESULTADO GLOBAL"
    echo "=========================================="

    printf "%-30s %s\n" \
        "Requests:" \
        "${TOTAL_REQUESTS}"

    printf "%-30s %s\n" \
        "Errores:" \
        "${TOTAL_ERRORS}"

    printf "%-30s %.2f %%\n" \
        "Error Rate:" \
        "${ERROR_RATE}"

    printf "%-30s %.2f ms\n" \
        "Average:" \
        "${AVG_RESPONSE_TIME}"

    printf "%-30s %.2f ms\n" \
        "P95:" \
        "${P95_RESPONSE_TIME}"

    printf "%-30s %.2f req/s\n" \
        "Throughput:" \
        "${THROUGHPUT}"


    echo ""
    echo "=========================================="
    echo "          RESULTADO POR ENDPOINT"
    echo "=========================================="
    echo ""


    jq -r '

        to_entries[]

        |

        select(.key != "Total")

        |

        [
            .key,
            (.value.sampleCount | tostring),
            (.value.errorPct | tostring),
            (.value.meanResTime | tostring),
            (.value.pct2ResTime | tostring),
            (.value.throughput | tostring)
        ]

        |

        @tsv

    ' "${STATISTICS}" \
    | while IFS=$'\t' read -r \
        NAME \
        COUNT \
        ERROR \
        AVG \
        P95 \
        THROUGHPUT_ENDPOINT
    do

        echo "${NAME}"

        echo "  Requests:   ${COUNT}"

        echo "  Error rate: ${ERROR}%"

        echo "  Average:    ${AVG} ms"

        echo "  P95:        ${P95} ms"

        echo "  Throughput: ${THROUGHPUT_ENDPOINT} req/s"

        echo ""

    done


    # ======================================================
    # QUALITY GATE
    # ======================================================

    FAILED=0


    if awk \
        -v value="${ERROR_RATE}" \
        -v limit="${MAX_ERROR_RATE}" \
        'BEGIN { exit !(value > limit) }'
    then

        echo "FAIL - Error Rate: ${ERROR_RATE}% > ${MAX_ERROR_RATE}%"

        FAILED=1

    else

        echo "PASS - Error Rate"

    fi


    if awk \
        -v value="${AVG_RESPONSE_TIME}" \
        -v limit="${MAX_AVG_RESPONSE_TIME}" \
        'BEGIN { exit !(value > limit) }'
    then

        echo "FAIL - Average: ${AVG_RESPONSE_TIME} ms > ${MAX_AVG_RESPONSE_TIME} ms"

        FAILED=1

    else

        echo "PASS - Average Response Time"

    fi


    if awk \
        -v value="${P95_RESPONSE_TIME}" \
        -v limit="${MAX_P95_RESPONSE_TIME}" \
        'BEGIN { exit !(value > limit) }'
    then

        echo "FAIL - P95: ${P95_RESPONSE_TIME} ms > ${MAX_P95_RESPONSE_TIME} ms"

        FAILED=1

    else

        echo "PASS - P95"

    fi


    # ======================================================
    # GITHUB STEP SUMMARY
    # ======================================================

    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then

        {
            echo "# JMeter Load Test"
            echo ""
            echo "**Backend:** ${BACKEND_REPOSITORY:-unknown}"
            echo ""
            echo "**Threads:** ${THREADS}"
            echo ""
            echo "**Ramp-up:** ${RAMPUP}s"
            echo ""
            echo "**Duration:** ${DURATION}s"
            echo ""

            echo "## Resultado global"
            echo ""
            echo "| Metrica | Resultado | Limite |"
            echo "|---|---:|---:|"
            echo "| Requests | ${TOTAL_REQUESTS} | - |"
            echo "| Errores | ${TOTAL_ERRORS} | - |"
            echo "| Error Rate | ${ERROR_RATE}% | ${MAX_ERROR_RATE}% |"
            echo "| Average | ${AVG_RESPONSE_TIME} ms | ${MAX_AVG_RESPONSE_TIME} ms |"
            echo "| P95 | ${P95_RESPONSE_TIME} ms | ${MAX_P95_RESPONSE_TIME} ms |"
            echo "| Throughput | ${THROUGHPUT} req/s | - |"
            echo ""

            echo "## Resultado por endpoint"
            echo ""
            echo "| Endpoint | Requests | Error % | Avg ms | P95 ms | Req/s |"
            echo "|---|---:|---:|---:|---:|---:|"

        } >> "${GITHUB_STEP_SUMMARY}"


        jq -r '

            to_entries[]

            |

            select(.key != "Total")

            |

            "| \(.key) | \(.value.sampleCount) | \(.value.errorPct) | \(.value.meanResTime) | \(.value.pct2ResTime) | \(.value.throughput) |"

        ' "${STATISTICS}" \
        >> "${GITHUB_STEP_SUMMARY}"

    fi


    echo ""


    if [ "${FAILED}" -eq 1 ]; then

        echo "=========================================="
        echo "         QUALITY GATE: FAILED"
        echo "=========================================="

        exit 1

    fi


    echo "=========================================="
    echo "         QUALITY GATE: PASSED"
    echo "=========================================="

}


# ==========================================================
# ANALISIS POR ESCALON (stress)
#
# Los escalones se acumulan, asi que no se pueden separar por
# nombre de sampler: se separan por ventana de tiempo sobre
# results.jtl.
#
#   escalon i    -> [(i-1)*STEP_DURATION + STEP_RAMPUP, i*STEP_DURATION)
#   recuperacion -> desde STAGE_COUNT*STEP_DURATION hasta el final
#
# La rampa de cada escalon se descarta: todavia estan entrando
# usuarios y los datos no son estables.
# Genera ${RESULT_DIR}/stages.tsv con una fila por escalon:
#   etiqueta usuarios requests errores error% avg p95 req/s estado motivos
# ==========================================================

analyze_stages() {

    local START_TS

    START_TS=$(
        awk -F, '
            NR > 1 && (min == "" || $1 + 0 < min + 0) { min = $1 }
            END { printf "%.0f", min }
        ' "${JTL_FILE}"
    )


    if [ -z "${START_TS}" ]; then

        echo "ERROR: results.jtl no contiene muestras."

        exit 1

    fi


    local USERS_CSV

    USERS_CSV="$(IFS=,; echo "${STAGE_USERS[*]}")"


    awk -F, \
        -v start="${START_TS}" \
        -v users="${USERS_CSV}" \
        -v step="${STEP_DURATION}" \
        -v ramp="${STEP_RAMPUP}" \
        -v recovery="${RECOVERY_DURATION}" \
        -v maxerr="${MAX_ERROR_RATE}" \
        -v maxavg="${MAX_AVG_RESPONSE_TIME}" \
        -v maxp95="${MAX_P95_RESPONSE_TIME}" '

        # Separa una linea CSV con campos entre comillas
        function splitcsv(line, limit,    len, i, c, inq, k, cur) {

            len = length(line)
            k = 1
            cur = ""
            inq = 0

            for (i = 1; i <= len; i++) {

                c = substr(line, i, 1)

                if (inq) {

                    if (c == "\"") {

                        if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ }
                        else inq = 0

                    } else cur = cur c

                } else if (c == "\"") inq = 1
                else if (c == ",") {

                    F[k++] = cur
                    cur = ""

                    if (k > limit) return k

                } else cur = cur c

            }

            F[k] = cur

            return k

        }

        BEGIN {

            n = split(users, U, ",")

            stepMs = step * 1000
            rampMs = ramp * 1000
            recStart = n * stepMs

        }

        NR == 1 {

            for (i = 1; i <= NF; i++) {

                if ($i == "timeStamp") its = i
                if ($i == "elapsed")   iel = i
                if ($i == "success")   iok = i

            }

            if (!its || !iel || !iok) {

                print "ERROR: results.jtl no tiene las columnas timeStamp, elapsed y success." > "/dev/stderr"
                bad = 1
                exit 1

            }

            limit = its; if (iel > limit) limit = iel; if (iok > limit) limit = iok

            next

        }

        {

            if (index($0, "\"") > 0) {

                splitcsv($0, limit)

                ts = F[its]; el = F[iel]; ok = F[iok]

            } else {

                ts = $its; el = $iel; ok = $iok

            }

            if (ts == "" || el == "") next

            rel = ts - start
            if (rel < 0) rel = 0

            if (rel >= recStart) s = n + 1
            else {

                s = int(rel / stepMs) + 1

                if (rel - (s - 1) * stepMs < rampMs) next

            }

            el = int(el)

            cnt[s]++
            sum[s] += el
            hist[s, el]++
            if (ok != "true") err[s]++
            if (el > maxel) maxel = el

        }

        END {

            if (bad) exit 1

            for (s = 1; s <= n + 1; s++) {

                label = (s <= n) ? s : "Recuperacion"
                u     = (s <= n) ? U[s] : U[1]
                secs  = (s <= n) ? step - ramp : recovery
                c     = cnt[s] + 0
                e     = err[s] + 0

                if (c == 0) {

                    printf "%s\t%d\t0\t0\t0.00\t0.0\t0.0\t0.0\tSIN_DATOS\t-\n", label, u
                    continue

                }

                epct = e * 100 / c
                avg  = sum[s] / c

                target = int(0.95 * c)
                if (target < 0.95 * c) target++
                if (target < 1) target = 1

                acc = 0
                p95 = 0

                for (x = 0; x <= maxel; x++) {

                    if ((s, x) in hist) acc += hist[s, x]

                    if (acc >= target) { p95 = x; break }

                }

                reasons = ""
                if (epct > maxerr + 0) reasons = reasons "errores"
                if (avg  > maxavg + 0) reasons = reasons (reasons == "" ? "" : "+") "promedio"
                if (p95  > maxp95 + 0) reasons = reasons (reasons == "" ? "" : "+") "P95"

                if (reasons == "") status = "OK"
                else status = (s <= n) ? "DEGRADADO" : "NO_RECUPERADO"

                printf "%s\t%d\t%d\t%d\t%.2f\t%.1f\t%.1f\t%.1f\t%s\t%s\n", \
                    label, u, c, e, epct, avg, p95, c / secs, status, (reasons == "" ? "-" : reasons)

            }

        }

    ' "${JTL_FILE}" > "${STAGES_TSV}"

}


build_stage_conclusion() {

    local LABEL USERS COUNT ERRORS EPCT AVG P95 RPS STATUS REASONS


    STAGES_TEXT=""

    STAGES_MD_ROWS=""

    RECOVERY_STATUS="SIN_DATOS"

    local BREAK_USERS="" BREAK_REASONS="" MAX_OK_USERS="" LAST_USERS=""


    while IFS=$'\t' read -r LABEL USERS COUNT ERRORS EPCT AVG P95 RPS STATUS REASONS; do

        local SHOWN="${STATUS//_/ }"

        if [ "${REASONS}" != "-" ]; then

            SHOWN="${SHOWN} (${REASONS//+/, })"

        fi


        STAGES_TEXT+="$(printf "%-13s %8s %10s %9s %9s %9s %9s  %s" \
            "${LABEL}" "${USERS}" "${COUNT}" "${EPCT}" "${AVG}" "${P95}" "${RPS}" "${SHOWN}")"$'\n'

        STAGES_MD_ROWS+="| ${LABEL} | ${USERS} | ${COUNT} | ${EPCT} | ${AVG} | ${P95} | ${RPS} | ${SHOWN} |"$'\n'


        if [ "${LABEL}" = "Recuperacion" ]; then

            RECOVERY_STATUS="${STATUS}"

            continue

        fi


        LAST_USERS="${USERS}"

        if [ -z "${BREAK_USERS}" ]; then

            if [ "${STATUS}" = "OK" ]; then

                MAX_OK_USERS="${USERS}"

            else

                BREAK_USERS="${USERS}"

                BREAK_REASONS="${REASONS//+/, }"

            fi

        fi

    done < "${STAGES_TSV}"


    if [ -z "${BREAK_USERS}" ]; then

        CONCLUSION="No se alcanzo el punto de quiebre: el backend soporto hasta ${LAST_USERS} usuarios dentro de los umbrales. Sube max_threads para seguir buscando el limite."

    elif [ -z "${MAX_OK_USERS}" ]; then

        CONCLUSION="Los umbrales ya se superan en el primer escalon (${BREAK_USERS} usuarios; ${BREAK_REASONS}). Reduce start_threads o revisa los endpoints y los umbrales."

    else

        CONCLUSION="Soporta hasta ${MAX_OK_USERS} usuarios; se degrada a partir de ${BREAK_USERS} usuarios (${BREAK_REASONS})."

    fi


    case "${RECOVERY_STATUS}" in

        OK)            CONCLUSION+=" Tras bajar la carga el backend se recupera." ;;

        SIN_DATOS)     CONCLUSION+=" No hay datos en la fase de recuperacion." ;;

        *)             CONCLUSION+=" Tras bajar la carga el backend NO se recupera." ;;

    esac

}


# ==========================================================
# RESULTADOS STRESS
#
# No compara contra umbrales para aprobar/fallar la prueba:
# analiza cada escalon, informa el punto de quiebre y solo
# falla si no hay datos o si el backend no se recupera.
# ==========================================================

validate_results_stress() {

    echo ""
    echo "=========================================="
    echo "      VALIDANDO RESULTADOS (STRESS)"
    echo "=========================================="


    STATISTICS="${RESULT_DIR}/report/statistics.json"

    JTL_FILE="${RESULT_DIR}/results.jtl"

    STAGES_TSV="${RESULT_DIR}/stages.tsv"


    if [ ! -f "${STATISTICS}" ]; then

        echo "ERROR: No existe statistics.json"

        exit 1

    fi


    if [ ! -f "${JTL_FILE}" ]; then

        echo "ERROR: No existe results.jtl"

        exit 1

    fi


    TOTAL_REQUESTS=$(jq -r '.Total.sampleCount // 0' "${STATISTICS}")

    TOTAL_ERRORS=$(jq -r '.Total.errorCount // 0' "${STATISTICS}")

    ERROR_RATE=$(jq -r '.Total.errorPct // 0' "${STATISTICS}")

    AVG_RESPONSE_TIME=$(jq -r '.Total.meanResTime // 0' "${STATISTICS}")

    P95_RESPONSE_TIME=$(jq -r '.Total.pct2ResTime // 0' "${STATISTICS}")

    THROUGHPUT=$(jq -r '.Total.throughput // 0' "${STATISTICS}")


    if [ "${TOTAL_REQUESTS}" -eq 0 ]; then

        echo "ERROR: JMeter no registro ninguna peticion."

        exit 1

    fi


    echo ""
    echo "=========================================="
    echo "     RESULTADO GLOBAL (INFORMATIVO)"
    echo "=========================================="

    printf "%-30s %s\n"      "Requests:"   "${TOTAL_REQUESTS}"
    printf "%-30s %s\n"      "Errores:"    "${TOTAL_ERRORS}"
    printf "%-30s %.2f %%\n" "Error Rate:" "${ERROR_RATE}"
    printf "%-30s %.2f ms\n" "Average:"    "${AVG_RESPONSE_TIME}"
    printf "%-30s %.2f ms\n" "P95:"        "${P95_RESPONSE_TIME}"
    printf "%-30s %.2f req/s\n" "Throughput:" "${THROUGHPUT}"


    analyze_stages

    build_stage_conclusion


    echo ""
    echo "=========================================="
    echo "          RESULTADO POR ESCALON"
    echo "=========================================="
    echo ""
    echo "Umbrales: error <= ${MAX_ERROR_RATE}%, promedio <= ${MAX_AVG_RESPONSE_TIME} ms, P95 <= ${MAX_P95_RESPONSE_TIME} ms"
    echo "Cada escalon se mide sin su rampa de entrada."
    echo ""

    printf "%-13s %8s %10s %9s %9s %9s %9s  %s\n" \
        "Escalon" "Usuarios" "Requests" "Error %" "Avg ms" "P95 ms" "Req/s" "Estado"

    printf '%s' "${STAGES_TEXT}"


    echo ""
    echo "CONCLUSION: ${CONCLUSION}"


    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then

        {
            echo "# JMeter Stress Test"
            echo ""
            echo "**Backend:** ${BACKEND_REPOSITORY:-unknown}"
            echo ""
            echo "**Escalones (usuarios):** ${STAGE_USERS[*]}"
            echo ""
            echo "**Ramp-up por escalon:** ${STEP_RAMPUP}s | **Duracion por escalon:** ${STEP_DURATION}s | **Recuperacion:** ${RECOVERY_DURATION}s"
            echo ""

            echo "## Conclusion"
            echo ""
            echo "**${CONCLUSION}**"
            echo ""
            echo "## Resultado por escalon"
            echo ""
            echo "Umbrales: error <= ${MAX_ERROR_RATE}%, promedio <= ${MAX_AVG_RESPONSE_TIME} ms, P95 <= ${MAX_P95_RESPONSE_TIME} ms. Cada escalon se mide sin su rampa de entrada."
            echo ""
            echo "| Escalon | Usuarios | Requests | Error % | Avg ms | P95 ms | Req/s | Estado |"
            echo "|---|---:|---:|---:|---:|---:|---:|---|"
            printf '%s' "${STAGES_MD_ROWS}"

            echo ""
            echo "## Resultado global (informativo)"
            echo ""
            echo "| Metrica | Resultado |"
            echo "|---|---:|"
            echo "| Requests | ${TOTAL_REQUESTS} |"
            echo "| Errores | ${TOTAL_ERRORS} |"
            echo "| Error Rate | ${ERROR_RATE}% |"
            echo "| Average | ${AVG_RESPONSE_TIME} ms |"
            echo "| P95 | ${P95_RESPONSE_TIME} ms |"
            echo "| Throughput | ${THROUGHPUT} req/s |"
            echo ""

            echo "## Resultado por endpoint (informativo)"
            echo ""
            echo "| Endpoint | Requests | Error % | Avg ms | P95 ms | Req/s |"
            echo "|---|---:|---:|---:|---:|---:|"

        } >> "${GITHUB_STEP_SUMMARY}"


        jq -r '

            to_entries[]

            |

            select(.key != "Total")

            |

            "| \(.key) | \(.value.sampleCount) | \(.value.errorPct) | \(.value.meanResTime) | \(.value.pct2ResTime) | \(.value.throughput) |"

        ' "${STATISTICS}" \
        >> "${GITHUB_STEP_SUMMARY}"

    fi


    echo ""


    if [ "${RECOVERY_STATUS}" != "OK" ]; then

        echo "=========================================="
        echo "   STRESS TEST: FAILED (SIN RECUPERACION)"
        echo "=========================================="

        exit 1

    fi


    echo "=========================================="
    echo "         STRESS TEST: COMPLETED"
    echo "=========================================="

}


# ==========================================================
# MAIN
# ==========================================================

validate_test_type

validate_requests

if [ "${TEST_TYPE}" = "stress" ]; then

    validate_stress_config

fi

install_jmeter

generate_jmx

run_jmeter

if [ "${TEST_TYPE}" = "stress" ]; then

    validate_results_stress

else

    validate_results

fi