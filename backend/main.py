import uvicorn
import logging
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

from controller.users import router as users_router

logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)

app = FastAPI(
    title="Agribot API",
    description="Backend API untuk Chatbot Agribot berbasis AI",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Tangkap semua HTTP error dan log
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger = logging.getLogger("exception_handler")
    logger.error(f"Unhandled error on {request.method} {request.url} → {exc}")
    return JSONResponse(
        status_code=500,
        content={"success": False, "message": "Internal server error"}
    )

app.include_router(users_router)

@app.get("/", tags=["Root"])
async def root():
    return {
        "status": "online",
        "message": "Agribot Backend is running successfully",
        "agent": "FastAPI"
    }

if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)