# Búsqueda del tesoro geolocalizada

Aplicación web para organizar búsquedas del tesoro en cualquier plaza del mundo. Un organizador crea su partida marcando los puntos en un mapa; los equipos juegan desde el celular, sin instalar nada. Cada pista se libera solo si el equipo está físicamente en el lugar, y esa validación la hace el servidor, no el navegador.

Trabajo práctico: *Búsqueda del tesoro geolocalizada con QR* 
Entrega final: viernes 23/10/2026.



---

## 1. Grupo

**Integrantes**

- | Franco Parrella | Supervisor |
- | Candela Alvarez | Desarrollo |
- | Bautista Brambilla | Desarrollo |
- | Yaco Yajia | Tester |
-
- **Universidad:** Universidad del Salvador (USAL)
- **Facultad:** de Ingeniería
- **Materia:** Paradigmas de Programación
- **Docente:** Antonio Martinez
- **Repositorio:** https://github.com/franco1301/tp-tesoro
- **Aplicación publicada:** https://franco1301.github.io/tp-tesoro/
- **Panel del organizador:** https://franco1301.github.io/tp-tesoro/admin/


---

## 2. Cómo se juega

**Organizador** (`/admin/`)

1. Busca la plaza (o usa su ubicación) y el mapa se acerca.
2. Elige un tipo de pista de la lista (fuente, estatua, árbol grande, frente a la iglesia, juegos, mesas de ajedrez, banco, mástil, cancha, kiosco u otro) y toca el mapa donde está ese lugar.
3. Ajusta cada punto: lo puede arrastrar, cambiar el radio de la geocerca (3 a 100 m), editar el texto de la pista, reordenar o quitar. Puede haber de 1 a 30 puntos.
4. Pone nombre al juego y una contraseña de organizador (mínimo 6 caracteres) y crea la partida. Recibe un **código de 6 caracteres**.
5. Define el **puntaje** (puntos por lugar, bonus máximo por velocidad y minutos en que el bonus llega a 0) y, si quiere, hasta 2 **pistas adicionales** por punto: escribe el texto y elige cuántos puntos cuestan (por defecto 20).
6. En el panel ve el estado del juego, los equipos con **puntaje y tiempo**, sus participantes (con los datos del tutor si son menores), los **códigos de respaldo** de cada punto, la **tabla histórica** (siempre visible), y puede imprimir y reiniciar la partida.
7. Cuando los equipos están registrados, aprieta **"Iniciar el juego"**: recién ahí aparece la primera pista y empieza a correr el tiempo.

**Jugadores** (`/?p=CODIGO`)

1. Entran con el link o escriben el código de partida.
2. Ven la **tabla histórica** de la partida (antes y durante el juego).
3. Registran el equipo (1 a 3 participantes). Quien tenga menos de 18 años necesita la autorización de madre, padre o tutor. Un compañero puede sumarse **desde otro celular** con el **código de equipo** (6 caracteres, visible en la pantalla de juego).
4. Esperan en la **sala de espera** (el tiempo no corre) hasta que el organizador inicia el juego.
5. Leen la pista del punto 1, la buscan en la plaza y, cuando creen estar ahí, tocan **Llegué al punto**.
6. El servidor verifica la posición. Si es correcta suma puntos (base + bonus por velocidad) y aparece la pista siguiente. Si no, el mensaje cambia cada 10 m medidos desde el borde del círculo: *muy cerca* (<10 m), *cerca*, *lejos*, *muy lejos* y *demasiado lejos* (más de 40 m).
7. Pueden pedir **pistas adicionales** (cuestan puntos, de a una y en orden; nunca se cobran dos veces).
8. Si el GPS falla, pueden escribir el **código de respaldo** del cartel (suma los puntos base, sin bonus).
9. Ven su puntaje y tiempo mientras juegan. Al completar todos los puntos el cronómetro se detiene y el equipo queda en la tabla histórica con puntaje, tiempo, día y hora, e integrantes (nombre e inicial del apellido).

Los jugadores **nunca reciben las coordenadas** de los puntos, solo la pista del punto actual.

---

## 3. Arquitectura

