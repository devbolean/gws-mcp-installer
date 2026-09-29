#!/usr/bin/env bash
# =============================================================================
# BOLÉAN : installateur du connecteur Google Workspace pour Claude
#
# Déploie le serveur open source workspace-mcp (taylorwilsdon/google_workspace_mcp)
# dans le projet Google Cloud D'UN CLIENT, sur Cloud Run :
#   - aucun serveur à louer ni à patcher (Cloud Run s'éteint quand personne ne s'en sert)
#   - app OAuth « Interne » : aucune vérification Google, réservée au domaine du client
#   - jetons Gmail/Drive des employés stockés dans LE bucket du client, pas chez BOLÉAN
#
# Conçu pour Cloud Shell (gcloud déjà authentifié). Idempotent : on peut le
# relancer sans danger, il saute ce qui existe déjà. Relancer avec --version
# pour mettre à jour.
#
# Usage :
#   bash install.sh --project <PROJECT_ID> [--region northamerica-northeast1]
#                [--version v1.30.0] [--tool-tier core|extended|complete]
#                [--min-instances 0] [--client-id <ID>] [--rebuild] [--reset-oauth]
#                [--yes]
#   Secret OAuth non interactif : exporter GWS_OAUTH_CLIENT_SECRET avant l'appel.
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Valeurs par défaut (à ajuster ici quand on valide une nouvelle version)
# --------------------------------------------------------------------------- #
UPSTREAM_REPO="https://github.com/taylorwilsdon/google_workspace_mcp.git"
VERSION="v1.30.0"                      # version upstream validée par BOLÉAN
REGION="northamerica-northeast1"      # Montréal : données au Canada (Loi 25)
SERVICE="gws-mcp"
TOOL_TIER=""                           # vide = tous les outils (comme chez BOLÉAN)
MIN_INSTANCES="0"
PROJECT=""
CLIENT_ID="${GWS_OAUTH_CLIENT_ID:-}"
REBUILD=0
RESET_OAUTH=0
ASSUME_YES=0

RUN_SA_NAME="gws-mcp-run"
BUILD_SA_NAME="gws-mcp-build"
AR_REPO="gws-mcp"
SECRET_CLIENT_ID="gws-mcp-oauth-client-id"
SECRET_CLIENT_SECRET="gws-mcp-oauth-client-secret"
SECRET_JWT="gws-mcp-jwt-signing-key"
CLAUDE_REDIRECTS="https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback"
APP_UID="1000"                         # uid de l'utilisateur « app » du Dockerfile upstream

# --------------------------------------------------------------------------- #
# Affichage
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi
step() { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '%s  ✓ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s  ! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%s  ✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
trap 'die "Échec à la ligne $LINENO (commande : $BASH_COMMAND). Corriger puis relancer : le script reprend où il était."' ERR

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --------------------------------------------------------------------------- #
# Arguments
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --version)       VERSION="$2"; shift 2 ;;
    --tool-tier)     TOOL_TIER="$2"; shift 2 ;;
    --min-instances) MIN_INSTANCES="$2"; shift 2 ;;
    --client-id)     CLIENT_ID="$2"; shift 2 ;;
    --rebuild)       REBUILD=1; shift ;;
    --reset-oauth)   RESET_OAUTH=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage 0 ;;
    *) warn "Argument inconnu : $1"; usage 1 ;;
  esac
done

case "$TOOL_TIER" in ""|core|extended|complete) ;; *) die "--tool-tier doit être core, extended ou complete." ;; esac
[[ "$MIN_INSTANCES" =~ ^[0-9]+$ ]] || die "--min-instances doit être un entier."

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local answer; read -r -p "  $1 [o/N] " answer
  [[ "$answer" =~ ^[oOyY]$ ]]
}

# Réessaie une commande (propagation IAM, API fraîchement activée, etc.)
retry() {
  local n=0 max="${RETRY_MAX:-6}" delay=10
  until "$@"; do
    n=$((n + 1)); [[ $n -ge $max ]] && return 1
    warn "Nouvel essai dans ${delay}s ($n/$max)..."; sleep "$delay"
  done
}

