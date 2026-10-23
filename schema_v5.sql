-- =====================================================================
-- TP Búsqueda del tesoro - migración v5 (Supabase / Postgres)
-- Se corre ENCIMA de schema_v2.sql + schema_v3.sql + schema_v4.sql. No borra datos.
--
-- Agrega:
--   * Menores de 18: piden nombre, teléfono y autorización de madre, padre o tutor.
--     La edad pasa a ser siempre obligatoria (sin edad no se sabe si es menor).
--   * Equipos con varios celulares: cada equipo tiene un código; desde otra pantalla
--     se entra con ese código (unirse_equipo) y se comparte el mismo progreso.
--   * Mensajes de cercanía en 5 franjas de 10 m (medidos desde el borde del círculo).
--   * Puntaje: puntos por lugar + bonus por velocidad, y pistas adicionales que cuestan puntos.
--   * Tabla histórica por partida (sobrevive a "Reiniciar partida"): muestra puntaje, tiempo,
--     día y hora en que se jugó, e integrantes (nombre + inicial del apellido).
--   * El organizador inicia el juego (admin_iniciar). Hasta entonces los equipos se registran
--     y se juntan en una sala de espera, sin que corra el tiempo. Un equipo que se registra
--     con el juego ya iniciado empieza a contar desde que se registra.
--   * Seguridad: bloqueo tras 5 contraseñas de organizador incorrectas, bloqueo tras
--     5 códigos de respaldo incorrectos (por equipo) y tras 10 códigos de equipo incorrectos
--     (por partida), códigos de respaldo de 6 caracteres, tope de 100 equipos por partida,
--     control de velocidad entre puntos (contra GPS falso), contraseñas muy fáciles
--     rechazadas, borrado automático de datos personales a los 30 días, y
--     admin_borrar_datos para borrarlos antes.
--
-- IMPORTANTE:
--   * Las funciones de organizador (admin_*) ahora devuelven {"error": "..."} cuando la
--     contraseña es incorrecta, en lugar de lanzar un error. Hay que subir los
--     admin/index.html y admin/datos.html nuevos junto con este SQL.
--   * Correr este SQL y subir los HTML nuevos enseguida: con páginas viejas el panel y
--     el formulario de equipo dejan de funcionar hasta que se actualicen.
--
-- CÓMO USARLO: Supabase -> SQL Editor -> New query -> pegar TODO -> Run.
-- Se puede volver a correr sin problema.
-- =====================================================================

-- ---------- Limpiar versiones anteriores de las funciones que cambian ----------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as firma
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('crear_partida', 'crear_equipo', 'editar_equipo', 'unirse_equipo',
                        '_validar_participantes', '_insertar_participantes', 'ranking',
                        'pedir_pista', 'historial', '_historial_json', '_admin_check',
                        '_registrar_historial', '_score_equipo', '_purgar_vencidos',
                        'admin_borrar_datos', '_entero', 'admin_iniciar', '_inicio_equipo')
  loop
    execute 'drop function if exists ' || r.firma || ' cascade';
  end loop;
end $$;

-- ---------- Tablas y columnas ----------
alter table partidas
  add column if not exists puntos_base         int not null default 100 check (puntos_base between 1 and 1000),
  add column if not exists bonus_max           int not null default 50  check (bonus_max between 0 and 1000),
  add column if not exists bonus_minutos       int not null default 10  check (bonus_minutos between 1 and 120),
  add column if not exists costo_pista         int not null default 20  check (costo_pista between 1 and 1000),
  add column if not exists fallos_admin        int not null default 0,
  add column if not exists bloqueo_admin_hasta timestamptz,
  add column if not exists fallos_union        int not null default 0,
  add column if not exists bloqueo_union_hasta timestamptz;

alter table equipos
  add column if not exists fallos_respaldo        int not null default 0,
  add column if not exists bloqueo_respaldo_hasta timestamptz,
  add column if not exists codigo_union           text;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'partidas' and column_name = 'iniciada_en') then
    alter table partidas add column iniciada_en timestamptz;
    -- las partidas que ya existían ya estaban en juego: se consideran iniciadas
    update partidas set iniciada_en = creada;
  end if;
end $$;

-- Códigos de equipo para los equipos que ya existían
do $$
declare r record; v text;
begin
  for r in select id, partida_codigo from equipos where codigo_union is null loop
    loop
      v := _codigo_azar(6, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
      exit when not exists (select 1 from equipos where partida_codigo = r.partida_codigo and codigo_union = v);
    end loop;
    update equipos set codigo_union = v where id = r.id;
  end loop;
end $$;
alter table equipos alter column codigo_union set not null;
create unique index if not exists equipos_union_idx on equipos (partida_codigo, codigo_union);

alter table llegadas
  add column if not exists puntos int not null default 0,
  add column if not exists bonus  int not null default 0;

-- Llegadas anteriores a esta versión: valen los puntos base de su partida
update llegadas l set puntos = pa.puntos_base
  from equipos e join partidas pa on pa.codigo = e.partida_codigo
 where l.equipo_id = e.id and l.puntos = 0;

alter table participantes
  add column if not exists tutor_nombre       text,
  add column if not exists tutor_telefono     text,
  add column if not exists autorizacion_tutor boolean,
  add column if not exists borrar_despues     timestamptz not null default (now() + interval '30 days');

-- "not valid": no revisa las filas viejas, pero toda fila nueva tiene que cumplirlo.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'participantes_menor_check') then
    alter table participantes add constraint participantes_menor_check check (
      edad is not null
      and (edad >= 18 or (autorizacion_tutor is true and tutor_nombre is not null and tutor_telefono is not null))
    ) not valid;
  end if;
end $$;
create index if not exists participantes_borrar_idx on participantes (borrar_despues);

create table if not exists pistas_extra (
  partida_codigo text not null references partidas(codigo) on delete cascade,
  orden          int  not null,
  nro            int  not null check (nro between 1 and 2),
  texto          text not null,
  costo          int  not null check (costo between 1 and 1000),
  primary key (partida_codigo, orden, nro)
);

create table if not exists pistas_usadas (
  equipo_id uuid not null references equipos(id) on delete cascade,
  orden     int  not null,
  nro       int  not null,
  costo     int  not null,
  creado    timestamptz not null default now(),
  primary key (equipo_id, orden, nro)             -- una vez por pista: no se cobra dos veces
);

