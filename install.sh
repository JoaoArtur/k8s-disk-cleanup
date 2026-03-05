#!/usr/bin/env bash
#
# install-k8s-cleanup.sh — Auto-instalador do k8s-disk-cleanup
#
# Uso:
#   curl -sSL https://raw.githubusercontent.com/JoaoArtur/k8s-disk-cleanup/main/install.sh | sudo bash
#   # ou
#   sudo bash install-k8s-cleanup.sh
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Configuração
SCRIPT_URL="https://raw.githubusercontent.com/JoaoArtur/k8s-disk-cleanup/refs/heads/main/k8s-disk-cleanup.sh"
INSTALL_DIR="/opt/k8s-cleanup"
SCRIPT_PATH="${INSTALL_DIR}/k8s-disk-cleanup.sh"
LOG_PATH="/var/log/k8s-disk-cleanup.log"
CRON_SCHEDULE="0 3 * * *"
CRON_COMMENT="k8s-disk-cleanup"

# Variáveis de ambiente do cleanup (ajuste conforme necessário)
DISK_THRESHOLD="${DISK_THRESHOLD:-75}"
MAX_IMAGES_TO_PRUNE="${MAX_IMAGES_TO_PRUNE:-600}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"

# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Verificações iniciais
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
echo "  k8s-disk-cleanup — Instalador automático"
echo "═══════════════════════════════════════════════"
echo ""

if [[ $EUID -ne 0 ]]; then
    die "Execute como root: sudo bash $0"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Dependências: cron
# ─────────────────────────────────────────────────────────────────────────────

if command -v crontab &>/dev/null; then
    log "crontab já instalado"
else
    warn "crontab não encontrado. Instalando..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq cron
    elif command -v dnf &>/dev/null; then
        dnf install -y -q cronie
    elif command -v yum &>/dev/null; then
        yum install -y -q cronie
    elif command -v apk &>/dev/null; then
        apk add --no-cache dcron
    else
        die "Gerenciador de pacotes não suportado. Instale o cron manualmente."
    fi

    # Garante que o serviço está ativo
    if command -v systemctl &>/dev/null; then
        systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
    fi

    command -v crontab &>/dev/null || die "Falha ao instalar crontab"
    log "cron instalado e ativo"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Dependências: curl ou wget
# ─────────────────────────────────────────────────────────────────────────────

DOWNLOADER=""
if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
else
    warn "Nem curl nem wget encontrados. Instalando curl..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq curl
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl
    elif command -v yum &>/dev/null; then
        yum install -y -q curl
    fi
    command -v curl &>/dev/null || die "Falha ao instalar curl"
    DOWNLOADER="curl"
    log "curl instalado"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Download do script
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "${INSTALL_DIR}"

log "Baixando k8s-disk-cleanup.sh..."

if [[ "${DOWNLOADER}" == "curl" ]]; then
    curl -fsSL "${SCRIPT_URL}" -o "${SCRIPT_PATH}.tmp"
elif [[ "${DOWNLOADER}" == "wget" ]]; then
    wget -q "${SCRIPT_URL}" -O "${SCRIPT_PATH}.tmp"
fi

# Validação básica: verifica se o download é um shell script
if ! head -1 "${SCRIPT_PATH}.tmp" | grep -q "^#!/"; then
    rm -f "${SCRIPT_PATH}.tmp"
    die "Download inválido — o arquivo não parece ser um shell script"
fi

mv "${SCRIPT_PATH}.tmp" "${SCRIPT_PATH}"
chmod 750 "${SCRIPT_PATH}"

log "Script instalado em ${SCRIPT_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Configuração do crontab
# ─────────────────────────────────────────────────────────────────────────────

CRON_LINE="${CRON_SCHEDULE} DISK_THRESHOLD=${DISK_THRESHOLD} MAX_IMAGES_TO_PRUNE=${MAX_IMAGES_TO_PRUNE} LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS} ${SCRIPT_PATH} --execute >> ${LOG_PATH} 2>&1 # ${CRON_COMMENT}"

# Remove entrada anterior se existir (evita duplicatas)
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "${EXISTING_CRON}" | grep -q "${CRON_COMMENT}"; then
    warn "Cron anterior encontrado. Substituindo..."
    EXISTING_CRON=$(echo "${EXISTING_CRON}" | grep -v "${CRON_COMMENT}")
fi

# Instala a nova entrada
if [[ -z "${EXISTING_CRON}" ]]; then
    echo "${CRON_LINE}" | crontab -
else
    (echo "${EXISTING_CRON}"; echo "${CRON_LINE}") | crontab -
fi

log "Crontab configurado (diário às 03:00)"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Cria logrotate para o log do cleanup
# ─────────────────────────────────────────────────────────────────────────────

if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/k8s-disk-cleanup <<EOF
${LOG_PATH} {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF
    log "Logrotate configurado para ${LOG_PATH}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Resumo
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════"
echo "  Instalação concluída"
echo "═══════════════════════════════════════════════"
echo ""
echo "  Script:     ${SCRIPT_PATH}"
echo "  Log:        ${LOG_PATH}"
echo "  Cron:       ${CRON_SCHEDULE} (diário às 03:00)"
echo "  Threshold:  ${DISK_THRESHOLD}%"
echo "  Max prune:  ${MAX_IMAGES_TO_PRUNE} imagens"
echo "  Retenção:   ${LOG_RETENTION_DAYS} dias"
echo ""
echo "  Comandos úteis:"
echo "    Dry-run:    sudo ${SCRIPT_PATH}"
echo "    Executar:   sudo ${SCRIPT_PATH} --execute"
echo "    Ver cron:   crontab -l | grep ${CRON_COMMENT}"
echo "    Ver log:    tail -f ${LOG_PATH}"
echo "    Desinstalar: crontab -l | grep -v '${CRON_COMMENT}' | crontab -"
echo ""