```
 Celular / navegador                       Supabase (plan gratuito)
┌─────────────────────────┐   HTTPS    ┌──────────────────────────────┐
│ GitHub Pages (estático) │ ─────────► │ PostgreSQL + funciones SQL   │
│  · index.html  (jugador)│  rpc/...   │  · crear_partida             │
│  · admin/index.html     │ ◄───────── │  · validar_llegada (haversine)│
│  · config.json          │            │  · validar_respaldo          │
│  · pedir_pista, unirse_equipo│
│  · admin_iniciar, historial  │
│ Leaflet + OpenStreetMap │            │  · admin_partida / reiniciar │
└─────────────────────────┘            │ Tablas con RLS, sin acceso   │
                                       │ directo para la clave pública│
                                       └──────────────────────────────┘
```

- **Cliente:** HTML + JavaScript sin instalación, dos páginas estáticas. Usa la Geolocation API y dibuja el mapa con Leaflet y OpenStreetMap (con la atribución requerida).
- **Servidor:** Supabase. Toda la lógica que decide algo (llegada, orden, tiempo, ranking, contraseñas) está en funciones SQL de los archivos `schema_v2.sql`, `schema_v3.sql`, `schema_v4.sql` y `schema_v5.sql` (se ejecutan en ese orden; ver sección 7). La clave pública solo puede **llamar a esas funciones**; no puede leer ni escribir las tablas.
- **Configuración:** `config.json` guarda la URL del servidor, la clave pública y las **plantillas de pistas**. No contiene coordenadas ni datos de ninguna plaza.

### Decisiones y alternativas

| Decisión | Alternativas consideradas | Por qué elegimos esta |
|---|---|---|
| Hosting en **GitHub Pages** | Netlify, Firebase Hosting | Gratis, HTTPS automático (obligatorio para la geolocalización) y el código ya está en GitHub. |
| Backend en **Supabase** (Postgres) | Firebase (Firestore + Functions) | La validación se escribe como una función SQL transaccional: el bloqueo de fila evita validaciones simultáneas y la clave primaria evita duplicados. Firestore exige más código y reglas de seguridad más difíciles de probar. |
| Lógica en **funciones SQL** (`security definer`) | Edge Functions de Supabase | No hay nada que desplegar aparte: se pega un SQL. Se pudo probar la lógica entera en un Postgres local. |
| Mapa con **Leaflet + OpenStreetMap** | Google Maps API | La API de Google exige cuenta de facturación y contradice la restricción de costo cero. |
| Búsqueda de lugares con **Nominatim** (OSM) | Geocoding de Google | Gratuito. Solo se consulta cuando el organizador aprieta *Buscar* (la política de uso de OSM pide poco tráfico). |
| Contraseña **por partida** (bcrypt) | Supabase Auth con email | No exige mails de confirmación ni configurar un proveedor; cualquiera crea su partida en un minuto. |
| El servidor **decide el punto siguiente** | Que el cliente envíe qué punto quiere validar | El cliente no puede saltear el orden ni probar puntos al azar. |
| **Reloj del servidor** para el cronómetro | Reloj del celular | No se puede adelantar ni atrasar desde el navegador. |

---

## 4. Mecanismo de descubrimiento y validación

> **Pendiente de aprobación del docente**, como pide la consigna.

**Propuesta:** *pistas por tipo de lugar + geocerca verificada en el servidor + código manual de respaldo.*

- **Descubrimiento:** la pista es un texto que describe un elemento típico de una plaza (por ejemplo "buscá el lugar donde el agua nunca deja de caer"). Los equipos tienen que reconocer el lugar. No hay que imprimir ni pegar nada para jugar.
- **Validación:** el equipo toca *Llegué*, el celular envía su posición y la precisión del GPS, y el servidor calcula la distancia (fórmula de haversine) al punto que corresponde. Acepta si está dentro del radio del punto más un margen por imprecisión (hasta 15 m, según la precisión que informe el GPS).
- **Respaldo:** cada punto tiene un código manual que el organizador escribe en un cartel en el lugar. Sirve cuando el GPS falla. Se registra cuántas veces se usó.

| Mecanismo | Por qué no lo elegimos (o cómo se combina) |
|---|---|
| **QR en el lugar** | Exige imprimir y pegar códigos en cada plaza y vuelve más difícil que cualquier persona cree una partida desde cualquier lugar del mundo. El código de respaldo cumple un rol parecido (confirma presencia física) sin depender de imprimir. |
| **Marco Polo** (caliente/frío) | Divertido, pero depende de un GPS impreciso: con 5 a 20 m de error la respuesta se vuelve ruido en una plaza chica. |
| **Brújula tramposa** | Necesita permiso y calibración de la brújula (en iOS es complicado) y es difícil de verificar en el servidor. |