# --------------------------------------------------------------------------- #
# 1. Vérifications préalables
# --------------------------------------------------------------------------- #
step "1/9 Vérifications préalables"
for bin in gcloud git openssl curl; do command -v "$bin" >/dev/null || die "Outil manquant : $bin (utiliser Cloud Shell)."; done

ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
[[ -n "$ACCOUNT" ]] || die "gcloud n'est pas authentifié. Lancer : gcloud auth login"
ok "Compte gcloud : $ACCOUNT"

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  [[ -n "$PROJECT" ]] || { read -r -p "  ID du projet GCP du client : " PROJECT; }
fi
[[ -n "$PROJECT" ]] || die "Projet GCP requis (--project)."

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null)" \
  || die "Projet « $PROJECT » introuvable ou inaccessible avec $ACCOUNT."
ok "Projet : $PROJECT (numéro $PROJECT_NUMBER)"

BILLING="$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
case "$BILLING" in
  True|true) ok "Facturation activée (requise par Cloud Run; l'usage attendu reste dans le palier gratuit)" ;;
  unknown)   warn "Impossible de vérifier la facturation (droits billing.viewer manquants). On continue." ;;
  *)         die "La facturation n'est pas activée sur $PROJECT. L'activer : https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT" ;;
esac

SERVICE_URL="https://${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
REDIRECT_URI="${SERVICE_URL}/oauth2callback"
MCP_URL="${SERVICE_URL}/mcp"
BUCKET="${PROJECT}-gws-mcp-data"
RUN_SA="${RUN_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
BUILD_SA="${BUILD_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${AR_REPO}/workspace-mcp:${VERSION}"

cat <<EOF
  Région          : $REGION
  Version         : $VERSION
  URL du service  : $SERVICE_URL
  URL connecteur  : $MCP_URL
  Bucket données  : gs://$BUCKET
EOF
confirm "On déploie avec ces paramètres?" || die "Annulé."

gc() { gcloud --project "$PROJECT" --quiet "$@"; }

# --------------------------------------------------------------------------- #
# 2. APIs
# --------------------------------------------------------------------------- #
step "2/9 Activation des APIs (1 à 2 minutes la première fois)"
gc services enable \
  run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com storage.googleapis.com iam.googleapis.com \
  gmail.googleapis.com drive.googleapis.com calendar-json.googleapis.com \
  docs.googleapis.com sheets.googleapis.com slides.googleapis.com \
  forms.googleapis.com tasks.googleapis.com people.googleapis.com \
  chat.googleapis.com script.googleapis.com
ok "APIs activées"

# --------------------------------------------------------------------------- #
# 3. Client OAuth (seule étape manuelle : Google n'offre aucune API pour la créer)
# --------------------------------------------------------------------------- #
step "3/9 Client OAuth Google"
secret_exists() { gc secrets describe "$1" >/dev/null 2>&1; }
put_secret() { # nom, valeur (lue sur stdin)
  if secret_exists "$1"; then
    gc secrets versions add "$1" --data-file=- >/dev/null
  else
    gc secrets create "$1" --replication-policy=user-managed --locations="$REGION" \
      --labels=app=gws-mcp,managed-by=bolean --data-file=- >/dev/null
  fi
}

if secret_exists "$SECRET_CLIENT_SECRET" && secret_exists "$SECRET_CLIENT_ID" && [[ $RESET_OAUTH -eq 0 ]]; then
  ok "Client OAuth déjà enregistré dans Secret Manager (--reset-oauth pour le remplacer)"
