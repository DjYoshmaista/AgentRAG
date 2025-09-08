#!/usr/bin/env python3
"""
AgenticRAG CLI - Advanced Multi-Agent System Command Line Interface

This CLI provides comprehensive interaction with the AgenticRAG multi-agent system,
supporting file processing, RAG database operations, model configuration, and more.

Usage:
  agentic-rag <command> [options] [files/folders...]
  agentic-rag --help
  agentic-rag --version
"""

import argparse
import asyncio
import json
import os
import sys
import yaml
from pathlib import Path
from typing import Dict, List, Optional, Any, Union
import httpx
import logging
from dataclasses import dataclass, asdict
from datetime import datetime
import subprocess
import tempfile

# CLI Configuration
CLI_VERSION = "1.0.0"
CLI_NAME = "agentic-rag"
CONFIG_DIR = Path.home() / ".config" / "agentic-rag"
CONFIG_FILE = CONFIG_DIR / "config.yaml"
LOG_DIR = Path.home() / ".local" / "share" / "agentic-rag" / "logs"

@dataclass
class CLIConfig:
    """CLI configuration structure"""
    # Service endpoints
    orchestrator_url: str = "http://localhost:8001"
    model_gateway_url: str = "http://localhost:8070"
    vector_engine_url: str = "http://localhost:8080"
    
    # Database settings
    postgresql_host: str = "localhost"
    postgresql_port: int = 5432
    postgresql_db: str = "agentic_system"
    postgresql_user: str = "postgres"
    postgresql_password: str = "password"
    
    # RAG settings
    embedding_model: str = "sentence-transformers/all-MiniLM-L6-v2"
    embedding_dimensions: int = 384
    rag_top_k: int = 5
    rag_weight: float = 0.0  # -10.0 to 10.0, knowledge vs RAG balance
    
    # Agent settings
    max_agents: int = 5
    agent_memory_timeout: int = 3600  # seconds
    default_context_window: int = 4096
    default_temperature: float = 0.7
    
    # Model settings
    default_model: str = "qwen3:8b"
    models: Dict[str, Dict] = None
    
    # Plugin settings
    plugin_dir: Path = CONFIG_DIR / "plugins"
    enabled_plugins: List[str] = None
    
    # Interface settings
    interactive_mode: bool = True
    color_output: bool = True
    verbose: bool = False
    
    def __post_init__(self):
        if self.models is None:
            self.models = {
                "orchestration": {"model": "qwen3:8b", "temperature": 0.3},
                "inference": {"model": "qwen3:8b", "temperature": 0.7},
                "embedding": {"model": "sentence-transformers/all-MiniLM-L6-v2"},
                "rag": {"model": "qwen3:8b", "temperature": 0.5}
            }
        if self.enabled_plugins is None:
            self.enabled_plugins = []

class CLIManager:
    """Main CLI management class"""
    
    def __init__(self):
        self.config: CLIConfig = CLIConfig()
        self.http_client: Optional[httpx.AsyncClient] = None
        self.logger = self._setup_logging()
        self._ensure_directories()
        self._load_config()
    
    def _setup_logging(self) -> logging.Logger:
        """Setup logging configuration"""
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        
        logger = logging.getLogger(CLI_NAME)
        logger.setLevel(logging.INFO)
        
        # File handler
        file_handler = logging.FileHandler(LOG_DIR / f"{CLI_NAME}.log")
        file_formatter = logging.Formatter(
            '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)
        
        return logger
    
    def _ensure_directories(self):
        """Ensure necessary directories exist"""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.config.plugin_dir.mkdir(parents=True, exist_ok=True)
    
    def _load_config(self):
        """Load configuration from file"""
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, 'r') as f:
                    config_data = yaml.safe_load(f)
                
                # Update config with loaded data
                for key, value in config_data.items():
                    if hasattr(self.config, key):
                        setattr(self.config, key, value)
                
                self.logger.info("Configuration loaded successfully")
            except Exception as e:
                self.logger.error(f"Error loading config: {e}")
                print(f"Warning: Could not load config file: {e}")
    
    def _save_config(self):
        """Save current configuration to file"""
        try:
            with open(CONFIG_FILE, 'w') as f:
                yaml.dump(asdict(self.config), f, default_flow_style=False)
            self.logger.info("Configuration saved successfully")
        except Exception as e:
            self.logger.error(f"Error saving config: {e}")
            print(f"Error: Could not save config file: {e}")
    
    async def _get_http_client(self) -> httpx.AsyncClient:
        """Get or create HTTP client"""
        if self.http_client is None:
            self.http_client = httpx.AsyncClient(timeout=60.0)
        return self.http_client
    
    async def close(self):
        """Cleanup resources"""
        if self.http_client:
            await self.http_client.aclose()

