#!/usr/bin/env bash
set -Eeuo pipefail

APP="GAOMON S620 Driver Manager"
MODEL="S620"
GAOMON_PAGE="https://download.gaomon.net/plus/list.php?cateId=12&system=linux&tid=9&type=0"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/gaomon-s620"
VERSION_FILE="$STATE_DIR/installed-version"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/gaomon-s620"

GUI=0
GUI_FIFO=""
GUI_PID=""

gui_available() {
  command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]
}

gui_info()  { zenity --info --title="$APP" --width=460 --text="$1" 2>/dev/null || true; }
gui_error() { zenity --error --title="$APP" --width=520 --text="$1" 2>/dev/null || true; }

gui_confirm() {
  zenity --question --title="$APP" --width=500 --text="$1" 2>/dev/null
}

gui_start_progress() {
  GUI_FIFO="$(mktemp -u)"
  mkfifo "$GUI_FIFO"
  zenity --progress --title="$APP" \
    --text="Preparando..." --percentage=0 --width=560 \
    --auto-close --no-cancel <"$GUI_FIFO" &
  GUI_PID=$!
  exec 9>"$GUI_FIFO"
}

gui_progress() {
  local pct="$1"; shift
  [[ "$GUI" -eq 1 ]] || return 0
  printf '%s\n# %s\n' "$pct" "$*" >&9 || true
}

gui_end_progress() {
  [[ "$GUI" -eq 1 ]] || return 0
  printf '100\n# Concluído\n' >&9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
  [[ -n "$GUI_PID" ]] && wait "$GUI_PID" 2>/dev/null || true
  [[ -n "$GUI_FIFO" ]] && rm -f "$GUI_FIFO"
  GUI_FIFO=""
  GUI_PID=""
}

gui_log_window() {
  local logfile="$1" title="${2:-$APP}"
  zenity --text-info --title="$title" --width=760 --height=500 \
    --filename="$logfile" --ok-label="Fechar" 2>/dev/null || true
}

run_gui_action() {
  local action="$1"
  gui_available || die "Modo gráfico solicitado, mas Zenity ou uma sessão gráfica não está disponível."

  local logfile
  logfile="$(mktemp)"
  gui_start_progress

  # Run the normal action while preserving a readable log.
  {
    case "$action" in
      install)
        gui_progress 5 "Verificando Fedora e arquitetura..."
        require_fedora
        gui_progress 12 "Verificando dependências..."
        install_dependencies
        gui_progress 25 "Consultando o site oficial da GAOMON..."
        discover_driver
        gui_progress 40 "Baixando driver v$AVAILABLE_VERSION..."
        download_driver
        gui_progress 62 "Validando e extraindo pacote..."
        extract_driver
        gui_progress 72 "Identificando instalador oficial..."
        find_installer
        gui_progress 82 "Instalando driver..."
        run_vendor_installer
        gui_progress 94 "Criando atalhos..."
        create_shortcuts
        ;;
      check)
        gui_progress 10 "Verificando sistema..."
        require_fedora
        gui_progress 30 "Verificando dependências..."
        install_dependencies
        gui_progress 60 "Consultando a GAOMON..."
        discover_driver
        local current
        current="$(installed_version)"
        echo "Versão instalada: ${current:-não identificada}"
        echo "Versão disponível: $AVAILABLE_VERSION"
        ;;
      status)
        gui_progress 30 "Verificando instalação..."
        status_cmd
        ;;
      update)
        require_fedora
        install_dependencies
        gui_progress 25 "Consultando a GAOMON..."
        discover_driver
        local current
        current="$(installed_version)"
        if [[ -n "$current" && "$current" == "$AVAILABLE_VERSION" ]]; then
          echo "O driver já está atualizado: v$current"
        else
          gui_end_progress
          if ! gui_confirm "Instalada: ${current:-desconhecida}\nDisponível: $AVAILABLE_VERSION\n\nDeseja atualizar o driver?"; then
            rm -f "$logfile"
            exit 0
          fi
          gui_start_progress
          gui_progress 35 "Baixando driver v$AVAILABLE_VERSION..."
          download_driver
          gui_progress 60 "Extraindo e validando..."
          extract_driver
          find_installer
          gui_progress 80 "Instalando atualização..."
          run_vendor_installer
          gui_progress 94 "Atualizando atalhos..."
          create_shortcuts
        fi
        ;;
      uninstall)
        require_fedora
        local uninstaller
        uninstaller="$(find_vendor_uninstaller)"
        [[ -n "$uninstaller" ]] || die "Não encontrei com segurança o desinstalador oficial instalado."
        gui_end_progress
        if ! gui_confirm "Deseja realmente remover o driver GAOMON?\n\n$uninstaller"; then
          rm -f "$logfile"
          exit 0
        fi
        gui_start_progress
        gui_progress 35 "Executando desinstalador oficial..."
        chmod +x "$uninstaller" 2>/dev/null || true
        (cd "$(dirname "$uninstaller")" && sudo "./$(basename "$uninstaller")")
        gui_progress 80 "Removendo atalhos..."
        rm -f "$VERSION_FILE"
        rm -f "$HOME/.local/share/applications"/gaomon-s620-{check,update,uninstall}.desktop
        command -v update-desktop-database >/dev/null &&
          update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
        ;;
      *) die "Ação gráfica desconhecida: $action" ;;
    esac
  } > >(tee -a "$logfile") 2> >(tee -a "$logfile" >&2)

  gui_end_progress
  gui_info "Operação concluída.\n\nUse “Mostrar log” no terminal se precisar diagnosticar algum problema."
  gui_log_window "$logfile" "$APP - Log"
  rm -f "$logfile"
}

