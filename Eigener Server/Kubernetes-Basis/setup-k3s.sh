#!/usr/bin/env bash
#
# k3s-bootstrap.sh - k3s + Ingress-Controller (waehlbar) + optional cert-manager
#
# Versionsverhalten:
#   Default            -> latest stable wird zur Laufzeit aufgeloest
#   PINNED=yes         -> bekannt-gute Pins (Block unten) statt Aufloesung
#   Einzelne Variable  -> gewinnt immer, egal ob PINNED gesetzt ist
#   Aufloesung fehlgeschlagen (Rate-Limit/offline) -> Fallback auf Pin + Warnung
#
# Optionen (alle per Env, non-interactive tauglich):
#   INGRESS=traefik|nginx-f5|ingress-nginx|none
#   CERT_MANAGER=yes|no          ACME_EMAIL=...
#   INSTALL_K9S=yes|no           ACCEPT_EOL=yes   
#   PINNED=yes                   RESOLVE_ONLY=yes 
#   HELM_FORCE=yes              
#
# Versionen einzeln pinnen:
#   INSTALL_K3S_VERSION=v1.33.5+k3s1  HELM_VERSION=v4.2.3  K9S_VERSION=v0.51.0
#   CERT_MANAGER_VERSION=v1.20.2      NIC_CHART_VERSION=2.6.4
#
set -Eeuo pipefail

# --------------------------------------------------- bekannt-gute Pins (2026-07)
PIN_HELM="v4.2.3"
PIN_K9S="v0.51.0"
PIN_CERT_MANAGER="v1.20.2"
PIN_NIC_CHART="2.6.4"                        # -> NIC appVersion 5.5.4
PIN_INGRESS_NGINX="controller-v1.15.1"       # letzter Release, Projekt archiviert

# ------------------------------------------------------------------- Optionen
: "${INSTALL_K3S_CHANNEL:=stable}"
: "${INSTALL_K3S_VERSION:=}"
: "${HELM_VERSION:=}"
: "${K9S_VERSION:=}"
: "${CERT_MANAGER_VERSION:=}"
: "${NIC_CHART_VERSION:=}"
: "${INGRESS_NGINX_REF:=}"
: "${PINNED:=no}"
: "${RESOLVE_ONLY:=no}"
: "${HELM_FORCE:=no}"
: "${INGRESS:=}"
: "${CERT_MANAGER:=}"
: "${ACME_EMAIL:=}"
: "${INSTALL_K9S:=}"
: "${ACCEPT_EOL:=no}"
: "${ACME_SERVER_PROD:=https://acme-v02.api.letsencrypt.org/directory}"
: "${ACME_SERVER_STAGING:=https://acme-staging-v02.api.letsencrypt.org/directory}"

# -------------------------------------------------------------------- Helpers
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n'  "$*" >&2; exit 1; }

on_err() {
  local rc=$1 line=$2
  printf '\033[1;31m[x]\033[0m Abbruch: exit %s in Zeile %s\n' "$rc" "$line" >&2
  exit "$rc"
}
trap 'on_err $? $LINENO' ERR

TMPDIR_BOOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BOOT"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || die "Fehlendes Kommando: $1"; }

retry() {
  local tries=$1 delay=$2 i; shift 2
  for ((i = 1; i <= tries; i++)); do
    if "$@"; then return 0; fi
    sleep "$delay"
  done
  return 1
}

ask() {
  local ans
  if [[ ! -t 0 ]]; then printf '%s' "$2"; return 0; fi
  read -rp "$1" ans
  printf '%s' "${ans:-$2}"
}

# ------------------------------------------------------------ Versionsaufloesung
# Hoechster stabiler SemVer-Tag eines GitHub-Repos. Bewusst nicht releases/latest
gh_latest_tag() {
  local repo=$1 auth=() json
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  json="$(curl -fsSL --max-time 20 ${auth[@]+"${auth[@]}"} \
          "https://api.github.com/repos/${repo}/releases?per_page=50")" || return 1
  printf '%s' "$json" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"\(.*\)"$/\1/' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1 | grep .
}

