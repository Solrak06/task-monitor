# task-monitor

Mod de **Claude Code** para Windows que abre una ventana con lo que gastan tus sesiones de Claude: CPU y RAM de cada una, en qué estado está (trabajando, esperándote, lista, en pausa…), cuánto te queda de uso semanal y un diario de todo lo que has pedido. También sigue los **renders de vídeo** (Remotion, Blender, ffmpeg, HandBrake, Media Encoder) y puede llevar la cola de vídeos de **FORJA**.

La ventana está hecha en PowerShell + WPF con un núcleo en C# que se compila una vez y se guarda en caché. No necesita instalar nada más.

---

## Índice

- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Cómo se abre](#cómo-se-abre)
- [La ventana](#la-ventana)
- [Pausar sesiones para liberar RAM](#pausar-sesiones-para-liberar-ram)
- [Diario](#diario)
- [Escenario](#escenario)
- [Pestaña Render](#pestaña-render)
- [Conectar la pestaña Render con FORJA](#conectar-la-pestaña-render-con-forja)
- [Ajustes](#ajustes)
- [Memoria y rendimiento](#memoria-y-rendimiento)
- [Archivos que usa](#archivos-que-usa)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Problemas frecuentes](#problemas-frecuentes)

---

## Requisitos

- Windows 10 u 11.
- Windows PowerShell 5.1 (viene con Windows) y .NET Framework 4.x (también viene de serie).
- Claude Code con soporte de mods (módulos `register.ts`).
- Opcional: Windows Terminal, para el acoplado y para saltar a la pestaña de cada sesión.

## Instalación

1. Clona el repositorio donde quieras:

   ```powershell
   git clone https://github.com/Solrak06/task-monitor.git "$env:USERPROFILE\Claude Mods\task-monitor"
   ```

2. Añade esa carpeta a `CLAUDE_CODE_PLUGIN_DIRS` en `~/.claude/settings.json` (separa varias carpetas con `;`):

   ```json
   {
     "env": {
       "CLAUDE_CODE_PLUGIN_DIRS": "C:\\Users\\TU_USUARIO\\Claude Mods\\task-monitor"
     }
   }
   ```

3. Reinicia Claude Code. Las sesiones que ya estaban abiertas no cargan el mod hasta que las reinicies.

4. Si PowerShell bloquea scripts, permite los locales para tu usuario (una vez):

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

La primera vez que se abre la ventana tarda unos segundos más porque compila su parte en C# (se guarda en `~/.claude/task-monitor/bin`).

## Cómo se abre

- **Automáticamente** al enviar un mensaje en cualquier sesión (configurable en Ajustes: siempre, solo la primera vez por sesión, solo si la RAM pasa de un umbral o nunca).
- **A mano** con el comando `/monitor` dentro de Claude Code.
- Solo hay una ventana a la vez: si ya está abierta, no se abre otra.

El mod (`hooks/register.ts`) escribe el estado de cada sesión en `~/.claude/task-monitor/sessions/<id>.json` (en curso, esperando permiso o respuesta, lista, error…, más el último mensaje, el modelo y el contexto usado) y el uso semanal / de 5 horas en `usage.json`. PowerShell solo arranca cuando hace falta: para averiguar el PID de la sesión o para abrir la ventana si no está abierta.

## La ventana

- **CPU y RAM** del sistema con su gráfica. Verde por debajo del 70 %, amarillo hasta el 90 %, rojo a partir de ahí.
- **Huecos**: un cuadrado por sesión abierta (con el color de su estado) y los huecos libres que caben según la RAM que queda.
- **Consejo**: te dice si puedes abrir más tareas o si conviene pausar alguna, y cuáles.
- **Sesiones de Claude**: una tarjeta por sesión con su memoria, CPU, tareas hechas, tiempo, subagentes, porcentaje de contexto, el último mensaje que enviaste y un Claude en pixel art que hace algo distinto según el estado.

  | Estado | Significado |
  |---|---|
  | EN CURSO | está trabajando |
  | ESPERANDO | te pide un permiso o tiene una pregunta |
  | LISTO | terminó (pasa a INACTIVA tras 30 min) |
  | ERROR | la respuesta acabó con un error |
  | EN PAUSA | la congelaste desde el monitor |
  | SIN DATOS | sesión abierta antes de instalar el mod (el estado sale del título de la terminal) |

- **Clic** en una tarjeta: va a su pestaña de Windows Terminal (o a su ventana). **Doble clic** en el nombre: renombrarla. **Clic derecho**: menú con pausar/reanudar, fijar arriba, abrir su carpeta, copiar `claude --resume <id>`, cerrar…
- **Otros programas**: lo que más memoria usa fuera de Claude, con opción de cerrarlo (los procesos del sistema están protegidos).
- **Barra inferior**: resumen de estados y uso semanal y de 5 horas de tu cuenta (pasa el ratón para ver cuándo se reinicia).
- **Actividad**: registro de lo que va pasando (también en `~/.claude/task-monitor/actividad.log`, que se recorta solo al pasar de 1 MB).

## Pausar sesiones para liberar RAM

Clic derecho → **Pausar** congela todos los procesos de esa sesión (Claude, sus comandos, sus servidores MCP…). Windows puede mover su memoria al archivo de paginación y dejarla libre para lo demás. **Reanudar** la descongela y sigue exactamente donde estaba. La consola de la sesión nunca se congela, así que la terminal sigue respondiendo.

Si cierras el monitor, las sesiones pausadas se reanudan solas.

## Diario

Botón del libro, arriba a la derecha. Lee los registros de Claude Code (`~/.claude/projects/*/*.jsonl`) y enseña, día a día:

- Cada petición que hiciste en cada sesión, con los archivos que editó Claude, los comandos que ejecutó, los subagentes y el tiempo que tardó.
- Por día: tiempo trabajado, archivos, comandos y un **gráfico de actividad por horas**.
- **Buscador**: filtra por texto de la petición, nombre de archivo, título de la sesión o carpeta (sin distinguir mayúsculas ni tildes).
- **Filtros**: sesiones abiertas o todas; hoy, 3 días o 7 días; y la casilla **claude -p** para incluir las sesiones que abren otros programas (pipelines, scripts). Por defecto solo salen las que escribiste tú.
- **Botón de copiar** en cada día: copia un resumen en texto, listo para pegar en una nota o un parte de trabajo.
- **Pasar el ratón** por una petición: el texto completo y la lista de archivos editados.
- **Clic derecho** en una petición o sesión: copiar la petición, copiar las rutas editadas, ir a su terminal, abrir su carpeta o copiar `claude --resume`.

La primera lectura puede tardar unos segundos si tienes muchos registros; después solo lee lo nuevo (lo guarda en `diary-cache-2.json`). Al cerrar el diario se libera su memoria.

## Escenario

Botón del mando: un mapa en pixel art (gimnasio, oficina o playa) con un Claude por sesión que se mueve según su estado. Sigue la hora del día y el tiempo, juegan al fútbol cuando están libres y puedes arrastrarlos. Clic en uno abre su menú. Solo gasta recursos mientras está abierto.

## Pestaña Render

Junto a **Claude Tasks** está la pestaña **Render**, con tres listas: en curso, en espera / en pausa y terminados. Detecta:

1. **Renders que publican su progreso** en `~/.claude/render-progress/*.json` (ver formato abajo). Son los más completos: fotogramas, codificación, tiempo restante, pausa y reanudación.
2. **Procesos de render sin progreso publicado**: `blender.exe` en segundo plano (`-b`), `ffmpeg.exe`, `HandBrakeCLI.exe`, Adobe Media Encoder y `remotion render` lanzado por línea de comandos.
3. **Lanzadores de Blender que esperan turno** (scripts `blender.py`, `lanza_blender.py`, `bl.py`, `lote.py` o `cola_turno.py` ejecutándose con Python).
4. **La cola de vídeos de FORJA** (ver la sección siguiente).

Clic derecho en un render: pausar (congela su árbol de procesos), reanudar, abrir la carpeta, reproducir el vídeo, copiar su ruta, ir a la sesión de Claude que lo lanzó o cancelar. Doble clic abre su carpeta. Cada tarjeta muestra el icono del programa y el nombre de la carpeta del proyecto.

### Publicar el progreso de un render

Cualquier script puede salir en la pestaña escribiendo (y reescribiendo mientras avanza) un JSON en `%USERPROFILE%\.claude\render-progress\<id>.json`:

```json
{
  "id": "mi-proyecto-1793692920897",
  "title": "mi-proyecto · Escena1",
  "output": "C:\\ruta\\al\\video\\out\\final.mp4",
  "pid": 23224,
  "session": "<id de la sesión de Claude que lo lanzó, opcional>",
  "stage": "rendering",
  "rendered": 1200,
  "encoded": 900,
  "total": 2591,
  "etaMs": 360000,
  "startedAt": 1793692920897,
  "updatedAt": 1793693798133,
  "error": null,
  "resume": { "cwd": "C:\\ruta\\al\\proyecto", "node": "C:\\Program Files\\nodejs\\node.exe", "args": ["render.mjs", "..."] },
  "retryAt": null
}
```

- `stage`: `bundling`, `rendering`, `encoding`, `muxing`, `paused`, `done` o `error`.
- `pid`: el proceso del render. Si muere sin llegar a `done`, la tarjeta pasa a "se cortó".
- `startedAt` / `updatedAt` / `retryAt`: milisegundos Unix.
- `resume` (opcional): cómo relanzarlo. Con él, **Reanudar** vuelve a ejecutar ese comando en esa carpeta (útil si tu script continúa desde los trozos ya hechos).
- Los JSON de más de 24 horas se ignoran.

## Conectar la pestaña Render con FORJA

FORJA es un pipeline que produce vídeos con sesiones de `claude -p`. El monitor puede **llevar su cola**: un vídeo en curso cada vez, los demás en espera, lanzarlos en orden, pausarlos y reanudarlos sin perder nada. Si no usas FORJA, esta parte no hace nada.

### 1. Dónde está FORJA

Por defecto el monitor busca FORJA en `%USERPROFILE%\OneDrive\Desktop\FORJA`. Si la tienes en otro sitio, ponlo en `~/.claude/task-monitor/settings.json`:

```json
{ "forjaRoot": "D:\\Proyectos\\FORJA" }
```

Además, si arrancas `lanzar_lote.py` desde una carpeta que tiene `runs\`, el monitor adopta esa carpeta automáticamente.

### 2. Estructura que espera

```
FORJA\
├─ forja.py
├─ herramientas\blender.py          (lanzador de Blender por turnos)
├─ motor\src\videos\<mid>\           (proyecto Remotion de cada vídeo)
└─ runs\
   └─ <AAAAMMDD-HHMMSS>\             (una tanda = "run")
      ├─ estado.json                 { "canal": "..." }
      ├─ ENTREGA\<mid>.mp4           (vídeo final entregado)
      └─ video<N>\
         ├─ 08_prompt\
         │   ├─ progreso.json        (lo escribe la sesión: ver abajo)
         │   ├─ prompt_panel.txt     (el encargo que le pasa el monitor)
         │   └─ sesion.jsonl / .err  (salida de la sesión lanzada)
         └─ ENTREGADO.md             (aparece al terminar: entregado)
```

Cada vídeo se identifica por su **mid**: `r<AAAAMMDD>_<HHMMSS>_v<N>` (por ejemplo `r20261031_100224_v3` es el vídeo 3 de la tanda `20261031-100224`). El monitor reconoce un proceso o un render como parte de un vídeo de FORJA si su línea de comandos o su ruta de salida contiene `runs\<run>\video<N>` o ese mid.

### 3. Meter vídeos en la cola

Hay dos formas:

- **Con `lanzar_lote.py`**: ejecútalo pasándole los vídeos como `RUN:N` (por ejemplo `python lanzar_lote.py 20261031-100224:1 20261031-100224:2`). En cuanto el monitor ve ese proceso, **se queda con su cola**, cierra el lanzador y te avisa: ya puedes cerrar la terminal. El orden se guarda en `renders.json`, así que la cola sobrevive a reinicios del monitor.
- **Con un archivo puente**: escribe `~/.claude/render-progress/forja-<AAAAMMDD-HHMMSS>-v<N>.json` (con al menos `updatedAt` en milisegundos; opcionalmente `output` y `startedAt`). Mientras sea de las últimas 6 horas, ese vídeo se añade a la cola.

### 4. Qué hace el monitor con la cola

- Solo hay **un vídeo EN CURSO**. Cuando no hay ninguno, saca el primero de **EN ESPERA** (como mucho uno cada 20 s).
- Para producir un vídeo escribe `08_prompt\prompt_panel.txt` con el encargo (continuar el vídeo donde se quedó, hacer un único render final con `herramientas\blender.py` para Blender y entregarlo en `ENTREGA\`) y lanza, sin ventana y desde la carpeta de FORJA:

  ```
  claude -p --model claude-opus-5-5 --permission-mode auto --output-format stream-json --verbose -n "FORJA <canal> v<N>"
  ```

  La sesión no depende del monitor ni de ninguna terminal: si cierras el monitor, sigue trabajando.
- La sesión debe ir reescribiendo `08_prompt\progreso.json` para que el panel enseñe el avance:

  ```json
  { "fase": "montaje", "pct": 62, "detalle": "montando la escena 4 de 6", "eta_min": 18 }
  ```

  `fase`: `revisando`, `audio`, `3d`, `montaje`, `render`, `entregado` o `bloqueado`.
- El vídeo cuenta como **entregado** cuando aparece `ENTREGADO.md` o `progreso.json` dice `"fase": "entregado"`. Entonces sale de la cola.
- Si la sesión muere sin entregar, el vídeo vuelve el primero a EN ESPERA y se reintenta al cabo de 1 minuto. Tras 3 caídas pasa a EN PAUSA.
- Los Blender que lanza la sesión, sus esperas de turno y el render final se agrupan dentro de la tarjeta de su vídeo.

### 5. Controles (clic derecho en un vídeo de la cola)

| Acción | Qué hace |
|---|---|
| Lanzar ahora | lo pone en curso aunque haya otro (pide confirmación) |
| Subir al primer puesto | será el siguiente en salir |
| Pausar | si está en curso, congela su sesión y sus renders tal cual (no pierde nada) y sale el siguiente; si está en espera, pasa a EN PAUSA y no sale solo |
| Reanudar | descongela o vuelve a ponerlo en la cola (si no hay ninguno en curso, sale ya) |
| Detener | cierra su sesión y sus renders; lo hecho se conserva y **Reanudar** sigue desde ahí |
| Quitar de la cola | lo saca de la lista |
| Ver ENTREGADO.md | abre el informe de entrega |

## Ajustes

Botón del engranaje. Todo se guarda al momento en `~/.claude/task-monitor/settings.json`.

- **Apariencia**: estilos Hacker (con paletas y efecto CRT), Simple, Analítico, Nefralis y Trading. Claudes animados en las tarjetas (activables) y galería con todas sus animaciones.
- **Cuándo abrir la ventana**: siempre, primera tarea de cada sesión, solo con la RAM por encima del 70/80/90 % o nunca (solo `/monitor`).
- **Lista de sesiones**: agrupar (fijadas y resto, por estado o sin grupos) y ordenar (apertura, último uso, nombre o memoria).
- **Rendimiento**: refresco cada 1, 2 o 5 s y la RAM de reserva que el consejo deja siempre libre.
- **Avisos y ventana**: sonidos (RAM crítica, sesión terminada), siempre encima, **acoplar con Windows Terminal** (el monitor a la derecha a toda altura y la Terminal ocupando el resto), tamaño fijo y **modo ligero**.

Ajustes que solo están en `settings.json`: `forjaRoot` (carpeta de FORJA).

## Memoria y rendimiento

El monitor está pensado para pasar el día abierto gastando lo mínimo:

- **Modo ligero** (activado por defecto): la ventana se dibuja por software en vez de con la tarjeta gráfica. El driver de la gráfica reservaba unos 80–150 MB solo para la ventana; así no. Cuesta alrededor de un 1 % más de un núcleo de CPU.
- La memoria se compacta y se devuelve a Windows poco después de arrancar, al cerrar el diario, el escenario o la galería, al minimizar y cada 3 minutos.
- Minimizada, solo refresca una vez de cada cinco.
- Lo pesado (lectura de procesos, diario, animaciones) está en C#; las cachés de procesos y archivos se vacían solas.

Con el modo ligero, la ventana ronda los 170–230 MB de memoria privada, de los que unos 100 son el mínimo de PowerShell más WPF.

## Archivos que usa

Todo en `%USERPROFILE%\.claude\task-monitor\`:

| Archivo | Para qué |
|---|---|
| `settings.json` | ajustes |
| `sessions\<id>.json`, `<id>.pid` | estado de cada sesión (lo escribe el mod) |
| `usage.json` | uso semanal y de 5 horas |
| `meta.json` | nombres puestos a mano y sesiones fijadas |
| `paused.json` | sesiones en pausa (se reanudan al cerrar) |
| `renders.json` | renders ocultos o en pausa y la cola de FORJA |
| `diary-cache-2.json` | lo ya leído para el diario |
| `actividad.log` | registro de eventos (máx. ~1 MB) |
| `alive` | latido: el mod lo mira para no abrir otra ventana |
| `bin\TaskMon-*.dll` | la parte en C# compilada |

Y `%USERPROFILE%\.claude\render-progress\*.json` para los renders con progreso.

## Estructura del repositorio

```
.claude-plugin/plugin.json   manifiesto del mod
hooks/hooks.json             registra el módulo
hooks/register.ts            estado de cada sesión, uso, comando /monitor, abre la ventana
app/launch.ps1               anota el PID de la sesión y abre el monitor según los ajustes
app/monitor.ps1              la ventana (PowerShell + WPF + C# embebido)
app/assets/                  iconos
```

## Problemas frecuentes

- **No se abre nada**: comprueba que la carpeta está en `CLAUDE_CODE_PLUGIN_DIRS`, que reiniciaste Claude Code y que PowerShell puede ejecutar scripts locales. Prueba `/monitor`.
- **La primera vez tarda mucho**: está compilando la parte en C#; las siguientes veces es inmediato.
- **Una sesión sale como SIN DATOS**: se abrió antes de instalar el mod. En cuanto le envíes un mensaje aparece su estado.
- **"Ir a su terminal" no encuentra la pestaña**: el monitor busca la pestaña de Windows Terminal por su título; si lo cambiaste a mano, abre Windows Terminal sin seleccionar pestaña.
- **Cerrar el monitor reanuda las sesiones pausadas**: es a propósito, para que nada se quede congelado sin que lo veas.
