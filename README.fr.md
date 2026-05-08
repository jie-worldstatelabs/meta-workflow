# stagent

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md) | [한국어](./README.ko.md) | **Français** | [Deutsch](./README.de.md) | [Español](./README.es.md)

Un plugin Claude Code qui exécute des **workflows de développement pilotés par configuration** sous la forme d'une machine à états. Vous déclarez les stages, transitions et entrées dans un unique `workflow.json` ; les hooks et scripts du plugin pilotent la boucle.

Deux modes :
- **Cloud** (par défaut) — état mirroré vers une [webapp hébergée](https://stagent.worldstatelabs.com/) avec une visualisation live dans le navigateur, reprise multi-machines, et zéro empreinte dans le répertoire projet.
- **Local** — l'état et les artifacts vivent sous `<project>/.stagent/`, sans réseau.

## Quick Start

### Installation

Exécute cette commande dans ton terminal. Le mode cloud est activé par défaut — pas besoin de configuration ni de clé ; les sessions anonymes fonctionnent pour `/stagent:start` et `/stagent:continue`. Un compte (`/stagent:login`) n'est nécessaire que pour publier des workflows sur le hub ou revendiquer la propriété authentifiée.

```
claude plugin marketplace add jie-worldstatelabs/stagent && claude plugin install stagent@stagent
```

Déjà installé ? Mets à jour avec :

```
claude plugin marketplace update stagent && claude plugin update stagent@stagent
```

Requis : [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (le mode cloud s'appuie aussi sur des outils POSIX standards comme `sha256sum` / `shasum`).

### Lancer un workflow

Facultatif mais recommandé : connecte-toi d'abord pour revendiquer la propriété de la session et mieux gérer tes sessions passées.

```
/stagent:login
```

Démarrez le workflow de développement par défaut — il construit ce que vous décrivez :

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

Le skill imprime une URL d'UI live. Sans connexion, c'est une session **anonyme et publiquement consultable** — quiconque a le lien peut suivre l'exécution de la machine à états en temps réel (timeline des stages, artifacts rendus, `git diff baseline..HEAD` mis à jour en direct via SSE), et il n'y a pas de propriétaire.

Pour une exécution entièrement hors ligne, basculez en mode local :

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### Créer votre propre template de workflow

Définissez votre workflow à partir d'un prompt en langage naturel — stagent scaffolde les stages :

```
/stagent:create "plan, implement, critique & score UX"
```

Cette commande tourne par défaut en mode **cloud** : le nouveau template est publié sur votre compte hub une fois les stages planning + writing terminés. Connectez-vous d'abord si ce n'est pas déjà fait :

```
/stagent:login
```

Pour un run entièrement hors-ligne (le template reste sur disque sous `~/.config/stagent/workflows/<name>/`, rien n'est poussé vers le hub), passez en mode local :

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

Besoin d'inspiration ? Parcourez le [cookbook](https://stagent.worldstatelabs.com/cookbook) pour douze templates de workflow éprouvés en conditions réelles, à forker ou remixer.

## Le workflow par défaut

Sans flag `--flow` :

- **Mode cloud** (par défaut) récupère `cloud://demo` depuis le hub — un template hébergé qui peut évoluer indépendamment de ce README
- **Mode local** utilise le workflow embarqué dans le plugin sous `skills/stagent/workflow/` (fallback hors ligne) — la source canonique du cycle décrit ci-dessous

Le workflow embarqué exécute un cycle **plan → execute → verify → review → QA → deploy** :

1. **Planning** *(interruptible)* — Q&A inline avec vous : questions de clarification, approches proposées, fichier plan. Vous confirmez avant que quoi que ce soit ne soit construit.
2. **Executing** — un subagent (opus) implémente le plan : tests-first quand spécifié, changements minimaux et ciblés.
3. **Verifying** — tests rapides (unit/integration) exécutés inline. FAIL → boucle vers Execute ; PASS/SKIPPED → Review.
4. **Reviewing** — un subagent fait une revue de code adverse contre le commit baseline. PASS → QA ; FAIL → boucle vers Execute.
5. **QA-ing** — un subagent exécute de vrais tests de parcours utilisateur (Playwright, XcodeBuildMCP, etc.). Distingue les bugs de tests des bugs d'app — seuls les bugs d'app confirmés bloquent la progression. PASS → Deploy ; FAIL → boucle vers Execute.
6. **Deploy** *(interruptible)* — flow inline Vercel CLI : `vercel whoami`, `vercel link` au premier lancement, sync des env vars de production, `vercel --prod`, smoke check de l'URL. Interruptible parce que la première configuration peut nécessiter `vercel login` dans un autre terminal ou des valeurs d'env-var de votre part. Terminé → terminal `complete`.

La boucle `execute → verify → review → QA` tourne **de manière autonome** après votre approbation du plan. Un Stop hook garantit que la boucle va jusqu'au bout (jusqu'à ce que QA passe ; deploy s'exécute ensuite comme dernier stage interruptible). La boucle s'arrête sur l'un de ces événements : deploy terminé (terminal `complete`), `max_epoch` atteint (par défaut `20`, configuré dans `workflow.json` → `.max_epoch` ; coupe l'itération qui s'emballe en forçant terminal `escalated`), ou vous intervenez avec `/stagent:interrupt` (pause) ou `/stagent:cancel` (terminal `cancelled`). Les trois — `complete`, `escalated`, `cancelled` — sont déclarés dans `workflow.json` → `.terminal_stages`.

## Workflows personnalisés

Le plugin est **générique** — n'importe quelle forme de stage fonctionne tant qu'elle suit le schéma. Lancer `/stagent:create` (voir Quick Start) délègue à un stagent interne qui vous interviewe, écrit `workflow.json` + les fichiers d'instructions par stage sous `~/.config/stagent/workflows/<name>/`, les valide dans une boucle de retry, et publie le bundle vers le hub (mode cloud uniquement). Réutilisez-le avec :

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

Voir [ARCHITECTURE.md](./ARCHITECTURE.md) pour le schéma de `workflow.json`.

Besoin d'idées sur ce qu'il faut transformer en workflow ? Voir le [cookbook](https://stagent.worldstatelabs.com/cookbook) — douze workflows prêts à l'emploi pour les modes d'échec courants de Claude Code (goal pursuit, research-first, end-to-end v1, scope lock-down, invariant guardrails, root-cause forced, real bug hunt, strict TDD, real-journey suite, visual QA gate, perf gate, compliance gate), chacun lançable avec `/stagent:start --flow=cloud://...`.

## Commandes

| Commande | Rôle |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | Démarrer un nouveau run |
| `/stagent:interrupt` | Mettre en pause le run actif sans effacer l'état (peut être appelé en plein stage ; reprendre avec `/stagent:continue`) |
| `/stagent:continue [--session <id>]` | Reprendre un run interrompu (`--session` pour reprise cloud multi-machines) |
| `/stagent:cancel [--hard]` | Annuler le run. Par défaut archive ; `--hard` supprime définitivement. Les fichiers en mode local sont archivés/supprimés en conséquence ; en mode cloud le shadow local est effacé dans tous les cas et la différence n'existe que côté serveur (archived vs hard-deleted) |
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | Créer un nouveau workflow ou éditer un workflow existant |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Publier un workflow local sur le hub |
| `/stagent:login` / `:logout` / `:whoami` | Gérer votre identité hub |

**`--flow=<ref>`** accepte :
- *(omis)* — le mode cloud récupère `cloud://demo` depuis le hub ; le mode local utilise le workflow embarqué
- `cloud://author/name` — récupéré depuis le hub (mode cloud)
- `/abs/path` ou `./rel/path` — répertoire de workflow local
- `<bare-name>` — résolu d'abord contre les workflows embarqués, puis `cloud://<bare-name>` sur le hub

**Variables d'environnement :**

| Variable | Défaut | Effet |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | Mettre à `local` pour inverser le défaut sur tous les runs du shell |

## Local vs Cloud

| Aspect | Local | Cloud |
|---|---|---|
| État faisant autorité | `<project>/.stagent/<session>/state.md` | ligne Postgres `sessions` ; shadow local en miroir |
| Où vivent les fichiers sur disque | Worktree du projet | `~/.cache/stagent/sessions/<session>/` — effacé à terminal |
| Visualiseur live | Aucun — lisez les fichiers | `https://stagent.worldstatelabs.com/s/<session_id>` |
| Continue multi-machines | Non supporté | `/stagent:continue --session <id>` avec vérification de project-fingerprint |
| Entrée `.gitignore` requise | `echo '/.stagent/' >> .gitignore` | Aucune |

### Reprise multi-machines / multi-clones — mises en garde

`/stagent:continue --session <id>` mirrore l'**état** du workflow (`state.md`, rapports de stage, plus le run-file `baseline` — le SHA git capturé au démarrage du workflow) vers la nouvelle machine. Il **ne** copie **pas** le code source du projet. Le code vit dans votre repo git, pas dans le plugin.

`continue-workflow.sh` vérifie :

1. Que le nouveau workdir est le même repo (fingerprint du commit racine).
2. Que le HEAD du nouveau workdir n'est pas en retard / divergent par rapport au HEAD que le workflow a vu en dernier (`last_seen_head` dans `state.md`, mis à jour à chaque transition de stage et à `/interrupt`). Un HEAD en retard / divergent est un **blocage dur** sauf si `--force-project-mismatch` est passé — sinon le stage repris tournerait sur du code obsolète et referait ou contredirait du travail déjà terminé.
3. Les changements non commités dans le nouveau workdir émettent un avertissement souple — ils peuvent entrer en conflit avec la sortie du prochain stage.

Si la session originale a commité le travail de son subagent avant l'interruption, `git fetch && git checkout <last_seen_head>` (ou merger cette branche) sur la nouvelle machine vous resynchronise avant `/continue`.

## Décisions de conception clés

- **Piloté par config** — stages, transitions, flags interruptible, types/modèles de subagent, dépendances d'entrée vivent tous dans `workflow.json`. Ajouter un stage ou changer une transition est une édition de config, pas un changement de code.
- **Un seul subagent générique** — chaque stage subagent tourne sous un unique `workflow-subagent` ; le protocole par stage vit dans `<workflow-dir>/<stage>.md`, lu par le subagent à l'exécution. Pas de champ `subagent_type` par stage.
- **Les entrées requises bloquent les transitions** — `update-status.sh` refuse d'entrer dans un stage si un artifact d'entrée `required` est manquant. Application au niveau machine à états.
- **Artifacts estampillés epoch** — l'artifact de chaque stage porte l'epoch courant à sa production. Le stop hook ne fait confiance qu'aux artifacts dont l'epoch correspond à `state.md` — les artifacts périmés des itérations précédentes sont ignorés.
- **Auto-contenu** — le skill instruit l'agent de ne pas invoquer de skills externes pour empêcher le détournement du flow.
- **La sortie propre déclenche un auto-interrupt** — quand une session Claude Code se termine proprement (par ex. `/exit`, fermeture de fenêtre), le hook `SessionEnd` de stagent bascule le workflow actif en `interrupted` pour qu'une autre session Claude puisse le reprendre via `/stagent:continue`. Les crashs / `kill -9` ne déclenchent pas cela ; en mode cloud, la détection serveur de session périmée est le filet de sécurité.
- **Une session = un run** — le run de chaque session Claude vit dans son propre sous-répertoire indexé par session. Plusieurs sessions Claude dans le même worktree peuvent exécuter des workflows indépendants sans interférence.

## Architecture & Internes

Voir [ARCHITECTURE.md](./ARCHITECTURE.md) pour :
- Layout du répertoire du plugin
- Layout des fichiers à l'exécution (local + cloud)
- Référence du schéma `workflow.json`
- Protocole de la machine à états (epoch, result, transitions)
- Comportement du stop-hook
- Walkthrough du cycle bout-en-bout

## License

MIT