# resolve <Anzeigename> <explizit> <Pin> <repo> -> setzt RESOLVED / RESOLVED_SRC
resolve() {
  local name=$1 explicit=$2 pin=$3 repo=$4 out
  if [[ -n "$explicit" ]]; then
    RESOLVED="$explicit"; RESOLVED_SRC="explizit"; return 0
  fi
  if [[ "$PINNED" == "yes" ]]; then
    RESOLVED="$pin"; RESOLVED_SRC="pin"; return 0
  fi
  if out="$(gh_latest_tag "$repo")"; then
    RESOLVED="$out"; RESOLVED_SRC="latest"; return 0
  fi
  warn "$name: Aufloesung ueber api.github.com fehlgeschlagen (Rate-Limit? offline?) - nutze Pin $pin"
  RESOLVED="$pin"; RESOLVED_SRC="fallback-pin"
}

# ------------------------------------------------------------------- Preflight
need curl; need tar; need sha256sum; need install; need getent; need sort
[[ "$(uname -s)" == "Linux" ]] || die "Nur Linux unterstuetzt."

if [[ $EUID -eq 0 ]]; then SUDO=""; else need sudo; SUDO="sudo"; fi

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Home von $TARGET_USER nicht gefunden."

case "$(uname -m)" in
  x86_64|amd64)  K9S_ARCH=amd64; HELM_ARCH=amd64 ;;
  aarch64|arm64) K9S_ARCH=arm64; HELM_ARCH=arm64 ;;
  armv7l|armv7)  K9S_ARCH=armv7; HELM_ARCH=arm   ;;
  *) die "Nicht unterstuetzte Architektur: $(uname -m)" ;;
esac

# --------------------------------------------------------------------- Auswahl
if [[ -z "$INGRESS" ]]; then
  cat <<'MENU'

Ingress-Controller waehlen:
  1) traefik        - k3s-Default, gepflegt, Ingress + Gateway API   [Empfehlung Homelab]
  2) nginx-f5       - F5/NGINX Inc. kubernetes-ingress (OSS), gepflegt, NGINX-Datenplane
  3) ingress-nginx  - Community-Controller, seit 03/2026 ARCHIVIERT/EOL, keine CVE-Fixes
  4) none           - kein Ingress-Controller
MENU
  case "$(ask 'Auswahl [1]: ' 1)" in
    1) INGRESS=traefik ;;
    2) INGRESS=nginx-f5 ;;
    3) INGRESS=ingress-nginx ;;
    4) INGRESS=none ;;
    *) die "Ungueltige Auswahl." ;;
  esac
fi
case "$INGRESS" in traefik|nginx-f5|ingress-nginx|none) ;; *) die "INGRESS ungueltig: $INGRESS" ;; esac

if [[ "$INGRESS" == "ingress-nginx" && "$ACCEPT_EOL" != "yes" ]]; then
  warn "kubernetes/ingress-nginx wurde am 2026-03-24 archiviert: keine Releases, keine Security-Patches."
  [[ "$(ask 'Trotzdem installieren? [j/N]: ' n)" =~ ^([jJ]|[yY])$ ]] || die "Abgebrochen."
fi

if [[ -z "$CERT_MANAGER" ]]; then
  [[ "$(ask 'cert-manager installieren? [J/n]: ' j)" =~ ^([jJ]|[yY])$ ]] && CERT_MANAGER=yes || CERT_MANAGER=no
fi
case "$CERT_MANAGER" in yes|no) ;; *) die "CERT_MANAGER ungueltig: $CERT_MANAGER" ;; esac

if [[ "$CERT_MANAGER" == "yes" && "$INGRESS" == "none" ]]; then
  warn "Ohne Ingress-Controller ist HTTP-01 nicht nutzbar - es werden keine ClusterIssuer angelegt (DNS-01 waere die Alternative)."
fi

if [[ "$CERT_MANAGER" == "yes" && "$INGRESS" != "none" && -z "$ACME_EMAIL" ]]; then
  ACME_EMAIL="$(ask 'E-Mail fuer Let'\''s Encrypt: ' '')"
