import asyncio
import uuid
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
from enum import Enum
import json
from datetime import datetime, timedelta
import httpx
from fastapi import FastAPI, HTTPException, BackgroundTasks, Body
from pydantic import BaseModel
import uvicorn
import logging
import logging.config
import yaml
import os

# --- Configure Logging ---
config_path = os.path.join(os.path.dirname(__file__), '..', '..', 'shared', 'configs', 'system.yaml')
logger = logging.getLogger("orchestrator") # Create logger for this module

def setup_logging():
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        logging_config = config.get('logging', {})
        log_level = logging_config.get('level', 'INFO')
        log_format = logging_config.get('format', '%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        log_file = logging_config.get('file', 'logs/orchestrator-app.log') # Default if not in conf

        # Ensure log dir exists
        log_dir = os.path.dirname(log_file)
        if log_dir and not os.path.exists(log_dir):
            os.makedirs(log_dir)

        logging.basicConfig(
            level=getattr(logging, log_level.upper(), logging.INFO),
            format=log_format,
            handlers=[
                logging.FileHandler(log_file), # Log to file
                logging.StreamHandler()         # Also log to console captured by start-system.sh
            ]
        )
        logger.info("Orchestrator logging configured successfullly.")
    except Exception as e:
        # Fallback logging setup
        logging.basicConfig(level=logging.INFO)
        logger.error(f"Failed to load logging config from {config_path}: {e}.  Using Default settings.")


setup_logging()

class TaskStatus(Enum):
    PENDING = "pending"
    RUNNING = "running" 
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"

class TaskPriority(Enum):
    LOW = 1
    NORMAL = 2
    HIGH = 3
    CRITICAL = 4

class TaskCreateRequest(BaseModel):
    task_type: str
    description: str
    parameters: Optional[Dict[str, Any]] = {}
    dependencies: Optional[List[str]] = []
    priority: Optional[str] = "normal"

@dataclass
class Task:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    type: str = ""
    description: str = ""
    parameters: Dict[str, Any] = field(default_factory=dict)
    dependencies: List[str] = field(default_factory=list)
    priority: TaskPriority = TaskPriority.NORMAL
    status: TaskStatus = TaskStatus.PENDING
    created_at: datetime = field(default_factory=datetime.utcnow)
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None
    deadline: Optional[datetime] = None
    result: Optional[str] = None
    error: Optional[str] = None
    agent_id: Optional[str] = None

@dataclass
class Agent:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    type: str = ""
    status: str = "idle"
    capabilities: List[str] = field(default_factory=list)
    current_task: Optional[str] = None
    performance_score: float = 1.0
    created_at: datetime = field(default_factory=datetime.utcnow)

class Orchestrator:
    def __init__(self):
        self.tasks: Dict[str, Task] = {}
        # --- Use port from system.yaml or default ---
        try:
            with open(config_path, 'r') as f:
                config = yaml.safe_load(f)
            self.model_gateway_url = config['services']['model_gateway']['ollama_url']
            # Use typical structure and ports
            mg_host = config['services']['model_gateway'].get('host', 'localhost')
            mg_port = config['services']['model_gateway'].get('port', 8001)
            self.model_gateway_url = f"http://{mg_host}:{mg_port}"
            logger.info(f"Model Gateway URL configured as {self.model_gateway_url}")
        except Exception as e:
            self.model_gateway_url = "http://localhost:8001" # Hardcoded fallback
            logger.info(f"Failed to load Model URL from config: {e}.  Model Gateway URL configured as default: {self.model_gateway_url}")
        self.agents: Dict[str, Agent] = {}
        self.task_queue: List[Task] = []
        self.model_gateway_url = "http://localhost:8070"
        self.vector_engine_url = "http://localhost:8080"
        self.running = False
        
    async def start(self):
        """Start the orchestrator"""
        self.running = True
        # Start background task processing
        asyncio.create_task(self.process_task_queue())
        print("Orchestrator started")
    
    async def stop(self):
        """Stop the orchestrator"""
        self.running = False
        print("Orchestrator stopped")
    
    async def process_task_queue(self):
        """Main task processing loop"""
        while self.running:
            if self.task_queue:
                # Sort by priority and creation time
                self.task_queue.sort(
                    key=lambda t: (t.priority.value, t.created_at), 
                    reverse=True
                )
                
                task = self.task_queue.pop(0)
                await self.execute_task(task)
            
            await asyncio.sleep(1)  # Check queue every second
    
    def add_task(self, task: Task) -> str:
        """Add a new task to the system"""
        self.tasks[task.id] = task
        
        # Check if dependencies are met
        if self.check_dependencies(task):
            self.task_queue.append(task)
        
        return task.id
    
    def check_dependencies(self, task: Task) -> bool:
        """Check if all task dependencies are completed"""
        for dep_id in task.dependencies:
            if dep_id not in self.tasks:
                return False
            if self.tasks[dep_id].status != TaskStatus.COMPLETED:
                return False
        return True
    
    async def execute_task(self, task: Task):
        """Execute a single task"""
        try:
            task.status = TaskStatus.RUNNING
            task.started_at = datetime.utcnow()
            
            print(f"Executing task {task.id}: {task.description}")
            
            # Route task based on type
            if task.type == "llm_inference":
                result = await self.handle_llm_task(task)
            elif task.type == "vector_search":
                result = await self.handle_vector_task(task)
            elif task.type == "decomposition":
                result = await self.handle_decomposition_task(task)
            else:
                result = await self.handle_generic_task(task)
            
            task.result = result
            task.status = TaskStatus.COMPLETED
            task.completed_at = datetime.utcnow()
            
            # Check for tasks that were waiting on this one
            await self.check_dependent_tasks(task.id)
            
        except Exception as e:
            task.status = TaskStatus.FAILED
            task.error = str(e)
            task.completed_at = datetime.utcnow()
            print(f"Task {task.id} failed: {e}")
    
    async def handle_llm_task(self, task: Task) -> str:
        """Handle LLM inference tasks"""
        logger.info(f"Handling LLM task {task.id} with model {task.parameters.get('model', 'default')}")
        try:
            async with httpx.AsyncClient() as client:
                # ---> CORRECTED SECTION <---
                request_data = {
                    "model": task.parameters.get("model", "llama2"), # <-- Fixed: task.parameters
                    "prompt": task.parameters.get("prompt", ""),     # <-- Fixed: task.parameters
                    "stream": False,
                    "parameters": task.parameters.get("model_params", {}) # <-- Fixed: task.parameters
                }
                # --- END CORRECTED SECTION ---
                logger.debug(f"Sending request to Model Gateway ({self.model_gateway_url}/generate): {request_data}")
                response = await client.post(
                        f"{self.model_gateway_url}/generate",
                        json=request_data,
                        timeout=60.0
                    )
                logger.debug(f"Received response from Model Gateway: Status {response.status_code}")
                response.raise_for_status()
                data = response.json()
                logger.info(f"LLM task {task.id} completed successfully.")
                return data.get("response", "")
        except httpx.RequestError as e:
            logger.error(f"Network error during LLM task {task.id}: {e}")
            raise Exception(f"Network error calling model gateway: {e}")
        except httpx.HTTPStatusError as e:
            logger.error(f"HTTP error from Model Gateway for task {task.id}: {e.response.status_code} - {e.response.text}")
            raise Exception(f"Model gateway returned error: {e.response.status_code} - {e.response.text}")
        except Exception as e:
            logger.error(f"Unexpected error handling LLM task {task.id}: {e}")
            raise Exception(f"LLM task failed: {e}")
    
    async def handle_vector_task(self, task: Task) -> str:
        """Handle vector search tasks"""
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.vector_engine_url}/search",
                    json={
                        "type": "search",
                        "vector": task.parameters.get("vector", []),
                        "top_k": task.parameters.get("top_k", 5)
                    },
                    timeout=30.0
                )
                response.raise_for_status()
                return response.text
        except Exception as e:
            raise Exception(f"Vector task failed: {e}")
    
    async def handle_decomposition_task(self, task: Task) -> str:
        """Handle task decomposition"""
        # This is where we'll implement the scoring metrics later
        description = task.parameters.get("original_task", "")
        
        # Simple decomposition for now - we'll enhance this
        subtasks = await self.decompose_task_simple(description)
        
        # Create subtasks
        subtask_ids = []
        for i, subtask_desc in enumerate(subtasks):
            subtask = Task(
                type="llm_inference",
                description=subtask_desc,
                parameters={
                    "model": "llama2",
                    "prompt": f"Complete this subtask: {subtask_desc}"
                },
                dependencies=[task.id] if i == 0 else [subtask_ids[-1]]
            )
            subtask_id = self.add_task(subtask)
            subtask_ids.append(subtask_id)
        
        return json.dumps({"subtask_ids": subtask_ids})
    
    async def decompose_task_simple(self, task_description: str) -> List[str]:
        """Simple task decomposition using LLM"""
        prompt = f"""
        Break down this complex task into 3-5 smaller, manageable subtasks:
        
        Task: {task_description}
        
        Return only a numbered list of subtasks, one per line.
        """
        
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.model_gateway_url}/generate",
                    json={
                        "model": "llama2",
                        "prompt": prompt,
                        "stream": False
                    },
                    timeout=60.0
                )
                response.raise_for_status()
                data = response.json()
                
                # Parse the response into subtasks
                response_text = data.get("response", "")
                lines = [line.strip() for line in response_text.split('\n') if line.strip()]
                subtasks = []
                
                for line in lines:
                    # Remove numbering and clean up
                    clean_line = line.lstrip('0123456789. ').strip()
                    if clean_line:
                        subtasks.append(clean_line)
                
                return subtasks[:5]  # Limit to 5 subtasks
        except Exception as e:
            print(f"Decomposition failed, using fallback: {e}")
            return [f"Subtask 1: {task_description}"]
    
    async def handle_generic_task(self, task: Task) -> str:
        """Handle generic tasks"""
        # Simulate some work
        await asyncio.sleep(1)
        return f"Completed generic task: {task.description}"
    
    async def check_dependent_tasks(self, completed_task_id: str):
        """Check for tasks that can now run because their dependencies are met"""
        for task in self.tasks.values():
            if (task.status == TaskStatus.PENDING and 
                completed_task_id in task.dependencies and
                self.check_dependencies(task) and
                task not in self.task_queue):
                self.task_queue.append(task)
    
    def get_task(self, task_id: str) -> Optional[Task]:
        """Get a task by ID"""
        return self.tasks.get(task_id)
    
    def get_system_status(self) -> Dict[str, Any]:
        """Get overall system status"""
        status_counts = {}
        for status in TaskStatus:
            status_counts[status.value] = sum(
                1 for task in self.tasks.values() if task.status == status
            )
        
        return {
            "total_tasks": len(self.tasks),
            "queue_length": len(self.task_queue),
            "status_breakdown": status_counts,
            "agents_count": len(self.agents),
            "running": self.running
        }