-- Tabla histórica: queda aunque se reinicie la partida (no depende de equipos).
create table if not exists historial (
  id             uuid primary key default gen_random_uuid(),
  partida_codigo text not null references partidas(codigo) on delete cascade,
  equipo_id      uuid not null unique,
  equipo         text not null,
  score          int  not null,
  tiempo_seg     int  not null,
  lugares        int  not null,
  fecha          timestamptz not null default now()
);
alter table historial
  add column if not exists inicio         timestamptz,
  add column if not exists integrantes    text,
  add column if not exists borrar_despues timestamptz not null default (now() + interval '30 days');
create index if not exists historial_partida_idx on historial (partida_codigo, score desc, tiempo_seg);

-- RLS activado y SIN políticas: la clave pública no lee ni escribe estas tablas.
alter table pistas_extra  enable row level security;
alter table pistas_usadas enable row level security;
alter table historial     enable row level security;

-- ---------- Utilidades internas ----------
create or replace function _entero(p_txt text, p_def int, p_min int, p_max int, p_nombre text)
returns int language plpgsql immutable as $$
begin
  if p_txt is null or trim(p_txt) = '' then return p_def; end if;
  if trim(p_txt) !~ '^[0-9]{1,6}$' or trim(p_txt)::int not between p_min and p_max then
    raise exception '% tiene que ser un número entre % y %', p_nombre, p_min, p_max;
  end if;
  return trim(p_txt)::int;
end $$;

-- Momento en que arranca el reloj de un equipo: el inicio del juego o, si se registró después,
-- su propio registro. NULL si el organizador todavía no inició el juego.
create or replace function _inicio_equipo(p_equipo uuid)
returns timestamptz language sql stable set search_path = public as $$
  select case when pa.iniciada_en is null then null else greatest(e.creado, pa.iniciada_en) end
  from equipos e join partidas pa on pa.codigo = e.partida_codigo where e.id = p_equipo;
$$;

-- Borra los datos personales vencidos (30 días). Se ejecuta sola cada vez que alguien se
-- registra o el organizador entra al panel.
-- Opcional, si activás la extensión pg_cron en Supabase:
--   select cron.schedule('purga-datos', '0 3 * * *', 'select _purgar_vencidos()');
create or replace function _purgar_vencidos()
returns int language plpgsql volatile as $$
declare v_n int;
begin
  delete from participantes where borrar_despues < now();
  get diagnostics v_n = row_count;
  update historial set integrantes = null where borrar_despues < now() and integrantes is not null;
  return v_n;
end $$;

-- Verifica la contraseña del organizador. Devuelve 'ok', 'credenciales_invalidas' o
-- 'demasiados_intentos'. 5 fallos seguidos bloquean la partida 5 minutos. No lanza errores:
-- así el contador de fallos se conserva. Cada fallo tarda 1 s y toma la fila de la partida,
-- así que los intentos en paralelo se hacen de a uno.
create or replace function _admin_check(p_codigo text, p_password text)
returns text language plpgsql volatile
set search_path = public, extensions as $$
declare v partidas;
begin
  select * into v from partidas where codigo = upper(trim(p_codigo)) for no key update;
  if not found then
    perform pg_sleep(1);
    return 'credenciales_invalidas';
  end if;
  if v.bloqueo_admin_hasta is not null and v.bloqueo_admin_hasta > now() then
    return 'demasiados_intentos';
  end if;
  if crypt(coalesce(p_password, ''), v.admin_hash) = v.admin_hash then
    if v.fallos_admin > 0 or v.bloqueo_admin_hasta is not null then
      update partidas set fallos_admin = 0, bloqueo_admin_hasta = null where codigo = v.codigo;
    end if;
    return 'ok';
  end if;
  if v.fallos_admin + 1 >= 5 then
    update partidas set fallos_admin = 0, bloqueo_admin_hasta = now() + interval '5 minutes' where codigo = v.codigo;
  else
    update partidas set fallos_admin = v.fallos_admin + 1 where codigo = v.codigo;
  end if;
  perform pg_sleep(1);
  return 'credenciales_invalidas';
end $$;

-- Puntaje del equipo = puntos de las llegadas (base + bonus) menos el costo de las pistas usadas.
create or replace function _score_equipo(p_equipo uuid)
returns int language sql stable set search_path = public as $$
  select greatest(0,
    coalesce((select sum(puntos) from llegadas where equipo_id = p_equipo), 0)
  - coalesce((select sum(costo)  from pistas_usadas where equipo_id = p_equipo), 0))::int;
$$;

-- Anota al equipo en la tabla histórica cuando completa todos los puntos.
create or replace function _registrar_historial(p_equipo uuid)
returns void language plpgsql volatile set search_path = public as $$
begin
  insert into historial (partida_codigo, equipo_id, equipo, score, tiempo_seg, lugares, inicio, integrantes)
  select e.partida_codigo, e.id, e.nombre, _score_equipo(e.id),
         greatest(0, extract(epoch from (l.ultimo - coalesce(_inicio_equipo(e.id), e.creado))))::int, l.n,
         coalesce(_inicio_equipo(e.id), e.creado),
         (select string_agg(pt.nombre || coalesce(' ' || left(pt.apellido, 1) || '.', ''), ', ' order by pt.posicion)
            from participantes pt where pt.equipo_id = e.id)
  from equipos e
  cross join lateral (select count(*)::int as n, max(creado) as ultimo from llegadas where equipo_id = e.id) l
  where e.id = p_equipo
  on conflict (equipo_id) do nothing;
end $$;

create or replace function _historial_json(p_codigo text)
returns json language sql stable set search_path = public as $$
  select coalesce(json_agg(json_build_object(
           'equipo', h.equipo, 'score', h.score, 'tiempoSeg', h.tiempo_seg,
           'lugares', h.lugares, 'fecha', h.fecha, 'inicio', coalesce(h.inicio, h.fecha),
           'integrantes', h.integrantes)
         order by h.score desc, h.tiempo_seg asc, h.fecha asc), '[]'::json)
  from (select * from historial where partida_codigo = upper(trim(p_codigo))
        order by score desc, tiempo_seg asc, fecha asc limit 20) h;
$$;

-- ---------- Validar y normalizar participantes (con menores y tutor) ----------
create or replace function _validar_participantes(p_cod text, p_part jsonb)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_c jsonb; v_n int; v_i int := 0; v_p jsonb; v_out jsonb := '[]'::jsonb;
  v_nom text; v_ape text; v_edad text; v_tel text; v_ig text; v_sin boolean;
  v_tnom text; v_ttel text; v_menor boolean;
