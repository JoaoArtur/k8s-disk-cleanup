#!/usr/bin/env bash
#
# k8s-disk-cleanup.sh — Cleanup de disco para nodes Kubernetes (containerd)
#
# Uso:
#   ./k8s-disk-cleanup.sh                  # dry-run (padrão)
#   ./k8s-disk-cleanup.sh --execute        # execução real
#
# Crontab (exemplo diário às 3h):
#   0 3 * * * /opt/scripts/k8s-disk-cleanup.sh --execute >> /var/log/k8s-disk-cleanup.log 2>&1
#
# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURAÇÃO
# ─────────────────────────────────────────────────────────────────────────────

# Threshold de uso de disco (%) para disparar o cleanup.
# O script só age se o uso atual estiver ACIMA deste valor.
DISK_THRESHOLD="${DISK_THRESHOLD:-30}"

# Partição a monitorar (ajuste conforme seu node)
DISK_PARTITION="${DISK_PARTITION:-/}"

# Idade mínima (em dias) de logs para remoção
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-3}"

# Idade mínima (em horas) de imagens não utilizadas para prune
IMAGE_AGE="${IMAGE_AGE:-24h}"

# Circuit breaker: aborta se o número de imagens a remover exceder este limite.
# Evita um prune acidental massivo em caso de bug ou falso positivo.
MAX_IMAGES_TO_PRUNE="${MAX_IMAGES_TO_PRUNE:-1000}"

# Modo de execução
DRY_RUN=true
if [[ "${1}" == "--execute" ]]; then
    DRY_RUN=false
fi

# Log file para auditoria
LOG_DIR="/var/log"
TIMESTAMP=$(date '+%Y-%m-%d_%H:%M:%S')

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES
# ─────────────────────────────────────────────────────────────────────────────

log() {
    echo "[${TIMESTAMP}] [INFO]  $*"
}

warn() {
    echo "[${TIMESTAMP}] [WARN]  $*" >&2
}

error() {
    echo "[${TIMESTAMP}] [ERROR] $*" >&2
}

get_disk_usage() {
    df "${DISK_PARTITION}" | awk 'NR==2 {gsub(/%/,""); print $5}'
}

