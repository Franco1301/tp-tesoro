-- =====================================================================
-- TP Búsqueda del tesoro - migración v4 (Supabase / Postgres)
-- Se corre ENCIMA de schema_v2.sql + schema_v3.sql. No borra datos.
--
-- Arregla / agrega:
--   * Error "Could not find the function public.crear_equipo(p_codigo, p_nombre,
--     p_participantes, p_version)": la función ahora existe con EXACTAMENTE esa firma
--     y se eliminan las versiones viejas (overloads) para que no choquen.
--   * Datos a pedir configurables por partida (nombre, apellido, edad, teléfono,
--     Instagram): cada uno apagado / opcional / obligatorio.
--   * Equipos de 1, 2 o 3 participantes.
--   * Consentimiento de datos personales guardado (versión del texto + fecha).
--   * editar_equipo: cambiar nombre del equipo y participantes.
--   * NOTIFY pgrst para recargar el schema cache de la API.
--
-- CÓMO USARLO: Supabase -> SQL Editor -> New query -> pegar TODO -> Run.
-- Se puede volver a correr sin problema.
-- =====================================================================

-- ---------- Limpiar TODAS las versiones (overloads) anteriores ----------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as firma
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('crear_equipo', 'crear_partida', 'editar_equipo', '_validar_participantes')
  loop
    execute 'drop function if exists ' || r.firma || ' cascade';
  end loop;
end $$;

-- ---------- Tablas ----------
alter table partidas add column if not exists campos jsonb not null default
  '{"nombre":"req","apellido":"req","edad":"req","telefono":"off","instagram":"off"}'::jsonb;

alter table equipos add column if not exists version_datos text;
alter table equipos add column if not exists acepto_en timestamptz;

alter table participantes alter column apellido drop not null;
alter table participantes alter column edad drop not null;
alter table participantes add column if not exists telefono text;
alter table participantes add column if not exists instagram text;
alter table participantes add column if not exists sin_instagram boolean not null default false;
alter table participantes add column if not exists acepto_datos boolean not null default false;

-- el tope de participantes por equipo ahora es 3 (1, 2 o 3)
-- (la validación vive en crear_equipo / editar_equipo)

-- ---------- Interno: validar y normalizar participantes según la config de la partida ----------
create or replace function _validar_participantes(p_cod text, p_part jsonb)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_c jsonb; v_n int; v_i int := 0; v_p jsonb; v_out jsonb := '[]'::jsonb;
  v_nom text; v_ape text; v_edad text; v_tel text; v_ig text; v_sin boolean;
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

    -- nombre: siempre obligatorio (identifica a la persona)
    v_nom := trim(coalesce(v_p->>'nombre', ''));
    if length(v_nom) < 2 then raise exception 'Participante %: completá el nombre', v_i; end if;

    -- apellido
    v_ape := null;
    if coalesce(v_c->>'apellido', 'off') <> 'off' then
      v_ape := nullif(trim(coalesce(v_p->>'apellido', '')), '');
      if v_ape is null and v_c->>'apellido' = 'req' then raise exception 'Participante %: completá el apellido', v_i; end if;
      if v_ape is not null and length(v_ape) < 2 then raise exception 'Participante %: el apellido es muy corto', v_i; end if;
    end if;

    -- edad
    v_edad := null;
    if coalesce(v_c->>'edad', 'off') <> 'off' then
      v_edad := nullif(trim(coalesce(v_p->>'edad', '')), '');
      if v_edad is null and v_c->>'edad' = 'req' then raise exception 'Participante %: completá la edad', v_i; end if;
      if v_edad is not null and not (v_edad ~ '^[0-9]{1,3}$' and v_edad::int between 1 and 120) then
        raise exception 'Participante %: la edad tiene que ser un número entre 1 y 120', v_i;
      end if;
    end if;

    -- teléfono
    v_tel := null;
    if coalesce(v_c->>'telefono', 'off') <> 'off' then
      v_tel := nullif(trim(coalesce(v_p->>'telefono', '')), '');
      if v_tel is null and v_c->>'telefono' = 'req' then raise exception 'Participante %: completá el teléfono', v_i; end if;
      if v_tel is not null and not (v_tel ~ '^\+?[0-9 ()-]{6,25}$'
                                    and length(regexp_replace(v_tel, '[^0-9]', '', 'g')) between 6 and 15) then
        raise exception 'Participante %: el teléfono no es válido', v_i;
      end if;
    end if;

    -- Instagram (con opción "No tengo Instagram")
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

    -- consentimiento de datos personales: siempre obligatorio
    if coalesce(v_p->>'acepto', 'false') <> 'true' then
      raise exception 'Participante %: tiene que aceptar el uso de sus datos personales', v_i;
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'nombre', left(v_nom, 40), 'apellido', left(v_ape, 40),
      'edad', v_edad::int, 'telefono', left(v_tel, 25),
      'instagram', left(v_ig, 30), 'sinInstagram', v_sin));
  end loop;
  return v_out;
