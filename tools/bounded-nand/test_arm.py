"""Isolated ARM Linux test: no console, network, disks, host shares or Nintendo code."""
if not __debug__:
    raise SystemExit("Verification requires Python assertions enabled")
from pathlib import Path
import argparse,hashlib,struct,subprocess,json
p=argparse.ArgumentParser()
for name in ['kernel','busybox','helper','tracer','qemu','output']:p.add_argument('--'+name,required=True,type=Path)
a=p.parse_args();a.output.mkdir(exist_ok=True)
assert hashlib.sha256(a.kernel.read_bytes()).hexdigest()=='b508abca3127cb0d9e1b3aba37f400cbd7dac170040641756807e0e496039de8'
assert hashlib.sha256(a.busybox.read_bytes()).hexdigest()=='440b72b46c50939356768f35ea02b682176ca49ef07b3702ee75912af74aabd6'
init=b'''#!/bin/sh
B=/probe/busybox
"$B" mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
"$B" mount -t proc proc /proc
printf 'ARM_HELPER_TEST_BEGIN\\n'
printf 'UNCHANGED' > /dev/nanda
/probe/test-linux-arm /probe/bounded-nand-read
result=$?
if test "$result" = 0 && test "$("$B" cat /dev/nanda)" = UNCHANGED; then
  echo ARM_HELPER_TEST_SUCCESS
else echo ARM_HELPER_TEST_FAILED:$result; fi
"$B" poweroff -f
'''
files={'init':(0o100755,init),'probe/busybox':(0o100755,a.busybox.read_bytes()),'bin/sh':(0o120777,b'../probe/busybox'),
 'probe/bounded-nand-read':(0o100755,a.helper.read_bytes()),'probe/test-linux-arm':(0o100755,a.tracer.read_bytes())}
dirs=['.','bin','dev','proc','tmp','probe'];archive=bytearray()
entries=[(n,0o40755,b'') for n in dirs]+[(n,m,d) for n,(m,d) in files.items()]+[('TRAILER!!!',0,b'')]
for inode,(name,mode,data) in enumerate(entries,1):
 name=name.encode()+b'\0';fields=[inode,mode,0,0,2 if mode&0xf000==0x4000 else 1,0,len(data),0,0,0,0,len(name),0]
 archive+=b'070701'+b''.join(('%08x'%v).encode() for v in fields)+name
 archive+=b'\0'*((-len(archive))%4)+data;archive+=b'\0'*((-len(archive))%4)
archive+=b'\0'*((-len(archive))%512);(a.output/'test.cpio').write_bytes(archive)
cmd=[str(a.qemu),'-M','virt','-cpu','cortex-a15','-m','128M','-accel','tcg','-display','none','-monitor','none',
 '-serial','stdio','-nic','none','-no-reboot','-kernel',str(a.kernel),'-initrd',str(a.output/'test.cpio'),'-append','console=ttyAMA0 rdinit=/init panic=1']
try:
 with (a.output/'guest.log').open('wb') as log:r=subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,timeout=90)
except subprocess.TimeoutExpired:raise SystemExit('ARM synthetic test timed out; inspect guest.log')
raw=(a.output/'guest.log').read_bytes();assert len(raw)<262144
assert r.returncode==0 and b'ARM_HELPER_TEST_SUCCESS' in raw and b'ARM_HELPER_ALL_CASES_PASSED' in raw and raw.count(b'ARM_HELPER_CASE_OK:')==20
assert b'ARM_HELPER_TEST_FAILED' not in raw
print(json.dumps({'passed':True,'cases':20,'helperSHA256':hashlib.sha256(a.helper.read_bytes()).hexdigest(),
 'scope':'isolated-synthetic-Linux-ARM','actualELFExecuted':True,'NANDIoctlsIntercepted':True,
 'fullActiveRangeRead':True,'outOfRangeRefusedBeforeOpen':True,'badBlockAndOutputErrorsStop':True,
 'writeIoctlsAllowed':False,'consoleAccessed':False,'firmwareEligible':False},indent=2))
