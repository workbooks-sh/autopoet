// Kokoro TTS in a Web Worker — inference is WASM and BLOCKS its thread, so it
// must NOT run on the UI thread or the whole widget freezes while it speaks.
// Protocol:
//   main -> worker: {type:"load"} | {type:"gen", id, text, voice}
//   worker -> main: {type:"ready"} | {type:"error", error}
//                   {type:"audio", id, audio:Float32Array, sr} | {type:"audio", id, error}
import { KokoroTTS } from "./kokoro.bundle.mjs";

let tts = null;

self.onmessage = async (e) => {
  const m = e.data;
  if (m.type === "load") {
    const REPO = "onnx-community/Kokoro-82M-v1.0-ONNX";
    // stream download progress up so the UI can show a real percentage
    let lastPct = -1;
    const progress = (info) => {
      if (info.status === "progress" && info.total) {
        const pct = Math.round((info.loaded / info.total) * 100);
        if (pct !== lastPct) { lastPct = pct; self.postMessage({ type: "progress", pct, file: info.file }); }
      }
    };
    // WebGPU is ~10x faster than WASM CPU on Apple Silicon; fall back to WASM.
    const tryWebGPU = typeof navigator !== "undefined" && "gpu" in navigator;
    try {
      if (tryWebGPU) {
        try {
          tts = await KokoroTTS.from_pretrained(REPO, { dtype: "fp32", device: "webgpu", progress_callback: progress });
          self.postMessage({ type: "ready", device: "webgpu" });
          return;
        } catch (gpuErr) { /* fall through to wasm */ }
      }
      tts = await KokoroTTS.from_pretrained(REPO, { dtype: "q8", device: "wasm", progress_callback: progress });
      self.postMessage({ type: "ready", device: "wasm" });
    } catch (err) {
      self.postMessage({ type: "error", error: String(err) });
    }
  } else if (m.type === "gen") {
    try {
      const out = await tts.generate(m.text, { voice: m.voice || "af_heart" });
      const audio = out.audio; // Float32Array
      self.postMessage({ type: "audio", id: m.id, audio, sr: out.sampling_rate }, [audio.buffer]);
    } catch (err) {
      self.postMessage({ type: "audio", id: m.id, error: String(err) });
    }
  }
};
