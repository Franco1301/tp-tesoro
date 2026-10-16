"""Genera puntos.sql a partir de config.json.

Así los puntos viven en un solo lugar (config.json) y el servidor se
actualiza pegando el resultado en Supabase. Para cambiar de plaza no se toca código.

Uso:
    python generar_puntos.py                 (lee config.json, escribe puntos.sql)
    python generar_puntos.py otra.json       (otro archivo de configuración)
"""
import json
import sys


def sql_texto(s):
    return "'" + str(s).replace("'", "''") + "'"


def main():
    ruta = sys.argv[1] if len(sys.argv) > 1 else "config.json"
    with open(ruta, encoding="utf-8") as f:
        cfg = json.load(f)

    puntos = cfg["puntos"]
    ids = [p["id"] for p in puntos]
    if len(ids) != len(set(ids)):
        sys.exit("Error: hay ids de puntos repetidos en " + ruta)

    filas = []
    for orden, p in enumerate(puntos, start=1):   # el orden es el de la lista del JSON
        if p["radioM"] <= 0:
            sys.exit(f"Error: el radio de {p['id']} tiene que ser mayor a 0")
        filas.append(
            f"  ({sql_texto(p['id'])}, {orden}, {sql_texto(p['nombre'])}, "
            f"{float(p['lat'])}, {float(p['lng'])}, {float(p['radioM'])})"
        )

    sql = (
        "-- Generado por generar_puntos.py desde " + ruta + ". No editar a mano.\n"
        "insert into puntos (id, orden, nombre, lat, lng, radio_m) values\n"
        + ",\n".join(filas)
        + "\non conflict (id) do update set\n"
        "  orden = excluded.orden, nombre = excluded.nombre,\n"
        "  lat = excluded.lat, lng = excluded.lng, radio_m = excluded.radio_m;\n"
    )
    with open("puntos.sql", "w", encoding="utf-8") as f:
        f.write(sql)
    print(f"puntos.sql listo con {len(puntos)} puntos")


if __name__ == "__main__":
    main()
