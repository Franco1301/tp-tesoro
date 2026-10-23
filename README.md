# Búsqueda del tesoro geolocalizada

TP de la materia **[COMPLETAR: materia]** – **[COMPLETAR: facultad]** – docente Antonio Martinez.
Integrantes: **[COMPLETAR: nombres y apellidos]**.

Aplicación web para jugar una búsqueda del tesoro en una plaza (o en cualquier lugar del mundo). Quien organiza crea su propia partida desde `/admin/` y los jugadores entran con un link `?p=CODIGO`.

## Cómo funciona

- **Página web** (HTML + JavaScript + Leaflet/OpenStreetMap) publicada en GitHub Pages (HTTPS, necesario para el GPS).
- **Servidor**: Supabase (Postgres). La página solo llama a funciones del servidor (`/rest/v1/rpc/...`) con la clave pública (publishable). Las tablas no se pueden leer ni escribir directamente (RLS activado sin políticas).
- **El servidor decide todo**: si el equipo llegó (distancia por Haversine), cuánto tardó, el puntaje y el ranking. El celular solo informa su posición; no puede decidir que "ganó".
- Los puntos que faltan **no se envían** al celular: solo se ve la pista del punto actual y los ya encontrados.

Archivos: `index.html` y `config.json` (jugadores), `admin/index.html` (organizador), `admin/datos.html` (datos personales, solo organizador), `schema_v2.sql` → `schema_v3.sql` → `schema_v4.sql` → `schema_v5.sql` (base de datos, en ese orden).

## Uso

**Organizador** (`/admin/`): elige nombre y contraseña, modo (presencial con GPS o a distancia marcando en el mapa), qué datos pedir, el puntaje, y marca los puntos en el mapa (con pista de plantilla o propia, radio y hasta 2 pistas adicionales por punto con su costo). Recibe un código de partida y un link para compartir. En el panel ve en todo momento: equipos con puntaje y tiempo, avance, participantes, y la **tabla histórica**.

**Jugadores**: entran con el link o el código, ven la tabla histórica, registran el equipo (1 a 3 personas) o se unen a un equipo existente, y juegan.

### Puntaje
- Cada lugar da **puntos base** (por defecto 100) más un **bonus por velocidad** (hasta 50) que baja de forma lineal hasta 0 a los 10 minutos desde que se reveló la pista. Todo configurable por el organizador.
- **Pistas adicionales** (opcionales, el organizador escribe el texto y el costo; por defecto 20 puntos): se piden de a una, en orden, se cobran una sola vez y el puntaje nunca baja de 0.
- Con código de respaldo se suman los puntos base pero no el bonus.
- Los jugadores ven su puntaje, el tiempo y el bonus actual mientras juegan. La **tabla histórica** guarda cada equipo que termina (puntaje y tiempo) y se conserva aunque se reinicie la partida.

### Mensajes de cercanía
Se miden desde el borde del círculo del punto, en franjas de 10 m: muy cerca (<10 m), cerca (10–20), lejos (20–30), muy lejos (30–40) y demasiado lejos (>40 m).

### Menores de 18
La edad siempre se pide. Si alguien tiene menos de 18, el formulario pide nombre, teléfono y autorización de madre, padre o tutor; el servidor lo exige y el organizador lo ve marcado como menor.

### Un equipo en varias pantallas
Cada equipo tiene un **código de equipo** (6 caracteres) que se ve en la pantalla de juego. Otra persona, desde otro celular, elige "Mi equipo ya existe", escribe el código y sus propios datos (con su consentimiento), y queda en el mismo equipo (máximo 3 personas registradas). Las pantallas se sincronizan solas cada pocos segundos.

## Datos personales (Ley 25.326)
- Se guardan solo en la base protegida, nunca en el repositorio, ni en el ranking ni en la tabla histórica (que solo muestran el nombre del equipo).
- Cada participante acepta expresamente (se guarda versión y fecha del texto). El texto está en `config.json`, campo `consentimiento`.
- Solo los ve el organizador con su contraseña. Se **borran automáticamente a los 30 días**, o antes con el botón "Borrar datos personales ahora" de `admin/datos.html`.
- Derechos de acceso, rectificación y supresión: contacto **[COMPLETAR: mail del grupo o del organizador]**. Autoridad de control: AAIP.

## Análisis de amenazas y medidas

| Amenaza | Medida |
|---|---|
| Leer o modificar tablas con la clave pública | RLS sin políticas; solo funciones con permiso explícito; las funciones internas no están expuestas |
| Falsificar la ubicación (GPS falso) | Distancia validada en el servidor; control de velocidad entre puntos (>12 m/s se rechaza); los puntos que faltan nunca se envían al celular |
| Adivinar la contraseña del organizador | bcrypt; 5 fallos bloquean la partida 5 min; 1 s por intento; contraseñas muy fáciles rechazadas |
| Adivinar el código de respaldo | 6 caracteres (32 símbolos); 5 fallos bloquean al equipo 5 min |
| Adivinar códigos de equipo | 10 fallos bloquean las uniones a esa partida 2 min |
| Trampa con pedidos simultáneos / doble cobro | Bloqueo de fila por equipo; claves primarias que impiden repetir llegadas o pistas |
| Spam de equipos | Máximo 100 equipos por partida; validación de todos los campos en el servidor |
| XSS / inyección | Todo texto de usuario se muestra con `textContent`; SQL parametrizado dentro de funciones |
| Inyección de fórmulas en el CSV | Se neutralizan celdas que empiezan con `= + - @` |
| Fuga de datos personales | Plazo de 30 días, borrado manual, consentimiento versionado, página de datos sin impresión |

Limitaciones conocidas: el bloqueo por intentos puede usarse para molestar a un organizador (se libera solo a los 5 min); en modo a distancia las franjas de 10 m permiten ir acercándose por ensayo y error; los jugadores del mismo equipo comparten el código de equipo, quien lo tenga puede unirse.

## Instalación
1. Supabase → SQL Editor: correr `schema_v2.sql`, `schema_v3.sql`, `schema_v4.sql` y `schema_v5.sql` en ese orden (v5 se puede repetir sin problema).
2. Subir al repositorio, con estos nombres exactos, `index.html`, `config.json`, `admin/index.html` y `admin/datos.html`. **Subir los HTML nuevos enseguida de correr v5**: las páginas viejas del organizador dejan de funcionar con el servidor nuevo.
3. En `config.json` completar `servidor.url` y `servidor.clave` (clave pública/publishable; **nunca** la service_role ni la contraseña de la base) y el contacto del consentimiento.
4. Activar GitHub Pages. Si se ve una versión vieja, abrir en ventana privada o agregar `?v=2` al link.

## Pruebas realizadas
Se probó con una base Postgres local y un navegador automático (Chromium): creación de partida, menores con y sin tutor, franjas de cercanía, bonus, pistas con costo y puntaje, historial y reinicio, dos equipos en distintos dispositivos, bloqueos de contraseña, códigos y uniones, permisos de la clave pública sobre tablas y funciones internas, y migración repetida. El mapa real (Leaflet) no pudo cargarse en ese entorno y se simuló.
Pruebas manuales del grupo: **[COMPLETAR: qué se verificó a mano]**. Prueba de campo (25/10): **[COMPLETAR: resultados]**.