fi
if [[ "$CERT_MANAGER" == "yes" && "$INGRESS" != "none" ]]; then
  [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Ungueltige E-Mail: '$ACME_EMAIL'"
fi

if [[ -z "$INSTALL_K9S" ]]; then
  [[ "$(ask 'k9s installieren? [J/n]: ' j)" =~ ^([jJ]|[yY])$ ]] && INSTALL_K9S=yes || INSTALL_K9S=no
fi

case "$INGRESS" in
  traefik)                INGRESS_CLASS=traefik ;;
  nginx-f5|ingress-nginx) INGRESS_CLASS=nginx ;;
  none)                   INGRESS_CLASS="" ;;
esac

# ------------------------------------------------------------------ Versionen
log "Versionen aufloesen"

if [[ -n "$INSTALL_K3S_VERSION" ]]; then
  K3S_SHOWN="$INSTALL_K3S_VERSION"; K3S_SRC="explizit"
else
  K3S_SHOWN="channel:${INSTALL_K3S_CHANNEL}"; K3S_SRC="channel (latest stable)"
  [[ "$PINNED" == "yes" ]] && warn "PINNED=yes: k3s bleibt auf Channel '${INSTALL_K3S_CHANNEL}'. Fuer echtes Pinning INSTALL_K3S_VERSION setzen."
fi

resolve helm "$HELM_VERSION" "$PIN_HELM" "helm/helm"
HELM_VER="$RESOLVED"; HELM_SRC="$RESOLVED_SRC"

if [[ "$INSTALL_K9S" == "yes" ]]; then
  resolve k9s "$K9S_VERSION" "$PIN_K9S" "derailed/k9s"
  K9S_VER="$RESOLVED"; K9S_SRC="$RESOLVED_SRC"
fi

if [[ "$CERT_MANAGER" == "yes" ]]; then
  # Chart-Version == Release-Tag bei cert-manager
  resolve cert-manager "$CERT_MANAGER_VERSION" "$PIN_CERT_MANAGER" "cert-manager/cert-manager"
  CM_VER="$RESOLVED"; CM_SRC="$RESOLVED_SRC"
fi

if [[ "$INGRESS" == "nginx-f5" ]]; then
  # Chart-Version != appVersion -> aus Chart.yaml des Release-Tags lesen
  NIC_APP="?"
  if [[ -n "$NIC_CHART_VERSION" ]]; then
    NIC_VER="$NIC_CHART_VERSION"; NIC_SRC="explizit"
  elif [[ "$PINNED" == "yes" ]]; then
    NIC_VER="$PIN_NIC_CHART"; NIC_SRC="pin"
  elif NIC_APP="$(gh_latest_tag nginx/kubernetes-ingress)" \
       && NIC_VER="$(curl -fsSL --max-time 20 \
            "https://raw.githubusercontent.com/nginx/kubernetes-ingress/${NIC_APP}/charts/nginx-ingress/Chart.yaml" \
            | awk '/^version:/{print $2; exit}' | grep .)"; then
    NIC_SRC="latest"
  else
    warn "F5 NIC: Aufloesung fehlgeschlagen - nutze Pin $PIN_NIC_CHART"
    NIC_VER="$PIN_NIC_CHART"; NIC_SRC="fallback-pin"; NIC_APP="?"
  fi
fi

if [[ "$INGRESS" == "ingress-nginx" ]]; then
  ING_REF="${INGRESS_NGINX_REF:-$PIN_INGRESS_NGINX}"
  if [[ -n "$INGRESS_NGINX_REF" ]]; then ING_SRC="explizit"; else ING_SRC="pin (EOL, kein latest)"; fi
fi

printf '\n  %-16s %-26s %s\n' "Komponente" "Version" "Quelle"
printf '  %-16s %-26s %s\n' "k3s"  "$K3S_SHOWN" "$K3S_SRC"
printf '  %-16s %-26s %s\n' "helm" "$HELM_VER"  "$HELM_SRC"
if [[ "$INSTALL_K9S" == "yes" ]]; then
  printf '  %-16s %-26s %s\n' "k9s" "$K9S_VER" "$K9S_SRC"
fi
if [[ "$INGRESS" == "nginx-f5" ]]; then
  printf '  %-16s %-26s %s\n' "F5 NIC chart" "$NIC_VER (app $NIC_APP)" "$NIC_SRC"
fi
if [[ "$INGRESS" == "ingress-nginx" ]]; then
  printf '  %-16s %-26s %s\n' "ingress-nginx" "$ING_REF" "$ING_SRC"
