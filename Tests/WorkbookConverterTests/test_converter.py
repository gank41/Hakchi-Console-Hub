import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/convert-game-genie-workbook.py'

class WorkbookConverterTests(unittest.TestCase):
    def convert(self, formula=False, effect="Multi effect", duplicate=False):
        spec = importlib.util.spec_from_file_location('converter', SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'synthetic.xlsx'
            with zipfile.ZipFile(p,'w') as z:
                z.writestr('xl/workbook.xml','<workbook xmlns:r="r"><sheets><sheet name="NES" r:id="rId1"/></sheets></workbook>')
                z.writestr('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
                z.writestr('xl/sharedStrings.xml','<sst><si><t>Test Game</t></si><si><r><t>'+effect+'</t></r></si></sst>')
                z.writestr('xl/worksheets/sheet1.xml','''<worksheet><sheetData><row r="3"><c r="A3" t="inlineStr"><is><t>Game</t></is></c><c r="C3" t="inlineStr"><is><t>Key in…</t></is></c><c r="D3" t="inlineStr"><is><t>Effect…</t></is></c></row><row r="4"><c r="A4" t="s"><v>0</v></c><c r="B4"><v>1</v></c><c r="C4" t="inlineStr"><is><t>SXIOPO + GZUXNGEI</t></is></c><c r="D4" t="s">'''+('<f>BAD()</f>' if formula else '')+'''<v>1</v></c></row><row r="'''+('4' if duplicate else '5')+'''"><c r="A5" t="s"><v>0</v></c><c r="C5" t="inlineStr"><is><t>Note line 1&#10;Note line 2</t></is></c></row></sheetData></worksheet>''')
            return module.convert(p)
    def test_groups_notes_and_source_rows_preserved(self):
        result=self.convert()
        self.assertEqual(result['rows'][0]['rawCodes'],'SXIOPO + GZUXNGEI')
        self.assertEqual(result['rows'][0]['effect'],'Multi effect')
        self.assertEqual(result['rows'][1]['rawCodes'],'Note line 1\nNote line 2')
        self.assertNotIn('effect',result['rows'][1])
        self.assertEqual([r['row'] for r in result['rows']],[4,5])
    def test_formulas_are_rejected_instead_of_using_cached_text(self):
        with self.assertRaises(ValueError):self.convert(formula=True)

    def test_oversized_effect_and_duplicate_row_ids_are_rejected(self):
        with self.assertRaises(ValueError):self.convert(effect='X'*513)
        with self.assertRaises(ValueError):self.convert(duplicate=True)

if __name__=='__main__':unittest.main()
