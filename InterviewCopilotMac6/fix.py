import re
with open('speechmatics_engine.py', 'r', encoding='utf-8') as f:
    c = f.read()
# Fix all unicode issues
import unicodedata
result = []
for ch in c:
    if unicodedata.category(ch) in ('Pi', 'Pf') or ord(ch) in (0x2018, 0x2019, 0x201c, 0x201d, 0x2013, 0x2014, 0x2026):
        if ord(ch) in (0x2018, 0x2019):
            result.append("'")
        elif ord(ch) in (0x201c, 0x201d):
            result.append('"')
        elif ord(ch) in (0x2013, 0x2014):
            result.append('-')
        elif ord(ch) == 0x2026:
            result.append('...')
    else:
        result.append(ch)
c = ''.join(result)
# Fix dunder names
c = c.replace('**version**', '__version__')
c = c.replace('**file**', '__file__')
c = c.replace('**name**', '__name__')
c = c.replace('**main**', '__main__')
# Fix dashes in argparse
c = c.replace('\u2013key', '--key')
c = c.replace('\u2013device', '--device')
c = c.replace('\u2013sysdevice', '--sysdevice')
c = c.replace('\u2013max-delay', '--max-delay')
c = c.replace('\u2013mode', '--mode')
c = c.replace('\u2013syscapture', '--syscapture')
with open('speechmatics_engine.py', 'w', encoding='utf-8') as f:
    f.write(c)
print('Fixed!')
