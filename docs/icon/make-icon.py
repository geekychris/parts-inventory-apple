# Draws the app icon: python3 make-icon.py writes ios.svg (full bleed) and mac.svg (the macOS rounded square);
# render them with `rsvg-convert -w 1024`, then make the asset catalog sizes with `magick -resize`.
import sys
def drawer(x,y,w,h,front,edge,label=True):
    s=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{front}" stroke="{edge}" stroke-width="4"/>'
    s+=f'<rect x="{x+w/2-26}" y="{y+h-30}" width="52" height="14" rx="7" fill="{edge}" opacity="0.85"/>'
    if label: s+=f'<rect x="{x+w/2-40}" y="{y+16}" width="80" height="26" rx="5" fill="#ffffff" opacity="0.92"/>'
    return s
def art():
    s='''<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2b8cff"/><stop offset="1" stop-color="#0a3a8c"/></linearGradient>
<linearGradient id="cab" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#d3dae3"/></linearGradient>
<linearGradient id="chip" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a3f47"/><stop offset="1" stop-color="#16191e"/></linearGradient>
<linearGradient id="pin" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#f3f5f8"/><stop offset="1" stop-color="#9aa3ae"/></linearGradient>
<linearGradient id="hot" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffb84d"/><stop offset="1" stop-color="#ff8a00"/></linearGradient>
<filter id="sh" x="-60%" y="-60%" width="220%" height="240%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#001a40" flood-opacity="0.45"/></filter>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<g filter="url(#sh)"><rect x="168" y="172" width="560" height="620" rx="44" fill="url(#cab)"/></g>
'''
    cols, rows = 3, 4
    x0,y0,iw,ih,g = 200,206,496,552,18
    cw=(iw-g*(cols-1))/cols; rh=(ih-g*(rows-1))/rows
    for r in range(rows):
        for c in range(cols):
            if (r,c)==(1,1): continue
            s+=drawer(x0+c*(cw+g), y0+r*(rh+g), cw, rh, "#cfe0f2", "#7d97b5")
    # pulled-out drawer
    x=x0+1*(cw+g); y=y0+1*(rh+g)
    s+=f'<rect x="{x}" y="{y}" width="{cw}" height="{rh}" rx="12" fill="#2c3e57"/>'
    s+=f'<g filter="url(#sh)"><rect x="{x-14}" y="{y+14}" width="{cw+28}" height="{rh+14}" rx="14" fill="url(#hot)" stroke="#c45f00" stroke-width="4"/></g>'
    s+=f'<rect x="{x+cw/2-30}" y="{y+rh-6}" width="60" height="16" rx="8" fill="#9a4a00"/>'
    s+=f'<rect x="{x+cw/2-44}" y="{y+32}" width="88" height="28" rx="6" fill="#fff"/>'
    # IC chip badge lower right
    cx,cy,w,h=532,566,320,240
    pins=''
    n=6
    for i in range(n):
        px=cx+30+i*((w-60-26)/(n-1))
        pins+=f'<rect x="{px}" y="{cy-34}" width="26" height="44" rx="5" fill="url(#pin)"/>'
        pins+=f'<rect x="{px}" y="{cy+h-10}" width="26" height="44" rx="5" fill="url(#pin)"/>'
    s+=f'<g filter="url(#sh)">{pins}<rect x="{cx}" y="{cy}" width="{w}" height="{h}" rx="26" fill="url(#chip)"/></g>'
    s+=f'<circle cx="{cx+48}" cy="{cy+h-48}" r="18" fill="#4b525c"/>'
    s+=f'<rect x="{cx+90}" y="{cy+84}" width="150" height="20" rx="10" fill="#8f98a3"/>'
    s+=f'<rect x="{cx+90}" y="{cy+126}" width="100" height="20" rx="10" fill="#646c76"/>'
    return s
a=art()
open('ios.svg','w').write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{a}</svg>')
# mac: 824 body at 100, rounded, with drop shadow
mac=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
<filter id="ms" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.3"/></filter></defs>
<g filter="url(#ms)"><g clip-path="url(#sq)"><g transform="translate(100 100) scale({824/1024})">{a}</g></g></g></svg>'''
open('mac.svg','w').write(mac)