Como no se usan QR, no hace falta un generador de códigos imprimibles.

---

## 5. Modelo de datos

| Tabla | Contenido |
|---|---|
| `partidas` | `codigo` (clave), nombre, hash bcrypt de la contraseña del organizador, centro del mapa, duración, modo, datos a pedir, **puntaje (base, bonus máximo, minutos del bonus, costo de pistas), `iniciada_en`** y contadores de bloqueo. |
| `puntos` | `partida_codigo`, `orden`, `tipo`, `pista`, `lat`, `lng`, `radio_m`, `respaldo`. Clave: (partida, orden). |
| `equipos` | `id` (uuid), `partida_codigo`, nombre, `creado`, **`codigo_union`** (para sumarse desde otro celular) y contadores de bloqueo. Nombre único por partida. El cronómetro arranca en `iniciada_en` de la partida (o en `creado`, si el equipo se registró después). |
| `participantes` | `equipo_id`, `posicion`, nombre, apellido, edad, **teléfono, Instagram, consentimiento (versión y fecha), datos del tutor si es menor y `borrar_despues`**. Son datos personales: ver sección 10. |
| `llegadas` | `equipo_id`, `orden`, `creado`, distancia, precisión, `uso_respaldo`, **puntos y bonus**. Clave: (equipo, orden): **una llegada por equipo y punto**. |
| `pistas_extra` | Pistas adicionales de cada punto: texto y costo (hasta 2 por punto). |
| `pistas_usadas` | Pistas que compró cada equipo. Clave: (equipo, punto, número): **no se cobra dos veces**. |
| `historial` | Un registro por equipo que termina: nombre del equipo, puntaje, tiempo, inicio (día y hora), lugares e integrantes (nombre + inicial del apellido; se borra a los 30 días). **Sobrevive al reinicio de la partida.** |

Todas las tablas tienen **seguridad por filas activada y ninguna política**: con la clave pública no se puede leer ni escribir nada directamente. Todo pasa por estas funciones:

| Función | Quién la usa | Qué hace |
|---|---|---|
| `crear_partida` | organizador | Valida y crea la partida y sus puntos; genera el código de partida y los códigos de respaldo. |
| `admin_partida` | organizador (con contraseña) | Devuelve la partida completa, los códigos de respaldo, el ranking y **los datos de los participantes**. |
| `admin_iniciar` | organizador (con contraseña) | Inicia el juego: desde ese momento corre el tiempo y se revelan las pistas. |
| `admin_reiniciar` | organizador (con contraseña) | Borra equipos y llegadas, vuelve a la sala de espera; conserva el juego y la tabla histórica. |
| `admin_borrar_datos` | organizador (con contraseña) | Borra los datos personales de todos los participantes de la partida; los equipos y el ranking quedan. |
| `partida_info` | jugador | Nombre, centro del mapa, cantidad de puntos, puntaje y si ya empezó. **Sin coordenadas de los puntos.** |
| `historial` | jugador y panel | Tabla histórica de la partida (equipo, puntaje, tiempo, día y hora, integrantes). |
| `crear_equipo` | jugador | Crea el equipo **y registra a sus participantes** en una sola operación: si algo falla, no queda nada guardado. Valida cantidad (1 a 3), nombre, edad, teléfono, Instagram, consentimiento y datos del tutor de los menores. |
| `unirse_equipo` | jugador | Suma a una persona (con su propio consentimiento) a un equipo existente, con el código de equipo. 10 códigos incorrectos bloquean 2 min. |
| `mi_progreso` | jugador | Estado del equipo (puntaje, tiempo, si empezó) y **solo la pista del punto actual** más las pistas adicionales ya compradas. Para poder editar los datos, devuelve los datos de **los integrantes del propio equipo** a quien tiene el id del equipo; no se devuelven datos de otros equipos. |
| `pedir_pista` | jugador | Compra una pista adicional (en orden, una sola vez cada una). |
| `validar_llegada` | jugador | Verifica posición y orden. |
| `validar_respaldo` | jugador | Verifica el código manual. |
| `ranking` | jugador y panel | Equipos ordenados por puntaje, con tiempo. Sin datos personales. |

### Flujo de una validación