fi
if [[ "$CERT_MANAGER" == "yes" ]]; then
  printf '  %-16s %-26s %s\n' "cert-manager" "$CM_VER" "$CM_SRC"
fi
printf '\n'

if [[ "$RESOLVE_ONLY" == "yes" ]]; then
  log "RESOLVE_ONLY=yes - es wird nichts installiert"
  exit 0
fi

log "Plan: ingress=$INGRESS | cert-manager=$CERT_MANAGER | k9s=$INSTALL_K9S"

# ------------------------------------------------------------------------- k3s
K3S_EXEC=""
[[ "$INGRESS" != "traefik" ]] && K3S_EXEC="--disable traefik"

if systemctl is-active --quiet k3s 2>/dev/null; then
  log "k3s laeuft bereits - Installation wird uebersprungen"
else
  log "k3s installieren ($K3S_SHOWN)"
  # Installer nicht direkt in die Shell pipen: erst ablegen, dann ausfuehren (auditierbar)
  curl -sfL https://get.k3s.io -o "$TMPDIR_BOOT/k3s-install.sh"
  chmod +x "$TMPDIR_BOOT/k3s-install.sh"
  $SUDO env \
    INSTALL_K3S_CHANNEL="$INSTALL_K3S_CHANNEL" \
    INSTALL_K3S_VERSION="$INSTALL_K3S_VERSION" \
    INSTALL_K3S_EXEC="$K3S_EXEC" \
    "$TMPDIR_BOOT/k3s-install.sh"
fi

log "Kubeconfig nach $TARGET_HOME/.kube/config"
$SUDO install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0700 "$TARGET_HOME/.kube"
$SUDO install -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0600 /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
export KUBECONFIG="$TARGET_HOME/.kube/config"
export PATH="/usr/local/bin:$PATH"

need kubectl
log "Auf API-Server und Node warten"
api_ready()    { kubectl get --raw='/readyz' >/dev/null 2>&1; }
node_present() { [[ -n "$(kubectl get nodes -o name 2>/dev/null)" ]]; }

retry 30 5 api_ready || die "API-Server nicht erreichbar"
# /readyz meldet nur den API-Server. Das Node-Objekt registriert das kubelet erst
# Sekunden spaeter - ohne diese Schleife bricht 'kubectl wait --all' bei null
# passenden Objekten sofort mit "no matching resources found" ab.
retry 60 5 node_present || die "Kein Node registriert - 'journalctl -u k3s' pruefen"
kubectl wait --for=condition=Ready node --all --timeout=300s

# ------------------------------------------------------------------------ helm
if command -v helm >/dev/null 2>&1 && [[ "$HELM_FORCE" != "yes" ]]; then
  helm_have="$(helm version --short 2>/dev/null || echo unbekannt)"
  log "helm vorhanden: $helm_have"
  [[ "$helm_have" == "$HELM_VER"* ]] || warn "helm $helm_have != Ziel $HELM_VER - mit HELM_FORCE=yes ueberschreiben"
else
  log "helm $HELM_VER installieren"
  hf="helm-${HELM_VER}-linux-${HELM_ARCH}.tar.gz"
  curl -fsSLo "$TMPDIR_BOOT/$hf"        "https://get.helm.sh/${hf}"
  curl -fsSLo "$TMPDIR_BOOT/$hf.sha256" "https://get.helm.sh/${hf}.sha256sum"
  ( cd "$TMPDIR_BOOT" && sha256sum -c "$hf.sha256" ) || die "helm Checksumme ungueltig"
  tar -xzf "$TMPDIR_BOOT/$hf" -C "$TMPDIR_BOOT" "linux-${HELM_ARCH}/helm"
  $SUDO install -m 0755 "$TMPDIR_BOOT/linux-${HELM_ARCH}/helm" /usr/local/bin/helm
fi