class CommandParser:
    """Command line argument parser"""
    
    def __init__(self, cli_manager: CLIManager):
        self.cli_manager = cli_manager
        self.parser = self._create_parser()
    
    def _create_parser(self) -> argparse.ArgumentParser:
        """Create the main argument parser"""
        parser = argparse.ArgumentParser(
            prog=CLI_NAME,
            description="Advanced Multi-Agent RAG System CLI",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Examples:
  agentic-rag query "What is machine learning?" --rag-weight 5.0
  agentic-rag ingest /path/to/documents --recursive
  agentic-rag config --set embedding_model=sentence-transformers/all-mpnet-base-v2
  agentic-rag agents --list
  agentic-rag db --create-table embeddings --dimensions 768
  agentic-rag tui  # Launch terminal UI
            """
        )
        
        parser.add_argument('--version', action='version', version=f'{CLI_NAME} {CLI_VERSION}')
        parser.add_argument('--verbose', '-v', action='store_true', help='Verbose output')
        parser.add_argument('--config', help='Path to config file')
        parser.add_argument('--no-color', action='store_true', help='Disable colored output')
        
        # Create subcommands
        subparsers = parser.add_subparsers(dest='command', help='Available commands')
        
        # Query command
        query_parser = subparsers.add_parser('query', help='Submit a query to the system')
        query_parser.add_argument('prompt', help='The query prompt')
        query_parser.add_argument('--model', help='Model to use for inference')
        query_parser.add_argument('--temperature', type=float, help='Temperature for generation')
        query_parser.add_argument('--rag-weight', type=float, help='RAG vs knowledge weight (-10.0 to 10.0)')
        query_parser.add_argument('--top-k', type=int, help='Number of RAG results to retrieve')
        query_parser.add_argument('--context-window', type=int, help='Context window size')
        query_parser.add_argument('--stream', action='store_true', help='Stream the response')
        query_parser.add_argument('--save-context', help='Save conversation context to file')
        
        # Ingest command
        ingest_parser = subparsers.add_parser('ingest', help='Ingest documents into RAG database')
        ingest_parser.add_argument('paths', nargs='+', help='Files or directories to ingest')
        ingest_parser.add_argument('--recursive', '-r', action='store_true', help='Process directories recursively')
        ingest_parser.add_argument('--file-types', help='Comma-separated file extensions to process')
        ingest_parser.add_argument('--chunk-size', type=int, default=1000, help='Text chunk size for embeddings')
        ingest_parser.add_argument('--overlap', type=int, default=200, help='Chunk overlap size')
        ingest_parser.add_argument('--embedding-model', help='Model for generating embeddings')
        ingest_parser.add_argument('--batch-size', type=int, default=100, help='Processing batch size')
        
        # Configuration command
        config_parser = subparsers.add_parser('config', help='Manage configuration')
        config_parser.add_argument('--show', action='store_true', help='Show current configuration')
        config_parser.add_argument('--set', action='append', help='Set config value (key=value)')
        config_parser.add_argument('--reset', action='store_true', help='Reset to default configuration')
        config_parser.add_argument('--validate', action='store_true', help='Validate configuration')
        
        # Agent management command
        agent_parser = subparsers.add_parser('agents', help='Manage agents')
        agent_parser.add_argument('--list', action='store_true', help='List active agents')
        agent_parser.add_argument('--create', help='Create new agent with specified type')
        agent_parser.add_argument('--stop', help='Stop agent by ID')
        agent_parser.add_argument('--info', help='Get agent information by ID')
        agent_parser.add_argument('--max-agents', type=int, help='Set maximum number of agents')
        
        # Database management command
        db_parser = subparsers.add_parser('db', help='Database operations')
        db_parser.add_argument('--create-table', help='Create table with specified name')
        db_parser.add_argument('--list-tables', action='store_true', help='List all tables')
        db_parser.add_argument('--table-info', help='Get table information')
        db_parser.add_argument('--dimensions', type=int, help='Vector dimensions for table creation')
        db_parser.add_argument('--migrate', action='store_true', help='Run database migrations')
        db_parser.add_argument('--backup', help='Backup database to file')
        db_parser.add_argument('--restore', help='Restore database from file')
        
        # Plugin management command
        plugin_parser = subparsers.add_parser('plugins', help='Plugin management')
        plugin_parser.add_argument('--list', action='store_true', help='List available plugins')
        plugin_parser.add_argument('--enable', help='Enable plugin by name')
        plugin_parser.add_argument('--disable', help='Disable plugin by name')
        plugin_parser.add_argument('--install', help='Install plugin from path or URL')
        plugin_parser.add_argument('--create', help='Create new plugin template')
        
        # System status command
        status_parser = subparsers.add_parser('status', help='System status')
        status_parser.add_argument('--services', action='store_true', help='Check service status')
        status_parser.add_argument('--health', action='store_true', help='Run health checks')
        status_parser.add_argument('--metrics', action='store_true', help='Show system metrics')
        
        # Terminal UI command
        tui_parser = subparsers.add_parser('tui', help='Launch terminal user interface')
        tui_parser.add_argument('--no-mouse', action='store_true', help='Disable mouse support')
        
        # Prompt management command
        prompt_parser = subparsers.add_parser('prompts', help='Manage custom prompts')
        prompt_parser.add_argument('--list', action='store_true', help='List saved prompts')
        prompt_parser.add_argument('--create', help='Create new prompt template')
        prompt_parser.add_argument('--edit', help='Edit existing prompt')
        prompt_parser.add_argument('--delete', help='Delete prompt by name')
        prompt_parser.add_argument('--export', help='Export prompts to file')
        prompt_parser.add_argument('--import', help='Import prompts from file')
        
        return parser
    
    def parse_args(self, args: Optional[List[str]] = None) -> argparse.Namespace:
        """Parse command line arguments"""
        return self.parser.parse_args(args)

class APIClient:
    """HTTP API client for communicating with backend services"""
    
    def __init__(self, cli_manager: CLIManager):
        self.cli_manager = cli_manager
        self.config = cli_manager.config
        self.logger = cli_manager.logger
    
    async def health_check(self) -> Dict[str, Any]:
        """Check health of all services"""
        client = await self.cli_manager._get_http_client()
        services = {
            'orchestrator': f"{self.config.orchestrator_url}/health",
            'model_gateway': f"{self.config.model_gateway_url}/health",
            'vector_engine': f"{self.config.vector_engine_url}/"
        }
        
        results = {}
        for service, url in services.items():
            try:
                response = await client.get(url, timeout=5.0)
                results[service] = {
                    'status': 'healthy' if response.status_code == 200 else 'unhealthy',
                    'status_code': response.status_code,
                    'response_time': response.elapsed.total_seconds()
                }
            except Exception as e:
                results[service] = {
                    'status': 'error',
                    'error': str(e)
                }
        
        return results
    
    async def submit_task(self, task_type: str, description: str, 
                         parameters: Dict[str, Any]) -> Dict[str, Any]:
        """Submit a task to the orchestrator"""
        client = await self.cli_manager._get_http_client()
        
        task_data = {
            'task_type': task_type,
            'description': description,
            'parameters': parameters
        }
        
        try:
            response = await client.post(
                f"{self.config.orchestrator_url}/tasks",
                json=task_data
            )
            response.raise_for_status()
            return response.json()
        except Exception as e:
            self.logger.error(f"Error submitting task: {e}")
            raise
    
    async def get_task_status(self, task_id: str) -> Dict[str, Any]:
        """Get task status by ID"""
        client = await self.cli_manager._get_http_client()
        
        try:
            response = await client.get(f"{self.config.orchestrator_url}/tasks/{task_id}")
            response.raise_for_status()
            return response.json()
        except Exception as e:
            self.logger.error(f"Error getting task status: {e}")
            raise
    
    async def generate_response(self, model: str, prompt: str, 
                              parameters: Dict[str, Any]) -> Dict[str, Any]:
        """Generate response using model gateway"""
        client = await self.cli_manager._get_http_client()
        
        request_data = {
            'model': model,
            'prompt': prompt,
            'stream': False,
            'parameters': parameters
        }
        
        try:
            response = await client.post(
                f"{self.config.model_gateway_url}/generate",
                json=request_data
            )
            response.raise_for_status()
            return response.json()
        except Exception as e:
            self.logger.error(f"Error generating response: {e}")
            raise

async def main():
    """Main CLI entry point"""
    cli_manager = CLIManager()
    parser = CommandParser(cli_manager)
    api_client = APIClient(cli_manager)
    
    try:
        args = parser.parse_args()
        
        # Update config based on args
        if args.verbose:
            cli_manager.config.verbose = True
            cli_manager.logger.setLevel(logging.DEBUG)
        
        if args.no_color:
            cli_manager.config.color_output = False
        
        # Handle commands
        if not args.command:
            parser.parser.print_help()
            return
        
        if args.command == 'query':
            await handle_query_command(args, cli_manager, api_client)
        elif args.command == 'config':
            await handle_config_command(args, cli_manager)
        elif args.command == 'status':
            await handle_status_command(args, cli_manager, api_client)
        elif args.command == 'tui':
            await handle_tui_command(args, cli_manager)
        else:
            print(f"Command '{args.command}' is not yet implemented.")
            print("This is part of the iterative development process.")
    
    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
    except Exception as e:
        print(f"Error: {e}")
        cli_manager.logger.error(f"CLI error: {e}")
    finally:
        await cli_manager.close()

# Command handlers (to be implemented in following steps)
async def handle_query_command(args, cli_manager, api_client):
    """Handle query command"""
    print(f"Query: {args.prompt}")
    print("This command will be fully implemented in the next iteration.")

async def handle_config_command(args, cli_manager):
    """Handle configuration command"""
    if args.show:
        print(yaml.dump(asdict(cli_manager.config), default_flow_style=False))
    else:
        print("Configuration management will be implemented in the next iteration.")

async def handle_status_command(args, cli_manager, api_client):
    """Handle status command"""
    print("Checking system status...")
    health = await api_client.health_check()
    
    for service, status in health.items():
        status_icon = "✅" if status.get('status') == 'healthy' else "❌"
        print(f"{status_icon} {service}: {status.get('status', 'unknown')}")

async def handle_tui_command(args, cli_manager):
    """Handle TUI command"""
    print("Terminal UI will be implemented in requirement 5.")
    print("This requires additional input from you for UI specifications.")

if __name__ == "__main__":
    asyncio.run(main())