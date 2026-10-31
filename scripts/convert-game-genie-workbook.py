#!/usr/bin/env python3
"""Read the supplied Game Genie workbook layout; emit local NES catalog JSON.

No Excel execution, macros, external links, network, extraction or app runtime dependency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import os
import xml.etree.ElementTree as ET
import zipfile

LIMIT = 32 * 1024 * 1024

def convert(path):
    path = Path(path)
    if path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError('Workbook is larger than 8 MiB')
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 200 or len({e.filename for e in entries}) != len(entries) or sum(e.file_size for e in entries) > LIMIT:
            raise ValueError('Unsupported workbook archive size or duplicate entries')
        def xml(name):
            if name not in archive.namelist():raise ValueError('Missing workbook part: '+name)
            with archive.open(name) as stream:data=stream.read(LIMIT+1)
            if len(data)>LIMIT or b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():raise ValueError('Unsupported XML declarations or size')
            return ET.fromstring(data)
        def local(tag):return tag.rsplit('}',1)[-1]
        workbook=xml('xl/workbook.xml')
        sheets=[node for node in workbook.iter() if local(node.tag)=='sheet' and node.attrib.get('name')=='NES']
        if len(sheets)!=1:raise ValueError('Expected one sheet named NES')
        rid=next((v for k,v in sheets[0].attrib.items() if local(k)=='id'),None)
        links=xml('xl/_rels/workbook.xml.rels')
        targets=[n.attrib.get('Target','') for n in links if n.attrib.get('Id')==rid and n.attrib.get('TargetMode')!='External']
        if len(targets)!=1:raise ValueError('Missing NES worksheet relationship')
        target=targets[0]
        if not re.fullmatch(r'worksheets/[^/]+\.xml',target):raise ValueError('Unsupported worksheet path')
        strings=[]
        if 'xl/sharedStrings.xml' in archive.namelist():
            strings=[''.join(n.text or '' for n in node.iter() if local(n.tag)=='t') for node in xml('xl/sharedStrings.xml') if local(node.tag)=='si']
        output=[];header=None
        for row in xml('xl/'+target).iter():
            if local(row.tag)!='row':continue
            number=int(row.attrib['r']);cells={}
            if number>100000:raise ValueError('Unsupported row number')
            for cell in row:
                if local(cell.tag)!='c':continue
                ref=cell.attrib.get('r','');match=re.fullmatch(r'([A-Z]+)([0-9]+)',ref)
                if not match:raise ValueError('Invalid cell reference')
                col=match.group(1)
                if col not in 'ABCDEF' or len(col)!=1:continue
                if any(local(n.tag)=='f' for n in cell):raise ValueError('Formulas are not accepted in catalog cells')
                kind=cell.attrib.get('t','')
                value=next((n.text or '' for n in cell if local(n.tag)=='v'),'')
                if kind=='s':value=strings[int(value)]
                elif kind=='inlineStr':value=''.join(n.text or '' for n in cell.iter() if local(n.tag)=='t')
                elif kind=='e':raise ValueError('Cell contains an Excel error')
                cells[col]=value
            if number==3:header=cells;continue
            if number<4 or not any(cells.values()):continue
            game=cells.get('A','').strip()
            if not game:raise ValueError('Missing game title on NES row'+str(number))
            record={'row':number,'game':game,'rawCodes':cells.get('C','')}
            for col,key in [('B','number'),('D','effect'),('E','source'),('F','originalOrder')]:
                if cells.get(col,'')!='':record[key]=cells[col]
            output.append(record)
        if not header or header.get('A')!='Game' or not header.get('C','').startswith('Key in') or not header.get('D','').startswith('Effect'):
            raise ValueError('Unexpected NES catalog headers')
        # Enforce the app schema before a command can replace an existing local catalog.
        if len(output)>20000 or len(path.name)>256:raise ValueError('Catalog exceeds supported row or filename limits')
        seen=set()
        for record in output:
            row=record['row']
            if row in seen:raise ValueError('Duplicate NES row'+str(row))
            seen.add(row)
            for key,limit in [('game',256),('number',64),('rawCodes',8192),('effect',512),('source',8192)]:
                if len(record.get(key,''))>limit:raise ValueError('NES row'+str(row)+': '+key+' exceeds '+str(limit)+' characters')
        return {'version':1,'system':'nes','workbookSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'workbookName':path.name,'rows':output}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workbook',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();catalog=convert(args.workbook)
    data=json.dumps(catalog,ensure_ascii=False,indent=2).encode()
    if len(data)>8*1024*1024:raise ValueError('Catalog exceeds app import limit')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    # Explicit output only; never overwrite the workbook.
    if args.output.resolve()==args.workbook.resolve():raise ValueError('Output must differ from workbook')
    descriptor,temp=tempfile.mkstemp(dir=args.output.parent,prefix='.catalog-',suffix='.json')
    try:
        with os.fdopen(descriptor,'wb') as stream:stream.write(data)
        os.replace(temp,args.output)
    finally:
        if os.path.exists(temp):os.unlink(temp)
    print('Catalog rows:',len(catalog['rows']),'→',args.output)

if __name__=='__main__':main()
