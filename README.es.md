# stagent

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md) | [한국어](./README.ko.md) | [Français](./README.fr.md) | [Deutsch](./README.de.md) | **Español**

Un plugin de Claude Code que ejecuta **flujos de desarrollo dirigidos por configuración** como una máquina de estados. Declaras stages, transiciones y entradas en un único `workflow.json`; los hooks y scripts del plugin conducen el bucle.

Dos modos:
- **Cloud** (por defecto) — el estado se replica en una [webapp alojada](https://stagent.worldstatelabs.com/) con visor en vivo en el navegador, reanudación entre máquinas y huella cero en el directorio del proyecto.
- **Local** — el estado y los artifacts viven bajo `<project>/.stagent/`, sin red.

## Quick Start

### Instalación

Ejecuta estos slash commands **dentro de una sesión de Claude Code**. El modo cloud está activado por defecto — sin configuración ni claves; las sesiones anónimas funcionan para `/stagent:start` y `/stagent:continue`. Solo necesitas una cuenta (`/stagent:login`) para publicar workflows en el hub o reclamar propiedad autenticada.

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

¿Ya está instalado? Actualízalo con:

```
/plugin update stagent@stagent
```

Requiere: [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (el modo cloud también se apoya en utilidades POSIX estándar como `sha256sum` / `shasum`).

### Ejecutar un workflow

**Opcional pero recomendado:** inicia sesión primero para reclamar la propiedad de la sesión y gestionar mejor tus sesiones pasadas.

```
/stagent:login
```

Inicia el workflow de desarrollo por defecto — construye lo que tú describas:

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

El skill imprime una URL de UI en vivo. Sin iniciar sesión, esta es una sesión **anónima y públicamente visible** — cualquiera con el enlace puede ver la máquina de estados ejecutarse en tiempo real (línea de tiempo de stages, artifacts renderizados, `git diff baseline..HEAD` actualizándose en vivo vía SSE), y no tiene propietario.

Para una ejecución totalmente offline, cambia al modo local:

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### Crea tu propia plantilla de workflow

Define tu propio workflow desde un prompt en lenguaje natural — stagent arma los stages:

```
/stagent:create "plan, implement, critique & score UX"
```

Este comando corre por defecto en modo **cloud**: la nueva plantilla se publica en tu cuenta del hub al terminar los stages de planning + writing. Inicia sesión primero si aún no lo hiciste:

```
/stagent:login
```

Para un run completamente offline (la plantilla queda en disco en `~/.config/stagent/workflows/<name>/`, nada se sube al hub), cambia a modo local:

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

¿Necesitas inspiración? Echa un vistazo al [cookbook](https://stagent.worldstatelabs.com/cookbook) para encontrar doce plantillas de workflow probadas en batalla que puedes forkear o remezclar.

## El workflow por defecto

Sin la flag `--flow`:

- **Modo cloud** (por defecto) trae `cloud://demo` desde el hub — una plantilla alojada que puede evolucionar independientemente de este README
- **Modo local** usa el workflow incluido en el plugin en `skills/stagent/workflow/` (fallback offline) — la fuente canónica del ciclo descrito a continuación

El workflow incluido ejecuta un ciclo **plan → execute → verify → review → QA → deploy**:

1. **Planning** *(interrumpible)* — Q&A inline contigo: preguntas de aclaración, enfoques propuestos, archivo de plan. Confirmas antes de que se construya nada.
2. **Executing** — un subagente (opus) implementa el plan: tests-first cuando se especifica, cambios mínimos y enfocados.
3. **Verifying** — tests rápidos (unit/integration) corren inline. FAIL → bucle a Execute; PASS/SKIPPED → Review.
4. **Reviewing** — un subagente hace una revisión adversarial del código contra el commit baseline. PASS → QA; FAIL → bucle a Execute.
5. **QA-ing** — un subagente corre tests reales de viaje del usuario (Playwright, XcodeBuildMCP, etc.). Distingue bugs de tests de bugs de la app — solo los bugs de app confirmados bloquean el avance. PASS → Deploy; FAIL → bucle a Execute.
6. **Deploy** *(interrumpible)* — flow inline de Vercel CLI: `vercel whoami`, `vercel link` en la primera ejecución, sincroniza env vars de producción, `vercel --prod`, smoke-check de la URL. Es interrumpible porque la configuración inicial puede necesitar `vercel login` en otra terminal o valores de env-var de tu parte. Hecho → terminal `complete`.

El bucle `execute → verify → review → QA` corre **de forma autónoma** después de que apruebes el plan. Un Stop hook garantiza que el bucle llegue al final (hasta que QA pase; deploy luego corre como stage final, interrumpible). El bucle se detiene en uno de: deploy completado (terminal `complete`), `max_epoch` alcanzado (por defecto `20`, configurado en `workflow.json` → `.max_epoch`; corta la iteración descontrolada forzando terminal `escalated`), o tú intervienes con `/stagent:interrupt` (pausa) o `/stagent:cancel` (terminal `cancelled`). Los tres — `complete`, `escalated`, `cancelled` — están declarados en `workflow.json` → `.terminal_stages`.

## Workflows personalizados

El plugin es **genérico** — cualquier forma de stage funciona mientras siga el schema. Ejecutar `/stagent:create` (ver Quick Start) despacha un stagent interno que te entrevista, escribe `workflow.json` + archivos de instrucciones por stage bajo `~/.config/stagent/workflows/<name>/`, los valida en un bucle de retry y publica el bundle al hub (solo modo cloud). Reutilízalo con:

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

Mira [ARCHITECTURE.md](./ARCHITECTURE.md) para el schema de `workflow.json`.

¿Necesitas ideas sobre qué convertir en workflow? Mira el [cookbook](https://stagent.worldstatelabs.com/cookbook) — doce workflows listos para usar para los modos de fallo comunes de Claude Code (goal pursuit, research-first, end-to-end v1, scope lock-down, invariant guardrails, root-cause forced, real bug hunt, strict TDD, real-journey suite, visual QA gate, perf gate, compliance gate), cada uno lanzable con `/stagent:start --flow=cloud://...`.

## Comandos

| Comando | Propósito |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | Iniciar un nuevo run |
| `/stagent:interrupt` | Pausar el run activo sin borrar el estado (puede invocarse a media stage; reanuda con `/stagent:continue`) |
| `/stagent:continue [--session <id>]` | Reanudar un run interrumpido (`--session` para toma de control cloud entre máquinas) |
| `/stagent:cancel [--hard]` | Cancelar el run. Por defecto archiva; `--hard` borra duro. Los archivos en modo local se archivan/eliminan en consecuencia; en modo cloud el shadow local se borra en cualquier caso y la diferencia está solo del lado del servidor (archived vs hard-deleted) |
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | Crear un nuevo workflow o editar uno existente |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | Publicar un workflow local en el hub |
| `/stagent:login` / `:logout` / `:whoami` | Gestionar tu identidad en el hub |

**`--flow=<ref>`** acepta:
- *(omitido)* — el modo cloud trae `cloud://demo` desde el hub; el modo local usa el workflow incluido en el plugin
- `cloud://author/name` — traído desde el hub (modo cloud)
- `/abs/path` o `./rel/path` — directorio local de workflow
- `<bare-name>` — resuelto primero contra los workflows incluidos, luego contra `cloud://<bare-name>` en el hub

**Variables de entorno:**

| Variable | Por defecto | Efecto |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | Ponlo a `local` para invertir el default en cada run de la shell |

## Local vs Cloud

| Aspecto | Local | Cloud |
|---|---|---|
| Estado autoritativo | `<project>/.stagent/<session>/state.md` | Fila de Postgres `sessions`; el shadow local hace de espejo |
| Dónde viven los archivos en disco | Worktree del proyecto | `~/.cache/stagent/sessions/<session>/` — borrado al terminal |
| Visor en vivo | Ninguno — lee los archivos | `https://stagent.worldstatelabs.com/s/<session_id>` |
| Continue entre máquinas | No soportado | `/stagent:continue --session <id>` con verificación de project-fingerprint |
| Entrada de `.gitignore` necesaria | `echo '/.stagent/' >> .gitignore` | Ninguna |

### Salvedad de toma de control entre máquinas / clones

`/stagent:continue --session <id>` espeja el **estado** del workflow (`state.md`, reportes de stage, más el run-file `baseline` — el SHA de git capturado al iniciar el workflow) a la nueva máquina. **No** copia el código fuente del proyecto. El código vive en tu repo de git, no en el plugin.

`continue-workflow.sh` verifica:

1. Que el nuevo workdir es el mismo repo (fingerprint del root-commit).
2. Que el HEAD del nuevo workdir no esté detrás / divergente del HEAD que el workflow vio por última vez (`last_seen_head` en `state.md`, actualizado en cada transición de stage y en `/interrupt`). Un HEAD detrás / divergente es un **bloqueo duro** a menos que se pase `--force-project-mismatch` — de lo contrario la stage reanudada correría contra código stale y rehacería o contradiría trabajo terminado.
3. Cambios sin commitear en el nuevo workdir emiten una advertencia suave — pueden chocar con la salida de la siguiente stage.

Si la sesión original commiteó el trabajo de su subagente antes de interrumpir, `git fetch && git checkout <last_seen_head>` (o mergear esa rama) en la nueva máquina te pone en sync antes de `/continue`.

## Decisiones de diseño clave

- **Dirigido por config** — stages, transiciones, flags interruptible, tipos/modelos de subagente y dependencias de entrada viven todos en `workflow.json`. Añadir un stage o cambiar una transición es una edición de config, no un cambio de código.
- **Un subagente genérico** — cada stage de subagente corre bajo un único `workflow-subagent`; el protocolo por stage vive en `<workflow-dir>/<stage>.md`, que el subagente lee en runtime. No hay campo `subagent_type` por stage.
- **Las entradas requeridas bloquean transiciones** — `update-status.sh` se niega a entrar en un stage si falta algún artifact de entrada `required`. Aplicación a nivel de máquina de estados.
- **Artifacts estampillados con epoch** — el artifact de cada stage lleva la epoch que estaba vigente cuando se produjo. El stop hook solo confía en artifacts cuya epoch coincida con `state.md` — los artifacts stale de iteraciones previas se ignoran.
- **Auto-contenido** — el skill instruye al agente a no invocar skills externos, para evitar el secuestro del flow.
- **Salida limpia auto-interrumpe** — cuando una sesión de Claude Code termina limpiamente (p. ej. `/exit`, cerrar ventana), el hook `SessionEnd` de stagent voltea el workflow activo a `interrupted` para que otra sesión de Claude pueda retomarlo vía `/stagent:continue`. Crashes / `kill -9` no disparan esto; en modo cloud, la detección stale del lado servidor es la red de seguridad.
- **Una sesión = un run** — el run de cada sesión de Claude vive en su propio subdirectorio indexado por session. Múltiples sesiones de Claude en el mismo worktree pueden correr workflows independientes sin interferirse.

## Arquitectura & Detalles internos

Mira [ARCHITECTURE.md](./ARCHITECTURE.md) para:
- Layout del directorio del plugin
- Layout de archivos en runtime (local + cloud)
- Referencia del schema de `workflow.json`
- Protocolo de la máquina de estados (epoch, result, transitions)
- Comportamiento del stop-hook
- Recorrido del ciclo end-to-end

## License

MIT
