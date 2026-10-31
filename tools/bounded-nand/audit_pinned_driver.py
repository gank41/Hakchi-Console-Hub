"""Inert, narrowly pinned ARM module inspection; never loads or executes the module.

This checks the instruction sites documented in docs/SNES-PHYSICAL-IO-AUDIT-2026-10-22.md.
It does not prove arbitrary driver builds equivalent or grant permission to write.
"""
import argparse
import hashlib
import json
if not __debug__:
    raise SystemExit("Verification requires Python assertions enabled")
from pathlib import Path
import struct

PIN = '5d67ca0977370a04f46edbf1c02aa1dcbb2fc964781775d906125c40eb7d29d5'

def audit(path):
    b = path.read_bytes()
    assert len(b) == 377076 and hashlib.sha256(b).hexdigest() == PIN, 'Unsupported NAND driver'
    assert b[:7] == b'\x7fELF\x01\x01\x01'
    u16 = lambda at: struct.unpack_from('<H', b, at)[0]
    u32 = lambda at: struct.unpack_from('<I', b, at)[0]
    assert u16(16) == 1 and u16(18) == 40 and u16(46) == 40
    at, count, names_index = u32(32), u16(48), u16(50)
    assert 0 < names_index < count <= 512 and at + count*40 <= len(b)
    sections = [struct.unpack_from('<10I', b, at+i*40) for i in range(count)]
    def contents(s):
        offset, size = s[4:6]
        assert offset <= len(b) and size <= len(b)-offset
        return b[offset:offset+size]
    def string(table, offset):
        assert offset < len(table)
        end = table.index(0, offset)
        return table[offset:end].decode('ascii')
    names = contents(sections[names_index])
    named = {string(names, s[0]): s for s in sections}
    text = contents(named['.text'])
    sym_section = named['.symtab']; assert sym_section[9] == 16
    symbols = contents(sym_section); strings = contents(sections[sym_section[6]])
    sym_names = [string(strings, struct.unpack_from('<I', symbols, i)[0]) for i in range(0, len(symbols), 16)]
    rels = contents(named['.rel.text']); assert len(rels) % 8 == 0
    relocation = {offset: sym_names[info >> 8] for offset, info in struct.iter_unpack('<II', rels)}
    def instruction(at, hex_bytes):
        assert text[at:at+4] == bytes.fromhex(hex_bytes), 'Instruction mismatch at '+hex(at)
    def branch(at, target):
        op = struct.unpack_from('<I', text, at)[0]
        assert (op >> 25) & 7 == 5
        signed = op & 0xffffff
        if signed & 0x800000: signed -= 0x1000000
        assert at + 8 + signed*4 == target
    def call(at, name):
        assert relocation[at] == name
    # Physical read: parameter raw&3, output flags reset, OOB byte1 sets bit0.
    for at, raw in [(0x1c8c,'0c70d3e5'),(0x1c9c,'033007e2'),(0x1d80,'3120dde5'),
                    (0x1d90,'01208213'),(0x1d9c,'010052e3'),(0x1dc0,'000053e3'),
                    (0x1dc4,'01404402'),(0x1ddc,'014084e2'),(0x1de0,'016086e2')]: instruction(at, raw)
    call(0x1d38, 'PHY_SimpleRead')
    read_calls = [name for at, name in relocation.items() if 0x1c80 <= at < 0x1df4]
    assert set(read_calls) == {'NAND_GetPageSize','NAND_GetPageCntPerBlk','NAND_GetBlkCntPerChip','memset','PHY_SimpleRead','printk'}
    # ioctl dispatch routes read/write to separate exact functions.
    branch(0x2964, 0x1c80); branch(0x2a8c, 0x2364)
    # Physical write raw1 does not retry on the next block after erase/program failure.
    call(0x23e4, 'PHY_SimpleErase'); call(0x246c, 'PHY_SimpleWrite')
    call(0x2420, 'mark_bad_block'); call(0x24b8, 'mark_bad_block')
    for at, raw in [(0x2388,'037007e2'),(0x2428,'000057e3'),(0x24a8,'010057e3'),
                    (0x24c0,'000057e3'),(0x24c8,'01404402'),(0x24e4,'014084e2'),(0x24e8,'016086e2')]: instruction(at, raw)
    branch(0x2434, 0x24e4); branch(0x24d0, 0x24e4)
    return {'verified':True,'scope':'pinned-driver-inert-instruction-audit','moduleSHA256':PIN,
            'readEntryTextOffset':'0x1c80','writeEntryTextOffset':'0x2364','readOutputKnownFlagMask':1,
            'raw1RetriesDataOnNextBlock':False,'writeFailuresMayMarkCurrentBlockBad':True,
            'moduleExecuted':False,'consoleAccessed':False,'firmwareEligible':False}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('module',type=Path)
    print(json.dumps(audit(parser.parse_args().module),indent=2))