begin
  select campos into v_c from partidas where codigo = upper(trim(p_cod));
  if v_c is null then raise exception 'No existe una partida con ese código'; end if;

  if p_part is null or jsonb_typeof(p_part) <> 'array' then
    raise exception 'Faltan los participantes';
  end if;
  v_n := jsonb_array_length(p_part);
  if v_n < 1 or v_n > 3 then
    raise exception 'El equipo tiene que tener 1, 2 o 3 participantes';
  end if;

  for v_p in select * from jsonb_array_elements(p_part) loop
    v_i := v_i + 1;
    if jsonb_typeof(v_p) <> 'object' then raise exception 'Participante %: datos inválidos', v_i; end if;

    v_nom := regexp_replace(trim(coalesce(v_p->>'nombre', '')), '\s+', ' ', 'g');
    if length(v_nom) < 2 then raise exception 'Participante %: completá el nombre', v_i; end if;

    v_ape := null;
    if coalesce(v_c->>'apellido', 'off') <> 'off' then
      v_ape := nullif(regexp_replace(trim(coalesce(v_p->>'apellido', '')), '\s+', ' ', 'g'), '');
      if v_ape is null and v_c->>'apellido' = 'req' then raise exception 'Participante %: completá el apellido', v_i; end if;
      if v_ape is not null and length(v_ape) < 2 then raise exception 'Participante %: el apellido es muy corto', v_i; end if;
    end if;

    -- la edad SIEMPRE es obligatoria: sin ella no se sabe si hace falta autorización de un adulto
    v_edad := nullif(trim(coalesce(v_p->>'edad', '')), '');
    if v_edad is null then raise exception 'Participante %: completá la edad', v_i; end if;
    if not (v_edad ~ '^[0-9]{1,3}$' and v_edad::int between 1 and 120) then
      raise exception 'Participante %: la edad tiene que ser un número entre 1 y 120', v_i;
    end if;
    v_menor := v_edad::int < 18;

    v_tel := null;
    if coalesce(v_c->>'telefono', 'off') <> 'off' then
      v_tel := nullif(trim(coalesce(v_p->>'telefono', '')), '');
      if v_tel is null and v_c->>'telefono' = 'req' then raise exception 'Participante %: completá el teléfono', v_i; end if;
      if v_tel is not null and not (v_tel ~ '^\+?[0-9 ()-]{6,25}$'
                                    and length(regexp_replace(v_tel, '[^0-9]', '', 'g')) between 6 and 15) then
        raise exception 'Participante %: el teléfono no es válido', v_i;
      end if;
    end if;

    v_ig := null; v_sin := false;
    if coalesce(v_c->>'instagram', 'off') <> 'off' then
      v_sin := coalesce(v_p->>'sinInstagram', 'false') = 'true';
      if not v_sin then
        v_ig := nullif(regexp_replace(trim(coalesce(v_p->>'instagram', '')), '^@+', ''), '');
        if v_ig is null and v_c->>'instagram' = 'req' then
          raise exception 'Participante %: completá el Instagram o marcá "No tengo Instagram"', v_i;
        end if;
        if v_ig is not null and v_ig !~ '^[A-Za-z0-9._]{1,30}$' then
          raise exception 'Participante %: el usuario de Instagram no es válido', v_i;
        end if;
      end if;
    end if;

    if coalesce(v_p->>'acepto', 'false') <> 'true' then
      raise exception 'Participante %: tiene que aceptar el uso de sus datos personales', v_i;
    end if;

    -- menores de 18: autorización de madre, padre o tutor
    v_tnom := null; v_ttel := null;
    if v_menor then
      v_tnom := regexp_replace(trim(coalesce(v_p->>'tutorNombre', '')), '\s+', ' ', 'g');
      v_ttel := trim(coalesce(v_p->>'tutorTelefono', ''));
      if length(v_tnom) < 5 or length(v_tnom) > 80 or position(' ' in v_tnom) = 0 then
        raise exception 'Participante % es menor de 18: escribí nombre y apellido de la madre, padre o tutor', v_i;
      end if;
      if not (v_ttel ~ '^\+?[0-9 ()-]{6,25}$'
              and length(regexp_replace(v_ttel, '[^0-9]', '', 'g')) between 6 and 15) then
        raise exception 'Participante % es menor de 18: falta un teléfono válido de la madre, padre o tutor', v_i;
      end if;
      if coalesce(v_p->>'autorizacionTutor', 'false') <> 'true' then
        raise exception 'Participante % es menor de 18: falta la autorización de la madre, padre o tutor', v_i;
      end if;
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'nombre', left(v_nom, 40), 'apellido', left(v_ape, 40),
      'edad', v_edad::int, 'telefono', left(v_tel, 25),
      'instagram', left(v_ig, 30), 'sinInstagram', v_sin,
      'tutorNombre', left(v_tnom, 80), 'tutorTelefono', left(v_ttel, 25)));
  end loop;
  return v_out;
end $$;

create or replace function _insertar_participantes(p_equipo uuid, p_norm jsonb, p_desde int)
returns void language plpgsql volatile set search_path = public as $$
declare v_p jsonb; v_i int := p_desde;
begin
  for v_p in select * from jsonb_array_elements(p_norm) loop
    v_i := v_i + 1;
    insert into participantes (equipo_id, posicion, nombre, apellido, edad, telefono, instagram,
                               sin_instagram, acepto_datos, tutor_nombre, tutor_telefono, autorizacion_tutor)
    values (p_equipo, v_i, v_p->>'nombre', v_p->>'apellido', (v_p->>'edad')::int,
            v_p->>'telefono', v_p->>'instagram', (v_p->>'sinInstagram')::boolean, true,
            v_p->>'tutorNombre', v_p->>'tutorTelefono',
            case when (v_p->>'edad')::int < 18 then true end);
  end loop;
end $$;

-- ---------- Organizador: crear partida ----------
-- p_campos   = {"nombre":"req","apellido":"req","edad":"req","telefono":"off","instagram":"off"}
-- p_puntaje  = {"base":100,"bonusMax":50,"bonusMinutos":10,"costoPista":20}
-- p_puntos[] = {"tipo","pista","lat","lng","radioM","pistasExtra":[{"texto":"...","costo":20}]}
create or replace function crear_partida(
  p_nombre text, p_password text, p_lat float8, p_lng float8, p_puntos jsonb,
  p_modo text default 'presencial', p_campos jsonb default null, p_puntaje jsonb default null)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_codigo text; v_n int; v_i int := 0; v_j int; v_p jsonb; v_x jsonb;
  v_campos jsonb := '{"nombre":"req","apellido":"req","edad":"req","telefono":"off","instagram":"off"}'::jsonb;
  k text; v text;
  v_base int := 100; v_bmax int := 50; v_bmin int := 10; v_costo int := 20;