else
  cat <<EOF

  ${B}Action manuelle (3 minutes), dans la console Google Cloud du client :${N}

  a) Image de marque : ${C}https://console.cloud.google.com/auth/branding?project=${PROJECT}${N}
     Nom de l'app : « Claude - Google Workspace »
     Courriel d'assistance : un admin du client

  b) Audience : ${C}https://console.cloud.google.com/auth/audience?project=${PROJECT}${N}
     Type d'utilisateur : ${B}Interne${N}  (aucune vérification Google, domaine du client seulement)

  c) Clients > Créer : ${C}https://console.cloud.google.com/auth/clients/create?project=${PROJECT}${N}
     Type : Application Web
     Nom : gws-mcp
     URI de redirection autorisé (copier exactement) :
       ${B}${REDIRECT_URI}${N}
     Créer, puis copier l'ID client et le code secret ci-dessous.

EOF
  if [[ -z "$CLIENT_ID" ]]; then read -r -p "  ID client OAuth : " CLIENT_ID; fi
  CLIENT_ID="$(printf '%s' "$CLIENT_ID" | tr -d '[:space:]')"
  [[ "$CLIENT_ID" =~ ^[0-9]+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$ ]] \
    || die "ID client invalide (attendu : 123...-abc.apps.googleusercontent.com)."

  CLIENT_SECRET="${GWS_OAUTH_CLIENT_SECRET:-}"
  if [[ -z "$CLIENT_SECRET" ]]; then read -r -s -p "  Code secret du client (masqué) : " CLIENT_SECRET; echo; fi
  CLIENT_SECRET="$(printf '%s' "$CLIENT_SECRET" | tr -d '[:space:]')"
  [[ -n "$CLIENT_SECRET" ]] || die "Code secret vide."
  [[ "$CLIENT_SECRET" == GOCSPX-* ]] || warn "Le code secret ne commence pas par GOCSPX- : vérifier le copier-coller."

  printf '%s' "$CLIENT_ID" | put_secret "$SECRET_CLIENT_ID"
  printf '%s' "$CLIENT_SECRET" | put_secret "$SECRET_CLIENT_SECRET"
  unset CLIENT_SECRET GWS_OAUTH_CLIENT_SECRET
  ok "Client OAuth enregistré dans Secret Manager ($REGION)"
fi

if secret_exists "$SECRET_JWT"; then
  ok "Clé de signature JWT déjà présente"
else
  openssl rand -base64 48 | tr -d '\n' | put_secret "$SECRET_JWT"
  ok "Clé de signature JWT générée"
fi

# --------------------------------------------------------------------------- #
# 4. Bucket de données (jetons des employés, chiffrés au repos par Google)
# --------------------------------------------------------------------------- #
step "4/9 Bucket de données"
if gcloud storage buckets describe "gs://$BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
  ok "gs://$BUCKET existe déjà"
else
  gcloud storage buckets create "gs://$BUCKET" --project "$PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention --quiet >/dev/null
  gcloud storage buckets update "gs://$BUCKET" --update-labels=app=gws-mcp,managed-by=bolean --quiet >/dev/null
  ok "gs://$BUCKET créé (privé, $REGION)"
fi

# --------------------------------------------------------------------------- #
# 5. Comptes de service et permissions minimales
# --------------------------------------------------------------------------- #
step "5/9 Comptes de service"
ensure_sa() { # nom, description
  if gc iam service-accounts describe "$1@${PROJECT}.iam.gserviceaccount.com" >/dev/null 2>&1; then
    ok "$1 existe déjà"
  else
    gc iam service-accounts create "$1" --display-name="$2" >/dev/null
    ok "$1 créé"
  fi
}
ensure_sa "$RUN_SA_NAME"   "Connecteur Google Workspace (exécution Cloud Run)"
ensure_sa "$BUILD_SA_NAME" "Connecteur Google Workspace (build de l'image)"

for s in "$SECRET_CLIENT_ID" "$SECRET_CLIENT_SECRET" "$SECRET_JWT"; do
  retry gc secrets add-iam-policy-binding "$s" --member="serviceAccount:$RUN_SA" \
    --role=roles/secretmanager.secretAccessor >/dev/null
