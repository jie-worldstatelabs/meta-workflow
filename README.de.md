# stagent

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md) | [한국어](./README.ko.md) | [Français](./README.fr.md) | **Deutsch** | [Español](./README.es.md)

Ein Claude-Code-Plugin, das **konfigurationsgetriebene Entwicklungsworkflows** als Zustandsmaschine ausführt. Stages, Übergänge und Eingaben deklarierst du in einer einzigen `workflow.json`; die Hooks und Skripte des Plugins treiben die Schleife.

Zwei Modi:
- **Cloud** (Standard) — Zustand wird in eine [gehostete Webapp](https://stagent.worldstatelabs.com/) gespiegelt, mit Live-Browser-Viewer, maschinenübergreifender Wiederaufnahme und null Fußabdruck im Projektverzeichnis.
- **Local** — Zustand und Artifacts liegen unter `<project>/.stagent/`, ohne Netzwerk.

## Quick Start

### Installation

Diese Slash-Commands **innerhalb einer Claude-Code-Session** ausführen. Cloud-Modus ist standardmäßig aktiv — keine Konfiguration oder Schlüssel nötig; anonyme Sessions funktionieren für `/stagent:start` und `/stagent:continue`. Ein Account (`/stagent:login`) ist nur nötig, um Workflows in den Hub zu publishen oder authentifizierte Eigentümerschaft zu beanspruchen.

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

Bereits installiert? Aktualisieren mit:

```
/plugin update stagent@stagent
```

Voraussetzungen: [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (Cloud-Modus nutzt zusätzlich Standard-POSIX-Tools wie `sha256sum` / `shasum`).

### Einen Workflow starten

**Optional, aber empfohlen:** melde dich zuerst an, um die Session-Eigentümerschaft zu beanspruchen und deine vergangenen Sessions besser zu verwalten.

```
/stagent:login
```

Starte den Standard-Entwicklungsworkflow — er baut, was du beschreibst:

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

Das Skill druckt eine Live-UI-URL. Ohne Anmeldung ist dies eine **anonyme, öffentlich einsehbare** Session — jeder mit dem Link kann die State Machine in Echtzeit verfolgen (Stage-Timeline, gerenderte Artifacts, `git diff baseline..HEAD` per SSE live aktualisiert), und es gibt keinen Besitzer.

Für einen vollständig offline-Lauf in den Local-Modus wechseln:

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### Eigene Workflow-Vorlage erstellen

Definiere deinen Workflow aus einem natürlichsprachlichen Prompt — stagent gerüstet die Stages:

```
/stagent:create "plan, implement, critique & score UX"
```

Dieser Befehl läuft standardmäßig im **Cloud**-Modus: Die neue Vorlage wird nach den Planning- und Writing-Stages in deinen Hub-Account publisht. Falls noch nicht geschehen, vorher anmelden:

```
/stagent:login
```

Für einen komplett offline laufenden Durchgang (die Vorlage bleibt lokal unter `~/.config/stagent/workflows/<name>/`, nichts wird in den Hub gepusht) in den Local-Modus wechseln:

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

Brauchst du Inspiration? Stöber im [Cookbook](https://stagent.worldstatelabs.com/cookbook) nach zwölf praxiserprobten Workflow-Vorlagen, die du forken oder remixen kannst.

## Der Standard-Workflow

Ohne `--flow`-Flag:

- **Cloud-Modus** (Standard) holt `cloud://demo` aus dem Hub — eine gehostete Vorlage, die sich unabhängig von diesem README weiterentwickeln kann
- **Local-Modus** verwendet den im Plugin gebündelten Workflow unter `skills/stagent/workflow/` (Offline-Fallback) — die kanonische Quelle des unten beschriebenen Zyklus

Der gebündelte Workflow läuft in einem **plan → execute → verify → review → QA → deploy** Zyklus:

1. **Planning** *(unterbrechbar)* — Inline-Q&A mit dir: Klärungsfragen, vorgeschlagene Ansätze, Plan-Datei. Du bestätigst, bevor irgendetwas gebaut wird.
2. **Executing** — Subagent (opus) implementiert den Plan: Tests-First, wenn spezifiziert, minimale fokussierte Änderungen.
3. **Verifying** — schnelle Tests (Unit/Integration) laufen inline. FAIL → Schleife zurück zu Execute; PASS/SKIPPED → Review.
4. **Reviewing** — Subagent führt adversariales Code-Review gegen den Baseline-Commit aus. PASS → QA; FAIL → Schleife zurück zu Execute.
5. **QA-ing** — Subagent führt echte User-Journey-Tests aus (Playwright, XcodeBuildMCP usw.). Unterscheidet Test-Bugs von App-Bugs — nur bestätigte App-Bugs blockieren den Fortschritt. PASS → Deploy; FAIL → Schleife zurück zu Execute.
6. **Deploy** *(unterbrechbar)* — Inline-Vercel-CLI-Flow: `vercel whoami`, beim ersten Lauf `vercel link`, Production-Env-Vars synchronisieren, `vercel --prod`, Smoke-Check der URL. Unterbrechbar, weil das Erst-Setup ein `vercel login` in einem anderen Terminal oder Env-Var-Werte von dir braucht. Fertig → terminal `complete`.

Die Schleife `execute → verify → review → QA` läuft **autonom**, nachdem du den Plan abgenickt hast. Ein Stop-Hook garantiert, dass die Schleife durchläuft (bis QA besteht; danach läuft Deploy als finale, unterbrechbare Stage). Die Schleife stoppt bei einem von: Deploy abgeschlossen (terminal `complete`), `max_epoch` erreicht (Standard `20`, in `workflow.json` → `.max_epoch` konfiguriert; bricht außer Kontrolle geratene Iterationen, indem terminal `escalated` erzwungen wird), oder du greifst mit `/stagent:interrupt` (Pause) bzw. `/stagent:cancel` (terminal `cancelled`) ein. Alle drei — `complete`, `escalated`, `cancelled` — sind in `workflow.json` → `.terminal_stages` deklariert.

## Eigene Workflows

Das Plugin ist **generisch** — jede Stage-Form funktioniert, solange sie dem Schema folgt. `/stagent:create` (siehe Quick Start) löst einen internen stagent aus, der dich interviewt, `workflow.json` + Pro-Stage-Anleitungen unter `~/.config/stagent/workflows/<name>/` schreibt, sie in einer Retry-Schleife validiert und das Bundle in den Hub publisht (nur Cloud-Modus). Wiederverwendung mit:

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

Siehe [ARCHITECTURE.md](./ARCHITECTURE.md) für das `workflow.json`-Schema.

Du brauchst Ideen, was du in einen Workflow umwandeln könntest? Siehe das [Cookbook](https://stagent.worldstatelabs.com/cookbook) — zwölf einsatzbereite Workflows für häufige Claude-Code-Fehlermodi (goal pursuit, research-first, end-to-end v1, scope lock-down, invariant guardrails, root-cause forced, real bug hunt, strict TDD, real-journey suite, visual QA gate, perf gate, compliance gate), jeder startbar mit `/stagent:start --flow=cloud://...`.

## Befehle

| Befehl | Zweck |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | Neuen Run starten |
| `/stagent:interrupt` | Aktiven Run pausieren, ohne den Zustand zu verwerfen (auch mitten in einer Stage aufrufbar; Wiederaufnahme mit `/stagent:continue`) |
| `/stagent:continue [--session <id>]` | Unterbrochenen Run wiederaufnehmen (`--session` für maschinenübergreifende Cloud-Übernahme) |
| `/stagent:cancel [--hard]` | Run abbrechen. Default archiviert; `--hard` löscht hart. Local-Modus-Dateien werden entsprechend archiviert/entfernt; im Cloud-Modus wird der Local-Shadow in beiden Fällen gewischt, der Unterschied existiert nur serverseitig (archived vs. hard-deleted) |
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | Neuen Workflow erstellen oder bestehenden bearbeiten |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Lokalen Workflow in den Hub publishen |
| `/stagent:login` / `:logout` / `:whoami` | Hub-Identität verwalten |

**`--flow=<ref>`** akzeptiert:
- *(weggelassen)* — Cloud-Modus holt `cloud://demo` aus dem Hub; Local-Modus benutzt den gebündelten Workflow
- `cloud://author/name` — aus dem Hub geholt (Cloud-Modus)
- `/abs/path` oder `./rel/path` — lokales Workflow-Verzeichnis
- `<bare-name>` — zuerst gegen die gebündelten Workflows aufgelöst, sonst als `cloud://<bare-name>` im Hub

**Umgebungsvariablen:**

| Variable | Default | Wirkung |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | Auf `local` setzen, um den Default für alle Runs in der Shell umzudrehen |

## Local vs Cloud

| Aspekt | Local | Cloud |
|---|---|---|
| Maßgeblicher Zustand | `<project>/.stagent/<session>/state.md` | Postgres-Zeile `sessions`; Local-Shadow spiegelt |
| Wo die Dateien auf der Platte liegen | Projekt-Worktree | `~/.cache/stagent/sessions/<session>/` — bei Terminal gewischt |
| Live-Viewer | Keiner — lies die Dateien | `https://stagent.worldstatelabs.com/s/<session_id>` |
| Maschinenübergreifend continue | Nicht unterstützt | `/stagent:continue --session <id>` mit Project-Fingerprint-Verifikation |
| `.gitignore`-Eintrag nötig | `echo '/.stagent/' >> .gitignore` | Keiner |

### Hinweis zur maschinen-/clone-übergreifenden Übernahme

`/stagent:continue --session <id>` spiegelt den **Zustand** des Workflows (`state.md`, Stage-Reports plus die `baseline`-Run-Datei — den beim Workflow-Start erfassten Git-SHA) auf die neue Maschine. Den Quellcode des Projekts kopiert es **nicht**. Code lebt in deinem Git-Repo, nicht im Plugin.

`continue-workflow.sh` verifiziert:

1. Das neue Workdir ist dasselbe Repo (Root-Commit-Fingerprint).
2. Der HEAD im neuen Workdir ist nicht hinter / divergiert vom HEAD, den der Workflow zuletzt gesehen hat (`last_seen_head` in `state.md`, aktualisiert bei jedem Stage-Übergang und bei `/interrupt`). Ein zurückliegender / divergierender HEAD ist eine **harte Sperre**, sofern nicht `--force-project-mismatch` übergeben wird — sonst würde die wiederaufgenommene Stage gegen veralteten Code laufen und abgeschlossene Arbeit wiederholen oder konterkarieren.
3. Nicht commitete Änderungen im neuen Workdir lösen eine weiche Warnung aus — sie könnten mit der Ausgabe der nächsten Stage kollidieren.

Hat die Originalsession die Subagent-Arbeit vor dem Interrupt commitet, bringt dich `git fetch && git checkout <last_seen_head>` (oder das Mergen dieses Branches) auf der neuen Maschine vor `/continue` in Sync.

## Wichtige Designentscheidungen

- **Konfigurationsgetrieben** — Stages, Übergänge, Interruptible-Flags, Subagent-Typen/-Modelle und Eingabeabhängigkeiten leben alle in `workflow.json`. Eine Stage hinzufügen oder einen Übergang ändern ist eine Konfig-Bearbeitung, keine Code-Änderung.
- **Ein generischer Subagent** — jede Subagent-Stage läuft unter einem einzigen `workflow-subagent`; das Pro-Stage-Protokoll lebt in `<workflow-dir>/<stage>.md`, das der Subagent zur Laufzeit liest. Kein Pro-Stage-`subagent_type`-Feld.
- **Pflichteingaben blockieren Übergänge** — `update-status.sh` weigert sich, in eine Stage zu gehen, wenn ein `required`-Eingabe-Artifact fehlt. Erzwingung auf Zustandsmaschinen-Ebene.
- **Epoch-gestempelte Artifacts** — das Artifact jeder Stage trägt die zum Zeitpunkt der Erzeugung gültige Epoch. Der Stop-Hook vertraut nur Artifacts, deren Epoch zu `state.md` passt — veraltete Artifacts aus früheren Iterationen werden ignoriert.
- **Selbstgenügsam** — das Skill weist den Agenten an, keine externen Skills aufzurufen, um Flow-Hijacking zu verhindern.
- **Sauberer Exit löst Auto-Interrupt aus** — wenn eine Claude-Code-Session sauber endet (z. B. `/exit`, Fenster schließen), kippt stagents `SessionEnd`-Hook den aktiven Workflow auf `interrupted`, damit eine andere Claude-Session per `/stagent:continue` übernehmen kann. Crashes / `kill -9` triggern dies nicht; im Cloud-Modus fängt serverseitige Stale-Erkennung das ab.
- **Eine Session = ein Run** — der Run jeder Claude-Session lebt in einem eigenen, nach Session-Key benannten Unterverzeichnis. Mehrere Claude-Sessions im selben Worktree können unabhängige Workflows ausführen, ohne sich gegenseitig zu stören.

## Architektur & Internas

Siehe [ARCHITECTURE.md](./ARCHITECTURE.md) für:
- Plugin-Verzeichnislayout
- Laufzeit-Dateilayout (local + cloud)
- `workflow.json`-Schema-Referenz
- Zustandsmaschinen-Protokoll (epoch, result, transitions)
- Stop-Hook-Verhalten
- End-to-End-Zyklus-Walkthrough

## License

MIT