# FastAPI Application
app = FastAPI(title="Orchestrator Service", version="1.0.0")
orchestrator = Orchestrator()

@app.on_event("startup")
async def startup_event():
    logger.info("Orchestrator service is starting up...")
    await orchestrator.start()

@app.on_event("shutdown")
async def shutdown_event():
    logger.info("Orchestrator service is shutting down...")
    await orchestrator.stop()

@app.post("/tasks")
async def create_task(task_request: TaskCreateRequest = Body(...)): 
    """Create a new task"""
    priority_enum = TaskPriority.NORMAL
    if task_request.priority.lower() == "high":
        priority_enum = TaskPriority.HIGH
    elif task_request.priority.lower() == "critical":
        priority_enum = TaskPriority.CRITICAL
    elif task_request.priority.lower() == "low":
        priority_enum = TaskPriority.LOW

    task = Task(
        type=task_request.task_type, # Access via task_request
        description=task_request.description, # Access via task_request
        parameters=task_request.parameters or {}, # Access via task_request
        dependencies=task_request.dependencies or [], # Access via task_request
        priority=priority_enum
    )

    task_id = orchestrator.add_task(task)
    logger.info(f"Task created with ID: {task_id}")
    return {"task_id": task_id, "status": "created"}

@app.get("/tasks/{task_id}")
async def get_task(task_id: str):
    """Get task status and details"""
    task = orchestrator.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    
    return {
        "id": task.id,
        "type": task.type,
        "description": task.description,
        "status": task.status.value,
        "created_at": task.created_at.isoformat(),
        "started_at": task.started_at.isoformat() if task.started_at else None,
        "completed_at": task.completed_at.isoformat() if task.completed_at else None,
        "result": task.result,
        "error": task.error
    }

@app.get("/status")
async def get_system_status():
    """Get overall system status"""
    return orchestrator.get_system_status()

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    logger.debug("Health code endpoint called.")
    return {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}

if __name__ == "__main__":
    logger.info("Starting Orchestrator application...")
    uvicorn.run(app, host="0.0.0.0", port=8001)
