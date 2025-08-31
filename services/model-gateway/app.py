import asyncio
import json
from typing import Dict, List, Optional, AsyncGenerator, Any
from dataclasses import dataclass, asdict
from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import StreamingResponse
import httpx
import uvicorn
import logging
import os
from pydantic import BaseModel
from datetime import datetime

logger = logging.getLogger("model_gateway")

# Simple logging settup for model gateway -- no YAML config load here for simplicity
log_file = "logs/model-gateway-app.log"
log_dir = os.path.dirname(log_file)
if log_dir and not os.path.exists(log_dir):
    os.makedirs(log_dir)

logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(log_file),
        logging.StreamHandler()
    ]
)
logger.info("Model Gateway logging initialized.")

@dataclass
class ModelInfo:
    name: str
    size: str
    format: str
    family: str
    parameters: str
    quantization: str
    loaded: bool = False

class InferenceRequest(BaseModel):
    model: str
    prompt: str
    stream: bool = False
    parameters: Dict[str, Any] = {}

class InferenceResponse(BaseModel):
    response: str
    done: bool
    context: Optional[List[int]] = None
    total_duration: Optional[int] = None
    load_duration: Optional[int] = None
    prompt_eval_count: Optional[int] = None
    prompt_eval_duration: Optional[int] = None
    eval_count: Optional[int] = None
    eval_duration: Optional[int] = None

class ModelGateway:
    def __init__(self, ollama_url: str = "http://localhost:11434"):
        self.ollama_url = ollama_url
        self.loaded_models: Dict[str, ModelInfo] = {}
        self.client = httpx.AsyncClient(timeout=60.0)
        
    async def initialize(self):
        """Initialize the gateway and discover available models"""
        try:
            await self.discover_models()
        except Exception as e:
            print(f"Warning: Could not connect to Ollama: {e}")
    
    async def discover_models(self) -> List[ModelInfo]:
        """Discover available models from Ollama"""
        try:
            response = await self.client.get(f"{self.ollama_url}/api/tags")
            response.raise_for_status()
            data = response.json()
            
            models = []
            for model_data in data.get("models", []):
                model_info = ModelInfo(
                    name=model_data["name"],
                    size=model_data.get("size", "unknown"),
                    format=model_data.get("format", "unknown"),
                    family=model_data.get("details", {}).get("family", "unknown"),
                    parameters=model_data.get("details", {}).get("parameter_size", "unknown"),
                    quantization=model_data.get("details", {}).get("quantization_level", "unknown")
                )
                models.append(model_info)
                self.loaded_models[model_info.name] = model_info
                
            return models
        except Exception as e:
            raise HTTPException(status_code=503, detail=f"Cannot connect to Ollama: {e}")
    
    async def load_model(self, model_name: str) -> bool:
        """Preload a model for faster inference"""
        try:
            # Send a simple request to load the model
            response = await self.client.post(
                f"{self.ollama_url}/api/generate",
                json={
                    "model": model_name,
                    "prompt": "",
                    "stream": False
                }
            )
            
            if response.status_code == 200:
                if model_name in self.loaded_models:
                    self.loaded_models[model_name].loaded = True
                return True
            return False
        except Exception as e:
            print(f"Error loading model {model_name}: {e}")
            return False
    
    async def unload_model(self, model_name: str) -> bool:
        """Unload a model to free resources"""
        try:
            # Ollama doesn't have explicit unload, but we can track loading state
            if model_name in self.loaded_models:
                self.loaded_models[model_name].loaded = False
            return True
        except Exception as e:
            print(f"Error unloading model {model_name}: {e}")
            return False
    
    async def generate_response(
        self, 
        model_name: str, 
        prompt: str, 
        stream: bool = False,
        parameters: Dict = None
    ) -> AsyncGenerator[str, None]:
        """Generate response from model"""
        if parameters is None:
            parameters = {}
            
        request_data = {
            "model": model_name,
            "prompt": prompt,
            "stream": stream,
            **parameters
        }
        
        try:
            async with self.client.stream(
                "POST",
                f"{self.ollama_url}/api/generate",
                json=request_data
            ) as response:
                response.raise_for_status()
                
                if stream:
                    async for line in response.aiter_lines():
                        if line:
                            try:
                                data = json.loads(line)
                                if "response" in data:
                                    yield data["response"]
                                if data.get("done", False):
                                    break
                            except json.JSONDecodeError:
                                continue
                else:
                    content = await response.aread()
                    data = json.loads(content)
                    yield data.get("response", "")
                    
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Generation error: {e}")
    
    async def get_model_info(self, model_name: str) -> Optional[ModelInfo]:
        """Get information about a specific model"""
        return self.loaded_models.get(model_name)
    
    async def health_check(self) -> Dict[str, Any]:
        """Check the health of the Ollama service"""
        try:
            response = await self.client.get(f"{self.ollama_url}/api/tags")
            return {
                "status": "healthy" if response.status_code == 200 else "unhealthy",
                "ollama_url": self.ollama_url,
                "models_loaded": len([m for m in self.loaded_models.values() if m.loaded])
            }
        except Exception as e:
            return {
                "status": "unhealthy",
                "error": str(e),
                "ollama_url": self.ollama_url
            }