get_disk_available_gb() {
    df -BG "${DISK_PARTITION}" | awk 'NR==2 {gsub(/G/,""); print $4}'
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "Este script precisa rodar como root"
    exit 1
fi

# Auto-detecta MicroK8s vs instalação padrão
CRICTL=""
CTR=""
MICROK8S=false

if command -v microk8s &>/dev/null; then
    MICROK8S=true
    log "MicroK8s detectado"

    # MicroK8s empacota crictl e ctr dentro do snap
    SNAP_CRICTL="/snap/microk8s/current/usr/local/bin/crictl"
    SNAP_CTR="/snap/microk8s/current/bin/ctr"

    # crictl do microk8s precisa do socket correto
    export CONTAINER_RUNTIME_ENDPOINT="unix:///var/snap/microk8s/common/run/containerd.sock"

    if [[ -x "${SNAP_CRICTL}" ]]; then
        CRICTL="${SNAP_CRICTL}"
    elif microk8s.ctr --help &>/dev/null 2>&1; then
        # fallback: usa microk8s.ctr para operações de imagem
        CRICTL=""
        warn "crictl não encontrado no snap — usando microk8s.ctr como fallback"
    fi

    if [[ -x "${SNAP_CTR}" ]]; then
        CTR="${SNAP_CTR} --address /var/snap/microk8s/common/run/containerd.sock"
    elif command -v microk8s.ctr &>/dev/null; then
        CTR="microk8s.ctr"
    fi

    # Paths de dados do MicroK8s (diferem do padrão)
    CONTAINERD_ROOT="${CONTAINERD_ROOT:-/var/snap/microk8s/common/var/lib/containerd}"
else
    # Instalação padrão (kubeadm, k3s, etc.)
    if command -v crictl &>/dev/null; then
        CRICTL="crictl"
    fi
    if command -v ctr &>/dev/null; then
        CTR="ctr"
    fi
    CONTAINERD_ROOT="${CONTAINERD_ROOT:-/var/lib/containerd}"
fi

if [[ -z "${CRICTL}" && -z "${CTR}" ]]; then
    error "Nenhum runtime CLI encontrado (crictl/ctr/microk8s.ctr)"
    exit 1
fi

log "CRICTL: ${CRICTL:-não disponível}"
log "CTR:    ${CTR:-não disponível}"
log "Containerd root: ${CONTAINERD_ROOT}"

CURRENT_USAGE=$(get_disk_usage)
AVAILABLE_GB=$(get_disk_available_gb)

log "=============================================="
log "K8S DISK CLEANUP — INÍCIO"
log "=============================================="
log "Modo:        $(${DRY_RUN} && echo 'DRY-RUN (nenhuma ação será executada)' || echo 'EXECUTE')"
log "Partição:    ${DISK_PARTITION}"
log "Uso atual:   ${CURRENT_USAGE}%"
log "Disponível:  ${AVAILABLE_GB}GB"
log "Threshold:   ${DISK_THRESHOLD}%"
log "=============================================="

if [[ "${CURRENT_USAGE}" -lt "${DISK_THRESHOLD}" ]]; then
    log "Uso de disco (${CURRENT_USAGE}%) abaixo do threshold (${DISK_THRESHOLD}%). Nada a fazer."
    exit 0
fi

log "Uso de disco (${CURRENT_USAGE}%) acima do threshold (${DISK_THRESHOLD}%). Iniciando cleanup..."

SPACE_BEFORE=$(get_disk_usage)

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 1: IMAGENS DE CONTAINER NÃO UTILIZADAS
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "--- ETAPA 1: Imagens não utilizadas ---"

if [[ -n "${CRICTL}" ]]; then
    # Lista imagens que não estão em uso por nenhum container
    UNUSED_IMAGES=$(${CRICTL} images -q 2>/dev/null | while read -r img_id; do
        if ! ${CRICTL} ps -a --image-id="${img_id}" -q 2>/dev/null | grep -q .; then
            echo "${img_id}"
        fi
    done)

    UNUSED_COUNT=$(echo "${UNUSED_IMAGES}" | grep -c . 2>/dev/null || echo 0)

    log "Imagens não utilizadas encontradas: ${UNUSED_COUNT}"

    if [[ "${UNUSED_COUNT}" -gt "${MAX_IMAGES_TO_PRUNE}" ]]; then
        warn "CIRCUIT BREAKER: ${UNUSED_COUNT} imagens excedem o limite de ${MAX_IMAGES_TO_PRUNE}."
        warn "Abortando prune de imagens por segurança. Ajuste MAX_IMAGES_TO_PRUNE se necessário."
    else
        if [[ "${UNUSED_COUNT}" -gt 0 ]]; then
            if ${DRY_RUN}; then
                log "[DRY-RUN] Imagens que seriam removidas:"
                echo "${UNUSED_IMAGES}" | while read -r img; do
                    ${CRICTL} inspecti "${img}" 2>/dev/null | grep -o '"repoTags":\[[^]]*\]' || echo "  ${img}"
                done
            else
                log "Executando rmi..."
                echo "${UNUSED_IMAGES}" | while read -r img; do
                    if ${CRICTL} rmi "${img}" 2>/dev/null; then
                        log "  Removida: ${img}"
                    else
                        warn "  Falha ao remover: ${img} (pode ter entrado em uso)"
                    fi
                done
            fi
        fi
    fi
elif [[ -n "${CTR}" ]]; then
    # Fallback: usa ctr para listar e remover imagens não referenciadas
    log "Usando ctr para gerenciamento de imagens"

    # Lista todas as imagens
    ALL_IMAGES=$(${CTR} -n k8s.io images ls -q 2>/dev/null)
    ALL_COUNT=$(echo "${ALL_IMAGES}" | grep -c . 2>/dev/null || echo 0)
    log "Total de imagens no namespace k8s.io: ${ALL_COUNT}"

    # Coleta IDs de imagens em uso por containers ativos e parados
    USED_IMAGES=$(${CTR} -n k8s.io containers ls -q 2>/dev/null | while read -r cid; do
        ${CTR} -n k8s.io containers info "${cid}" 2>/dev/null | grep -oP '"image":\s*"\K[^"]+'
    done | sort -u)

    # Filtra imagens não utilizadas
    if [[ -z "${USED_IMAGES}" ]]; then
        UNUSED_IMAGES="${ALL_IMAGES}"
    else
        UNUSED_IMAGES=$(comm -23 <(echo "${ALL_IMAGES}" | sort) <(echo "${USED_IMAGES}") 2>/dev/null)
    fi

    if [[ -z "${UNUSED_IMAGES}" ]]; then
        UNUSED_COUNT=0
    else
        UNUSED_COUNT=$(echo "${UNUSED_IMAGES}" | wc -l)
    fi

    log "Imagens não utilizadas encontradas: ${UNUSED_COUNT}"

    if [[ "${UNUSED_COUNT}" -gt "${MAX_IMAGES_TO_PRUNE}" ]]; then
        warn "CIRCUIT BREAKER: ${UNUSED_COUNT} imagens excedem o limite de ${MAX_IMAGES_TO_PRUNE}."
        warn "Abortando prune de imagens por segurança. Ajuste MAX_IMAGES_TO_PRUNE se necessário."
    elif [[ "${UNUSED_COUNT}" -gt 0 ]]; then
        if ${DRY_RUN}; then
            log "[DRY-RUN] Imagens que seriam removidas:"
            echo "${UNUSED_IMAGES}" | head -20
            [[ "${UNUSED_COUNT}" -gt 20 ]] && log "  ... e mais $((UNUSED_COUNT - 20)) imagens"
        else
            log "Removendo imagens não utilizadas via ctr..."
            echo "${UNUSED_IMAGES}" | while read -r img; do
                if ${CTR} -n k8s.io images rm "${img}" 2>/dev/null; then
                    log "  Removida: ${img}"
                else
                    warn "  Falha ao remover: ${img}"
                fi
            done
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 2: BUILD CACHE DO CONTAINERD
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "--- ETAPA 2: Build cache do containerd ---"

if [[ -n "${CTR}" ]]; then
    # Namespace do containerd no MicroK8s é k8s.io
    CTR_NS="${CTR} -n k8s.io"

    STALE_CONTENT=$(${CTR_NS} content ls 2>/dev/null | awk 'NR>1 {print $1}' | wc -l)
    log "Objetos de content encontrados: ${STALE_CONTENT}"

    if ${DRY_RUN}; then
        log "[DRY-RUN] Executaria: ${CTR_NS} content prune references"
        SNAPSHOTS=$(${CTR_NS} snapshots ls 2>/dev/null | awk 'NR>1' | wc -l)
        log "[DRY-RUN] Snapshots encontrados: ${SNAPSHOTS}"

        # Mostra tamanho do diretório de dados do containerd
        if [[ -d "${CONTAINERD_ROOT}" ]]; then
            CONTAINERD_SIZE=$(du -sh "${CONTAINERD_ROOT}" 2>/dev/null | awk '{print $1}')
            log "[DRY-RUN] Tamanho do containerd root (${CONTAINERD_ROOT}): ${CONTAINERD_SIZE}"
        fi
    else
        log "Limpando content não referenciado..."
        ${CTR_NS} content prune references 2>/dev/null && \
            log "  Content prune concluído" || \
            warn "  Falha no content prune"

        log "Limpando leases expirados..."
        ${CTR_NS} leases ls 2>/dev/null | awk 'NR>1 {print $1}' | while read -r lease; do
            ${CTR_NS} leases rm "${lease}" 2>/dev/null
        done
        log "  Leases cleanup concluído"
    fi
else
    warn "ctr indisponível — etapa ignorada"
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 3: LOGS ANTIGOS DE CONTAINERS
# ─────────────────────────────────────────────────────────────────────────────

log ""
log "--- ETAPA 3: Logs antigos de containers ---"

LOG_PATHS=(
    "/var/log/pods"
    "/var/log/containers"
)

# MicroK8s armazena logs adicionais dentro do snap
if ${MICROK8S}; then
    LOG_PATHS+=(
        "/var/snap/microk8s/common/var/log"
    )
fi

TOTAL_LOG_SIZE=0

for log_path in "${LOG_PATHS[@]}"; do
    if [[ -d "${log_path}" ]]; then
        # Encontra logs comprimidos e logs antigos (rotacionados)
        OLD_LOGS=$(find "${log_path}" -type f \( -name "*.gz" -o -name "*.log.*" \) -mtime +"${LOG_RETENTION_DAYS}" 2>/dev/null)
        if [[ -z "${OLD_LOGS}" ]]; then
            OLD_LOG_COUNT=0
        else
            OLD_LOG_COUNT=$(echo "${OLD_LOGS}" | wc -l)
        fi

        if [[ "${OLD_LOG_COUNT}" -gt 0 ]]; then
            SIZE=$(echo "${OLD_LOGS}" | xargs du -sh 2>/dev/null | tail -1 | awk '{print $1}')
            log "Logs antigos em ${log_path}: ${OLD_LOG_COUNT} arquivos (~${SIZE})"

            if ${DRY_RUN}; then
                log "[DRY-RUN] Arquivos que seriam removidos:"
                echo "${OLD_LOGS}" | head -10
                [[ "${OLD_LOG_COUNT}" -gt 10 ]] && log "  ... e mais $((OLD_LOG_COUNT - 10)) arquivos"
            else
                echo "${OLD_LOGS}" | xargs rm -f 2>/dev/null
                log "  Removidos ${OLD_LOG_COUNT} arquivos de ${log_path}"
            fi
        else
            log "Nenhum log antigo (>${LOG_RETENTION_DAYS}d) em ${log_path}"
        fi

        # Trunca logs ativos muito grandes (>100MB) para evitar disrupção
        LARGE_LOGS=$(find "${log_path}" -type f -name "*.log" -size +100M 2>/dev/null)
        if [[ -z "${LARGE_LOGS}" ]]; then
            LARGE_COUNT=0
        else
            LARGE_COUNT=$(echo "${LARGE_LOGS}" | wc -l)
        fi

        if [[ "${LARGE_COUNT}" -gt 0 ]]; then
            log "Logs ativos >100MB encontrados: ${LARGE_COUNT}"
            if ${DRY_RUN}; then
                echo "${LARGE_LOGS}" | while read -r f; do
                    SIZE=$(du -sh "${f}" 2>/dev/null | awk '{print $1}')
                    log "[DRY-RUN] Truncaria: ${f} (${SIZE})"
                done
            else
                echo "${LARGE_LOGS}" | while read -r f; do
                    SIZE_BEFORE=$(du -sh "${f}" 2>/dev/null | awk '{print $1}')
                    truncate -s 0 "${f}" 2>/dev/null
                    log "  Truncado: ${f} (era ${SIZE_BEFORE})"
                done
            fi
        fi
    fi
done

# Limpa logs do journald do kubelet/kubelite
if command -v journalctl &>/dev/null; then
    log ""
    if ${MICROK8S}; then
        JOURNAL_UNIT="snap.microk8s.daemon-kubelite"
    else
        JOURNAL_UNIT="kubelet"
    fi
    log "Limpando journal antigo (${JOURNAL_UNIT})..."
    if ${DRY_RUN}; then
        JOURNAL_SIZE=$(journalctl -u "${JOURNAL_UNIT}" --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]')
        log "[DRY-RUN] Journal do ${JOURNAL_UNIT} ocupa: ${JOURNAL_SIZE:-desconhecido}"
        JOURNAL_TOTAL=$(journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]')
        log "[DRY-RUN] Journal total ocupa: ${JOURNAL_TOTAL:-desconhecido}"
        log "[DRY-RUN] Executaria: journalctl --vacuum-time=${LOG_RETENTION_DAYS}d"
    else
        journalctl --vacuum-time="${LOG_RETENTION_DAYS}d" 2>/dev/null
        log "  Journal cleanup concluído"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# RELATÓRIO FINAL
# ─────────────────────────────────────────────────────────────────────────────

SPACE_AFTER=$(get_disk_usage)
AVAILABLE_AFTER=$(get_disk_available_gb)

log ""
log "=============================================="
log "RELATÓRIO FINAL"
log "=============================================="
log "Uso antes:      ${SPACE_BEFORE}%"
log "Uso depois:     ${SPACE_AFTER}%"
log "Disponível:     ${AVAILABLE_AFTER}GB"
if ! ${DRY_RUN}; then
    RECOVERED=$((SPACE_BEFORE - SPACE_AFTER))
    log "Recuperado:     ~${RECOVERED}% de disco"
fi
log "Modo:           $(${DRY_RUN} && echo 'DRY-RUN' || echo 'EXECUTE')"
log "=============================================="

if ${DRY_RUN}; then
    log ""
    log ">>> Nenhuma alteração foi feita. Rode com --execute para aplicar. <<<"
fi

exit 0
