"""Isolated bounded-writer test: no console, network, disks, host shares or Nintendo code."""
if not __debug__:
    raise SystemExit("Verification requires Python assertions enabled")
from pathlib import Path
import argparse,hashlib,struct,subprocess,json
p=argparse.ArgumentParser()
for name in ['kernel','busybox','helper','tracer','qemu','output']:p.add_argument('--'+name,required=True,type=Path)
p.add_argument('--upload-command',type=Path)
a=p.parse_args();a.output.mkdir(exist_ok=True)
assert hashlib.sha256(a.kernel.read_bytes()).hexdigest()=='b508abca3127cb0d9e1b3aba37f400cbd7dac170040641756807e0e496039de8'
assert hashlib.sha256(a.busybox.read_bytes()).hexdigest()=='440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6'
init=b'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
printf 'ARM_WRITER_TEST_BEGIN\\n'
printf 'UNCHANGED' > /dev/nanda
/probe/test-linux-arm /probe/bounded-nand-write
result=$?
if test "$result" = 0 && test "$("$B" cat /dev/nanda)" = UNCHANGED; then
  echo ARM_WRITER_TEST_SUCCESS
else echo ARM_WRITER_TEST_FAILED:$result; fi
"$B" poweroff -f
'''
files={'init':(0o100755,init),'probe/busybox':(0o100755,a.busybox.read_bytes()),'bin/sh':(0o120777,b'../probe/busybox'),
 'probe/bounded-nand-write':(0o100755,a.helper.read_bytes()),'probe/test-linux-arm':(0o100755,a.tracer.read_bytes())}
if a.upload_command:
 script=a.upload_command.read_text()
 import re
 paths=re.findall(r"'(/tmp/swifthakchi-[^']+)'",script)
 assert len(paths)==1 and script.count(paths[0])==1
 files['probe/upload.sh']=(0o100700,script.replace(paths[0],'/tmp/swifthakchi-upload-test/writer').encode())
 files['bin/busybox']=(0o120777,b'../probe/busybox')
 checks=b'''"$B" mkdir /tmp/swifthakchi-upload-test
P=/tmp/swifthakchi-upload-test/writer
printf 'old' > "$P"
if printf new | "$B" sh /probe/upload.sh; then echo UPLOAD_FAILURE; fi
test "$("$B" cat "$P")" = old || echo UPLOAD_FAILURE
"$B" rm "$P"
printf old > /tmp/original
"$B" ln -s /tmp/original "$P"
if printf new | "$B" sh /probe/upload.sh; then echo UPLOAD_FAILURE; fi
test "$("$B" cat /tmp/original)" = old || echo UPLOAD_FAILURE
"$B" rm "$P"
"$B" ln -s /tmp/absent "$P"
if printf new | "$B" sh /probe/upload.sh; then echo UPLOAD_FAILURE; fi
test ! -e /tmp/absent || echo UPLOAD_FAILURE
"$B" rm "$P"
printf new | "$B" sh /probe/upload.sh || echo UPLOAD_FAILURE
test "$("$B" cat "$P")" = new || echo UPLOAD_FAILURE
if printf replacement | "$B" sh /probe/upload.sh; then echo UPLOAD_FAILURE; fi
test "$("$B" cat "$P")" = new || echo UPLOAD_FAILURE
echo ARM_EXCLUSIVE_UPLOADS_PASSED
'''
 mode,data=files['init'];files['init']=(mode,data.replace(b'"$B" poweroff -f',checks+b'"$B" poweroff -f'))
dirs=['.','bin','dev','proc','tmp','probe'];archive=bytearray()
entries=[(n,0o40755,b'') for n in dirs]+[(n,m,d) for n,(m,d) in files.items()]+[('TRAILER!!!',0,b'')]
for inode,(name,mode,data) in enumerate(entries,1):
 name=name.encode()+b'\0';fields=[inode,mode,0,0,2 if mode&0xf000==0x4000 else 1,0,len(data),0,0,0,0,len(name),0]
 archive+=b'070701'+b''.join(('%08x'%v).encode() for v in fields)+name
 archive+=b'\0'*((-len(archive))%4)+data;archive+=b'\0'*((-len(archive))%4)
archive+=b'\0'*((-len(archive))%512);(a.output/'test.cpio').write_bytes(archive)
cmd=[str(a.qemu),'-M','virt','-cpu','cortex-a15','-m','192M','-accel','tcg','-display','none','-monitor','none',
 '-serial','stdio','-nic','none','-no-reboot','-kernel',str(a.kernel),'-initrd',str(a.output/'test.cpio'),'-append','console=ttyAMA0 rdinit=/init panic=1']
try:
 with (a.output/'guest.log').open('wb') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=180)
except subprocess.TimeoutExpired:raise SystemExit('ARM synthetic test timed out; inspect guest.log')
raw=(a.output/'guest.log').read_bytes();assert len(raw)<262144
assert r.returncode==0 and b'ARM_WRITER_TEST_SUCCESS' in raw and b'ARM_WRITER_ALL_CASES_PASSED' in raw and raw.count(b'ARM_WRITER_CASE_OK:')==31
assert b'ARM_WRITER_TEST_FAILED' not in raw
if a.upload_command:assert b'ARM_EXCLUSIVE_UPLOADS_PASSED' in raw and b'UPLOAD_FAILURE' not in raw
print(json.dumps({'exclusiveUploadCases':5 if a.upload_command else 0,'passed':True,'cases':31,'helperSHA256':hashlib.sha256(a.helper.read_bytes()).hexdigest(),
 'scope':'isolated-synthetic-Linux-ARM','actualELFExecuted':True,'NANDIoctlsIntercepted':True,
 'fullActivePreimageBeforeWrite':True,'exactSyntheticReplacement':True,'outOfRangeRefusedBeforeOpen':True,'badBlockAndOutputErrorsStop':True,
 'syntheticWriteIoctlsOnly':True,'consoleAccessed':False,'firmwareEligible':False},indent=2))