end $$;

-- ---------- Organizador: crear partida (con modo y datos a pedir) ----------
-- p_campos = {"nombre":"req","apellido":"req","edad":"opt","telefono":"off","instagram":"off"}
create or replace function crear_partida(
  p_nombre text, p_password text, p_lat float8, p_lng float8, p_puntos jsonb,
  p_modo text default 'presencial', p_campos jsonb default null)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  v_codigo text; v_n int; v_i int := 0; v_p jsonb;
  v_campos jsonb := '{"nombre":"req","apellido":"req","edad":"req","telefono":"off","instagram":"off"}'::jsonb;
  k text; v text;
begin
  if length(trim(coalesce(p_nombre, ''))) < 2 then
    raise exception 'El nombre del juego es muy corto';
  end if;
  if length(coalesce(p_password, '')) < 6 then
    raise exception 'La contraseña tiene que tener al menos 6 caracteres';
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

  loop
    v_codigo := _codigo_azar(6, 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    exit when not exists (select 1 from partidas where codigo = v_codigo);
  end loop;

  insert into partidas (codigo, nombre, admin_hash, centro_lat, centro_lng, modo, campos)
  values (v_codigo, left(trim(p_nombre), 60), crypt(p_password, gen_salt('bf')), p_lat, p_lng, p_modo, v_campos);

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
            _codigo_azar(5, '23456789'));
  end loop;

  return json_build_object('codigo', v_codigo, 'puntos', v_n, 'modo', p_modo, 'campos', v_campos);
end $$;

