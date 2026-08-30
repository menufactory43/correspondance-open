import sys, collections
from xml.etree import ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
byid = {el.get('id'): el for el in root.iter() if el.get('id')}
def deref(el):
    r = el.get('ref'); return byid[r] if r else el
keys = ['restoreWindow','MessageBubbleView','InboxListPane','ThreadView','render(interval','_makeViewList','NSSplitViewController','TextLinks.detect','MessageAvatarView','AttachmentImageView','LinkPreview','CTFont','CoreText','TypeSetter','NSDataDetector','orderFront','_setUpFirstResponderBeforeBecomingVisible']
bins = collections.defaultdict(lambda: collections.Counter())
tot = collections.Counter(); offmain = collections.Counter()
for row in root.iter('row'):
    d = {}
    for c in row:
        c = deref(c); d[c.tag] = c
    st = d.get('sample-time')
    if st is None: continue
    t = int(st.text)/1e9
    b = int(t*20)/20
    thr = d.get('thread')
    if thr is None or 'Main Thread' not in (thr.get('fmt') or ''):
        offmain[b] += 1; continue
    tot[b] += 1
    bt = d.get('tagged-backtrace'); frames=[]
    if bt is not None:
        bb = deref(bt); b2 = bb.find('backtrace')
        if b2 is not None: bb = deref(b2)
        frames = [ (deref(fr).get('name') or '') for fr in bb.findall('frame')]
    joined = '\n'.join(frames)
    for k in keys:
        if k in joined: bins[b][k] += 1
print('bin    main off  ' + ' '.join(k[:10].rjust(10) for k in keys))
for b in sorted(set(tot)|set(offmain)):
    if b > 3.6: break
    print(f"{b:5.2f} {tot[b]:5d} {offmain[b]:3d}  " + ' '.join(str(bins[b][k]).rjust(10) for k in keys))