1. El cliente envía `equipo`, `lat`, `lng` y `precisión`. **No envía qué punto es.**
2. El servidor toma la fila del equipo (`for update`): dos pedidos simultáneos se procesan de a uno.
3. Cuenta las llegadas del equipo; el punto a validar es el siguiente.
4. Verifica que el juego esté iniciado, calcula la distancia con haversine y la compara con `radio + margen` (margen = precisión del GPS, con tope de 15 m).
5. Si está dentro, controla que la velocidad desde el punto anterior sea posible a pie (máximo 12 m/s), calcula el bonus por velocidad e inserta la llegada con sus puntos; la clave primaria impide duplicarla. Si no está dentro, responde solo la franja de cercanía (1 a 5).

### Recuperar el progreso y batería

- El equipo se guarda en el navegador (`localStorage`) y, si se recarga la página o se pierde la conexión, se recupera todo desde el servidor con `mi_progreso`.
- La ubicación se deja de pedir cuando la pantalla está apagada o la pestaña oculta, y se retoma al volver. El ranking se actualiza cada 30 s y las pantallas de un mismo equipo se sincronizan cada 4 s, solo con la pestaña visible.

---

## 6. Portabilidad: pasar el juego a otra plaza

Criterio de la consigna: *otro grupo, siguiendo solo el README, pasa el juego a otra plaza editando únicamente el JSON y regenerando el material, sin modificar código.*

En esta versión **no hace falta editar ningún archivo**: el organizador abre `/admin/`, busca la nueva plaza y marca los puntos en el mapa. Nada del lugar está escrito en el código.

Lo que sí se configura en `config.json` (sin tocar código):

| Campo | Para qué sirve |
|---|---|
| `servidor.url` y `servidor.clave` | A qué proyecto de Supabase se conecta. |
| `radioPorDefectoM` | Radio inicial de cada punto nuevo. |
| `puntaje` y `costoPistaPorDefecto` | Valores iniciales de puntaje (base, bonus, minutos) y costo de pistas adicionales; el organizador los puede cambiar. |
| `consentimiento` | Texto del aviso de privacidad y contacto. |
| `plantillas` | Los tipos de pista (nombre y texto). Se pueden agregar, quitar o traducir. |

El JSON de ejemplo de la consigna (puntos con id, nombre, latitud, longitud, radio, pista y respaldo) lo reemplaza la base de datos: esos datos viven en la tabla `puntos`.

---

## 7. Puesta en marcha desde cero

1. **Supabase:** crear una cuenta y un proyecto nuevo (plan Free). En *SQL Editor → New query* ejecutar, **en este orden**, uno por vez: `schema_v2.sql` (**borra las tablas existentes**: usarlo solo en la instalación inicial), `schema_v3.sql` (modo presencial/remoto y participantes con nombre, apellido y edad) y `schema_v4.sql` (registro completo con consentimiento, tutor, borrado y tamaño de equipo) y `schema_v5.sql` (puntaje, pistas adicionales, tabla histórica, inicio del juego por el organizador, equipos en varios celulares y medidas de seguridad). `schema_v4.sql` y `schema_v5.sql` **no borran datos** y se pueden ejecutar más de una vez. Si el proyecto ya tiene v2, v3 y v4 instalados, alcanza con ejecutar `schema_v5.sql`.
2. **Claves:** en *Project Settings → API* copiar la *Project URL* y la clave pública (`sb_publishable_...` o *anon*). **Nunca** usar ni publicar la clave `service_role` ni la contraseña de la base de datos.
3. **`config.json`:** pegar esos dos valores en el bloque `servidor`. La URL va sin `/rest/v1/` al final.
4. **GitHub Pages:** subir al repositorio `index.html`, `config.json`, `admin/index.html` y `admin/datos.html` (con la carpeta `admin`). **Ejecutar `schema_v5.sql` antes de subir las páginas nuevas** y subirlas enseguida: las páginas usan funciones que ese script crea, y las páginas viejas del organizador dejan de funcionar con el servidor nuevo. En *Settings → Pages* elegir la rama `main` y la carpeta `/ (root)`. Esperar a que termine el despliegue (tilde verde en el último commit).
5. **Probar:** abrir `/admin/`, crear una partida de prueba, abrir el link de jugador desde el celular y registrar un equipo de prueba; después entrar a `/admin/datos.html` con el código y la contraseña para ver los datos y comprobar que se pueden borrar.