-- ---------- Jugadores: crear equipo (1 a 3 participantes) ----------
-- Firma exacta que usa el frontend: p_codigo, p_nombre, p_participantes (jsonb), p_version
create or replace function crear_equipo(
  p_codigo text, p_nombre text, p_participantes jsonb, p_version text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_cod text := upper(trim(p_codigo)); v_norm jsonb; v_p jsonb; v_i int := 0;
begin
  if length(trim(coalesce(p_nombre, ''))) < 2 then
    raise exception 'El nombre del equipo es muy corto';
  end if;
  if not exists (select 1 from partidas where codigo = v_cod) then
    raise exception 'No existe una partida con ese código';
  end if;

  v_norm := _validar_participantes(v_cod, p_participantes);   -- valida todo antes de insertar nada

  begin
    insert into equipos (partida_codigo, nombre, version_datos, acepto_en)
    values (v_cod, left(trim(p_nombre), 40), left(p_version, 40), now())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Ya hay un equipo con ese nombre en esta partida';
  end;

  for v_p in select * from jsonb_array_elements(v_norm) loop
    v_i := v_i + 1;
    insert into participantes (equipo_id, posicion, nombre, apellido, edad, telefono, instagram, sin_instagram, acepto_datos)
    values (v_id, v_i, v_p->>'nombre', v_p->>'apellido', (v_p->>'edad')::int,
            v_p->>'telefono', v_p->>'instagram', (v_p->>'sinInstagram')::boolean, true);
  end loop;
  return v_id;
end $$;

-- ---------- Jugadores: editar equipo y participantes ----------
create or replace function editar_equipo(
  p_equipo uuid, p_nombre text, p_participantes jsonb, p_version text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_eq equipos; v_norm jsonb; v_p jsonb; v_i int := 0;
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
  for v_p in select * from jsonb_array_elements(v_norm) loop
    v_i := v_i + 1;
    insert into participantes (equipo_id, posicion, nombre, apellido, edad, telefono, instagram, sin_instagram, acepto_datos)
    values (p_equipo, v_i, v_p->>'nombre', v_p->>'apellido', (v_p->>'edad')::int,
            v_p->>'telefono', v_p->>'instagram', (v_p->>'sinInstagram')::boolean, true);
  end loop;
  return json_build_object('ok', true);
end $$;

-- ---------- Jugadores: info pública (con datos que se piden) ----------
create or replace function partida_info(p_codigo text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'codigo', pa.codigo, 'nombre', pa.nombre, 'modo', pa.modo, 'campos', pa.campos,
    'centro', json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'totalPuntos', (select count(*) from puntos p where p.partida_codigo = pa.codigo))
  from partidas pa where pa.codigo = upper(trim(p_codigo));
$$;

-- ---------- Jugadores: estado del equipo (con datos para editar) ----------
create or replace function mi_progreso(p_equipo uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'equipo',      e.nombre,
    'codigo',      e.partida_codigo,
    'juego',       pa.nombre,
    'modo',        pa.modo,
    'campos',      pa.campos,
    'centro',      json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'inicio',      e.creado,
    'ahora',       now(),
    'total',       t.total,
    'completados', c.n,
    'terminado',   c.n >= t.total,
    'fin',         case when c.n >= t.total then c.ultimo end,
    'pista',       (select p.pista from puntos p
                    where p.partida_codigo = e.partida_codigo and p.orden = c.n + 1),
    'integrantes', coalesce((select json_agg(trim(pt.nombre || ' ' || coalesce(pt.apellido, '')) order by pt.posicion)
                             from participantes pt where pt.equipo_id = e.id), '[]'::json),
    'participantes', coalesce((select json_agg(json_build_object(
                         'nombre', pt.nombre, 'apellido', pt.apellido, 'edad', pt.edad,
                         'telefono', pt.telefono, 'instagram', pt.instagram,
                         'sinInstagram', pt.sin_instagram) order by pt.posicion)
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

-- ---------- Organizador: ver la partida completa ----------
create or replace function admin_partida(p_codigo text, p_password text)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare v_codigo text := upper(trim(p_codigo));
begin
  if not _admin_ok(v_codigo, p_password) then
    raise exception 'credenciales_invalidas';
  end if;
  return (select json_build_object(
    'codigo', pa.codigo, 'nombre', pa.nombre, 'modo', pa.modo, 'campos', pa.campos,
    'centro', json_build_object('lat', pa.centro_lat, 'lng', pa.centro_lng),
    'duracionMin', pa.duracion_min,
    'puntos', coalesce((select json_agg(json_build_object(
        'orden', p.orden, 'tipo', p.tipo, 'pista', p.pista, 'lat', p.lat, 'lng', p.lng,
        'radioM', p.radio_m, 'respaldo', p.respaldo) order by p.orden)
      from puntos p where p.partida_codigo = pa.codigo), '[]'::json),
    'equipos', coalesce((select json_agg(json_build_object(
        'id', e.id, 'nombre', e.nombre, 'puntos', e.n, 'ultimo', e.ultimo,
        'usosRespaldo', e.resp, 'participantes', e.parts, 'visitados', e.vis)
        order by e.n desc, e.ultimo asc nulls last)
      from (select eq.id, eq.nombre,
                   (select count(*)::int from llegadas l where l.equipo_id = eq.id) as n,
                   (select max(l.creado) from llegadas l where l.equipo_id = eq.id) as ultimo,
                   (select count(*)::int from llegadas l
                     where l.equipo_id = eq.id and l.uso_respaldo) as resp,
                   coalesce((select json_agg(json_build_object(
                       'nombre', pt.nombre, 'apellido', pt.apellido, 'edad', pt.edad,
                       'telefono', pt.telefono, 'instagram', pt.instagram,
                       'sinInstagram', pt.sin_instagram)
                       order by pt.posicion)
                     from participantes pt where pt.equipo_id = eq.id), '[]'::json) as parts,
                   coalesce((select json_agg(json_build_object(
                       'orden', l.orden, 'creado', l.creado, 'respaldo', l.uso_respaldo)
                       order by l.orden)
                     from llegadas l where l.equipo_id = eq.id), '[]'::json) as vis
            from equipos eq where eq.partida_codigo = pa.codigo) e), '[]'::json))
  from partidas pa where pa.codigo = v_codigo);
end $$;

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array[
    'crear_partida(text, text, float8, float8, jsonb, text, jsonb)',
    'admin_partida(text, text)',
    'admin_reiniciar(text, text)',
    'partida_info(text)',
    'crear_equipo(text, text, jsonb, text)',
    'editar_equipo(uuid, text, jsonb, text)',
    'mi_progreso(uuid)',
    'validar_llegada(uuid, float8, float8, float8)',
    'validar_respaldo(uuid, text)',
    'ranking(text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  revoke all on function _validar_participantes(text, jsonb) from public;
end $$;

-- ---------- Recargar el schema cache de la API (PostgREST) ----------
notify pgrst, 'reload schema';
