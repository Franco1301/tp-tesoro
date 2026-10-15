"""Lógica de geocercas en Python (misma que index.html, pero para usar en el servidor).

Lee config.json y decide si una posición está dentro del radio de algún punto.
Uso:
    python geocerca.py                      -> prueba con posiciones de ejemplo
    python geocerca.py -34.4920 -58.5107    -> chequea esa posición
    python geocerca.py --dms 34 29 31.4 S 58 30 38.6 W   -> convierte a decimal
"""
import json
import math
import sys


def haversine(lat1, lon1, lat2, lon2):
    """Distancia en metros entre dos coordenadas."""
    R = 6371000
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2)
    return 2 * R * math.asin(math.sqrt(a))


def dms_a_decimal(grados, minutos, segundos, hemisferio):
    """Convierte grados/minutos/segundos a decimal. S y O (W) dan negativo."""
    valor = grados + minutos / 60 + segundos / 3600
    return -valor if hemisferio.upper() in ("S", "W", "O") else valor


def cargar_config(ruta="config.json"):
    with open(ruta, encoding="utf-8") as f:
        return json.load(f)


def punto_mas_cercano(cfg, lat, lng):
    """Devuelve (punto, distancia_en_metros) del punto más cercano."""
    mejor = None
    for p in cfg["puntos"]:
        d = haversine(lat, lng, p["lat"], p["lng"])
        if mejor is None or d < mejor[1]:
            mejor = (p, d)
    return mejor


def esta_dentro(cfg, lat, lng):
    """True si la posición cae dentro del radio del punto más cercano."""
    p, d = punto_mas_cercano(cfg, lat, lng)
    return d <= p["radioM"], p, d


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--dms":
        lat = dms_a_decimal(float(args[1]), float(args[2]), float(args[3]), args[4])
        lng = dms_a_decimal(float(args[5]), float(args[6]), float(args[7]), args[8])
        print(f'"lat": {lat:.6f}, "lng": {lng:.6f}')
        sys.exit()

    cfg = cargar_config()
    if len(args) == 2:
        posiciones = [(float(args[0]), float(args[1]))]
    else:
        # sin argumentos: probamos justo sobre el primer punto y bastante lejos
        p0 = cfg["puntos"][0]
        posiciones = [(p0["lat"], p0["lng"]), (p0["lat"] + 0.001, p0["lng"])]

    for lat, lng in posiciones:
        dentro, p, d = esta_dentro(cfg, lat, lng)
        estado = "DENTRO" if dentro else "FUERA"
        print(f"({lat:.6f}, {lng:.6f}) -> {estado} | {p['nombre']} a {d:.0f} m (radio {p['radioM']} m)")
