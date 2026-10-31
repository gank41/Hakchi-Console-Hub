"""Inert ELF validation for the freestanding read-only helper, never executes it."""
if not __debug__:
    raise SystemExit("Verification requires Python assertions enabled")
from pathlib import Path
import hashlib,struct,sys,json

def verify(path):
 data=path.read_bytes();assert 256<len(data)<128*1024
 assert data[:7]==b'\x7fELF\x01\x01\x01'
 kind,machine,version,entry,phoff,shoff,flags,ehsize,phsize,phnum=struct.unpack_from('<HHIIIIIHHH',data,16)
 assert (kind,machine,version,ehsize,phsize)==(2,40,1,52,32)
 assert flags&0xff000000==0x05000000 and 1<=phnum<=12 and phoff+phnum*phsize<=len(data)
 found_entry=False;loads=0;stack=False
 for n in range(phnum):
  ptype,offset,addr,paddr,filesz,memsz,perm,align=struct.unpack_from('<8I',data,phoff+n*phsize)
  assert ptype not in [2,3] # No dynamic segment or runtime interpreter.
  if ptype==1:
   loads+=1;assert filesz<=memsz and offset+filesz<=len(data)
   assert perm&3!=3 # No writable executable segment.
   assert memsz<512*1024
   if addr<=entry<addr+filesz and perm&1:found_entry=True
  if ptype==0x6474e551:stack=True;assert not perm&1
 assert 1<=loads<=4 and found_entry and stack
 assert b'/dev/nanda\0' in data and b'read-active\0' in data
 return {'verified':True,'path':str(path),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'machine':'ARM EABI5','static':True,'executableEntryInRXSegment':True,'writeExecuteSegments':False,'firmwareEligible':False,'hardwareTested':False}
if __name__=='__main__':
 assert len(sys.argv)==2
 print(json.dumps(verify(Path(sys.argv[1])),indent=2))