# FastAPI application
app = FastAPI(title="Model Gateway", version="1.0.0")
gateway = ModelGateway()

@app.on_event("startup")
async def startup_event():
    logger.info("Model Gateway service is starting up...")
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get("http://localhost:11434/api/tags", timeout=10.0)
            response.raise_for_status()
            logger.info("Successfully connected to Ollama API.")
    except Exception as e:
        logger.error(f"Failed to connect to Ollama API on startup: {e}")

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    logger.debug("Health check endpoint called.")
    try:
        async with httpx.AsyncClient() as client:
            # Quick check if Ollama is reachable
            response = await client.get("http://localhost:11434/", timeout=5.0)
            if response.status_code == 200:
                logger.info("Health check: Model Gateway and Ollama connection OK.")
                return {"status": "healthy", "ollama_connected": True, "timestamp": datetime.utcnow().isoformat()}
            else:
                logger.warning(f"Health check: Model Gateway OK, but Ollama responded with status {response.status_code}.")
                return {"status": "degraded", "ollama_connected": False, "ollama_status": response.status_code, "timestamp": datetime.utcnow().isoformat()}
    except Exception as e:
        logger.error(f"Health check failed: Error connecting to Ollama: {e}")
        return {"status": "unhealthy", "ollama_connected": False, "error": str(e), "timestamp": datetime.utcnow().isoformat()}

@app.get("/models")
async def list_models():
    return {"models": [asdict(model) for model in gateway.loaded_models.values()]}

@app.post("/models/{model_name}/load")
async def load_model(model_name: str, background_tasks: BackgroundTasks):
    background_tasks.add_task(gateway.load_model, model_name)
    return {"message": f"Loading model {model_name}"}

@app.post("/models/{model_name}/unload")
async def unload_model(model_name: str):
    success = await gateway.unload_model(model_name)
    return {"success": success, "message": f"Model {model_name} unload requested"}

@app.post("/generate")
async def generate_text(request: InferenceRequest):
    logger.info(f"Received generation request for model '{request.model}'")
    logger.debug(f"Request details: prompt='{request.prompt[:50]}...', stream={request.stream}, params={request.parameters}")
    try:
        async with httpx.AsyncClient() as client:
            # Forward the request to Ollama
            ollama_request = {
                "model": request.model,
                "prompt": request.prompt,
                "stream": request.stream,
                "options": request.parameters # Pass parameters as options to Ollama
            }
            logger.debug(f"Forwarding request to Ollama: {ollama_request}")
            response = await client.post(
                "http://localhost:11434/api/generate", # Standard Ollama endpoint
                json=ollama_request,
                timeout=300.0 # Increase timeout for generation
            )
            logger.debug(f"Received response from Ollama: Status {response.status_code}")
            response.raise_for_status()

            if request.stream:
                # Handle streaming response if needed (your existing logic)
                # ...
                pass
            else:
                # Return the full response
                ollama_response = response.json()
                logger.info(f"Generation completed successfully for model '{request.model}'.")
                # Return the response in the format expected by the Orchestrator
                return {"response": ollama_response.get("response", "")}

    except httpx.RequestError as e:
        logger.error(f"Network error calling Ollama: {e}")
        raise HTTPException(status_code=502, detail=f"Network error calling Ollama: {e}")
    except httpx.HTTPStatusError as e:
        logger.error(f"Ollama returned error {e.response.status_code}: {e.response.text}")
        raise HTTPException(status_code=e.response.status_code, detail=f"Ollama error: {e.response.text}")
    except Exception as e:
        logger.error(f"Unexpected error during generation: {e}")
        raise HTTPException(status_code=500, detail=f"Internal server error: {e}")

@app.get("/models/{model_name}/info")
async def get_model_info(model_name: str):
    info = await gateway.get_model_info(model_name)
    if not info:
        raise HTTPException(status_code=404, detail="Model not found")
    return asdict(info)

if __name__ == "__main__":
    logger.info("Starting Model Gateway application...")
    uvicorn.run(app, host="0.0.0.0", port=8070)