Si la página muestra una versión vieja, abrirla en una pestaña privada o agregarle `?v=2` al final del link: el navegador guarda copias.

---

## 8. Estructura del repositorio

```
tp-tesoro/
├── index.html          Página del jugador
├── admin/
│   ├── index.html      Panel del organizador: crear y administrar la partida
│   └── datos.html      Datos personales de los participantes (solo organizador): ver, CSV, borrar
├── config.json         Servidor, plantillas de pistas, radio por defecto y texto de consentimiento
├── schema_v2.sql       Tablas, seguridad y funciones del servidor (base)
├── schema_v3.sql       Modo remoto y participantes (nombre, apellido, edad)
├── schema_v4.sql       Registro completo: contacto, consentimiento, tutor, borrado
├── schema_v5.sql       Puntaje, pistas, historial, inicio por el organizador, equipos multi-dispositivo, seguridad
└── README.md
```

Archivos de versiones anteriores del prototipo (`geocerca.py`, `generar_puntos.py`, `puntos.sql`, `schema.sql`) ya no se usan y pueden borrarse.

---

## 9. Análisis de amenazas

| Ataque | ¿Es posible? | Qué se hizo |
|---|---|---|
| **Compartir una pista, un QR o una URL con otro equipo** | **Sí, parcialmente.** Un equipo puede contarle a otro el texto de una pista o el código de partida. | No hay QR ni tokens en el lugar. Las coordenadas no viajan al cliente: aunque se comparta la pista, el otro equipo igual tiene que **estar físicamente en el punto** (GPS) y validar **en orden**. No se hicieron rutas distintas por equipo (opcional de la consigna). |
| **Adivinar tokens o saltear el orden de los puntos** | **El orden: no.** **Los códigos de respaldo: difícil pero no imposible.** | El cliente no elige el punto: el servidor valida siempre el siguiente. Los códigos de respaldo son de 6 caracteres (32 símbolos, más de mil millones de combinaciones); cada intento fallido tarda 1 s y 5 fallos seguidos bloquean al equipo 5 minutos. **Limitación:** crear equipos es gratis (hay un tope de 100 por partida), así que alguien podría probar códigos desde varios equipos; con ese espacio de combinaciones sigue siendo inviable. |
| **Suplantar la ubicación con un GPS falso** | **Sí.** El servidor solo ve las coordenadas que le envían y no puede distinguir una falsa. | Mitigación parcial: la tolerancia por imprecisión tiene tope de 15 m y el servidor decide el orden y el tiempo. Además, en modo presencial el servidor rechaza una llegada si, respecto del punto anterior, implica una velocidad de más de 12 m/s (imposible a pie): frena los saltos bruscos, pero no un GPS falso que simule un recorrido realista. |
| **Enviar validaciones repetidas o simultáneas para alterar el ranking** | **No.** | Cada validación toma la fila del equipo (`for update`), así que se procesan de a una; repetir una validación no suma nada porque la clave primaria es (equipo, punto). Se probó con 10 pedidos simultáneos del mismo punto: se registró uno solo. |
| **Acceder al panel del organizador sin credenciales** | **No sin la contraseña.** | Todas las funciones del panel verifican la contraseña (guardada con bcrypt). Las tablas no se pueden leer directamente (RLS sin políticas) y las funciones internas no son invocables con la clave pública. Cada contraseña incorrecta tarda 1 s. Se exige un mínimo de 6 caracteres, se rechazan contraseñas muy comunes y 5 fallos seguidos bloquean la partida 5 minutos. **Limitación:** ese bloqueo permite que alguien moleste al organizador (se libera solo a los 5 minutos). |

Otros riesgos revisados:

- **Código inyectado en textos** (nombres de juego, de equipo o pistas con HTML o JavaScript): todo texto del usuario se muestra con `textContent`, nunca como HTML. Se probó con `<img onerror=...>` y `<script>` y no se ejecuta.
- **Unirse a un equipo ajeno:** el código de equipo (6 caracteres) lo tiene quien lo reciba del equipo; 10 códigos incorrectos bloquean las uniones a la partida 2 minutos. Los equipos tienen un máximo de 3 integrantes registrados.
- **Crear partidas sin límite:** cualquiera con el link del sitio puede crear partidas. Queda como riesgo aceptado para un TP; la solución sería limitarlas por IP o exigir una invitación.

