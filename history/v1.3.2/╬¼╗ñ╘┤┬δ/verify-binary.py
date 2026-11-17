"""Read the actual Inno 6 solid LZMA2 data without executing the installer."""
import hashlib,lzma,pathlib,sys
p=pathlib.Path(__file__).resolve().parent
d=pathlib.Path(sys.argv[1]).read_bytes()
sig=b'zlb\x1a'
assert d.count(sig)==1, 'Unexpected number of payload streams'
i=d.index(sig)+4
n=d[i]
obj=lzma.LZMADecompressor(format=lzma.FORMAT_RAW,filters=[dict(id=lzma.FILTER_LZMA2,dict_size=(2|(n&1))<<(n//2+11))])
raw=obj.decompress(d[i+1:])
assert obj.eof
# Reverse Inno's per-file relative CALL/JMP address filter (Compression.Base.pas).
def decode(code,block):
    buf=bytearray(code)
    for start in range(0,len(buf),block):
        j=start
        while j<min(len(buf),start+block)-4:
            if buf[j] not in (0xe8,0xe9): j+=1;continue
            j+=1
            if buf[j+3] in (0,255):
                orig=(int.from_bytes(buf[j:j+3],'little')-j-4)&0xffffff
                if orig&0x800000: buf[j+3]^=255
                buf[j:j+3]=orig.to_bytes(3,'little')
            j+=4
    return buf
cursor=0
for row in (p/'payload.sha256').read_text(encoding='utf-8').splitlines():
    sha,name=row.split('  ',1)
    f=p/'stage'/name
    body=raw[cursor:cursor+f.stat().st_size];cursor+=len(body)
    ok=hashlib.sha256(body).hexdigest()==sha
    if not ok and name.endswith('.exe'):
        ok=any(hashlib.sha256(decode(body,block)).hexdigest()==sha for block in [65536,32768,len(body)])
    assert ok,name
assert cursor==len(raw),'Extra bytes outside manifest'
print('PASS: all embedded files match SHA-256; no extra data in the payload stream.')

