# Toasty

Moniteur système discret pour la barre de menus de macOS.

> A discreet system monitor for the macOS menu bar.

> Un discreto monitor de sistema para la barra de menús de macOS.

---

## 🇫🇷 Français

### Qu'est-ce que c'est ?

Toasty est un petit moniteur système qui s'incruste poliment dans la barre de menus de macOS. Il espionne discrètement ce que fait votre Mac, toutes les 2 secondes, pour vous le résumer sans jamais vous casser les oreilles.

Pas de chiffres qui dansent dans tous les sens, pas d'interface envahissante : juste quelques jauges qui grandissent ou rapetissent. Un simple clic vous dévoile tous les détails.

### Fonctionnalités

- **CPU** — Charge totale et une barre par cœur, affichées **dans l'ordre naturel du système** (Cœur 1, Cœur 2, ...). Vous pouvez ainsi suivre un cœur précis dans le temps, sans voir ses numéros sauter à chaque rafraîchissement.
- **GPU** — Utilisation du GPU intégré. S'il travaille dur, ça se voit.
- **Mémoire (RAM)** — Mémoire active, compressée et liée. Parce que macOS adore compresser tout ce qu'il peut pour gagner de la place.
- **Réseau** — Débits descendant/montant lissés sur 6 secondes, avec détection automatique de l'interface active. Échelle logarithmique (vert < ~1,48 Mo/s, jaune < ~3,88 Mo/s, rouge au-delà). On mesure ce qui circule vraiment, sans deviner la bande passante théorique (qu'il est impossible de lire proprement sur macOS).
- **Température** — Pic du die SoC. Sur Apple Silicon, CPU et GPU partagent le même die : tous les capteurs thermiques évoluent ensemble. On affiche donc honnêtement le pic du die, plutôt que d'inventer une séparation qui n'existe pas.
- **Batterie** — **Temps restant** affiché directement dans la barre de menus (ex. `1h23`, `⚡ 27 min`). Devient **rouge** lorsque le niveau descend sous 20 %. Simple, lisible et efficace.

L'en-tête du panneau détaillé affiche le modèle de Mac à gauche, et la puce + nombre de cœurs à droite, sur la même ligne :

```
MAC - 17.3                                   Apple M5 - 10 cœurs
```

### Prérequis

- macOS 14 ou ultérieur
- Swift (Command Line Tools installés)
- **Apple Silicon uniquement** (les Macs Intel n'exposent pas `machdep.cpu.brand_string`)

### Compilation et lancement

```bash
./build.sh            # Compile build/Toasty.app (uniquement dans build/)
open build/Toasty.app
```

Pour l'installer directement dans `/Applications` :

```bash
./build.sh --install  # Copie (jamais un déplacement) vers /Applications
```

> Par défaut, le build n'écrit que dans `build/`, à côté des sources. L'option `--install` effectue une **copie** dans `/Applications` — jamais un déplacement. Comme un élément de connexion (Login Item) pointe vers un chemin fixe, cette copie évite qu'un rebuild ou un nettoyage ne casse votre lancement automatique. Un argument inconnu est rejeté avec le code de sortie 2 (plutôt qu'ignoré), histoire de vous avertir gentiment en cas de faute de frappe.

### Utilisation

1. Lancez `Toasty.app` (manuellement ou au démarrage).
2. Il apparaît discrètement dans la barre de menus (à droite, dans la zone des icônes système).
3. Cliquez sur l'icône pour afficher le panneau détaillé.
4. Cliquez à nouveau (ou cliquez hors du panneau) pour le fermer. C'est tout.

### Démarrage automatique

**Réglages Système → Général → Éléments de connexion et extensions → +**

Dans le sélecteur de fichiers : `⌘⇧G`, collez `/Applications` (si installé avec `--install`) ou `/Users/<votre-nom>/Downloads/swift_stat/build`, puis sélectionnez `Toasty.app`. Vous pouvez aussi le glisser directement dans la liste.

Pour le retirer : sélectionnez-le dans la liste → `-`.

**Remarques utiles :**
- **Pas de relance automatique après un crash.** Si l'application plante (fort peu probable ici), elle restera inactive jusqu'à votre prochaine connexion.
- **Un élément de connexion pointe vers un chemin, pas une copie.** Si vous déplacez ou supprimez le `.app`, il faudra le rajouter. C'est pourquoi la copie dans `/Applications` est recommandée.
- **Option plus robuste :** un LaunchAgent (`~/Library/LaunchAgents/local.Toasty.plist`) avec `KeepAlive` + `SuccessfulExit: false` permet la relance automatique après un crash, tout en respectant un `⌘Q` propre.

### Structure du projet