---

## 10. Datos personales (Ley 25.326)

**Qué se pide a cada participante:** nombre, apellido (según lo que elija el organizador), edad (siempre), teléfono e Instagram (o "No tengo Instagram"). Si es menor de 18: nombre y teléfono de madre, padre o tutor y la marca de que autoriza.

**Cómo se protege y qué se hizo:**

- **Consentimiento expreso e informado:** antes de cargar los datos se muestra el texto de `config.json` (finalidad, quién accede, plazo, derechos y la leyenda de la AAIP, órgano de control de la ley). Cada participante tiene que tildar su propio consentimiento; el servidor **rechaza** el registro si falta, y guarda la versión del texto aceptado y la fecha.
- **Finalidad limitada:** identificar equipos, contactar por la actividad y el informe del TP. No se usan para publicidad ni se ceden.
- **Tabla protegida:** `participantes` tiene seguridad por filas sin políticas; con la clave pública no se puede leer. Se probó que el rol público recibe "permission denied".
- **Solo el organizador accede:** con código y contraseña de la partida, en `/admin/datos.html`. El **ranking, la tabla histórica y la información de la partida no incluyen** teléfono, Instagram ni datos del tutor. La tabla histórica muestra solo nombre e inicial del apellido de los integrantes, y esto se informa en el texto de consentimiento. El estado del juego (`mi_progreso`) devuelve los datos de los integrantes del **propio** equipo a quien tiene el id del equipo (hace falta para editarlos); nunca los de otros equipos.
- **Nunca en el repositorio:** los datos viven en la base, no en el código, no en `config.json` y no en el navegador del jugador (solo se guarda el id del equipo; el formulario se vacía al registrarse). La página del organizador no imprime los datos.
- **Validación en el servidor:** cantidad de participantes, formato de teléfono y de usuario de Instagram, edad, consentimiento y datos del tutor se validan en la base, no solo en la página.
- **Menores de 18:** el registro exige datos de madre/padre/tutor y su autorización; el panel los marca como menores.
- **Borrado:** (1) automático, a los **30 días** del registro (campo `borrar_despues`; se purga en cada registro y cada consulta del organizador, sin necesidad de una tarea programada; **si nadie usa la app después de los 30 días, la purga espera a la próxima vez que alguien la use**, así que al terminar la actividad conviene borrar a mano con el botón), y (2) manual con el botón **"Borrar datos personales ahora"**, que borra todos los datos de la partida y deja equipos, ranking y tabla histórica (de esta última solo se quitan los nombres de los integrantes).
- **Exportación segura:** el CSV del organizador neutraliza celdas que empiezan con `=`, `+`, `-` o `@` para evitar fórmulas maliciosas en Excel.

**Qué falta confirmar con la USAL (no es algo que resuelva el código):**

- Que se puedan pedir teléfono e Instagram para esta actividad y el plazo de 30 días.
- Cómo se pide y guarda la autorización de menores (hoy es una casilla tildada por quien carga los datos; no hay firma ni verificación de que sea el tutor).
- Si hace falta inscribir la base en el Registro de la AAIP y quién es el **responsable de la base** (completar el contacto en `config.json`).
- Las páginas de Supabase y GitHub guardan datos en servidores en el exterior: revisar si corresponde informarlo en el texto de consentimiento.

---

## 11. Pruebas realizadas