done
retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --project "$PROJECT" \
  --member="serviceAccount:$RUN_SA" --role=roles/storage.objectUser --quiet >/dev/null
for role in roles/cloudbuild.builds.builder roles/logging.logWriter; do
  retry gc projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$BUILD_SA" \
    --role="$role" --condition=None >/dev/null
done
ok "Permissions appliquées (secrets et bucket pour l'exécution, build pour la construction)"

# --------------------------------------------------------------------------- #
# 6. Dépôt d'images
# --------------------------------------------------------------------------- #
step "6/9 Dépôt Artifact Registry"
if gc artifacts repositories describe "$AR_REPO" --location="$REGION" >/dev/null 2>&1; then
  ok "Dépôt $AR_REPO existe déjà"
else
  gc artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" \
    --description="Images du connecteur Google Workspace (BOLÉAN)" >/dev/null
  ok "Dépôt $AR_REPO créé"
fi
retry gc artifacts repositories add-iam-policy-binding "$AR_REPO" --location="$REGION" \
  --member="serviceAccount:$BUILD_SA" --role=roles/artifactregistry.writer >/dev/null

# --------------------------------------------------------------------------- #
# 7. Construction de l'image (version upstream épinglée, aucun fork à maintenir)
# --------------------------------------------------------------------------- #
step "7/9 Image $VERSION"
if [[ $REBUILD -eq 0 ]] && gc artifacts docker images describe "$IMAGE" >/dev/null 2>&1; then
  ok "Image déjà construite (--rebuild pour forcer)"
else
  WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT
  git clone --quiet --depth 1 --branch "$VERSION" "$UPSTREAM_REPO" "$WORKDIR/src" \
    || die "Version $VERSION introuvable sur $UPSTREAM_REPO."
  cat > "$WORKDIR/cloudbuild.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: ["build", "-t", "\${_IMAGE}", "."]
images: ["\${_IMAGE}"]
serviceAccount: "projects/${PROJECT}/serviceAccounts/${BUILD_SA}"
options:
  logging: CLOUD_LOGGING_ONLY
timeout: 1200s
EOF
  echo "  Construction en cours (3 à 5 minutes)..."
  RETRY_MAX=2 retry gc builds submit "$WORKDIR/src" --config="$WORKDIR/cloudbuild.yaml" \
    --substitutions=_IMAGE="$IMAGE" >/dev/null
  ok "Image construite : $IMAGE"
fi

# --------------------------------------------------------------------------- #
# 8. Déploiement Cloud Run
# --------------------------------------------------------------------------- #
step "8/9 Déploiement Cloud Run"
ENV_VARS="^|^MCP_ENABLE_OAUTH21=true"
ENV_VARS+="|WORKSPACE_EXTERNAL_URL=${SERVICE_URL}"
ENV_VARS+="|GOOGLE_OAUTH_REDIRECT_URI=${REDIRECT_URI}"
ENV_VARS+="|WORKSPACE_MCP_CREDENTIALS_DIR=/data/credentials"
ENV_VARS+="|WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND=disk"
ENV_VARS+="|WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY=/data/oauth-proxy"
ENV_VARS+="|WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS=${CLAUDE_REDIRECTS}"
ENV_VARS+="|WORKSPACE_MCP_BRAND_NAME=Google Workspace"
[[ -n "$TOOL_TIER" ]] && ENV_VARS+="|WORKSPACE_MCP_TOOL_TIER=${TOOL_TIER}"