| Fichier | Rôle |
| --- | --- |
| `Sensors/Sensors.swift` | Lecteurs bas-niveau : CPU, RAM, réseau, batterie, GPU, températures (IOKit/Darwin). |
| `App/StatusItemView.swift` | Affichage des jauges et du temps de batterie dans la barre de menus (dessin NSView). |
| `App/PopupView.swift` | Panneau détaillé affiché au clic (dessin NSView). |
| `App/AppDelegate.swift` | Orchestration : status item, timer 2s, lissage réseau, couleurs. |
| `App/main.swift` | Point d'entrée explicite de l'application. |
| `verify/` | Outils de rendu hors-écran pour générer les captures de référence (clair/sombre). |
| `build.sh` | Script de build, empaquetage `.app`, strip et signature ad-hoc. |
| `.swiftlint.yml` | Configuration SwiftLint avec justifications explicites. |

### Licence

Distribué sous licence [MIT](LICENSE).

### Remerciements & notes techniques

- **Ownership IOKit soigné.** Utilisation systématique de `Unmanaged<T>` là où IOKit renvoie un `+1` retain. Pas de double-free à l'horizon.
- **Appel direct de `host_processor_info`.** Ce symbole n'est pas exposé dans le SDK, il est invoqué via `@_silgen_name` — un petit coup de pouce bien poli au linker.
- **Températures honnêtes.** Sur les macOS récents, `IOReport` a disparu de l'espace utilisateur. Tous les capteurs du die évoluent ensemble : on affiche donc le pic du die plutôt que d'inventer une séparation CPU/GPU qui n'existe pas.
- **Signal batterie fiable.** L'état « charge limitée » (Optimisation de la charge, ~80 %) est détecté via le **bit 24** de `ChargerData.NotChargingReason` (IOKit), et non déduit du pourcentage. Il suit la décision réelle de macOS.
- **Réseau en échelle logarithmique.** Un pic de téléchargement n'est pas un niveau de charge linéaire. Et la vitesse négociée du lien n'est tout simplement pas lisible de façon fiable sur macOS.
- **Extrêmement léger.** Bundle ~184 Ko (176 Ko pour le binaire). `strip -x` avant signature économise 48 Ko (21 %). Projet complet (sources + vérifs) : 328 Ko. Aussi léger qu'un gremlin bien élevé.

---

## 🇬🇧 English

### What is it?

Toasty is a discreet system monitor that politely sits in your macOS menu bar. It keeps a nosy little eye on what your Mac is up to every 2 seconds, and sums it up without ever raising its voice.

No numbers frantically jumping around, no cluttered interface — just a few bars that grow or shrink. One click reveals all the gory details.

### Features

