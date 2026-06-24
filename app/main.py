import socket

from fastapi import FastAPI

app = FastAPI(title="Floci ECS Fargate Dummy Service")


@app.get("/")
def read_root():
    return {
        "message": "Hello from FastAPI running on Floci ECS Fargate!",
        "hostname": socket.gethostname(),
    }


@app.get("/health")
def health_check():
    return {"status": "ok"}
