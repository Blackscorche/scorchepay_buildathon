#!/usr/bin/env python3
"""Free voices for ScorchePay's voice assistant.

Speaks the OpenAI text-to-speech API (POST /v1/audio/speech). The voice
name decides the engine:

  en-NG-EzinneNeural   Microsoft's neural Nigerian-English voice (female, the
                       default). en-NG-AbeoNeural is the male one. Spoken
                       slower and a little lower for a soft, calm tone: change
                       it with EDGE_RATE and EDGE_PITCH.
  gtts:ha              Google Translate's Hausa voice (no key; plainer).
  mms:yor / mms:ibo / mms:hau
                       Meta's MMS voices for Yoruba, Igbo and Hausa through the
                       Hugging Face inference API. Needs HF_TOKEN. Yoruba and
                       Igbo have no other free voice, so this is the way to
                       get one. NOT TESTED here: try it with your token.

    pip install edge-tts gTTS
    python3 scripts/free-tts-server.py            # listens on 127.0.0.1:5050

then in backend/.env:

    TTS_BASE_URL=http://127.0.0.1:5050/v1
    TTS_VOICE=en-NG-EzinneNeural
    TTS_VOICE_HA=gtts:ha
    # TTS_VOICE_YO=mms:yor      (needs HF_TOKEN in this server's environment)
    # TTS_VOICE_IG=mms:ibo

Edge's voice service is unofficial: fine for a demo and a pilot, but for
production point TTS_BASE_URL at a service you have a contract with (OpenAI,
Groq, ElevenLabs behind a shim) or at a self-hosted open model such as Kokoro.
"""
import asyncio
import io
import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import edge_tts

DEFAULT_VOICE = "en-NG-EzinneNeural"
# Softer than the default: a touch slower and lower.
EDGE_RATE = os.environ.get("EDGE_RATE", "-8%")
EDGE_PITCH = os.environ.get("EDGE_PITCH", "-3Hz")


async def edge(text: str, voice: str) -> bytes:
    audio = b""
    communicate = edge_tts.Communicate(text, voice, rate=EDGE_RATE, pitch=EDGE_PITCH)
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            audio += chunk["data"]
    return audio


def gtts_voice(text: str, lang: str) -> bytes:
    from gtts import gTTS  # pip install gTTS

    out = io.BytesIO()
    gTTS(text, lang=lang).write_to_fp(out)
    return out.getvalue()


def mms_voice(text: str, code: str) -> tuple[bytes, str]:
    token = os.environ.get("HF_TOKEN")
    if not token:
        raise RuntimeError("HF_TOKEN is not set")
    request = urllib.request.Request(
        f"https://api-inference.huggingface.co/models/facebook/mms-tts-{code}",
        data=json.dumps({"inputs": text}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=40) as response:
        return response.read(), response.headers.get("content-type", "audio/flac")


def synthesize(text: str, voice: str) -> tuple[bytes, str]:
    """Returns the audio and its content type."""
    if voice.startswith("gtts:"):
        return gtts_voice(text, voice.split(":", 1)[1]), "audio/mpeg"
    if voice.startswith("mms:"):
        return mms_voice(text, voice.split(":", 1)[1])
    if "Neural" not in voice:  # an OpenAI voice name like "alloy"
        voice = DEFAULT_VOICE
    return asyncio.run(edge(text, voice)), "audio/mpeg"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path.rstrip("/") != "/v1/audio/speech":
            return self._send(404, b"not found", "text/plain")
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
            text = str(body["input"])[:600]
            voice = str(body.get("voice") or DEFAULT_VOICE)
            audio, content_type = synthesize(text, voice)
        except Exception as error:  # noqa: BLE001
            return self._send(502, str(error).encode(), "text/plain")
        self._send(200, audio, content_type)

    def _send(self, status, data, content_type):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5050"))
    print(f"Free voice server on http://127.0.0.1:{port}/v1 (voice {DEFAULT_VOICE})")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
