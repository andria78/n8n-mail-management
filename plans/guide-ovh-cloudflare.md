# Guide OVH → Cloudflare : Changer les serveurs DNS

## Pourquoi faire ça ?

Actuellement, ton domaine `andrianarison.com` est géré par OVH (ses serveurs DNS sont chez OVH). Pour utiliser Cloudflare Tunnel (et avoir HTTPS gratuit, protection DDoS, etc.), tu dois **confier la gestion DNS à Cloudflare**.

**Ça ne change rien pour tes emails ou ton site web** — tu recopies juste les enregistrements DNS existants chez Cloudflare.

---

## Étape 1 : Créer un compte Cloudflare (si pas déjà fait)

1. Va sur [https://dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up)
2. Crée un compte avec ton email
3. Choisis le plan **Free** (gratuit, suffisant)

## Étape 2 : Ajouter ton domaine dans Cloudflare

1. Une fois connecté, clique sur **"Add a Site"**
2. Entre `andrianarison.com`
3. Clique sur **"Add Site"**
4. Cloudflare scanne les enregistrements DNS existants (patiente 30-60 secondes)
5. Tu verras la liste des enregistrements DNS actuels (ceux d'OVH)
   - **Laisse tout coché** — Cloudflare va les importer
   - Clique sur **"Continue"**
6. Choisis le plan **Free** → **"Continue"**
7. **Écran IMPORTANT** : Cloudflare te donne **2 nouveaux serveurs DNS**. Note-les :
   ```
   Exemple :
   darl.ns.cloudflare.com
   nash.ns.cloudflare.com
   ```
   (Les tiens seront différents, note les bien !)

## Étape 3 : Désactiver DNSSEC chez OVH (obligatoire avant de changer les DNS)

1. Va sur [https://www.ovh.com/manager](https://www.ovh.com/manager) → **Web Cloud**
2. Menu gauche → **Noms de domaine** → clique sur `andrianarison.com`
3. Regarde les onglets en haut — cherche **"Sécurité"** (parfois caché derrière une flèche `>`)
4. Section **DNSSEC** → clique sur **"Désactiver"** et confirme

## Étape 4 : Changer les serveurs DNS chez OVH

1. Va sur [https://www.ovh.com/manager](https://www.ovh.com/manager)
2. Connecte-toi avec ton compte OVH
3. Clique sur **"Web Cloud"** en haut
4. Dans le menu de gauche, clique sur **"Noms de domaine"**
5. Clique sur **`andrianarison.com`**
6. Va dans l'onglet **"Serveurs DNS"**
7. Clique sur **"Modifier les serveurs DNS"**

   Tu vas voir un tableau :

   | Serveur DNS | Adresse IP |
   |-------------|------------|
   | dnsXX.ovh.net | _(déjà rempli)_ |
   | nsXX.ovh.net | _(déjà rempli)_ |

8. **Remplace les noms** par ceux de Cloudflare (de l'étape 2). **Laisse le champ IP vide** :

   | Serveur DNS | Adresse IP |
   |-------------|------------|
   | `darl.ns.cloudflare.com` | _(laisser vide)_ |
   | `nash.ns.cloudflare.com` | _(laisser vide)_ |

9. **Décoche** "Utiliser la configuration DNS minimal" si présent
10. Clique sur **"Appliquer la configuration"**

## Étape 5 : Attendre la propagation

- Le changement peut prendre de **quelques minutes à 48 heures**
- En général, c'est fait en **1 à 2 heures**
- Cloudflare t'enverra un email quand c'est actif

## Étape 6 : Finaliser dans Cloudflare

1. Une fois que les nouveaux serveurs DNS sont détectés, reçois l'email : **"andrianarison.com is now active on Cloudflare"**
2. Retourne sur [https://dash.cloudflare.com](https://dash.cloudflare.com)
3. Clique sur `andrianarison.com`
4. Va dans l'onglet **DNS** → vérifie que tous tes enregistrements sont là

## Étape 7 : Installer le tunnel Cloudflare

```bash
# Installer cloudflared
brew install cloudflared

# Connecter ton compte Cloudflare
cloudflared tunnel login
# → Un navigateur s'ouvre, connecte-toi et autorise andrianarison.com

# Créer un tunnel
cloudflared tunnel create n8n-tunnel
# → Un ID de tunnel est créé (ex: 6ff42ae2-765d-4adf-8112-31c55c1551ef)
# → Note cet ID ! Tu en auras besoin
```

## Étape 8 : Configurer le tunnel

Crée le fichier **`~/.cloudflared/config.yml`** :

```yaml
tunnel: 15d21c73-5452-4be9-94f5-9f09dda282fb
credentials-file: /Users/ericandrianarison/.cloudflared/15d21c73-5452-4be9-94f5-9f09dda282fb.json

ingress:
  - hostname: n8n.andrianarison.com
    service: http://localhost:5678
  - service: http_status:404
```

## Étape 9 : Configurer DNS dans Cloudflare Dashboard

1. Va sur [https://dash.cloudflare.com](https://dash.cloudflare.com) → `andrianarison.com`
2. **DNS** → **Records** → **Add Record**
3. Remplis :
   - **Type:** `CNAME`
   - **Name:** `n8n`
   - **Target:** `TON_ID_DU_TUNNEL.cfargotunnel.com` (ex: `6ff42ae2-765d-4adf-8112-31c55c1551ef.cfargotunnel.com`)
   - **Proxy status:** ✅ Orange cloud (Proxied)
4. **Save**

## Étape 10 : Redémarrer n8n avec docker-compose

```bash
# Arrêter l'ancien conteneur
docker stop n8n
docker rm n8n

# Démarrer avec docker-compose
cd /Volumes/Public/Hobbies/VibeCoding/n8nMailManagement
docker compose up -d
```

## Étape 11 : Lancer le tunnel et activer le workflow

```bash
# Démarrer le tunnel
cloudflared tunnel run n8n-mail-tunnel &
```

Vérifie que `https://n8n.andrianarison.com` répond (tu devrais voir l'interface n8n).

Puis active le workflow :
- Va dans n8n → **Workflows** → **"Telegram Ollama Chatbot"**
- Met le toggle **"Active"** sur ON

## Étape 12 : Tester

Envoie un message à ton bot Telegram → il répondra via Ollama gemma4:e4b 🎉

---

## Résumé visuel

```
AVANT :
  andrianarison.com → Serveurs DNS OVH → (pas de tunnel possible)

APRÈS :
  andrianarison.com → Serveurs DNS Cloudflare → Cloudflare Tunnel → ton Mac → n8n
```

## Questions fréquentes

**Q: Mes emails vont-ils fonctionner ?**
R: Oui, tant que tu as bien recopié les enregistrements MX (mail) dans Cloudflare. Cloudflare les importe automatiquement.

**Q: Mon site web va-t-il être coupé ?**
R: Pendant la propagation DNS, il peut y avoir une courte interruption. Une fois Cloudflare actif, tout revient à la normale.

**Q: C'est gratuit ?**
R: Oui, le plan Free de Cloudflare est gratuit et inclut les tunnels.

**Q: Où trouver DNSSEC dans OVH ?**
R: Web Cloud → Noms de domaine → `andrianarison.com` → onglet **"Sécurité"** → section DNSSEC → **Désactiver**