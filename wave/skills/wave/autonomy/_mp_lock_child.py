import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from daily_cap import RunLock
ok, reason = RunLock(Path(sys.argv[1])).acquire('child')
print('OK' if ok else 'HELD')
print(reason)
