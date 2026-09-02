#!/bin/bash
cd "$HOME/agriasic_regression/sim_build"
source "$HOME/rv-venv/bin/activate"
python - <<'PY'
import xml.etree.ElementTree as ET
t = ET.parse('results.xml'); r = t.getroot()
passed, failed = [], []
for tc in r.iter('testcase'):
    name = tc.get('name')
    fails = tc.findall('failure')
    if fails:
        msg = (fails[0].get('message') or '').strip().replace('\n',' ')[:150]
        failed.append((name, msg))
    else:
        passed.append(name)
print(f"PASSED ({len(passed)}):")
for n in passed: print("   ", n)
print(f"\nFAILED ({len(failed)}):")
for n,m in failed[:20]: print(f"    {n}\n        {m}")
print(f"\n... showing first 20 of {len(failed)} failures")
PY
