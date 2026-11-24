#!/usr/bin/env python3
"""Operate the isolated VM UI through the documented application scripting API."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).absolute().parent

def main():
    spec = importlib.util.spec_from_file_location('guest_control', HERE / 'b2-guest-control.py')
    control = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control)
    control.initialize()
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['capture', 'keys'])
    parser.add_argument('values', nargs='*')
    parser.add_argument('--firmware', action='store_true')
    args = parser.parse_args()
    try:
        if args.operation == 'keys':
            codes = [int(value) for value in args.values]
            if not codes or any(code < 0 or code > 255 for code in codes):
                raise ValueError('The scan code sequence is invalid.')
            script = '''on run argv
                set scanValues to {}
                repeat with i from 2 to count argv
                    set end of scanValues to (item i of argv) as integer
                end repeat
                tell application id "com.utmapp.UTM"
                    input scan code (virtual machine id (item 1 of argv)) codes scanValues
                end tell
            end run'''
            operation = 'observed-firmware-ui-input' if args.firmware else 'observed-guest-ui-input'
            control.record_operation(operation, 'started')
            result = subprocess.run(['osascript', '-e', script, '--', control.VM_ID, *map(str, codes)], capture_output=True, text=True, timeout=20)
            control.record_operation(operation, 'ended', {'exit_code': result.returncode})
            print(control.redact(json.dumps({'exit_code': result.returncode, 'error': result.stderr})))
            return result.returncode
        tag = args.values[0] if args.values else 'guest-screen'
        if not re.fullmatch(r'[a-z0-9-]{1,48}', tag):
            raise ValueError('The public screen alias is invalid.')
        if not args.firmware:
            private = control.powershell('[pscustomobject]@{a=$env:COMPUTERNAME;b=(Get-CimInstance Win32_ComputerSystem).UserName} | ConvertTo-Json -Compress', 10, label='resolve-private-screen-redaction-tokens')
            if private.get('exit_code') != 0:
                raise RuntimeError('Guest privacy token preparation failed; screen export is blocked.')
            if private.get('exit_code') == 0:
                guest_values = list(json.loads(private['stdout']).values())
                for value in guest_values:
                    if value:
                        control.PRIVATE_TOKENS.update(str(value).split(chr(92)))
        raw = Path(tempfile.gettempdir()) / 'b2-raw-guest-screen.png'
        script = '''on run argv
            tell application id "com.utmapp.UTM"
                capture screen (virtual machine id (item 1 of argv)) to (POSIX file (item 2 of argv))
            end tell
        end run'''
        result = subprocess.run(['osascript', '-e', script, '--', control.VM_ID, str(raw)], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError(control.redact(result.stderr))
        from PIL import Image
        with Image.open(raw) as captured:
            captured.convert('RGB').save(raw, format='PNG')
        recognizer = HERE / ('b2-screen-ocr.swift' if args.firmware else 'b2-screen-ocr-cn.swift')
        ocr = subprocess.run(['swift', str(recognizer), str(raw)], capture_output=True, text=True, timeout=60)
        if ocr.returncode:
            raise RuntimeError('Local screen privacy recognition failed: ' + control.redact(ocr.stderr.strip()))
        rows = json.loads(ocr.stdout)
        from PIL import Image, ImageDraw
        with Image.open(raw) as original:
            image = original.convert('RGB')
        draw = ImageDraw.Draw(image)
        width, height = image.size
        safe_rows = []
        for row in rows:
            safe = control.redact(row['text'])
            compact = re.sub(r'[^a-z0-9]', '', row['text'].lower())
            sensitive_fuzzy = any(len(token) > 3 and re.sub(r'[^a-z0-9]', '', token.lower()) in compact for token in control.PRIVATE_TOKENS if token.isascii())
            if re.search(r'(?i)[a-z]\s*:[\\/]', row['text']): sensitive_fuzzy = True
            if re.search(r'(?<![\w])\d{6,}(?![\w])', row['text']): sensitive_fuzzy = True
            if '[private-' in row['text']: sensitive_fuzzy = True
            if any(marker in row['text'] for marker in ['[guest-path]', '[private-path]', '[email]', '[identifier]', '[private]']): sensitive_fuzzy = True
            if sensitive_fuzzy: safe = '[private-text-redacted]'
            if safe != row['text']:
                x = int(row['x'] * width)
                y = int((1 - row['y'] - row['height']) * height)
                right = int((row['x'] + row['width']) * width)
                bottom = int((1 - row['y']) * height)
                draw.rectangle((max(0,x-8),max(0,y-6),min(width,right+8),min(height,bottom+6)), fill='#202020')
            safe_rows.append({**row, 'text': safe})
        image.save(HERE / ('b2-' + tag + '.png'))
        image.save(Path('/tmp') / 'b2-guest-screen.png')
        raw.unlink(missing_ok=True)
        print(control.redact(json.dumps({'artifact_alias': 'b2-'+tag+'.png','image_size':[width,height],'screen_text':safe_rows}, ensure_ascii=False)))
        return 0
    except Exception as error:
        if 'raw' in locals():
            raw.unlink(missing_ok=True)
        print(control.redact(json.dumps({'status':'failed','error':str(error)}, ensure_ascii=False)))
        return 1

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        print('{"status":"failed","error":"Private UI discovery failed safely."}')
        raise SystemExit(1)
