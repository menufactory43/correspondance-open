#!/usr/bin/env python3
"""Fichier d'ordre de l'éditeur de liens depuis des traces App Launch.

À froid, le noyau lit le binaire page par page (16 Ko) au fil des fonctions
touchées ; dispersées sur 40 Mo de `__text`, elles coûtent des centaines de
lectures. Rangées côte à côte (ORDER_FILE, project.yml), elles tiennent dans
quelques mégaoctets contigus.

    xcrun xctrace record --template 'App Launch' --launch -- <app> --time-limit 8s
    xcrun xctrace symbolicate --input <trace> --dsym <Correspondance.app.dSYM>
    xcrun xctrace export --input <trace> --xpath \
      '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
    xcrun xctrace export --input <trace> --xpath \
      '/trace-toc/run[@number="1"]/data/table[@schema="virtual-memory"]' > vm.xml
    tools/launch/orderfile.py <app>/Contents/MacOS/Correspondance tp.xml vm.xml [tp2.xml vm2.xml …] \
      > tools/launch/launch.order

Une trace à froid (`sudo purge` avant) d'abord, une tiède ensuite : l'ordre
suit le premier contact. Les fonctions viennent des défauts de page dans
`__text` (tous fils), puis des piles échantillonnées, jusqu'à `--until` ms.
Le décalage ASLR de chaque trace est retrouvé par un symbole ancre résolu.
"""
import bisect, re, subprocess, sys, xml.etree.ElementTree as ET

ANCHOR = "InboxStore.conversationsDidChange()"
UNTIL = 3600.0  # ms de trace : jusqu'au fil peint, à froid

def nm(binary):
    out = subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        p = line.split(" ", 2)
        if len(p) == 3 and p[1] in "Tt" and p[0]:
            syms.append((int(p[0], 16), p[2]))
    return syms

def text_range(binary):
    out = subprocess.run(["otool", "-l", binary], capture_output=True, text=True).stdout
    m = re.search(r"sectname __text\n\s+segname __TEXT\n\s+addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)", out)
    return int(m.group(1), 16), int(m.group(1), 16) + int(m.group(2), 16)

ANCHOR_MANGLED = re.compile(r"^_\$s14Correspondance10InboxStoreC22conversationsDidChange33_[0-9A-F]+LLyyF$")

def anchor_start(syms):
    for addr, name in syms:
        if ANCHOR_MANGLED.match(name):
            return addr
    sys.exit(f"ancre {ANCHOR!r} introuvable dans nm")

def resolved(el, byid):
    return byid.get(el.attrib.get("ref"), el) if "ref" in el.attrib else el

def table(path):
    root = ET.parse(path).getroot()
    byid = {e.attrib["id"]: e for e in root.iter() if "id" in e.attrib}
    return root, byid

def slide_of(tp_root, anchor):
    for f in tp_root.iter("frame"):
        if f.attrib.get("name") == ANCHOR and "addr" in f.attrib:
            return (int(f.attrib["addr"], 16) - anchor) & ~0x3FFF
    sys.exit("ancre absente de la trace : symboliser d'abord (xctrace symbolicate)")

def main():
    binary, files = sys.argv[1], sys.argv[2:]
    syms = nm(binary); starts = [a for a, _ in syms]
    lo, hi = text_range(binary)
    anchor = anchor_start(syms)
    order, seen = [], set()
    def add(unslid):
        if not (lo <= unslid < hi): return
        i = bisect.bisect_right(starts, unslid) - 1
        if i >= 0 and syms[i][1] not in seen:
            seen.add(syms[i][1]); order.append(syms[i][1])
    for tp_path, vm_path in zip(files[::2], files[1::2]):
        tp_root, _ = table(tp_path)
        slide = slide_of(tp_root, anchor)
        vm_root, byid = table(vm_path)
        faults = []
        for row in vm_root.iter("row"):
            c = [resolved(x, byid) for x in row]
            ts = int(c[0].text) / 1e6
            kind = c[2].attrib.get("fmt") or c[2].text
            addr = int(c[7].attrib.get("fmt") or c[7].text or "0", 16)
            if kind == "File Backed Page In" and ts <= UNTIL:
                faults.append((ts, addr - slide))
        for _, u in sorted(faults): add(u)
        samples = []
        for row in tp_root.iter("row"):
            t = row.find("sample-time")
            ts = int(t.text) / 1e6 if t is not None and t.text else None
            if ts is None or ts > UNTIL: continue
            for f in row.iter("frame"):
                a = f.attrib.get("addr")
                if a: samples.append((ts, int(a, 16) - slide))
        for _, u in sorted(samples): add(u)
        print(f"{tp_path}: décalage {slide:#x}, {len(order)} fonctions cumulées", file=sys.stderr)
    sys.stdout.write("\n".join(order) + "\n")

if __name__ == "__main__":
    main()
