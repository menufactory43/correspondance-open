import sys, collections, re
from xml.etree import ElementTree as ET
path, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
root = ET.parse(path).getroot()
byid = {el.get('id'): el for el in root.iter() if el.get('id')}
def deref(el):
    r = el.get('ref'); return byid[r] if r else el
CATS = [
 ('app-body', re.compile(r'MessageBubbleView\.|ThreadView\.|MessageGrouping|InboxListPane\.|ContentView\.|MessageAvatarView\.|ConversationAvatarView\.|AvatarStore|LinkPreviewCard\.|AttachmentImageView\.|AttachmentThumbnailStore|TextLinks|LinkedText|ConversationSearch|WritingTheme|Typography')),
 ('text', re.compile(r'CTFont|CoreText|TypeSetter|Typesetter|CTLine|CTRun|CTFrame|TLine|StyledText|ResolvedText|NSAttributedString|TextLayout|TextStorage|NSLayoutManager|TextKit|Text\.')),
 ('image', re.compile(r'ImageIO|CGImage|IIO|decode|NSImage|NSBitmap|AppleJPEG|PNG|HEIC')),
 ('a11y', re.compile(r'ccessibility|AX')),
 ('render', re.compile(r'render\(interval|DisplayList|CA::|CALayer|CABackingStore|RBDisplayList|Rasterize|CGContext|Quartz|_display')),
 ('layout', re.compile(r'sizeThatFits|LayoutComputer|layoutSubtree|NSISEngine|Layout|minSize|_layoutViewTree|updateConstraints|Constraint')),
 ('graph', re.compile(r'AG::Graph|AGGraph|updateValue|ViewGraph')),
]
bins = collections.defaultdict(collections.Counter)
totals = collections.Counter()
for row in root.iter('row'):
    d = {}
    for c in row:
        c = deref(c); d[c.tag] = c
    st = d.get('sample-time')
    if st is None: continue
    t = int(st.text)/1e9
    if not (t0 <= t <= t1): continue
    thr = d.get('thread')
    if thr is None or 'Main Thread' not in (thr.get('fmt') or ''): continue
    bt = d.get('tagged-backtrace'); frames=[]
    if bt is not None:
        bb = deref(bt); b2 = bb.find('backtrace')
        if b2 is not None: bb = deref(b2)
        frames = [ (deref(fr).get('name') or '') for fr in bb.findall('frame')]
    joined='\n'.join(frames)
    cat='other'
    for name, rx in CATS:
        if rx.search(joined): cat=name; break
    b = int(t*20)/20
    bins[b][cat]+=1; totals[cat]+=1
names=[c for c,_ in CATS]+['other']
print('bin    ' + ' '.join(n.rjust(9) for n in names) + '   total')
for b in sorted(bins):
    print(f"{b:5.2f}  " + ' '.join(str(bins[b][n]).rjust(9) for n in names) + f"   {sum(bins[b].values()):5d}")
print('TOTAL  ' + ' '.join(str(totals[n]).rjust(9) for n in names) + f"   {sum(totals.values()):5d}")
