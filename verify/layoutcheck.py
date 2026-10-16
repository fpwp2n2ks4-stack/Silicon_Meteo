import struct, zlib, sys
from collections import Counter

def read_png(p):
    d = open(p,'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'pas un PNG'
    i, idat, ct = 8, b'', None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]
        typ = d[i+4:i+8]
        data = d[i+8:i+8+ln]
        i += 12 + ln
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'IDAT': idat += data
        elif typ == b'IEND': break
    raw = zlib.decompress(idat)
    ch = {0:1,2:3,3:1,4:2,6:4}[ct]
    stride = w*ch
    out = bytearray(); prev = bytearray(stride); pos = 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        for x in range(stride):
            a = line[x-ch] if x >= ch else 0
            b = prev[x]
            c = prev[x-ch] if x >= ch else 0
            if f == 1: line[x] = (line[x]+a) & 255
            elif f == 2: line[x] = (line[x]+b) & 255
            elif f == 3: line[x] = (line[x]+(a+b)//2) & 255
            elif f == 4:
                pp = a+b-c
                pa, pb, pc = abs(pp-a), abs(pp-b), abs(pp-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x]+pr) & 255
        out += line; prev = line
    return w, h, ch, bytes(out)


def analyse(path, label, scale=2, inset=5):
    """Contrôle heuristique d'une capture de `verify/`.

    Le fond n'est plus supposé clair : on prend la couleur **la plus
    fréquente** de l'image (elle domine largement). Le cadre arrondi et le
    trait de séparation sont ignorés via `inset` (en points), sinon ils
    collent au bord et font croire à un débordement.
    """
    w, h, ch, px = read_png(path)

    def rgb(x, y):
        o = (y*w+x)*ch
        return (px[o], px[o+1], px[o+2])

    def alpha(x, y):
        # RGBA uniquement : un pixel transparent (coins arrondis, extérieur du
        # cadre) ne doit pas être pris pour du contenu.
        if ch < 4:
            return 255
        return px[(y*w+x)*ch + 3]

    hist = Counter()
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            if alpha(x, y) > 40:
                hist[rgb(x, y)] += 1
    bg = hist.most_common(1)[0][0]

    def content(x, y, thr=40):
        if alpha(x, y) <= 40:
            return False
        r, g, b = rgb(x, y)
        return abs(r-bg[0]) + abs(g-bg[1]) + abs(b-bg[2]) > thr

    def coloured(x, y):
        if alpha(x, y) <= 40:
            return False
        r, g, b = rgb(x, y)
        return max(r, g, b) - min(r, g, b) > 30

    # La bande `inset` évite le cadre arrondi et le trait de séparation, qui
    # touchent le bord et fausseraient la mesure de débordement.
    m = inset*scale
    xs, ys = [], []
    for y in range(m, h-m):
        for x in range(m, w-m):
            if content(x, y):
                xs.append(x); ys.append(y)

    print(f"{label} : image {w//scale}×{h//scale} pt (fond {bg})", end="")
    if not xs:
        print(" → ✗ rien n'a été dessiné"); return False
    print()

    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    print(f"  contenu (hors cadre) : x {x0//scale}..{x1//scale} pt, y {y0//scale}..{y1//scale} pt")
    print(f"  marges : droite {(w-1-x1)/scale:.1f} pt, basse {(h-1-y1)/scale:.1f} pt")

    ok = True
    if x1 >= w-1-m or y1 >= h-1-m:
        print("  ✗ le contenu atteint le bord (débordement ?)"); ok = False

    # Bandes de texte : une ligne « pleine » change de couleur sur beaucoup
    # de pixels. Les bandes fusionnent les lignes voisines, c'est suffisant
    # pour vérifier qu'il y a du contenu réparti dans la hauteur.
    rows = [sum(1 for x in range(0, w, 2) if content(x, y)) for y in range(m, h-m)]
    bands, cur = [], None
    for y, n in enumerate(rows, start=m):
        if n > 6:
            if cur is None: cur = [y, y]
            else: cur[1] = y
        elif cur:
            bands.append(tuple(cur)); cur = None
    if cur: bands.append(tuple(cur))
    print(f"  {len(bands)} bandes de texte")
    if bands:
        last = bands[-1]
        print(f"  dernière bande : y {last[0]//scale}..{last[1]//scale} pt")
        if last[1] > h - 6*scale:
            print("  ✗ le pied de page touche le bord inférieur"); ok = False
    else:
        print("  ✗ aucune bande de texte détectée"); ok = False

    ncol = sum(1 for y in range(0, h, 3) for x in range(0, w, 3) if coloured(x, y))
    print(f"  pixels colorés (jauges) : {ncol}")
    if ncol < 20:
        print("  ✗ aucune jauge colorée"); ok = False

    print("  → " + ("OK" if ok else "PROBLÈMES DÉTECTÉS"))
    return ok


r1 = analyse('verify/panel.png', 'Panneau')
print()
r2 = analyse('verify/menubar-clair.png', 'Barre de menus (clair)', scale=3)
print()
r3 = analyse('verify/menubar-sombre.png', 'Barre de menus (sombre)', scale=3)
sys.exit(0 if (r1 and r2 and r3) else 1)
