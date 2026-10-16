-- Generado por generar_puntos.py desde config.json. No editar a mano.
insert into puntos (id, orden, nombre, lat, lng, radio_m) values
  ('p01', 1, 'Punto 1 Fuente', -34.492056, -58.510722, 5.0),
  ('p02', 2, 'Punto 2 Estatua', -34.491778, -58.510083, 5.0),
  ('p03', 3, 'Punto 3 Mesas Ajedrez', -34.491622, -58.510007, 5.0)
on conflict (id) do update set
  orden = excluded.orden, nombre = excluded.nombre,
  lat = excluded.lat, lng = excluded.lng, radio_m = excluded.radio_m;