log()  { printf '\033[1;34m[GAOMON]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

require_fedora() {
  [[ -r /etc/os-release ]] || die "Não foi possível identificar a distribuição."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "fedora" ]] || die "Este instalador foi feito para Fedora. Detectado: ${PRETTY_NAME:-desconhecido}"
  [[ "$(uname -m)" == "x86_64" ]] || die "O driver oficial consultado é x86_64. Arquitetura detectada: $(uname -m)"
}

install_dependencies() {
  local pkgs=(curl tar xz gzip coreutils grep sed gawk findutils desktop-file-utils zenity)
  local missing=()
  for p in "${pkgs[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if ((${#missing[@]})); then
    log "Instalando dependências: ${missing[*]}"
    sudo dnf install -y "${missing[@]}"
  else
    ok "Dependências básicas já instaladas."
  fi
}

fetch_page() {
  curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
    -A "Mozilla/5.0 gaomon-s620-fedora-installer" "$GAOMON_PAGE"
}

discover_driver() {
  local html filename version url
  log "Consultando o site oficial da GAOMON..."
  html="$(fetch_page)" || die "Não foi possível consultar a página oficial."

  filename="$(printf '%s' "$html" |
    grep -oE 'GaomonTablet_LinuxDriver_v[0-9.]+\.x86_64\.tar\.xz' |
    sort -V | tail -n1 || true)"
  [[ -n "$filename" ]] || die "Nenhum .tar.xz Linux da S620 foi identificado. A página da GAOMON pode ter mudado."

  version="$(sed -E 's/.*_v([0-9.]+)\.x86_64\.tar\.xz/\1/' <<<"$filename")"

  # Primeiro tenta obter um href absoluto ou relativo que contenha exatamente o arquivo.
  url="$(printf '%s' "$html" |
    grep -oE 'href=["'\''][^"'\'']*GaomonTablet_LinuxDriver_v[0-9.]+\.x86_64\.tar\.xz[^"'\'']*["'\'']' |
    grep -F "$filename" | head -n1 |
    sed -E 's/^href=["'\''](.*)["'\'']$/\1/' || true)"

  # Alguns sites usam onclick/data-url em vez de href.
  if [[ -z "$url" ]]; then
    url="$(printf '%s' "$html" |
      grep -oE '(https?:)?//[^"'\'']*GaomonTablet_LinuxDriver_v[0-9.]+\.x86_64\.tar\.xz[^"'\'']*' |
      grep -F "$filename" | head -n1 || true)"
  fi

  [[ -n "$url" ]] || die "A versão $version foi encontrada, mas não consegui extrair com segurança a URL de download. Nada foi instalado."

  case "$url" in
    https://*) ;;
    http://*) warn "O site retornou HTTP; o download será recusado por segurança."; die "URL sem HTTPS: $url" ;;
    //*) url="https:${url}" ;;
    /*) url="https://download.gaomon.net${url}" ;;
    *) url="https://download.gaomon.net/plus/${url#./}" ;;
  esac

  case "$url" in
    https://download.gaomon.net/*|https://driver.gaomon.net/*)
      ;;
    *)
      die "URL de download fora dos hosts oficiais permitidos recusada: $url"
      ;;
  esac

  DRIVER_FILENAME="$filename"
  AVAILABLE_VERSION="$version"
  DRIVER_URL="$url"
  ok "Driver oficial encontrado: v$AVAILABLE_VERSION"
}

installed_version() {
  if [[ -s "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE"
    return
  fi

  # Melhor esforço caso o driver tenha sido instalado fora deste gerenciador.
  local v=""
  v="$(find /usr /opt -maxdepth 5 -type f \( -iname '*gaomon*' -o -iname '*tablet*' \) \
      -printf '%f\n' 2>/dev/null |
      grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1 || true)"
  printf '%s' "$v"
}

download_driver() {
  mkdir -p "$CACHE_DIR"
  DRIVER_PATH="$CACHE_DIR/$DRIVER_FILENAME"
  log "Baixando $DRIVER_FILENAME..."
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
    --proto '=https' --tlsv1.2 -o "$DRIVER_PATH.part" "$DRIVER_URL"
  mv "$DRIVER_PATH.part" "$DRIVER_PATH"

  [[ -s "$DRIVER_PATH" ]] || die "O arquivo baixado está vazio."
  xz -t "$DRIVER_PATH" || die "O download não é um arquivo XZ válido."
  tar -tJf "$DRIVER_PATH" >/dev/null || die "O download não é um TAR.XZ válido."
  ok "Pacote validado: $(du -h "$DRIVER_PATH" | awk '{print $1}')"
}

extract_driver() {
  WORK_DIR="$(mktemp -d)"
  tar -xJf "$DRIVER_PATH" -C "$WORK_DIR"

  # Recusa caminhos suspeitos antes de executar qualquer coisa.
  if tar -tJf "$DRIVER_PATH" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    die "Pacote contém caminhos inseguros."
  fi

  log "Conteúdo extraído e validado."
}

find_installer() {
  local candidates=()
  while IFS= read -r -d '' f; do candidates+=("$f"); done < <(
    find "$WORK_DIR" -maxdepth 4 -type f \
      \( -iname 'install.sh' -o -iname 'install' -o -iname '*install*.sh' \) -print0
  )

  ((${#candidates[@]})) || {
    warn "Não encontrei automaticamente o instalador interno."
    find "$WORK_DIR" -maxdepth 3 -type f -printf '  %P\n' | head -n 80
    die "Abortado sem executar arquivos desconhecidos como root."
  }

  # Prefere exatamente install.sh, depois install.
  INSTALLER=""
  local f
  for f in "${candidates[@]}"; do
    [[ "$(basename "$f")" == "install.sh" ]] && INSTALLER="$f" && break
  done
  [[ -n "$INSTALLER" ]] || INSTALLER="${candidates[0]}"
  ok "Instalador interno identificado: ${INSTALLER#$WORK_DIR/}"
}

run_vendor_installer() {
  log "Executando o instalador oficial da GAOMON..."
  chmod +x "$INSTALLER"
  (
    cd "$(dirname "$INSTALLER")"
    sudo "./$(basename "$INSTALLER")"
  )
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$AVAILABLE_VERSION" > "$VERSION_FILE"
  ok "Versão v$AVAILABLE_VERSION registrada."
}

find_vendor_uninstaller() {
  find /usr /opt -type f \( -iname 'uninstall.sh' -o -iname 'uninstall' -o -iname '*gaomon*uninstall*' \) \
    2>/dev/null | head -n1 || true
}

create_shortcuts() {
  local appdir="$HOME/.local/share/applications"
  local self
  self="$(readlink -f "$0")"
  mkdir -p "$appdir"

  cat > "$appdir/gaomon-s620-check.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GAOMON S620 - Verificar atualização
Comment=Verifica a versão mais recente do driver oficial
Exec="$self" --gui check
Terminal=false
Categories=Utility;
EOF

  cat > "$appdir/gaomon-s620-update.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GAOMON S620 - Atualizar driver
Comment=Atualiza o driver oficial da GAOMON S620
Exec="$self" --gui update
Terminal=false
Categories=Utility;
EOF

  cat > "$appdir/gaomon-s620-uninstall.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GAOMON S620 - Desinstalar driver
Comment=Remove o driver oficial da GAOMON
Exec="$self" --gui uninstall
Terminal=false
Categories=Utility;
EOF

  chmod +x "$appdir"/gaomon-s620-{check,update,uninstall}.desktop
  command -v update-desktop-database >/dev/null && update-desktop-database "$appdir" >/dev/null 2>&1 || true
  ok "Atalhos criados no menu de aplicativos."
}

status_cmd() {
  require_fedora
  local current
  current="$(installed_version)"
  printf '%s\n' "$APP"
  printf 'Fedora:       %s\n' "$(. /etc/os-release; printf '%s' "$PRETTY_NAME")"
  printf 'Arquitetura: %s\n' "$(uname -m)"
  printf 'Instalada:    %s\n' "${current:-não identificada}"
  if lsusb 2>/dev/null | grep -qiE 'gaomon|256c'; then
    printf 'Tablet USB:   detectado\n'
  else
    printf 'Tablet USB:   não identificado pelo teste básico\n'
  fi
}

check_cmd() {
  require_fedora
  install_dependencies
  discover_driver
  local current
  current="$(installed_version)"
  printf 'Instalada:   %s\n' "${current:-não identificada}"
  printf 'Disponível:  %s\n' "$AVAILABLE_VERSION"
  if [[ -n "$current" && "$current" == "$AVAILABLE_VERSION" ]]; then
    ok "Você já está na versão identificada como atual."
  elif [[ -n "$current" ]]; then
    log "Há diferença entre a versão registrada e a disponível."
  else
    log "Nenhuma versão instalada foi registrada por este gerenciador."
  fi
}

install_cmd() {
  require_fedora
  install_dependencies
  discover_driver
  download_driver
  extract_driver
  find_installer
  run_vendor_installer
  create_shortcuts
  ok "Instalação concluída."
}

update_cmd() {
  require_fedora
  install_dependencies
  discover_driver
  local current
  current="$(installed_version)"
  if [[ -n "$current" && "$current" == "$AVAILABLE_VERSION" ]]; then
    ok "Driver já está atualizado: v$current"
    exit 0
  fi
  printf 'Instalada:  %s\nDisponível: %s\n' "${current:-desconhecida}" "$AVAILABLE_VERSION"
  read -r -p "Continuar com a atualização? [s/N] " ans
  [[ "${ans,,}" == "s" || "${ans,,}" == "sim" ]] || die "Atualização cancelada."
  download_driver
  extract_driver
  find_installer
  run_vendor_installer
  create_shortcuts
  ok "Atualização concluída."
}

uninstall_cmd() {
  require_fedora
  local uninstaller
  uninstaller="$(find_vendor_uninstaller)"
  [[ -n "$uninstaller" ]] || die "Não encontrei com segurança o desinstalador oficial instalado. Nada foi removido."

  printf 'Desinstalador encontrado: %s\n' "$uninstaller"
  read -r -p "Deseja realmente remover o driver GAOMON? [s/N] " ans
  [[ "${ans,,}" == "s" || "${ans,,}" == "sim" ]] || die "Desinstalação cancelada."

  chmod +x "$uninstaller" 2>/dev/null || true
  (
    cd "$(dirname "$uninstaller")"
    sudo "./$(basename "$uninstaller")"
  )

  rm -f "$VERSION_FILE"
  rm -f "$HOME/.local/share/applications"/gaomon-s620-{check,update,uninstall}.desktop
  command -v update-desktop-database >/dev/null &&
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  ok "Desinstalação solicitada ao desinstalador oficial."
}

usage() {
  cat <<EOF
$APP

Uso CLI (padrão):
  $0                 Instala o driver oficial
  $0 check           Verifica versão disponível
  $0 update          Atualiza o driver
  $0 status          Mostra o estado local
  $0 uninstall       Desinstala usando o desinstalador oficial
  $0 reinstall       Reinstala o driver

Modo gráfico opcional:
  $0 --gui
  $0 --gui check
  $0 --gui update
  $0 --gui status
  $0 --gui uninstall
  $0 --gui reinstall

A execução normal permanece sempre no terminal.
EOF
}

if [[ "${1:-}" == "--gui" ]]; then
  GUI=1
  shift
  action="${1:-install}"
  [[ "$action" == "reinstall" ]] && action="install"
  run_gui_action "$action"
  exit 0
fi

case "${1:-install}" in
  install)    install_cmd ;;
  check)      check_cmd ;;
  update)     update_cmd ;;
  status)     status_cmd ;;
  uninstall) uninstall_cmd ;;
  reinstall) install_cmd ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