- **Servidor:** las funciones SQL se probaron en un PostgreSQL local: orden de los puntos, repetición, tolerancia por precisión, código de respaldo, contraseña del organizador, reinicio y 10 validaciones simultáneas del mismo punto. También que la clave pública no puede leer ni escribir tablas ni llamar a funciones internas.
- **Registro y datos personales:** pruebas del SQL de `schema_v4.sql` (registro válido; rechazo por consentimiento faltante, teléfono o Instagram inválido, menor sin tutor o sin autorización, cantidad de participantes fuera de rango, nombre de equipo repetido, falta de versión del texto; que no queden equipos a medias; que ranking, progreso e información de la partida no filtren contacto; que el rol público no lea la tabla; borrado manual y por vencimiento; migración repetida sin pérdida de datos existentes) y **35 pruebas de navegador** (Chromium real contra ese SQL): formulario en celular, bloque de tutor al poner una edad menor a 18, validaciones antes de llamar al servidor, máximo de participantes, nombres con HTML inyectado, panel del organizador, CSV con neutralización de fórmulas, borrado, y partida en modo remoto.
- **Versión actual (`schema_v5.sql`):** pruebas en un PostgreSQL local (migración sobre v2+v3+v4 ejecutada dos veces, franjas de cercanía, bonus, control de velocidad con tiempos adelantados, pistas con costo y orden, puntaje, tabla histórica y reinicio, inicio por el organizador, unión a equipos, bloqueos de contraseña, de códigos de respaldo y de uniones, que la clave pública no lea tablas ni llame a funciones internas, borrado por vencimiento) y pruebas de navegador automático con tres sesiones: organizador que crea la partida y la inicia, un jugador menor con tutor, otro jugador que se une al mismo equipo desde otra pantalla, sala de espera, sincronización entre pantallas, tabla histórica con integrantes y fecha, y la página de datos.
- **De punta a punta (versión anterior):** 47 pruebas automáticas con un navegador Chromium real contra ese SQL: crear una partida en Tokio, editar puntos, jugar completa con y sin código de respaldo, recuperar el progreso al recargar, entrar al panel con contraseña correcta e incorrecta, reiniciar, y textos con código malicioso.
- **Límite de estas pruebas:** el mapa se simuló con un reemplazo de Leaflet y los tiles y la búsqueda de OpenStreetMap con respuestas simuladas, porque el entorno de pruebas no podía descargar Leaflet. **Falta verificar a mano** el dibujo del mapa, el arrastre de marcadores y la búsqueda de lugares, y probar con GPS real en un celular Android (Chrome) y uno iPhone (Safari).


---

## 12. Limitaciones conocidas y mejoras

- **Modo remoto:** en una partida remota no se verifica que el equipo esté físicamente en el lugar: marcan el lugar en el mapa (con vista satélite) y el servidor compara la marca con el punto. Es una elección del grupo para poder jugar a distancia; **el control de presencia por GPS solo vale en modo presencial**, y el análisis de amenazas de la sección 9 se refiere a ese modo.
- **Mapa satélite:** el modo remoto usa imágenes satélite de Esri, que no son de OpenStreetMap; hay que revisar sus condiciones de uso y mantener la atribución visible.
- **Registro:** la autorización de menores es una casilla, sin verificación de identidad; falta la confirmación legal de la USAL (sección 10).
- No hay desafíos por punto (acertijos, preguntas ni fotos), ni narrativa que se vaya revelando, ni insignias. Hoy la mecánica es: pista por tipo de lugar, orden, tiempo, puntaje con bonus por velocidad, pistas adicionales con costo y tabla histórica.
- **Tamaño de equipo:** el sistema admite 1 a 3 participantes; confirmar con el docente si la consigna exige otro tamaño.
- En modo remoto, las franjas de 10 m permiten acercarse al lugar por prueba y error.
- El control de velocidad no detecta un GPS falso que simule un recorrido realista.
- No hay modo contrarreloj ni rutas distintas por equipo (opcionales).
- El ranking solo se actualiza cada 30 s.
- Un organizador que olvida su contraseña no puede recuperarla: el hash no se puede revertir.

---

## 13. Uso de asistentes de IA

> La consigna permite usar IA si se declara para qué y qué se verificó a mano. Completar la parte de verificación.

**Para qué se usó:** Claude (Anthropic) se usó para planificar la entrega, escribir el código de las páginas, el SQL del servidor (incluido el registro con consentimiento y el borrado de datos), las pruebas automáticas y este README, y para explicar cómo usar GitHub y Supabase.

**Qué verificó el grupo a mano:** coordenadas tomadas en la plaza con Google Maps; prueba del mapa y el GPS en un celular real; lectura y explicación de cada función SQL; revisión del análisis de amenazas, verificación de código en general, del texto qe leen los suarios de la página, probar todas las funciones. 

Todo el código del repositorio tiene que poder ser explicado por cualquier integrante: el código que el grupo no pueda explicar se evalúa como no entregado.

---

## 14. Créditos y licencias

- Mapas: © colaboradores de [OpenStreetMap](https://www.openstreetmap.org/copyright). Los tiles y Nominatim se usan con el tráfico bajo de un curso, según su política de uso.
- [Leaflet](https://leafletjs.com/) (licencia BSD-2).
- [Supabase](https://supabase.com/) (plan gratuito) y [GitHub Pages](https://pages.github.com/).

