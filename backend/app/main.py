from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv
import os

load_dotenv()

app = FastAPI(title="Raphaela AI Backend", version="0.1.0")

app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

class ChatRequest(BaseModel):
    message: str

class ChatResponse(BaseModel):
    response: str

@app.get("/health")
async def health():
    return {"status": "ok", "message": "Raphaela backend is running"}

@app.get("/")
async def root():
    return {"message": "Welcome to Raphaela AI Backend"}

@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    reply = "Raphaela heard: " + req.message
    return ChatResponse(response=reply)