begin
  if length(trim(coalesce(p_nombre, ''))) < 2 then
    raise exception 'El nombre del juego es muy corto';
  end if;
  if length(coalesce(p_password, '')) < 6 then
    raise exception 'La contraseña tiene que tener al menos 6 caracteres';
  end if;
  if lower(p_password) in ('123456', '1234567', '12345678', '123456789', '1234567890', 'password',
                           'contraseña', 'contrasena', 'qwerty', 'abc123', '111111', '000000',
                           'tesoro', 'tesoro123', 'admin123') then
    raise exception 'Esa contraseña es muy fácil de adivinar. Elegí otra.';
  end if;
  if coalesce(p_modo, '') not in ('presencial', 'remoto') then
    raise exception 'Modo de juego inválido';
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Ubicación inválida';
  end if;
  if p_puntos is null or jsonb_typeof(p_puntos) <> 'array' then
    raise exception 'Faltan los puntos';
  end if;
  v_n := jsonb_array_length(p_puntos);
  if v_n < 1 or v_n > 30 then
    raise exception 'La partida tiene que tener entre 1 y 30 puntos';
  end if;

  if p_campos is not null then
    if jsonb_typeof(p_campos) <> 'object' then raise exception 'Configuración de datos inválida'; end if;
    for k, v in select key, value #>> '{}' from jsonb_each(p_campos) loop
      if k not in ('nombre', 'apellido', 'edad', 'telefono', 'instagram') then
        raise exception 'Dato desconocido: %', k;
      end if;
      if v not in ('off', 'opt', 'req') then
        raise exception 'Valor inválido para %', k;
      end if;
      v_campos := jsonb_set(v_campos, array[k], to_jsonb(v));
    end loop;
  end if;
  v_campos := jsonb_set(v_campos, '{nombre}', '"req"');   -- el nombre siempre se pide
  v_campos := jsonb_set(v_campos, '{edad}',   '"req"');   -- la edad también: define si hace falta tutor

  if p_puntaje is not null then
    if jsonb_typeof(p_puntaje) <> 'object' then raise exception 'Puntaje inválido'; end if;
    v_base  := _entero(p_puntaje->>'base',         100, 1, 1000, 'Los puntos por lugar');
    v_bmax  := _entero(p_puntaje->>'bonusMax',      50, 0, 1000, 'El bonus máximo');
    v_bmin  := _entero(p_puntaje->>'bonusMinutos',  10, 1, 120,  'Los minutos del bonus');
    v_costo := _entero(p_puntaje->>'costoPista',    20, 1, 1000, 'El costo de las pistas');
  end if;

  loop
    v_codigo := _codigo_azar(6, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    exit when not exists (select 1 from partidas where codigo = v_codigo);
  end loop;

  insert into partidas (codigo, nombre, admin_hash, centro_lat, centro_lng, modo, campos,
                        puntos_base, bonus_max, bonus_minutos, costo_pista)
  values (v_codigo, left(trim(p_nombre), 60), crypt(p_password, gen_salt('bf')), p_lat, p_lng,
          p_modo, v_campos, v_base, v_bmax, v_bmin, v_costo);

  for v_p in select * from jsonb_array_elements(p_puntos) loop
    v_i := v_i + 1;
    if (v_p->>'lat')::float8 not between -90 and 90
       or (v_p->>'lng')::float8 not between -180 and 180 then
      raise exception 'El punto % tiene coordenadas inválidas', v_i;
    end if;
    insert into puntos (partida_codigo, orden, tipo, pista, lat, lng, radio_m, respaldo)
    values (v_codigo, v_i,
            left(coalesce(v_p->>'tipo', 'otro'), 30),
            left(coalesce(nullif(trim(v_p->>'pista'), ''), 'Buscá el próximo lugar'), 300),
            (v_p->>'lat')::float8, (v_p->>'lng')::float8,
            coalesce((v_p->>'radioM')::float8, 15),
            -- 6 caracteres de 32 símbolos: más de mil millones de combinaciones
            _codigo_azar(6, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'));

    if jsonb_typeof(v_p->'pistasExtra') = 'array' then
      if jsonb_array_length(v_p->'pistasExtra') > 2 then
        raise exception 'Cada punto admite hasta 2 pistas adicionales (punto %)', v_i;
      end if;
      v_j := 0;
      for v_x in select * from jsonb_array_elements(v_p->'pistasExtra') loop
        v_j := v_j + 1;
        if length(trim(coalesce(v_x->>'texto', ''))) < 1 then
          raise exception 'La pista adicional % del punto % está vacía', v_j, v_i;
        end if;
        insert into pistas_extra (partida_codigo, orden, nro, texto, costo)
        values (v_codigo, v_i, v_j, left(trim(v_x->>'texto'), 300),
                _entero(v_x->>'costo', v_costo, 1, 1000, 'El costo de la pista adicional'));
      end loop;
    end if;
  end loop;

  return json_build_object('codigo', v_codigo, 'puntos', v_n, 'modo', p_modo, 'campos', v_campos);
end $$;

-- ---------- Organizador: ver la partida completa ----------
-- Si la contraseña es incorrecta devuelve {"error": "credenciales_invalidas" | "demasiados_intentos"}.
create or replace function admin_partida(p_codigo text, p_password text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare v_codigo text := upper(trim(p_codigo)); v_est text;
begin
  perform _purgar_vencidos();
  v_est := _admin_check(v_codigo, p_password);
  if v_est <> 'ok' then
    return json_build_object('error', v_est);
  end if;
  return (select json_build_object(
    'codigo', pa.codigo, 'nombre', pa.nombre, 'modo', pa.modo,
    'campos', pa.campos || '{"edad":"req"}'::jsonb,
    'centro', json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'duracionMin', pa.duracion_min, 'ahora', now(),
    'iniciada', pa.iniciada_en is not null, 'iniciadaEn', pa.iniciada_en,
    'puntaje', json_build_object('base', pa.puntos_base, 'bonusMax', pa.bonus_max,
                                 'bonusMinutos', pa.bonus_minutos, 'costoPista', pa.costo_pista),
    'historial', _historial_json(pa.codigo),
    'puntos', coalesce((select json_agg(json_build_object(
        'orden', p.orden, 'tipo', p.tipo, 'pista', p.pista, 'lat', p.lat, 'lng', p.lng,
        'radioM', p.radio_m, 'respaldo', p.respaldo,
        'pistasExtra', coalesce((select json_agg(json_build_object(
              'nro', x.nro, 'texto', x.texto, 'costo', x.costo) order by x.nro)
            from pistas_extra x where x.partida_codigo = p.partida_codigo and x.orden = p.orden), '[]'::json))
        order by p.orden)
      from puntos p where p.partida_codigo = pa.codigo), '[]'::json),
    'equipos', coalesce((select json_agg(json_build_object(
        'id', e.id, 'nombre', e.nombre, 'codigoUnion', e.codigo_union,
        'puntos', e.n, 'score', e.score, 'inicio', e.inicio,
        'fin', case when e.n >= e.total and e.total > 0 then e.ultimo end,
        'terminado', (e.n >= e.total and e.total > 0),
        'pistasUsadas', e.pu, 'ultimo', e.ultimo,
        'usosRespaldo', e.resp, 'participantes', e.parts, 'visitados', e.vis)
        order by e.score desc, e.ultimo asc nulls last)
      from (select eq.id, eq.nombre, eq.creado, eq.codigo_union, _inicio_equipo(eq.id) as inicio,
                   (select count(*)::int from llegadas l where l.equipo_id = eq.id) as n,
                   (select count(*)::int from puntos pp where pp.partida_codigo = eq.partida_codigo) as total,
                   _score_equipo(eq.id) as score,
                   (select count(*)::int from pistas_usadas pu where pu.equipo_id = eq.id) as pu,
                   (select max(l.creado) from llegadas l where l.equipo_id = eq.id) as ultimo,
                   (select count(*)::int from llegadas l
                     where l.equipo_id = eq.id and l.uso_respaldo) as resp,
                   coalesce((select json_agg(json_build_object(
                       'nombre', pt.nombre, 'apellido', pt.apellido, 'edad', pt.edad,
                       'telefono', pt.telefono, 'instagram', pt.instagram,
                       'sinInstagram', pt.sin_instagram,
                       'menor', coalesce(pt.edad < 18, false),
                       'tutorNombre', pt.tutor_nombre, 'tutorTelefono', pt.tutor_telefono,
                       'consentimiento', pt.acepto_datos,
                       'consentimientoVersion', eq.version_datos,
                       'consentimientoFecha', eq.acepto_en,
                       'borrarDespues', pt.borrar_despues)
                       order by pt.posicion)
                     from participantes pt where pt.equipo_id = eq.id), '[]'::json) as parts,
                   coalesce((select json_agg(json_build_object(
                       'orden', l.orden, 'creado', l.creado, 'respaldo', l.uso_respaldo,
                       'puntos', l.puntos, 'bonus', l.bonus)
                       order by l.orden)
                     from llegadas l where l.equipo_id = eq.id), '[]'::json) as vis
            from equipos eq where eq.partida_codigo = pa.codigo) e), '[]'::json))
  from partidas pa where pa.codigo = v_codigo);
end $$;

-- ---------- Organizador: iniciar el juego ----------
-- Hasta que se llama, los equipos están en la sala de espera. Es idempotente: si ya estaba
-- iniciado devuelve el mismo momento de inicio.
create or replace function admin_iniciar(p_codigo text, p_password text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare v_est text; v_ini timestamptz;
begin
  v_est := _admin_check(p_codigo, p_password);
  if v_est <> 'ok' then
    return json_build_object('error', v_est);
  end if;
  update partidas set iniciada_en = coalesce(iniciada_en, now())
   where codigo = upper(trim(p_codigo)) returning iniciada_en into v_ini;
  return json_build_object('ok', true, 'iniciadaEn', v_ini);
end $$;

-- ---------- Organizador: reiniciar (borra equipos; conserva el juego y la tabla histórica) ----------
create or replace function admin_reiniciar(p_codigo text, p_password text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare v_est text; v_n int;
begin
  v_est := _admin_check(p_codigo, p_password);
  if v_est <> 'ok' then
    return json_build_object('error', v_est);
  end if;
  delete from equipos where partida_codigo = upper(trim(p_codigo));
  get diagnostics v_n = row_count;
  update partidas set iniciada_en = null where codigo = upper(trim(p_codigo));   -- vuelve a la sala de espera
  return json_build_object('ok', true, 'equiposBorrados', v_n);
end $$;

-- ---------- Organizador: borrar los datos personales ahora (fin de la actividad) ----------
-- Conserva equipos, llegadas, ranking y tabla histórica; elimina nombre, apellido, edad,
-- teléfono, Instagram y datos de tutores de TODOS los participantes de la partida.
create or replace function admin_borrar_datos(p_codigo text, p_password text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare v_est text; v_n int;
begin
  v_est := _admin_check(p_codigo, p_password);
  if v_est <> 'ok' then
    return json_build_object('error', v_est);
  end if;
  delete from participantes
   where equipo_id in (select id from equipos where partida_codigo = upper(trim(p_codigo)));
  get diagnostics v_n = row_count;
  update historial set integrantes = null where partida_codigo = upper(trim(p_codigo));
  return json_build_object('ok', true, 'borrados', v_n);
end $$;

-- ---------- Jugadores: info pública ----------
create or replace function partida_info(p_codigo text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'codigo', pa.codigo, 'nombre', pa.nombre, 'modo', pa.modo,
    'campos', pa.campos || '{"edad":"req"}'::jsonb,
    'centro', json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'iniciada', pa.iniciada_en is not null,
    'puntaje', json_build_object('base', pa.puntos_base, 'bonusMax', pa.bonus_max,
                                 'bonusMinutos', pa.bonus_minutos),
    'totalPuntos', (select count(*) from puntos p where p.partida_codigo = pa.codigo))
  from partidas pa where pa.codigo = upper(trim(p_codigo));
$$;

-- ---------- Tabla histórica (pública para quien tenga el código de la partida) ----------
create or replace function historial(p_codigo text)
returns json language sql stable security definer set search_path = public as $$
  select _historial_json(p_codigo);
$$;

-- ---------- Jugadores: crear equipo (1 a 3 participantes) ----------
create or replace function crear_equipo(
  p_codigo text, p_nombre text, p_participantes jsonb, p_version text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_cod text := upper(trim(p_codigo)); v_norm jsonb; v_union text;
begin
  perform _purgar_vencidos();
  if length(trim(coalesce(p_nombre, ''))) < 2 then
    raise exception 'El nombre del equipo es muy corto';
  end if;
  if not exists (select 1 from partidas where codigo = v_cod) then
    raise exception 'No existe una partida con ese código';
  end if;
  if length(trim(coalesce(p_version, ''))) = 0 then
    raise exception 'Falta la versión del aviso de privacidad. Recargá la página.';
  end if;
  if (select count(*) from equipos where partida_codigo = v_cod) >= 100 then
    raise exception 'Esta partida ya tiene el máximo de 100 equipos';
  end if;

  v_norm := _validar_participantes(v_cod, p_participantes);   -- valida todo antes de insertar nada

  loop
    v_union := _codigo_azar(6, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    exit when not exists (select 1 from equipos where partida_codigo = v_cod and codigo_union = v_union);
  end loop;

  begin
    insert into equipos (partida_codigo, nombre, version_datos, acepto_en, codigo_union)
    values (v_cod, left(trim(p_nombre), 40), left(p_version, 40), now(), v_union)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Ya hay un equipo con ese nombre en esta partida';
  end;

  perform _insertar_participantes(v_id, v_norm, 0);
  return v_id;
end $$;

-- ---------- Jugadores: unirse a un equipo desde otra pantalla ----------
-- Con p_participantes (los datos de quien se une, con su propio consentimiento) los agrega
-- al equipo; sin p_participantes solo entra (para quien ya figura entre los participantes).
-- Devuelve {"ok":true,"equipo":"<uuid>"} o {"ok":false,"motivo":"..."}.
-- 10 códigos de equipo incorrectos seguidos bloquean las uniones a esa partida 2 minutos.
create or replace function unirse_equipo(
  p_codigo text, p_codigo_equipo text, p_participantes jsonb default null, p_version text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_cod text := upper(trim(p_codigo)); v_pa partidas; v_eq equipos;
  v_norm jsonb; v_ya int; v_pos int;
begin
  perform _purgar_vencidos();
  select * into v_pa from partidas where codigo = v_cod for no key update;
  if not found then
    perform pg_sleep(1);
    return json_build_object('ok', false, 'motivo', 'partida_inexistente');
  end if;
  if v_pa.bloqueo_union_hasta is not null and v_pa.bloqueo_union_hasta > now() then
    return json_build_object('ok', false, 'motivo', 'demasiados_intentos');
  end if;

  select * into v_eq from equipos
   where partida_codigo = v_cod and codigo_union = upper(trim(coalesce(p_codigo_equipo, '')));
  if not found then
    perform pg_sleep(1);
    if v_pa.fallos_union + 1 >= 10 then
      update partidas set fallos_union = 0, bloqueo_union_hasta = now() + interval '2 minutes' where codigo = v_cod;
      return json_build_object('ok', false, 'motivo', 'demasiados_intentos');
    end if;
    update partidas set fallos_union = v_pa.fallos_union + 1 where codigo = v_cod;
    return json_build_object('ok', false, 'motivo', 'codigo_incorrecto');
  end if;

  if v_pa.fallos_union > 0 or v_pa.bloqueo_union_hasta is not null then
    update partidas set fallos_union = 0, bloqueo_union_hasta = null where codigo = v_cod;
  end if;

  if p_participantes is not null and jsonb_typeof(p_participantes) = 'array'
     and jsonb_array_length(p_participantes) > 0 then
    if length(trim(coalesce(p_version, ''))) = 0 then
      raise exception 'Falta la versión del aviso de privacidad. Recargá la página.';
    end if;
    v_norm := _validar_participantes(v_cod, p_participantes);
    select count(*), coalesce(max(posicion), 0) into v_ya, v_pos from participantes where equipo_id = v_eq.id;
    if v_ya + jsonb_array_length(v_norm) > 3 then
      raise exception 'El equipo ya tiene % participantes registrados (el máximo es 3)', v_ya;
    end if;
    perform _insertar_participantes(v_eq.id, v_norm, v_pos);
    update equipos set version_datos = coalesce(left(p_version, 40), version_datos), acepto_en = now()
     where id = v_eq.id;
  end if;

  return json_build_object('ok', true, 'equipo', v_eq.id);
end $$;

-- ---------- Jugadores: editar equipo y participantes ----------
create or replace function editar_equipo(
  p_equipo uuid, p_nombre text, p_participantes jsonb, p_version text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_eq equipos; v_norm jsonb;
begin
  select * into v_eq from equipos where id = p_equipo for update;
  if not found then raise exception 'No encontramos tu equipo'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then
    raise exception 'El nombre del equipo es muy corto';
  end if;

  v_norm := _validar_participantes(v_eq.partida_codigo, p_participantes);

  begin
    update equipos set nombre = left(trim(p_nombre), 40),
           version_datos = coalesce(left(p_version, 40), version_datos), acepto_en = now()
     where id = p_equipo;
  exception when unique_violation then
    raise exception 'Ya hay un equipo con ese nombre en esta partida';
  end;

  delete from participantes where equipo_id = p_equipo;
  perform _insertar_participantes(p_equipo, v_norm, 0);
  return json_build_object('ok', true);
end $$;

-- ---------- Jugadores: estado del equipo ----------
-- Revela la pista del punto ACTUAL, el texto de las pistas adicionales YA compradas y los
-- puntos YA visitados. Nunca revela los puntos que faltan ni el texto de pistas sin comprar.
create or replace function mi_progreso(p_equipo uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'equipo',      e.nombre,
    'codigoEquipo', e.codigo_union,
    'codigo',      e.partida_codigo,
    'juego',       pa.nombre,
    'modo',        pa.modo,
    'campos',      pa.campos || '{"edad":"req"}'::jsonb,
    'centro',      json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'inicio',      _inicio_equipo(e.id),
    'iniciada',    pa.iniciada_en is not null,
    'ahora',       now(),
    'total',       t.total,
    'completados', c.n,
    'terminado',   (c.n >= t.total and pa.iniciada_en is not null),
    'fin',         case when c.n >= t.total then c.ultimo end,
    'score',       _score_equipo(e.id),
    'puntaje',     json_build_object('base', pa.puntos_base, 'bonusMax', pa.bonus_max,
                                     'bonusMinutos', pa.bonus_minutos),
    'desdePunto',  coalesce(c.ultimo, _inicio_equipo(e.id)),
    'pista',       (select p.pista from puntos p
                    where p.partida_codigo = e.partida_codigo and p.orden = c.n + 1
                      and pa.iniciada_en is not null),
    'pistas',      coalesce((select json_agg(json_build_object(
                       'nro', pe.nro, 'costo', pe.costo, 'usada', (u.equipo_id is not null),
                       'texto', case when u.equipo_id is not null then pe.texto end) order by pe.nro)
                     from pistas_extra pe
                     left join pistas_usadas u on u.equipo_id = e.id and u.orden = pe.orden and u.nro = pe.nro
                     where pe.partida_codigo = e.partida_codigo and pe.orden = c.n + 1 and c.n < t.total
                       and pa.iniciada_en is not null),
                   '[]'::json),
    'integrantes', coalesce((select json_agg(trim(pt.nombre || ' ' || coalesce(pt.apellido, '')) order by pt.posicion)
                             from participantes pt where pt.equipo_id = e.id), '[]'::json),
    'participantes', coalesce((select json_agg(json_build_object(
                         'nombre', pt.nombre, 'apellido', pt.apellido, 'edad', pt.edad,
                         'telefono', pt.telefono, 'instagram', pt.instagram,
                         'sinInstagram', pt.sin_instagram,
                         'tutorNombre', pt.tutor_nombre, 'tutorTelefono', pt.tutor_telefono,
                         'autorizacionTutor', pt.autorizacion_tutor) order by pt.posicion)
                       from participantes pt where pt.equipo_id = e.id), '[]'::json),
    'visitados',   coalesce((select json_agg(json_build_object(
                       'orden', p.orden, 'tipo', p.tipo, 'pista', p.pista,
                       'lat', p.lat, 'lng', p.lng, 'creado', l.creado) order by p.orden)
                     from llegadas l
                     join puntos p on p.partida_codigo = e.partida_codigo and p.orden = l.orden
                     where l.equipo_id = e.id), '[]'::json))
  from equipos e
  join partidas pa on pa.codigo = e.partida_codigo
  cross join lateral (select count(*)::int as total from puntos p where p.partida_codigo = e.partida_codigo) t
  cross join lateral (select count(*)::int as n, max(l.creado) as ultimo from llegadas l where l.equipo_id = e.id) c
  where e.id = p_equipo;
$$;

-- ---------- Validación por ubicación ----------
-- Si todavía no llegó devuelve la franja de cercanía (1 a 5): cada franja son 10 m medidos
-- desde el borde del círculo del punto (1 = muy cerca ... 5 = 40 m o más = demasiado lejos).
-- Presencial: también devuelve la distancia redondeada a 10 m. Remoto: solo la franja, con
-- 1 s de espera por intento fallido.
-- Presencial: si el equipo llega a un punto a una velocidad imposible a pie respecto del
-- punto anterior (más de 12 m/s) se rechaza: sirve contra GPS falso que "teletransporta".
create or replace function validar_llegada(
  p_equipo uuid, p_lat float8, p_lng float8, p_precision float8 default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_eq equipos; v_pa partidas; v_hechos int; v_total int; v_punto puntos; v_prev puntos;
  v_dist float8; v_margen float8; v_fuera float8; v_banda int;
  v_ult timestamptz; v_seg float8; v_bonus int; v_entre float8;
begin
  select * into v_eq from equipos where id = p_equipo for update;   -- serializa pedidos simultáneos
  if not found then
    return json_build_object('ok', false, 'motivo', 'equipo_desconocido');
  end if;
  select * into v_pa from partidas where codigo = v_eq.partida_codigo;
  if v_pa.iniciada_en is null then
    return json_build_object('ok', false, 'motivo', 'no_iniciada');
  end if;

  select count(*), max(creado) into v_hechos, v_ult from llegadas where equipo_id = p_equipo;
  select count(*) into v_total from puntos where partida_codigo = v_eq.partida_codigo;
  if v_hechos >= v_total then
    return json_build_object('ok', true, 'motivo', 'terminado');
  end if;

  select * into v_punto from puntos
   where partida_codigo = v_eq.partida_codigo and orden = v_hechos + 1;

  v_dist := haversine_m(p_lat, p_lng, v_punto.lat, v_punto.lng);
  if v_pa.modo = 'remoto' then
    v_margen := 0;
  else
    v_margen := least(greatest(coalesce(p_precision, 0), 0), 15);   -- tolerancia por imprecisión del GPS
  end if;

  if v_dist > v_punto.radio_m + v_margen then
    v_fuera := v_dist - (v_punto.radio_m + v_margen);
    v_banda := least(5, greatest(1, ceil(v_fuera / 10.0)::int));
    if v_pa.modo = 'remoto' then
      perform pg_sleep(1);
      return json_build_object('ok', false, 'motivo', 'lejos', 'banda', v_banda);
    end if;
    return json_build_object('ok', false, 'motivo', 'lejos', 'banda', v_banda,
                             'distanciaM', round(v_dist / 10) * 10);
  end if;

  -- control de velocidad entre puntos (solo presencial)
  if v_pa.modo = 'presencial' and v_hechos > 0 then
    select * into v_prev from puntos
     where partida_codigo = v_eq.partida_codigo and orden = v_hechos;
    v_entre := haversine_m(v_prev.lat, v_prev.lng, v_punto.lat, v_punto.lng);
    v_seg := greatest(extract(epoch from (now() - v_ult)), 0.001);
    if greatest(v_entre - v_prev.radio_m - v_punto.radio_m, 0) / v_seg > 12 then
      return json_build_object('ok', false, 'motivo', 'muy_rapido');
    end if;
  end if;

  -- bonus por velocidad: baja de forma lineal hasta 0 a los "bonus_minutos" desde que se
  -- reveló la pista (llegada anterior, o creación del equipo si es el primer punto)
  v_seg := extract(epoch from (now() - coalesce(v_ult, greatest(v_eq.creado, v_pa.iniciada_en))));
  v_bonus := round(v_pa.bonus_max * greatest(0, 1 - v_seg / (v_pa.bonus_minutos * 60.0)))::int;

  insert into llegadas (equipo_id, orden, distancia_m, precision_m, puntos, bonus)
  values (p_equipo, v_hechos + 1, v_dist, p_precision, v_pa.puntos_base + v_bonus, v_bonus);

  if v_hechos + 1 >= v_total then
    perform _registrar_historial(p_equipo);
  end if;
  return json_build_object('ok', true, 'motivo', 'validado',
                           'puntos', v_pa.puntos_base + v_bonus, 'bonus', v_bonus);
end $$;

-- ---------- Jugadores: código manual de respaldo (con bloqueo) ----------
-- 5 códigos incorrectos seguidos de un mismo equipo bloquean el código 5 minutos. Con código
-- de respaldo se suman los puntos base pero no el bonus de velocidad.
create or replace function validar_respaldo(p_equipo uuid, p_codigo text)
returns json language plpgsql security definer set search_path = public as $$
declare v_eq equipos; v_pa partidas; v_hechos int; v_total int; v_punto puntos; v_fallos int;
begin
  select * into v_eq from equipos where id = p_equipo for update;
  if not found then
    return json_build_object('ok', false, 'motivo', 'equipo_desconocido');
  end if;
  if v_eq.bloqueo_respaldo_hasta is not null and v_eq.bloqueo_respaldo_hasta > now() then
    return json_build_object('ok', false, 'motivo', 'bloqueado',
      'segundos', ceil(extract(epoch from (v_eq.bloqueo_respaldo_hasta - now())))::int);
  end if;
  select * into v_pa from partidas where codigo = v_eq.partida_codigo;
  if v_pa.iniciada_en is null then
    return json_build_object('ok', false, 'motivo', 'no_iniciada');
  end if;

  select count(*) into v_hechos from llegadas where equipo_id = p_equipo;
  select count(*) into v_total  from puntos   where partida_codigo = v_eq.partida_codigo;
  if v_hechos >= v_total then
    return json_build_object('ok', true, 'motivo', 'terminado');
  end if;
  select * into v_punto from puntos
   where partida_codigo = v_eq.partida_codigo and orden = v_hechos + 1;

  if upper(trim(coalesce(p_codigo, ''))) <> v_punto.respaldo then
    perform pg_sleep(1);   -- con la fila del equipo tomada: un intento por segundo como máximo
    v_fallos := v_eq.fallos_respaldo + 1;
    if v_fallos >= 5 then
      update equipos set fallos_respaldo = 0, bloqueo_respaldo_hasta = now() + interval '5 minutes'
       where id = p_equipo;
      return json_build_object('ok', false, 'motivo', 'bloqueado', 'segundos', 300);
    end if;
    update equipos set fallos_respaldo = v_fallos where id = p_equipo;
    return json_build_object('ok', false, 'motivo', 'codigo_incorrecto');
  end if;

  update equipos set fallos_respaldo = 0, bloqueo_respaldo_hasta = null where id = p_equipo;
  insert into llegadas (equipo_id, orden, uso_respaldo, puntos, bonus)
  values (p_equipo, v_hechos + 1, true, v_pa.puntos_base, 0);
  if v_hechos + 1 >= v_total then
    perform _registrar_historial(p_equipo);
  end if;
  return json_build_object('ok', true, 'motivo', 'validado_respaldo', 'puntos', v_pa.puntos_base, 'bonus', 0);
end $$;

-- ---------- Jugadores: comprar una pista adicional ----------
-- p_orden = punto actual que ve el jugador; p_nro = pista que quiere (1 o 2). Pedir de nuevo
-- una pista ya comprada la devuelve sin cobrar otra vez. Las pistas se compran en orden.
create or replace function pedir_pista(p_equipo uuid, p_orden int, p_nro int)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_eq equipos; v_hechos int; v_total int; v_pe pistas_extra; v_u pistas_usadas; v_usadas int;
begin
  select * into v_eq from equipos where id = p_equipo for update;
  if not found then
    return json_build_object('ok', false, 'motivo', 'equipo_desconocido');
  end if;
  if (select iniciada_en from partidas where codigo = v_eq.partida_codigo) is null then
    return json_build_object('ok', false, 'motivo', 'no_iniciada');
  end if;
  select count(*) into v_hechos from llegadas where equipo_id = p_equipo;
  select count(*) into v_total  from puntos   where partida_codigo = v_eq.partida_codigo;
  if v_hechos >= v_total then
    return json_build_object('ok', false, 'motivo', 'terminado');
  end if;
  if p_orden is distinct from v_hechos + 1 then
    return json_build_object('ok', false, 'motivo', 'punto_cambio');   -- otro compañero ya avanzó
  end if;

  select * into v_pe from pistas_extra
   where partida_codigo = v_eq.partida_codigo and orden = v_hechos + 1 and nro = p_nro;
  if not found then
    return json_build_object('ok', false, 'motivo', 'sin_pista');
  end if;

  select * into v_u from pistas_usadas where equipo_id = p_equipo and orden = v_hechos + 1 and nro = p_nro;
  if found then
    return json_build_object('ok', true, 'motivo', 'ya_comprada', 'texto', v_pe.texto,
                             'costo', 0, 'score', _score_equipo(p_equipo));
  end if;

  select count(*) into v_usadas from pistas_usadas where equipo_id = p_equipo and orden = v_hechos + 1;
  if p_nro <> v_usadas + 1 then
    return json_build_object('ok', false, 'motivo', 'en_orden');
  end if;

  insert into pistas_usadas (equipo_id, orden, nro, costo) values (p_equipo, v_hechos + 1, p_nro, v_pe.costo);
  return json_build_object('ok', true, 'motivo', 'comprada', 'texto', v_pe.texto,
                           'costo', v_pe.costo, 'score', _score_equipo(p_equipo));
end $$;

-- ---------- Ranking (sin datos personales): ordenado por puntaje ----------
create or replace function ranking(p_codigo text)
returns table (equipo text, puntos int, ultimo timestamptz, score int,
               terminado boolean, tiempo_seg int, total int)
language sql stable security definer set search_path = public as $$
  select e.nombre, l.n, l.ultimo, _score_equipo(e.id),
         (l.n >= t.total and t.total > 0),
         case when _inicio_equipo(e.id) is null then 0 else
           greatest(0, extract(epoch from (case when l.n >= t.total and t.total > 0 then l.ultimo else now() end
                                           - _inicio_equipo(e.id))))::int end,
         t.total
  from equipos e
  cross join lateral (select count(*)::int as n, max(creado) as ultimo from llegadas where equipo_id = e.id) l
  cross join lateral (select count(*)::int as total from puntos where partida_codigo = e.partida_codigo) t
  where e.partida_codigo = upper(trim(p_codigo))
  order by 4 desc, 3 asc nulls last;
$$;

-- ---------- Permisos: la clave pública solo llama a estas funciones ----------
do $$
declare f text;
begin
  foreach f in array array[
    'crear_partida(text, text, float8, float8, jsonb, text, jsonb, jsonb)',
    'admin_partida(text, text)',
    'admin_reiniciar(text, text)',
    'admin_iniciar(text, text)',
    'admin_borrar_datos(text, text)',
    'partida_info(text)',
    'historial(text)',
    'crear_equipo(text, text, jsonb, text)',
    'unirse_equipo(text, text, jsonb, text)',
    'editar_equipo(uuid, text, jsonb, text)',
    'mi_progreso(uuid)',
    'validar_llegada(uuid, float8, float8, float8)',
    'validar_respaldo(uuid, text)',
    'pedir_pista(uuid, int, int)',
    'ranking(text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  -- las utilidades internas no se exponen
  revoke all on function _entero(text, int, int, int, text) from public;
  revoke all on function _purgar_vencidos() from public;
  revoke all on function _admin_check(text, text) from public;
  revoke all on function _score_equipo(uuid) from public;
  revoke all on function _inicio_equipo(uuid) from public;
  revoke all on function _registrar_historial(uuid) from public;
  revoke all on function _historial_json(text) from public;
  revoke all on function _validar_participantes(text, jsonb) from public;
  revoke all on function _insertar_participantes(uuid, jsonb, int) from public;
end $$;

-- ---------- Recargar el schema cache de la API (PostgREST) ----------
notify pgrst, 'reload schema';
