FROM python:3.12-slim

WORKDIR /app

# Install deps first for better layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the controller code
COPY handler.py .
COPY lib/ ./lib/
COPY templates/ ./templates/

# Default environment — override in the Deployment
ENV LAB_REGISTRY="registry.lab.local"
ENV LAB_IMAGE_TAG="v1"
ENV PYTHONUNBUFFERED=1

# kopf has a built-in entrypoint
CMD ["kopf", "run", "--standalone", "handler.py", "--verbose"]