- **CPU** — Total load plus one bar per core, shown in **natural system order** (Core 1, Core 2, ...). This lets you track a specific core over time instead of watching its numbers play musical chairs on every refresh.
- **GPU** — Integrated GPU utilization. If it's working hard, you'll see it.
- **Memory (RAM)** — Active, compressed, and wired memory. Because macOS loves compressing things to save space.
- **Network** — Download/upload throughput smoothed over 6 seconds, with automatic active interface detection. Logarithmic scale (green < ~1.48 MB/s, yellow < ~3.88 MB/s, red above). We measure what actually flows, without guessing link bandwidth (which isn't reliably readable on macOS).
- **Temperature** — SoC die peak. On Apple Silicon, CPU and GPU share the same die — all thermal sensors move together. So we honestly show the die peak instead of inventing a CPU/GPU split that doesn't exist.
- **Battery** — **Remaining time** shown directly in the menu bar (e.g. `1h23`, `⚡ 27 min`). Turns **red** when below 20%. Simple, readable, no fuss.

The detailed panel header shows the Mac model on the left and chip + core count on the right, on the same line:

```
MAC - 17.3                                   Apple M5 - 10 cœurs
```

### Requirements

- macOS 14 or later
- Swift (Command Line Tools installed)
- **Apple Silicon only** (Intel Macs don't expose `machdep.cpu.brand_string`)

### Build & Run

```bash
./build.sh            # Builds build/Toasty.app (build/ only)
open build/Toasty.app
```

To install cleanly into `/Applications`:

```bash
./build.sh --install  # Copies (never moves) to /Applications
```

> By default it only writes to `build/` next to the sources. `--install` makes a **copy** to `/Applications` — never a move. Since Login Items point to a fixed path, copying to `/Applications` avoids breakage if you rebuild or tidy up your folders. Unknown arguments are rejected with exit code 2 (not silently ignored), so typos like `--instal` will politely let you know.

### Usage

1. Launch `Toasty.app` (manually or at login).
2. It'll appear discreetly in the menu bar (top-right, system icons area).
3. Click the icon to show the detailed panel.
4. Click again (or outside the panel) to close it. That's it.

### Launch at Login

**System Settings → General → Login Items & Extensions → +**

In the file picker: `⌘⇧G`, paste `/Applications` (if installed with `--install`) or `/Users/<your-name>/Downloads/swift_stat/build`, pick `Toasty.app`. Or just drag it from Finder into the list.

To remove: select it in the list → `-`.

**Honest caveats:**
- **No auto-restart on crash.** If it crashes (very unlikely here), it'll stay down until your next login.
- **Login Item is a path, not a copy.** If you move or delete the `.app`, you'll need to re-add it. That's why the `/Applications` copy is recommended.
- **Sturdier option:** a LaunchAgent at `~/Library/LaunchAgents/local.Toasty.plist` with `KeepAlive` + `SuccessfulExit: false` will restart on crash while still honoring a clean `⌘Q`.

### Project Structure

| File | Purpose |
| --- | --- |
| `Sensors/Sensors.swift` | Low-level readers: CPU, RAM, network, battery, GPU, temperatures (IOKit/Darwin). |
| `App/StatusItemView.swift` | Renders gauges + battery time in menu bar (`NSView.draw(_:)`). |
| `App/PopupView.swift` | Detailed panel on click (`NSView.draw(_:)`). |
| `App/AppDelegate.swift` | Wiring: status item, 2s timer, network smoothing, colors. |
| `App/main.swift` | Explicit app entry point. |
| `verify/` | Offscreen rendering tools to generate light/dark reference captures. |
| `build.sh` | Build script, `.app` packaging, strip, ad-hoc signing. |
| `.swiftlint.yml` | SwiftLint config with explicit justifications. |

### License

Released under the [MIT License](LICENSE).

### Acknowledgements & Technical Notes

- **Proper IOKit ownership.** Uses `Unmanaged<T>` wherever IOKit returns a `+1` retain. No double-frees in sight.
- **Calls `host_processor_info` by hand.** Undeclared in the SDK, reached via `@_silgen_name` — politely cheating the linker.
- **Honest temperatures.** On recent macOS, `IOReport` was removed from userspace. All die sensors move together, so we show the die peak instead of fabricating a CPU/GPU split that doesn't exist.
- **Reliable battery signal.** The "charge limited" state (Optimized Battery Charging, ~80%) comes from bit 24 of `ChargerData.NotChargingReason` (IOKit), not inferred from percentage. It follows what macOS actually decided.
- **Logarithmic network scale.** A download spike isn't a linear "load level". Also, negotiated link speed isn't reliably readable on macOS.
- **Ridiculously lightweight.** ~184 KB bundle (176 KB binary). `strip -x` before signing saves 48 KB (21%). Full project (sources + verify): 328 KB. Light as a well-behaved gremlin.

---

## 🇪🇸 Español

### ¿Qué es?

Toasty es un pequeño monitor de sistema que se instala con educación en la barra de menús de macOS. Vigila discretamente qué hace tu Mac cada 2 segundos y te lo resume sin levantar nunca la voz.

Sin números saltando de un lado a otro, sin una interfaz invasiva: solo unas cuantas barras que crecen o se encogen. Un clic te revela todos los detalles.

### Características

- **CPU** — Carga total y una barra por núcleo, mostradas **en el orden natural del sistema** (Núcleo 1, Núcleo 2, ...). Así puedes seguir un núcleo concreto a lo largo del tiempo, sin ver cómo sus números se recolocan en cada actualización.
- **GPU** — Utilización de la GPU integrada. Si trabaja duro, se nota.
- **Memoria (RAM)** — Memoria activa, comprimida y *wired*. Porque a macOS le encanta comprimir todo lo que puede para ganar espacio.
- **Red** — Caudales de descarga/subida suavizados en 6 segundos, con detección automática de la interfaz activa. Escala logarítmica (verde < ~1,48 MB/s, amarillo < ~3,88 MB/s, rojo por encima). Medimos lo que realmente circula, sin adivinar el ancho de banda del enlace (que no se puede leer de forma fiable en macOS).
- **Temperatura** — Pico del die del SoC. En Apple Silicon, CPU y GPU comparten el mismo die: todos los sensores térmicos evolucionan a la vez. Por eso mostramos honestamente el pico del die, en lugar de inventar una separación CPU/GPU que no existe.
- **Batería** — **Tiempo restante** mostrado directamente en la barra de menús (p. ej. `1h23`, `⚡ 27 min`). Se pone en **rojo** cuando el nivel baja del 20 %. Sencillo, legible y sin complicaciones.

La cabecera del panel detallado muestra el modelo del Mac a la izquierda y el chip + número de núcleos a la derecha, en la misma línea:

```
MAC - 17.3                                   Apple M5 - 10 cœurs
```

### Requisitos

- macOS 14 o posterior
- Swift (Command Line Tools instalados)
- **Solo Apple Silicon** (los Mac Intel no exponen `machdep.cpu.brand_string`)

### Compilación y ejecución

```bash
./build.sh            # Compila build/Toasty.app (solo dentro de build/)
open build/Toasty.app
```

Para instalarlo directamente en `/Applications`:

```bash
./build.sh --install  # Copia (nunca mueve) a /Applications
```

> Por defecto, la compilación solo escribe en `build/`, junto a las fuentes. La opción `--install` hace una **copia** en `/Applications` — nunca un movimiento. Como un elemento de inicio de sesión apunta a una ruta fija, esa copia evita que una recompilación o una limpieza rompan tu arranque automático. Un argumento desconocido se rechaza con el código de salida 2 (en vez de ignorarse en silencio), así que un `--instal` mal escrito te avisará con educación.

### Uso

1. Lanza `Toasty.app` (manualmente o al iniciar sesión).
2. Aparecerá discretamente en la barra de menús (arriba a la derecha, en la zona de iconos del sistema).
3. Haz clic en el icono para mostrar el panel detallado.
4. Haz clic otra vez (o fuera del panel) para cerrarlo. Eso es todo.

### Inicio automático

**Ajustes del Sistema → General → Elementos de inicio de sesión y extensiones → +**

En el selector de archivos: `⌘⇧G`, pega `/Applications` (si lo instalaste con `--install`) o `/Users/<tu-nombre>/Downloads/swift_stat/build` y selecciona `Toasty.app`. También puedes arrastrarlo directamente desde Finder a la lista.

Para quitarlo: selecciónalo en la lista → `-`.

**Notas honestas:**
- **Sin reinicio automático tras un fallo.** Si la aplicación peta (muy poco probable aquí), se quedará inactiva hasta tu próximo inicio de sesión.
- **Un elemento de inicio de sesión es una ruta, no una copia.** Si mueves o borras el `.app`, tendrás que volver a añadirlo. Por eso se recomienda la copia en `/Applications`.
- **Opción más robusta:** un LaunchAgent (`~/Library/LaunchAgents/local.Toasty.plist`) con `KeepAlive` + `SuccessfulExit: false` reinicia automáticamente tras un fallo, todo respetando un `⌘Q` limpio.

### Estructura del proyecto

| Archivo | Rol |
| --- | --- |
| `Sensors/Sensors.swift` | Lectores de bajo nivel: CPU, RAM, red, batería, GPU, temperaturas (IOKit/Darwin). |
| `App/StatusItemView.swift` | Dibuja las barras y el tiempo de batería en la barra de menús (`NSView.draw(_:)`). |
| `App/PopupView.swift` | Panel detallado al hacer clic (`NSView.draw(_:)`). |
| `App/AppDelegate.swift` | Orquestación: status item, temporizador de 2 s, suavizado de red, colores. |
| `App/main.swift` | Punto de entrada explícito de la aplicación. |
| `verify/` | Herramientas de renderizado fuera de pantalla para generar las capturas de referencia (claro/oscuro). |
| `build.sh` | Script de compilación, empaquetado `.app`, strip y firma ad-hoc. |
| `.swiftlint.yml` | Configuración de SwiftLint con justificaciones explícitas. |

### Licencia

Distribuido bajo la [Licencia MIT](LICENSE).

### Agradecimientos y notas técnicas

- **Propiedad de IOKit cuidada.** Uso sistemático de `Unmanaged<T>` donde IOKit devuelve un `+1` retain. Ni una doble liberación a la vista.
- **Llamada directa a `host_processor_info`.** Este símbolo no está declarado en el SDK, así que se invoca vía `@_silgen_name` — un pequeño favor muy educado al linker.
- **Temperaturas honestas.** En las versiones recientes de macOS, `IOReport` ha desaparecido del espacio de usuario. Todos los sensores del die evolucionan a la vez, así que mostramos el pico del die en vez de fabricar una separación CPU/GPU que no existe.
- **Señal de batería fiable.** El estado de «carga limitada» (Optimización de carga, ~80 %) se detecta mediante el **bit 24** de `ChargerData.NotChargingReason` (IOKit), y no se deduce del porcentaje. Sigue la decisión real de macOS.
- **Red en escala logarítmica.** Un pico de descarga no es un «nivel de carga» lineal. Y la velocidad negociada del enlace sencillamente no se puede leer de forma fiable en macOS.
- **Absurdamente ligero.** Bundle de ~184 KB (176 KB el binario). `strip -x` antes de firmar ahorra 48 KB (21 %). Proyecto completo (fuentes + verificaciones): 328 KB. Ligero como un duende bien criado.
