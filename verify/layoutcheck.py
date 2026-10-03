import struct, zlib, sys

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

def analyse(path, label, scale=2):
    w, h, ch, px = read_png(path)
    def dark(x, y, t=170):
        o = (y*w+x)*ch
        return px[o] < t or px[o+1] < t or px[o+2] < t
    def coloured(x, y):
        """pixel non gris = texte accentué ou jauge colorée"""
        o = (y*w+x)*ch
        r, g, b = px[o], px[o+1], px[o+2]
        return max(r,g,b) - min(r,g,b) > 30

    # bbox du contenu sombre
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            if dark(x, y):
                xs.append(x); ys.append(y)
    if not xs:
        print(f"✗ {label} : rien n'a été dessiné"); return False

    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    print(f"{label} : image {w//scale}×{h//scale} pt")
    print(f"  contenu : x {x0//scale}..{x1//scale} pt, y {y0//scale}..{y1//scale} pt")

    ok = True
    # marge : rien ne doit toucher le bord (le cadre arrondi est à x=0)
    pad = 4*scale
    if x0 < pad or y0 < pad:
        print(f"  ✗ contenu trop près du bord haut/gauche ({x0//scale}, {y0//scale})")
        ok = False
    right_margin = (w-1-x1)/scale
    bottom_margin = (h-1-y1)/scale
    print(f"  marge droite {right_margin:.1f} pt, marge basse {bottom_margin:.1f} pt")
    if right_margin < 4:
        print("  ✗ débordement à droite"); ok = False
    if bottom_margin < 2:
        print("  ✗ contenu collé au bas (piège de page rogné ?)"); ok = False

    # dernier texte visible : doit être le pied de page
    rows = []
    for y in range(h):
        n = sum(1 for x in range(0, w, 2) if dark(x, y))
        rows.append(n)
    bands, cur = [], None
    for y, n in enumerate(rows):
        if n > 6:
            if cur is None: cur = [y, y]
            else: cur[1] = y
        elif cur:
            bands.append(tuple(cur)); cur = None
    if cur: bands.append(tuple(cur))
    print(f"  {len(bands)} bandes de texte")
    last = bands[-1] if bands else None
    if last:
        print(f"  dernière bande : y {last[0]//scale}..{last[1]//scale} pt")
        if last[1] > h - 6*scale:
            print("  ✗ le pied de page touche le bord inférieur"); ok = False

    # jauges colorées présentes ?
    ncol = sum(1 for y in range(0, h, 3) for x in range(0, w, 3) if coloured(x, y))
    print(f"  pixels colorés (jauges) : {ncol}")
    if ncol < 20:
        print("  ✗ aucune jauge colorée"); ok = False

    print("  → " + ("OK" if ok else "PROBLÈMES DÉTECTÉS"))
    return ok

r1 = analyse('verify/panel.png', 'Panneau')
print()
r2 = analyse('verify/menubar.png', 'Barre de menus')
sys.exit(0 if (r1 and r2) else 1)
