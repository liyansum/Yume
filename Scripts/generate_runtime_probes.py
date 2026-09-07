#!/usr/bin/env python3
"""Generate Yume-owned diagnostic projects, with no commercial engine assets.

These exercise host integration; they are not a game compatibility matrix.
Requires only Python 3. The destination must not already exist.
"""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import wave
import zipfile
import zlib


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def bars_png():
    colors = [(240, 40, 40), (40, 220, 70), (40, 80, 240), (245, 220, 30)]
    rows = bytearray()
    for y in range(480):
        rows.append(0)
        for x in range(640):
            color = colors[(y // 240) * 2 + x // 320]
            rows.extend((255, 255, 255) if x < 8 or y < 8 else color)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 480, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def tone_wav():
    out = io.BytesIO()
    with wave.open(out, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(22050)
        # A quiet half-second tone followed by silence, repeated by each engine.
        pcm = [int(1800 * math.sin(2 * math.pi * 440 * i / 22050)) if i < 11025 else 0 for i in range(22050)]
        audio.writeframes(struct.pack('<' + 'h' * len(pcm), *pcm))
    return out.getvalue()


def marshal_size(value):
    if value == 0:
        return b'\0'
    if value < 123:
        return bytes([value + 5])
    payload = value.to_bytes((value.bit_length() + 7) // 8, 'little')
    return bytes([len(payload)]) + payload


def marshal(value):
    # Ruby Marshal 4.8's common Ruby 1.8/1.9 binary string representation.
    if isinstance(value, list):
        return b'[' + marshal_size(len(value)) + b''.join(marshal(v) for v in value)
    if isinstance(value, int):
        return b'i' + marshal_size(value)
    return b'"' + marshal_size(len(value)) + value


RGSS = '''# Yume-owned RGSS 1/2/3 diagnostic. No RPG Maker standard scripts or RTP.
Graphics.frame_rate = 30
w = Graphics.respond_to?(:width) ? Graphics.width : 640
h = Graphics.respond_to?(:height) ? Graphics.height : 480
sprite = Sprite.new
sprite.bitmap = Bitmap.new(w, h)
x = 40
y = h / 2
count = 0
save_file = System.data_directory + "yume-probe.txt"
if File.exist?(save_file)
  count = File.read(save_file).to_i
end
Audio.bgm_play("tone.wav", 30, 100)
loop do
  Input.update
  x -= 4 if Input.press?(Input::LEFT)
  x += 4 if Input.press?(Input::RIGHT)
  y -= 4 if Input.press?(Input::UP)
  y += 4 if Input.press?(Input::DOWN)
  x = [[x, 0].max, w - 32].min
  y = [[y, 80].max, h - 32].min
  if Input.trigger?(Input::C)
    count += 1
    File.open(save_file, "wb") { |file| file.write(count.to_s) }
  end
  break if Input.trigger?(Input::B)
  sprite.bitmap.fill_rect(0, 0, w, h, Color.new(25, 40, 70))
  sprite.bitmap.fill_rect(x, y, 32, 32, Color.new(40, 230, 90))
  sprite.bitmap.draw_text(8, 8, w-16, 32, "Yume RGSS probe: hold arrows; Z saves; X exits")
  sprite.bitmap.draw_text(8, 40, w-16, 32, "Saved count: " + count.to_s)
  Graphics.update
end
Audio.bgm_stop
sprite.bitmap.dispose
sprite.dispose
'''

RENPY = '''# Yume-owned diagnostic; runs without project-specific GUI assets.
define config.name = "Yume RenPy GENERATION probe"
define config.screen_width = 640
define config.screen_height = 480
image yume_bars = "bars.png"
label main_menu:
    jump start
label start:
    scene yume_bars
    play music "tone.wav"
    $ persistent.yume_probe_starts = (persistent.yume_probe_starts or 0) + 1
    $ renpy.save_persistent()
    "Yume RenPy GENERATION probe. Red/green above blue/yellow. White edges at top and left."
    "Persistent launch count: [persistent.yume_probe_starts]. Tap to continue."
    menu:
        "Save test slot":
            $ renpy.save("yume-probe")
            "Saved slot yume-probe."
        "Load test slot":
            $ renpy.load("yume-probe")
        "Continue":
            pass
    "Host rendering, tap and audio reached this point. Close with the Yume button."
    $ renpy.pause(hard=True)
'''

KIRIKIRI = '''// Yume-owned native TJS/Layer diagnostic; no KAG scripts or plugins.
class ProbeLayer extends Layer {
    function ProbeLayer(owner) {
        super.Layer(owner, null);
        loadImages("bars.png");
        setSize(640, 480);
        visible = true;
    }
    function onMouseDown(x, y, button, shift) {
        fillRect(x - 12, y - 12, 24, 24, 0xffffff);
        Debug.message("yume.probe.pointer-down " + x + "," + y);
    }
    function onMouseMove(x, y, shift) {
        fillRect(x - 3, y - 3, 6, 6, 0xffffff);
    }
}
class ProbeWindow extends Window {
    var plane;
    function ProbeWindow() {
        super.Window();
        caption = "Yume Kirikiri probe";
        setInnerSize(640, 480);
        plane = new ProbeLayer(this);
        visible = true;
    }
}
var yumeProbe = new ProbeWindow();
Debug.message("yume.probe.window-created");
'''

WEB = '''<!doctype html><html><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no"><style>body{margin:0;background:#17233a;color:white;font:18px sans-serif}canvas{width:100%;max-height:70vh;object-fit:contain}button{font:inherit;padding:12px}</style><body><p>Yume Web host probe (routed through Tyrano; no Tyrano/MV/MZ engine included)</p><canvas width="640" height="480" tabindex="0"></canvas><button id="save">Save counter</button><span id="count"></span><script src="tyrano/tyrano.js"></script></body></html>'''
WEB_SCRIPT = '''// Yume-owned host probe, not a Tyrano implementation.
const canvas=document.querySelector('canvas'),ctx=canvas.getContext('2d'),held=new Set();
let x=50,y=200,count=Number(localStorage.getItem('yume-probe')||0);
const label=document.getElementById('count');label.textContent='Saved: '+count;
document.getElementById('save').onclick=()=>{localStorage.setItem('yume-probe',String(++count));label.textContent='Saved: '+count};
window.addEventListener('keydown',e=>held.add(e.keyCode));window.addEventListener('keyup',e=>held.delete(e.keyCode));
canvas.addEventListener('pointerdown',e=>{const r=canvas.getBoundingClientRect();x=(e.clientX-r.left)*640/r.width;y=(e.clientY-r.top)*480/r.height});
function draw(){x+=((held.has(39)?1:0)-(held.has(37)?1:0))*4;y+=((held.has(40)?1:0)-(held.has(38)?1:0))*4;
x=Math.max(0,Math.min(608,x));y=Math.max(0,Math.min(448,y));ctx.fillStyle='#20304a';ctx.fillRect(0,0,640,480);ctx.fillStyle='#38e575';ctx.fillRect(x,y,32,32);requestAnimationFrame(draw)}draw();
console.info('yume.probe.web-started');
'''


def flash_movie():
    # SWF6: two one-second frames, colored background and AVM1 trace actions.
    bits = '10000' + ''.join(format(v & 65535, '016b') for v in (0, 12800, 0, 9600))
    bits += '0' * (-len(bits) % 8)
    body = int(bits, 2).to_bytes(len(bits) // 8, 'big') + struct.pack('<HH', 256, 2)
    def tag(code, payload=b''):
        if len(payload) < 63:
            return struct.pack('<H', code * 64 + len(payload)) + payload
        return struct.pack('<HI', code * 64 + 63, len(payload)) + payload
    for color, name in ((b'\xf0\x28\x28', b'red'), (b'\x28\x50\xf0', b'blue')):
        text = b'\0Yume Flash probe: ' + name + b'\0'
        action = b'\x96' + struct.pack('<H', len(text)) + text + b'\x26\0'
        body += tag(9, color) + tag(12, action) + tag(1)
    body += tag(0)
    return b'FWS\x06' + struct.pack('<I', len(body) + 8) + body


def generate(destination):
    destination.mkdir(parents=True, exist_ok=False)
    png, tone = bars_png(), tone_wav()
    projects = {}
    for generation, extension, dll in ((1, 'rxdata', 'RGSS102E.dll'), (2, 'rvdata', 'RGSS202E.dll'), (3, 'rvdata2', 'RGSS301.dll')):
        projects['rgss' + str(generation)] = {
            'Game.ini': '[Game]\nLibrary=' + dll + '\nScripts=Data/Scripts.' + extension + '\nTitle=Yume RGSS' + str(generation) + ' probe\nRTP=\n',
            'Data/Scripts.' + extension: b'\x04\x08' + marshal([[1, b'Yume probe', zlib.compress(RGSS.encode())]]),
            'probe-source.rb': RGSS, 'tone.wav': tone,
        }
    for generation in (7, 8):
        projects['renpy' + str(generation)] = {
            'game/script.rpy': RENPY.replace('GENERATION', str(generation)),
            'game/script_version.txt': str(generation) + '.0.0\n',
            'game/bars.png': png, 'game/tone.wav': tone,
        }
    projects['onscripter'] = {'0.txt': ';mode640\n*define\ncaption "Yume ONS probe"\ngame\n*start\nbgm "tone.wav"\nbg "bars.png",1\nclick\nbg #2050e0,1\nclick\ngoto *start\n', 'bars.png': png, 'tone.wav': tone}
    projects['kirikiri'] = {'startup.tjs': KIRIKIRI, 'bars.png': png}
    projects['artemis'] = {'system.ini': ''.join('['+p+']\nWIDTH=640\nHEIGHT=480\nFPS=30\nCHARSET=UTF-8\nBOOT=boot.iet\n' for p in ('IOS','WINDOWS')),
        'boot.iet': '*main\n[caption data="Yume Artemis probe"]\n[lyc2 id="1" file="bars.png" alpha="255"]\n[stop]\n', 'bars.png': png}
    projects['flash-avm1'] = {'probe.swf': flash_movie()}
    projects['web-host'] = {'index.html': WEB, 'tyrano/tyrano.js': WEB_SCRIPT}
    manifests = []
    for name, files in projects.items():
        entries = []
        for relative, contents in files.items():
            data = contents.encode('utf-8') if isinstance(contents, str) else contents
            file = destination / name / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
            entries.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
        archive = destination / (name + '.zip')
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
            for entry in entries:
                package.write(destination / name / entry['path'], name + '/' + entry['path'])
        manifests.append({'project': name, 'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'files': entries})
    (destination / 'manifest.json').write_text(json.dumps({'schemaVersion':1,'origin':'Yume-owned generated probes','deviceValidated':False,'projects':manifests}, indent=2) + '\n')
    (destination / 'device-results.csv').write_text('build,revision,device,os,project,cold_start,first_frame,input,audio,save_reload,background_resume,stop,next_engine,session_id,notes\n' + '\n'.join(',,,,"'+name+'",,,,,,,,,,' for name in projects) + '\n')
    (destination / 'README.txt').write_text('Yume diagnostic probes; generated entirely from Yume-owned code.\nImport the individual ZIP files, not the whole output folder.\n\nRGSS1/2/3: moving green square; hold arrows, Z saves count, X exits; quiet repeating tone.\nRenPy7/8: colored quadrants, dialogue, persistent launch counter, optional save/load slot, quiet tone. Fully restart Yume between Python/Ruby sessions.\nONS: colored quadrants; tap alternates with blue; quiet tone.\nKirikiri: colored quadrants; touch/drag draws white marks.\nArtemis: colored quadrants only; no text/audio/save verification.\nFlash AVM1: red/blue background once per second and trace logs; no AVM2/input/save verification.\nWeb host: green square, hold arrows/tap, save button persists counter. It routes via Tyrano detection but contains no Tyrano or RPG Maker engine. Use your own actual MV/MZ/Tyrano browser exports for engine compatibility.\n\nQuadrants: red/green top; blue/yellow bottom; white edges top/left.\nThese probes have not been device-validated. A pass only establishes the stated host path. Report failures with device-results.csv and Settings diagnostic export, including session ID and source revision.\nLicense: same AGPL-3.0-or-later as the repository. No reference-app binaries, commercial scripts, RTP or fonts are included.\n')
    return manifests


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('BuildArtifacts/RuntimeProbes'))
    args = parser.parse_args()
    result = generate(args.output)
    print('Generated ' + str(len(result)) + ' projects at ' + str(args.output))
