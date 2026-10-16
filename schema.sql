-- =====================================================================
-- TP Búsqueda del tesoro - esquema del servidor (Supabase / Postgres)
-- Se pega UNA vez en Supabase: SQL Editor -> New query -> Run.
-- Se puede volver a correr sin romper nada.
-- =====================================================================

-- ---------- Tablas ----------
create table if not exists puntos (
  id        text primary key,
  orden     int  not null unique,
  nombre    text not null,
  lat       double precision not null,
  lng       double precision not null,
  radio_m   double precision not null check (radio_m > 0)
);

create table if not exists equipos (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  codigo_partida text not null,
  creado         timestamptz not null default now(),
  unique (codigo_partida, nombre)
);

create table if not exists llegadas (
  equipo_id    uuid references equipos(id) on delete cascade,
  punto_id     text references puntos(id),
  creado       timestamptz not null default now(),
  distancia_m  double precision,
  precision_m  double precision,
  primary key (equipo_id, punto_id)          -- una llegada por equipo y punto
);

-- ---------- Seguridad ----------
-- Con RLS activado y SIN políticas, la clave pública no puede leer ni
-- escribir las tablas directamente. Todo pasa por las funciones de abajo.
alter table puntos   enable row level security;
alter table equipos  enable row level security;
alter table llegadas enable row level security;

-- ---------- Distancia (misma fórmula haversine que el cliente) ----------
create or replace function haversine_m(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8 language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

-- ---------- Crear equipo ----------
create or replace function crear_equipo(p_nombre text, p_codigo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if length(trim(coalesce(p_nombre, ''))) < 2 or length(trim(coalesce(p_codigo, ''))) < 2 then
    raise exception 'Nombre de equipo o código de partida inválido';
  end if;
  insert into equipos (nombre, codigo_partida)
  values (left(trim(p_nombre), 40), upper(left(trim(p_codigo), 20)))
  returning id into v_id;
  return v_id;
end $$;

-- ---------- Validar llegada (la decide el servidor) ----------
create or replace function validar_llegada(
  p_equipo uuid, p_punto text, p_lat float8, p_lng float8, p_precision float8 default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_equipo equipos;
  v_punto  puntos;
  v_hechos int;
  v_dist   float8;
  v_margen float8;
begin
  -- Bloquea la fila del equipo: dos pedidos simultáneos se procesan de a uno.
  select * into v_equipo from equipos where id = p_equipo for update;
  if not found then
    return json_build_object('ok', false, 'motivo', 'equipo_desconocido');
  end if;

  select * into v_punto from puntos where id = p_punto;
  if not found then
    return json_build_object('ok', false, 'motivo', 'punto_desconocido');
  end if;

  -- Repetir una validación no cambia nada (idempotente).
  if exists (select 1 from llegadas where equipo_id = p_equipo and punto_id = p_punto) then
    return json_build_object('ok', true, 'motivo', 'ya_validado');
  end if;

  -- Orden: solo se puede validar el siguiente punto.
  select count(*) into v_hechos from llegadas where equipo_id = p_equipo;
  if v_punto.orden <> v_hechos + 1 then
    return json_build_object('ok', false, 'motivo', 'fuera_de_orden');
  end if;

  -- Geocerca con tolerancia por imprecisión del GPS (máximo 15 m extra).
  v_dist   := haversine_m(p_lat, p_lng, v_punto.lat, v_punto.lng);
  v_margen := least(greatest(coalesce(p_precision, 0), 0), 15);
  if v_dist > v_punto.radio_m + v_margen then
    return json_build_object('ok', false, 'motivo', 'lejos', 'distancia_m', round(v_dist));
  end if;

  insert into llegadas (equipo_id, punto_id, distancia_m, precision_m)
  values (p_equipo, p_punto, v_dist, p_precision);

  return json_build_object('ok', true, 'motivo', 'validado', 'distancia_m', round(v_dist));
end $$;

-- ---------- Progreso del equipo (para recuperar al recargar) ----------
create or replace function mi_progreso(p_equipo uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'equipo',   e.nombre,
    'codigo',   e.codigo_partida,
    'inicio',   e.creado,
    'ahora',    now(),
    'llegadas', coalesce((
      select json_agg(l.punto_id order by p.orden)
      from llegadas l join puntos p on p.id = l.punto_id
      where l.equipo_id = e.id), '[]'::json))
  from equipos e where e.id = p_equipo;
$$;

-- ---------- Ranking (sin datos personales) ----------
create or replace function ranking(p_codigo text)
returns table (equipo text, puntos int, ultimo timestamptz)
language sql stable security definer set search_path = public as $$
  select e.nombre, count(l.punto_id)::int, max(l.creado)
  from equipos e left join llegadas l on l.equipo_id = e.id
  where e.codigo_partida = upper(trim(p_codigo))
  group by e.id
  order by 2 desc, 3 asc nulls last;
$$;

-- ---------- Permisos: la clave pública solo puede llamar a estas funciones ----------
revoke all on function crear_equipo(text, text)                         from public;
revoke all on function validar_llegada(uuid, text, float8, float8, float8) from public;
revoke all on function mi_progreso(uuid)                                from public;
revoke all on function ranking(text)                                    from public;
grant execute on function crear_equipo(text, text)                         to anon, authenticated;
grant execute on function validar_llegada(uuid, text, float8, float8, float8) to anon, authenticated;
grant execute on function mi_progreso(uuid)                                to anon, authenticated;
grant execute on function ranking(text)                                    to anon, authenticated;