# shellcheck disable=SC2054  # les virgules font partie des valeurs gcloud
DEPLOY_ARGS=(
  run deploy "$SERVICE"
  --image="$IMAGE" --region="$REGION"
  --service-account="$RUN_SA"
  --execution-environment=gen2
  --cpu=1 --memory=1Gi --cpu-boost
  --min-instances="$MIN_INSTANCES" --max-instances=1 --concurrency=80 --timeout=3600
  "--add-volume=name=data,type=cloud-storage,bucket=${BUCKET},mount-options=uid=${APP_UID};gid=${APP_UID}"
  --add-volume-mount=volume=data,mount-path=/data
  "--set-env-vars=${ENV_VARS}"
  "--set-secrets=GOOGLE_OAUTH_CLIENT_ID=${SECRET_CLIENT_ID}:latest,GOOGLE_OAUTH_CLIENT_SECRET=${SECRET_CLIENT_SECRET}:latest,FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY=${SECRET_JWT}:latest"
  --labels=app=gws-mcp,managed-by=bolean,upstream-version="${VERSION//./-}"
)
# Accès public requis (Claude appelle le serveur depuis Internet; la protection est
# l'OAuth Google du serveur). --no-invoker-iam-check contourne la politique
# d'organisation « partage restreint au domaine » qui bloque allUsers sur les
# organisations Workspace récentes.
if ! gc "${DEPLOY_ARGS[@]}" --no-invoker-iam-check; then
  warn "--no-invoker-iam-check refusé; nouvel essai avec --allow-unauthenticated."
  gc "${DEPLOY_ARGS[@]}" --allow-unauthenticated
fi
ACTUAL_URL="$(gc run services describe "$SERVICE" --region="$REGION" --format='value(metadata.annotations."run.googleapis.com/urls")' 2>/dev/null || true)"
if [[ -n "$ACTUAL_URL" && "$ACTUAL_URL" != *"$SERVICE_URL"* ]]; then
  warn "URL inattendue ($ACTUAL_URL). Vérifier que l'URI de redirection OAuth correspond."
fi
ok "Service déployé"

# --------------------------------------------------------------------------- #
# 9. Vérifications
# --------------------------------------------------------------------------- #
step "9/9 Vérifications"
health_ok() { curl -fsS --max-time 20 "$SERVICE_URL/health" >/dev/null 2>&1; }
retry health_ok || die "Le service ne répond pas sur /health. Journaux : gcloud run services logs read $SERVICE --region $REGION --project $PROJECT"
ok "/health répond"
META="$(curl -fsS --max-time 20 "$SERVICE_URL/.well-known/oauth-authorization-server" 2>/dev/null || true)"
if [[ "$META" == *"authorization_endpoint"* ]]; then ok "Métadonnées OAuth publiées"
else warn "Métadonnées OAuth introuvables : vérifier les journaux avant de brancher Claude."; fi

SUMMARY="gws-mcp-${PROJECT}.txt"
cat > "$SUMMARY" <<EOF
Connecteur Google Workspace pour Claude (BOLÉAN)
Installé le      : $(date -u +%Y-%m-%dT%H:%MZ) par $ACCOUNT
Projet GCP       : $PROJECT ($PROJECT_NUMBER)
Région           : $REGION
Version upstream : $VERSION
Service Cloud Run: $SERVICE
URL connecteur   : $MCP_URL
Redirection OAuth: $REDIRECT_URI
Bucket           : gs://$BUCKET
Secrets (noms)   : $SECRET_CLIENT_ID, $SECRET_CLIENT_SECRET, $SECRET_JWT
Aucune valeur secrète dans ce fichier.
EOF

cat <<EOF

${G}${B}Terminé.${N}  Résumé enregistré dans ./$SUMMARY (sans secret)

${B}Brancher Claude (propriétaire de l'organisation Claude Team du client) :${N}
  1. claude.ai > Paramètres de l'organisation (Admin settings) > Connecteurs
  2. Ajouter un connecteur personnalisé
       Nom : Google Workspace
       URL : ${B}${MCP_URL}${N}
     (laisser les paramètres avancés OAuth vides : le serveur gère l'inscription)
  3. Chaque membre : Paramètres > Connecteurs > Google Workspace > Connecter,
     puis se connecter avec son compte Google du domaine.

Mise à jour plus tard : relancer ce script avec --version vX.Y.Z
EOF
