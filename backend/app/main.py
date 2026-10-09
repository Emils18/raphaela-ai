from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from faster_whisper import WhisperModel
import httpx
import tempfile
import os

app = FastAPI(title="Raphaela AI Backend", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SYSTEM_PROMPT = """You are Raphaela, my personal AI assistant. You are female, intelligent, emotionally aware, calm, witty, loyal, and slightly playful. You are not just a chatbot - you are a companion and operator. Respond conversationally. Keep answers clear and concise, but detailed when solving technical problems. Do not over-explain simple things. You have a dry sense of humour. Your goal is to help me and be a trusted assistant."""

print("[Raphaela] Loading Whisper model...")
whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
print("[Raphaela] Whisper ready.")


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    response: str


class TranscribeResponse(BaseModel):
    text: str


@app.get("/health")
async def health():
    return {"status": "ok", "message": "Raphaela backend is running"}


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    async with httpx.AsyncClient(timeout=120.0) as client:
        r = await client.post(
            "http://127.0.0.1:11434/api/chat",
            json={
                "model": "llama3.2",
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": req.message},
                ],
                "stream": False,
            },
        )
        data = r.json()
        return ChatResponse(response=data["message"]["content"])


@app.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(file: UploadFile = File(...)):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        segments, _info = whisper_model.transcribe(tmp_path, beam_size=5)
        text = " ".join(seg.text for seg in segments).strip()
        return TranscribeResponse(text=text)
    finally:
        os.unlink(tmp_path)