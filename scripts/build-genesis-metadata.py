#!/usr/bin/env python3
"""Offline developer conversion of four pinned Libretro text files, never ROMs."""
import argparse,hashlib,json,re,os,uuid
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',type=Path,required=True,help='Directory containing source.json and the four pinned DAT files')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
source=args.source
meta=json.loads((source/'source.json').read_text())
assert re.fullmatch(r'[0-9a-f]{40}',meta['commit'])
records={};inputs=[]
for filename,field in [('publisher','publisher'),('releaseyear','releaseyear'),('releasemonth','releasemonth'),('maxusers','users')]:
    path=source/(filename+'.dat');raw=path.read_bytes();assert len(raw)<=4*1024*1024;text=raw.decode('utf-8')
    assert re.search(r'^\s*name "Sega - Mega Drive - Genesis"$',text,re.M)
    inputs.append({'path':f'metadat/{filename}/Sega - Mega Drive - Genesis.dat','sha256':hashlib.sha256(raw).hexdigest()})
    blocks=re.findall(r'^game \(\s*\n(.*?)^\)\s*$',text,re.M|re.S)
    assert len(blocks)>300
    for block in blocks:
        title=re.search(r'^\s*comment "((?:[^"\\]|\\.)*)"\s*$',block,re.M)
        crc=re.search(r'rom \( crc ([0-9A-Fa-f]{8}) \)',block)
        value=re.search(r'^\s*'+field+r' (?:"([^"\n]*)"|([0-9]+))\s*$',block,re.M)
        if not (title and crc and value):raise ValueError('Unparsed metadata block in '+filename)
        comment=title[1].replace('\\"','"').replace('\\\\','\\')
        key=(crc[1].upper(),comment);row=records.setdefault(key,{})
        v=value[1] if value[1] is not None else value[2]
        if field in row and row[field]!=v:raise ValueError('Conflicting exact variant field')
        row[field]=v
result=[]
for (crc,comment),fields in sorted(records.items()):
    title=comment.split(' (',1)[0].strip()
    groups=re.findall(r'\(([^)]*)\)',comment)
    regions=[g for g in groups if all(r.strip() in {'USA','Europe','Japan','World','Brazil','Korea','Taiwan','China','Australia','France','Germany','Spain','Italy','Sweden','Asia','Unknown','Canada','United Kingdom'} for r in g.split(','))]
    year=fields.get('releaseyear');month=fields.get('releasemonth')
    date=year if year and re.fullmatch(r'[12][0-9]{3}',year) else None
    if date and month and 1<=int(month)<=12:date+='-'+month.zfill(2)
    players=int(fields['users']) if fields.get('users','').isdigit() else None
    if players is not None and not 1<=players<=16:players=None
    result.append(dict(crc32=crc,title=title,region=regions[0] if len(regions)==1 else None,releaseDate=date,publisher=fields.get('publisher'),players=players))
value={'version':1,'platform':'genesis','license':'CC-BY-SA-4.0','sourceRepository':meta['repository'],'sourceCommit':meta['commit'],'inputs':inputs,'records':result}
out=args.output
sonic=[r for r in result if r['title']=='Sonic The Hedgehog' and r['crc32']=='F9394E97']
assert any(r['releaseDate']=='1991' and r['publisher']=='SEGA' and r['players']==1 for r in sonic),sonic
assert not out.is_symlink()
stage=out.with_name(out.name+'.tmp-'+uuid.uuid4().hex)
try:
    stage.write_text(json.dumps(value,ensure_ascii=False,separators=(',',':'))+'\n')
    os.replace(stage,out)
finally:
    if stage.exists():stage.unlink()
print('Genesis catalog:',len(result),'records;',out.stat().st_size,'bytes; verified Sonic CRC F9394E97 metadata.')
