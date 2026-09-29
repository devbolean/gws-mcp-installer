# gws-mcp-installer

Installe le connecteur Google Workspace pour Claude dans le projet Google Cloud
d'un client, en une commande, sur Cloud Run.

Le serveur est le projet open source
[workspace-mcp](https://github.com/taylorwilsdon/google_workspace_mcp)
(Gmail, Drive, Agenda, Docs, Sheets, Slides, Forms, Tasks, Contacts, Chat,
Apps Script), à une version épinglée et validée par BOLÉAN. Aucun fork à
maintenir.

## Pourquoi Cloud Run chez le client

| | Cloud Run dans le GCP du client | Droplet chez BOLÉAN |
|---|---|---|
| Coût | Palier gratuit Cloud Run (2 M requêtes/mois), facturé au client | Serveur loué en continu, payé par BOLÉAN |
| Maintenance | Aucune machine à patcher | OS, Docker, TLS, sauvegardes |
| App OAuth | « Interne » : aucune vérification Google | Externe multi-clients : vérification Google + évaluation de sécurité annuelle pour Gmail/Drive |
| Jetons Gmail/Drive | Dans le bucket du client, au Canada | Sur un serveur de BOLÉAN |
| Départ du client | Il garde tout, rien à migrer | À démêler |

GitHub seul ne suffit pas : Claude doit joindre un serveur HTTPS qui répond en
direct, et GitHub n'héberge que du code et des pages statiques. Cloud Run est
l'équivalent « sans serveur » : le code vient de GitHub, Google l'exécute
seulement quand quelqu'un s'en sert.

## Prérequis (à vérifier avant la séance)

- Le client utilise Google Workspace (domaine payant), pas des comptes Gmail gratuits.
- Un projet GCP du client avec la facturation activée, et un compte BOLÉAN
  qui y est **Propriétaire** (ou Éditeur + Administrateur de la sécurité).
- Une personne du client **propriétaire** de son organisation Claude Team.

## Installation (10 minutes, dont 3 manuelles)

1. Ouvrir Cloud Shell dans le projet du client :
   `https://console.cloud.google.com/?project=<PROJECT_ID>&cloudshell=true`
2. Récupérer et lancer l'installateur :

   ```bash
   git clone https://github.com/devbolean/gws-mcp-installer.git
   cd gws-mcp-installer && bash install.sh --project <PROJECT_ID>
   ```

   Le dépôt est public (aucun secret dedans) : Cloud Shell le clone sans
   jeton GitHub.
3. Le script s'arrête une seule fois pour la création du client OAuth : il
   affiche les trois liens de console et l'URI de redirection exacte à coller.
   Google n'offre aucune API pour cette étape.
4. À la fin, il affiche l'URL du connecteur (`https://gws-mcp-<numéro>.northamerica-northeast1.run.app/mcp`)
   et enregistre un résumé sans secret dans `gws-mcp-<projet>.txt`.

## Brancher Claude (Team ou Enterprise)

1. Le propriétaire de l'organisation Claude : Paramètres de l'organisation >
   Connecteurs > Ajouter un connecteur personnalisé. Nom « Google Workspace »,
   URL du connecteur. Laisser les paramètres OAuth avancés vides.
2. Chaque membre : Paramètres > Connecteurs > Google Workspace > Connecter,
   puis connexion Google avec son compte du domaine.

## Options

| Option | Effet |
|---|---|
| `--region` | Région Cloud Run (défaut `northamerica-northeast1`, Montréal) |
| `--version vX.Y.Z` | Version upstream (défaut : celle validée dans le script) |
| `--tool-tier core\|extended\|complete` | Réduit le nombre d'outils exposés (défaut : tous) |
| `--min-instances 1` | Garde une instance allumée : plus de démarrage à froid, petit coût mensuel |
| `--client-id` + variable `GWS_OAUTH_CLIENT_SECRET` | Mode non interactif |
| `--rebuild` | Reconstruit l'image même si elle existe |
| `--reset-oauth` | Remplace le client OAuth enregistré |
| `--yes` | Aucune confirmation |

## Mettre à jour

Relancer `bash install.sh --project <PROJECT_ID> --version vX.Y.Z`. Les
connexions des employés sont conservées (bucket inchangé).

## Ce que le script crée

- APIs Workspace et Cloud activées
- 3 secrets Secret Manager (client OAuth, clé de signature), répliqués à Montréal
- Bucket privé `<projet>-gws-mcp-data` (jetons des employés, chiffrés au repos)
- Comptes de service `gws-mcp-run` (exécution) et `gws-mcp-build` (construction), permissions minimales
- Dépôt Artifact Registry `gws-mcp` et image construite depuis le tag upstream
- Service Cloud Run `gws-mcp` : 1 instance max, OAuth 2.1, inscription de
  clients limitée aux URL de rappel de Claude

## Désinstaller

```bash
P=<PROJECT_ID>; R=northamerica-northeast1
gcloud run services delete gws-mcp --region $R --project $P
gcloud storage rm -r gs://$P-gws-mcp-data
gcloud secrets delete gws-mcp-oauth-client-id --project $P
gcloud secrets delete gws-mcp-oauth-client-secret --project $P
gcloud secrets delete gws-mcp-jwt-signing-key --project $P
gcloud artifacts repositories delete gws-mcp --location $R --project $P
gcloud iam service-accounts delete gws-mcp-run@$P.iam.gserviceaccount.com --project $P
gcloud iam service-accounts delete gws-mcp-build@$P.iam.gserviceaccount.com --project $P
```

Puis supprimer le client OAuth dans la console (Google Auth Platform > Clients).

## Tester sans GCP

`bash tests/run-dry.sh` exécute le script contre de faux `gcloud` et `curl` et
affiche chaque commande qui serait lancée.
