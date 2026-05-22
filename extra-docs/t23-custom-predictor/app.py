"""
Minimal HF-transformers TinyLlama predictor for KServe Design D T23 redo.

Loads TinyLlama-1.1B-Chat-v1.0 at startup; exposes an OpenAI-style chat
completions endpoint at /v1/chat/completions plus a /healthz probe.

Built multi-arch (linux/amd64 + linux/arm64) to bypass the upstream KServe
huggingfaceserver image's missing arm64 manifest. Same model, same protocol
shape — just a runtime that actually pulls on Apple Silicon.
"""
import os
from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoModelForCausalLM, AutoTokenizer
import torch

MODEL_ID = os.getenv("MODEL_ID", "TinyLlama/TinyLlama-1.1B-Chat-v1.0")

print(f"[predictor] loading tokenizer for {MODEL_ID} ...", flush=True)
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
print(f"[predictor] loading model {MODEL_ID} (this may take a few minutes on first run) ...", flush=True)
model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.float32)
model.eval()
print(f"[predictor] model loaded. ready for inference.", flush=True)

app = FastAPI(title="tinyllama-predictor", version="1.0")


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage]
    max_tokens: int = 64
    temperature: float = 0.0


@app.get("/healthz")
def healthz():
    return {"ok": True, "model": MODEL_ID}


@app.get("/v1/models")
def list_models():
    return {"data": [{"id": MODEL_ID, "object": "model"}]}


@app.post("/v1/chat/completions")
def chat_completions(req: ChatRequest):
    msgs = [{"role": m.role, "content": m.content} for m in req.messages]
    prompt = tokenizer.apply_chat_template(
        msgs, tokenize=False, add_generation_prompt=True
    )
    inputs = tokenizer(prompt, return_tensors="pt")
    with torch.no_grad():
        out_ids = model.generate(
            **inputs,
            max_new_tokens=req.max_tokens,
            do_sample=(req.temperature > 0),
            temperature=max(req.temperature, 1e-5),
            pad_token_id=tokenizer.eos_token_id,
        )
    gen_ids = out_ids[0][inputs["input_ids"].shape[1]:]
    text = tokenizer.decode(gen_ids, skip_special_tokens=True).strip()
    return {
        "object": "chat.completion",
        "model": MODEL_ID,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
    }
