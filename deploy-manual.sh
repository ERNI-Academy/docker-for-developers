#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Creating Docker networks...${NC}"
docker network create app-network
docker network create backend-network

echo -e "${BLUE}Creating Docker volumes...${NC}"
docker volume create postgres-data
docker volume create redis-data

echo -e "${BLUE}Building the application image...${NC}"
docker build -t example-app .

echo -e "${BLUE}Starting PostgreSQL...${NC}"

docker run -d \
    --name postgres \
    --network backend-network \
    -v postgres-data:/var/lib/postgresql/data \
    -v "$(pwd)/init-scripts:/docker-entrypoint-initdb.d" \
    -e POSTGRES_DB=${DB_NAME:-myapp} \
    -e POSTGRES_USER=${DB_USER:-postgres} \
    -e POSTGRES_PASSWORD=${DB_PASSWORD:-example} \
    --health-cmd="pg_isready -U ${DB_USER:-postgres}" \
    --health-interval=10s \
    --health-timeout=5s \
    --health-retries=5 \
    --health-start-period=10s \
    postgres:15-alpine

echo -e "${BLUE}Starting Redis...${NC}"
docker run -d \
    --name redis \
    --network backend-network \
    -v redis-data:/data \
    --health-cmd="redis-cli ping" \
    --health-interval=10s \
    --health-timeout=5s \
    --health-retries=5 \
    --health-start-period=10s \
    redis:7-alpine

echo -e "${BLUE}Waiting for PostgreSQL to be ready...${NC}"
while ! docker exec postgres pg_isready -U ${DB_USER:-postgres} > /dev/null 2>&1; do
    echo "Waiting for PostgreSQL to be ready..."
    sleep 2
done

echo -e "${BLUE}Waiting for Redis to be ready...${NC}"
while ! docker exec redis redis-cli ping > /dev/null 2>&1; do
    echo "Waiting for Redis to be ready..."
    sleep 2
done

echo -e "${BLUE}Starting the application...${NC}"
docker run -d \
    --name app \
    --network app-network \
    -p "${APP_PORT:-3000}:3000" \
    -e NODE_ENV=${NODE_ENV:-development} \
    -e DB_HOST=postgres \
    -e DB_PORT=5432 \
    -e DB_NAME=${DB_NAME:-myapp} \
    -e DB_USER=${DB_USER:-postgres} \
    -e DB_PASSWORD=${DB_PASSWORD:-example} \
    -e REDIS_HOST=redis \
    -e REDIS_PORT=6379 \
    --health-cmd="wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1" \
    --health-interval=30s \
    --health-timeout=3s \
    --health-retries=3 \
    --health-start-period=5s \
    example-app

# Connect app container to backend network so it can reach postgres and redis
docker network connect backend-network app

echo -e "${BLUE}Starting Adminer (Development Only)...${NC}"
docker run -d \
    --name adminer \
    --network backend-network \
    -p "8080:8080" \
    adminer:latest

echo -e "${GREEN}All services have been started!${NC}"
echo -e "${GREEN}You can access:${NC}"
echo -e "- Application: http://localhost:${APP_PORT:-3000}"
echo -e "- Adminer: http://localhost:8080"

# Print container status
echo -e "\n${BLUE}Container Status:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Function to clean up containers, networks, and volumes
cleanup() {
    echo -e "\n${BLUE}Cleaning up containers...${NC}"
    docker rm -f app postgres redis adminer 2>/dev/null
    echo -e "${BLUE}Removing networks...${NC}"
    docker network rm app-network backend-network 2>/dev/null
    echo -e "${BLUE}Removing volumes...${NC}"
    docker volume rm postgres-data redis-data 2>/dev/null
}

echo -e "\n${BLUE}To clean up all resources, run:${NC}"
echo "./$(basename $0) cleanup"

# Check if cleanup argument is provided
if [ "$1" == "cleanup" ]; then
    cleanup
fi