# ------------------------------------------------------------------------- k9s
if [[ "$INSTALL_K9S" == "yes" ]]; then
  log "k9s $K9S_VER installieren"
  kf="k9s_Linux_${K9S_ARCH}.tar.gz"
  k9s_base="https://github.com/derailed/k9s/releases/download/${K9S_VER}"
  curl -fsSLo "$TMPDIR_BOOT/$kf" "${k9s_base}/${kf}"
  curl -fsSLo "$TMPDIR_BOOT/checksums.sha256" "${k9s_base}/checksums.sha256"
  ( cd "$TMPDIR_BOOT" && grep " ${kf}\$" checksums.sha256 | sha256sum -c - ) || die "k9s Checksumme ungueltig"
  tar -xzf "$TMPDIR_BOOT/$kf" -C "$TMPDIR_BOOT" k9s
  $SUDO install -m 0755 "$TMPDIR_BOOT/k9s" /usr/local/bin/k9s
fi

# --------------------------------------------------------------------- Ingress
case "$INGRESS" in
  traefik)
    log "Traefik (k3s-Bundle) - auf Deployment warten"
    retry 30 10 kubectl -n kube-system get deploy traefik >/dev/null
    kubectl -n kube-system rollout status deploy/traefik --timeout=300s
    ;;
  nginx-f5)
    log "F5 NGINX Ingress Controller installieren (Chart $NIC_VER)"
    helm upgrade --install nginx-ingress oci://ghcr.io/nginx/charts/nginx-ingress \
      --version "$NIC_VER" \
      --namespace nginx-ingress --create-namespace \
      --set controller.ingressClass.name=nginx \
      --set controller.ingressClass.setAsDefaultIngress=true \
      --set controller.service.type=LoadBalancer \
      --set controller.enableSnippets=false \
      --wait --timeout 10m
    ;;
  ingress-nginx)
    log "ingress-nginx $ING_REF installieren (EOL)"
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${ING_REF}/deploy/static/provider/cloud/deploy.yaml"
    retry 30 10 kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null
    kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
    ;;
  none)
    log "Kein Ingress-Controller installiert"
    ;;
esac

# ---------------------------------------------------------------- cert-manager
if [[ "$CERT_MANAGER" == "yes" ]]; then
  log "cert-manager $CM_VER installieren"
  helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "$CM_VER" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 10m
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s

  if [[ -n "$INGRESS_CLASS" ]]; then
    log "ClusterIssuer letsencrypt-staging / letsencrypt-prod anlegen (Class: $INGRESS_CLASS)"
    cat >"$TMPDIR_BOOT/issuers.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: ${ACME_SERVER_STAGING}
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          ingress:
            ingressClassName: ${INGRESS_CLASS}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: ${ACME_SERVER_PROD}
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: ${INGRESS_CLASS}
EOF
    # Webhook braucht nach dem Rollout noch Zeit fuer gueltige CA-Injection
    retry 12 10 kubectl apply -f "$TMPDIR_BOOT/issuers.yaml" \
      || die "ClusterIssuer konnten nicht angelegt werden (cert-manager Webhook?)"
    kubectl wait --for=condition=Ready clusterissuer/letsencrypt-staging --timeout=120s || \
      warn "letsencrypt-staging noch nicht Ready - 'kubectl describe clusterissuer letsencrypt-staging' pruefen"
  fi
fi

# --------------------------------------------------------------------- Summary
cat <<EOF

Fertig.
  kubeconfig   : $TARGET_HOME/.kube/config   (export KUBECONFIG=$TARGET_HOME/.kube/config)
  k3s          : $(k3s --version 2>/dev/null | head -1)
  Ingress      : $INGRESS${INGRESS_CLASS:+  (ingressClassName: $INGRESS_CLASS)}
  cert-manager : $CERT_MANAGER${CM_VER:+ $CM_VER}
$( [[ "$CERT_MANAGER" == "yes" && -n "$INGRESS_CLASS" ]] && cat <<'HINT'

  Erst mit letsencrypt-staging testen, dann auf letsencrypt-prod umstellen
  (LE-Rate-Limit: 5 Fehlversuche/Konto/Stunde, 50 Zertifikate/Domain/Woche).
  HTTP-01 setzt voraus: oeffentlicher DNS-Record + Port 80 von aussen erreichbar.
HINT
)
  Die aufgeloesten Versionen stehen oben in der Tabelle. Fuer einen
  reproduzierbaren Nachbau als Variablen setzen oder PINNED=yes verwenden.
EOF