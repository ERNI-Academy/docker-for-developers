# Docker for Developers

A concentrate of best practice, commands, troubleshooting, tips and tricks related to docker and docker compose, from a developers' point of view.

- [Docker for Developers](#docker-for-developers)
  - [Quick Commands](#quick-commands)
    - [Containers \& Images](#containers--images)
    - [Compose Syntax](#compose-syntax)
    - [Cleanup (reclaim space)](#cleanup-reclaim-space)
  - [Example compose file](#example-compose-file)
  - [Dockerfile](#dockerfile)
  - [Hot Reloading](#hot-reloading)
  - [Environment \& Secrets](#environment--secrets)
  - [Networking That Just Works](#networking-that-just-works)
    - [What networks exist in dev?](#what-networks-exist-in-dev)
    - [Which one should I use?](#which-one-should-i-use)
    - [Reaching the host from a container](#reaching-the-host-from-a-container)
    - [Publishing ports - What actually happens?](#publishing-ports---what-actually-happens)
    - [Useful checks](#useful-checks)
  - [Health \& Startup Order](#health--startup-order)
  - [Common Recipes for this stack](#common-recipes-for-this-stack)
    - [Seed DB on first run](#seed-db-on-first-run)
    - [One-off DB admin (psql)](#one-off-db-admin-psql)
    - [Redis quick admin](#redis-quick-admin)
    - [Profiles (optional services)](#profiles-optional-services)
    - [Multi-file overlays (e.g. dev vs prod)](#multi-file-overlays-eg-dev-vs-prod)
  - [Troubleshooting Playbook (stack-specific)](#troubleshooting-playbook-stack-specific)
  - [Performance Tips](#performance-tips)
  - [Safety Checks](#safety-checks)
  - [Best Practices](#best-practices)
    - [Images \& Builds](#images--builds)
    - [Security \& Secrets](#security--secrets)
    - [Runtime \& Ops](#runtime--ops)
    - [Networking \& Data](#networking--data)
    - [Node-specific](#node-specific)
  - [Copy-Paste Starters](#copy-paste-starters)
    - [.env.example](#envexample)
    - [Healthchecks](#healthchecks)
    - [Inspect what Compose created](#inspect-what-compose-created)
    - [Minimal Express server with /health](#minimal-express-server-with-health)
    - [package.json scripts (dev/prod)](#packagejson-scripts-devprod)
  - [Quick tips](#quick-tips)

> **How to use this doc**
> - Skim **Quick Commands** and **Gotchas** before coding
> - Use **Recipes** when you need hot-reload, init data, or admin tasks
> - All examples target this stack: **Node app + Postgres + Redis + Adminer**

---

## Quick Commands

### Containers & Images
~~~bash
# List running containers
docker ps
docker ps -a # <--- Will also list stopped containers
docker ps -q # <--- List only container IDs (useful for batch-processing, e.g. docker rm -f $(docker ps -qa) force-removes ALL containers)

# List images
docker image ls
docker image ls -q # <--- Returns all image IDs

# Start / stop / remove container(s)
docker start <name|id>
docker stop <name|id>
docker rm <name|id>

# Shell into a running container
docker exec -it <name|id> bash   # Or whichever available shell there is, like sh, or ash

# Logs (live-streaming)
docker logs -f <name|id>

# Inspect (ports, env, mounts, networks)
docker inspect <name|id> | jq . # Requires JQ for working with JSON objects. Can be done away with
~~~

### Compose Syntax
~~~bash
# Bring stack up (build if needed) / detached
docker compose up --build
docker compose up -d

# Stop & remove containers + network (keeps named volumes)
docker compose down

# Also remove named volumes (‼️ deletes data!)
docker compose down -v

# List services / logs / run a command inside a service
docker compose ps
docker compose logs -f
docker compose exec app sh

# Rebuild images without starting
docker compose build

# Scale a service (e.g., workers)
docker compose up -d --scale app=2
~~~

### Cleanup (reclaim space)
~~~bash
# Remove dangling images
docker image prune

# Remove stopped containers, networks, build cache (prompts)
docker system prune

# Include unused volumes too (⚠ data loss for unused volumes)
docker system prune -a --volumes
~~~

> **Tip:** If things get weird: `docker compose down`, then `docker compose up --build`.

---

## Example compose file

This is the [best practices version of the stack here mentioned](./docker-compose.yml).

---

## Dockerfile

Use a lean multi-stage build. For dev hot-reload we’ll override the `command` and mount the code (see next section).

~~~dockerfile
# Dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
# Install only production deps by default; dev flow uses override
COPY package*.json ./
RUN npm ci

FROM node:20-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# If you have a build step (TypeScript, bundlers), run it here:
# RUN npm run build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app ./
EXPOSE 3000
CMD ["npm", "start"]
~~~

> If you use TypeScript:
> - Add `RUN npm run build` in the build stage
> - Set `CMD ["node", "dist/index.js"]` or keep `npm start` if your script runs it

---

## Hot Reloading

Bind-mount the source and run a watch command (e.g., `nodemon` or `npm run dev`). Keep large folders out via `.dockerignore`.

~~~yaml
# docker-compose.override.yml  (dev-only overrides)
services:
  app:
    command: npm run dev
    working_dir: /app
    volumes:
      - ./:/app
      # optionally mount a separate, writeable node_modules cache:
      # - app-node-modules:/app/node_modules
    environment:
      - NODE_ENV=development

# volumes:
#   app-node-modules:
~~~

`.dockerignore` essentials:
~~~text
.git
node_modules
npm-debug.log*
yarn-error.log*
dist
.build
.tmp
coverage
.DS_Store
~~~

> **Gotcha:** On macOS/Windows, huge bind mounts can be slow. Mount only what you need and keep dependencies inside the container.

---

## Environment & Secrets

Create a `.env` for local dev and a `.env.example` for the repo.

~~~bash
# .env.example
APP_PORT=3000
NODE_ENV=development

DB_HOST=postgres
DB_PORT=5432
DB_NAME=myapp
DB_USER=postgres
DB_PASSWORD=example

REDIS_HOST=redis
REDIS_PORT=6379
~~~

Compose auto-loads `.env` in the same directory. Do **not** commit real secrets; inject them in CI/CD or keep them local.

---

## Networking That Just Works

### What networks exist in dev?

- **User-defined bridge networks (recommended)**
  This is what Compose creates by default (e.g., `<project>_default`) and what we explicitly use here (`app-network`, `backend-network`). Containers on the same user-defined bridge get **automatic DNS**: you can reach `postgres` and `redis` by those **service names**. Isolation is per-network

- **Default bridge – legacy**
  The engine ships with a network called `bridge`. It **does not provide DNS-based service discovery** like user-defined bridges do. Prefer Compose’s user-defined bridges for development. (On Linux, the `bridge` gateway is often `172.17.0.1`)

- **Host network – Linux-only**
  Shares the host’s network namespace. No port publishing (`ports:` is ignored), no isolation, and easy port conflicts. **Not supported on Docker Desktop** for macOS/Windows with Linux containers. Avoid for multi-service dev; use only for niche cases (low-level networking, perf tests)

- **none**
  No networking at all (air‑gapped container). Rarely used for app dev

### Which one should I use?

- **Use user-defined bridge networks from Compose.**
  Keep internal services (DB/Redis) on a private network (e.g., `backend-network`). Put the app on both `app-network` (for future frontends) **and** `backend-network` (to reach DB/Redis). **Only publish the app’s port** to the host; don’t publish DB/Redis

- **Service name ≠ localhost.**
  Inside containers, use **service names** (`postgres:5432`, `redis:6379`). From your **host**, use `localhost:<published-port>` (e.g., `http://localhost:3000`)

### Reaching the host from a container

- **Docker Desktop (macOS/Windows):** use `host.docker.internal`
- **Linux:** add the host-gateway alias

~~~yaml
services:
  app:
    extra_hosts:
      - host.docker.internal:host-gateway
~~~

Now anything in the container can talk to services on your host via `host.docker.internal` (e.g., hitting a local SMTP/dev server).

### Publishing ports - What actually happens?

- `ports: ["3000:3000"]` ⇒ host TCP 3000 → container TCP 3000. The **left** side is the **host** port
- `ports: ["3000"]` ⇒ publish container TCP 3000 to a **random** host port (useful for parallel test runs)
- Port clashes? Change the **host** side (`8081:3000`) or run with a different project name `-p`

### Useful checks

~~~bash
# List and inspect networks
docker network ls
docker network inspect <project>_backend-network
docker network inspect bridge         # the default docker0 bridge (legacy)

# See where app is published and verify
docker compose ps
docker compose port app 3000          # shows mapped host port
curl -I http://localhost:3000         # from the host

# From inside the app container
docker compose exec app sh -lc "getent hosts postgres redis || true; ping -c1 postgres || true"
~~~

---

## Health & Startup Order

`depends_on.condition: service_healthy` requires the dependency to have a `healthcheck`.

- **App:** simple HTTP health at `/health` (already in compose)
- **Postgres:** `pg_isready` (already in compose)
- **Redis:** `redis-cli ping` (already in compose)

Still racing? Add retry logic in the app’s startup (recommended) or a tiny “wait-for” script.

---

## Common Recipes for this stack

### Seed DB on first run
Put `.sql` files in `./init-scripts`. Postgres runs them on first init.

~~~sql
-- ./init-scripts/001_schema.sql
CREATE TABLE IF NOT EXISTS todos (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  done BOOLEAN NOT NULL DEFAULT FALSE
);
-- ./init-scripts/010_seed.sql
INSERT INTO todos (title, done) VALUES
('Learn Compose', false),
('Wire up Redis cache', false);
~~~

### One-off DB admin (psql)
~~~bash
# Open psql inside the Postgres container (uses container localhost)
docker compose exec -e PGPASSWORD=$DB_PASSWORD postgres   psql -U $DB_USER -d $DB_NAME -h 127.0.0.1 -p 5432

# Dump/restore examples
docker compose exec -e PGPASSWORD=$DB_PASSWORD postgres   pg_dump -U $DB_USER -d $DB_NAME > dump.sql

docker compose exec -e PGPASSWORD=$DB_PASSWORD postgres   psql -U $DB_USER -d $DB_NAME -f /var/lib/postgresql/dump.sql
~~~

### Redis quick admin
~~~bash
docker compose exec redis redis-cli ping
docker compose exec redis redis-cli keys '*'
docker compose exec redis redis-cli flushdb   # ⚠ clears current DB
~~~

### Profiles (optional services)
Enable tools only on demand.

~~~yaml
# example: only run Adminer with a "tools" profile
services:
  adminer:
    profiles: ["tools"]

# run: docker compose --profile tools up -d
~~~

### Multi-file overlays (e.g. dev vs prod)
~~~bash
# Base + prod overlay
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
~~~

---

## Troubleshooting Playbook (stack-specific)

1) **Read the error** (build vs runtime).
2) **Check logs**:
~~~bash
docker compose logs -f app
docker compose logs -f postgres
docker compose logs -f redis
~~~
3) **Container exits immediately?** Run foreground (no `-d`) to see output.
4) **Connectivity test from app**:
~~~bash
docker compose exec app sh -lc "apk add --no-cache curl netcat-openbsd || true; nc -zv postgres 5432; nc -zv redis 6379"
~~~
5) **Network membership**:
~~~bash
docker network inspect <stack>_backend-network
~~~
6) **Port conflict** (e.g., 3000 in use): change the **left** side of `host:container`.
7) **Hot-reload not updating**: check the mount path, `npm run dev` / `nodemon` running, and `.dockerignore`.
8) **Volumes stuck**: remove containers, keep volumes (`down`), or reset volumes cautiously (`down -v`).
9) **Rebuild from scratch**:
~~~bash
docker compose build --no-cache
docker compose down -v && docker compose up --build
~~~

---

## Performance Tips

- Keep images **lean** (Alpine base, `npm ci`, multi-stage builds, `.dockerignore`)
- Mount only what you need for dev. Avoid mounting `node_modules` from host on macOS/Windows
- If needed, use a named volume for `node_modules` managed in-container
- Don’t run heavy admin containers unless needed (use **profiles**)

---

## Safety Checks

- Don’t commit real secrets; provide a `.env.example`
- Be cautious with `docker compose down -v` and `docker system prune --volumes` (data loss!)

## Best Practices

### Images & Builds
- **Pin base images** by major/minor (avoid `latest`) for reproducibility. Example: `node:20-alpine`
- **Multi-stage builds**: compile in one stage, copy only runtime artifacts to the final image
- **Keep contexts small** with a solid `.dockerignore` (no `node_modules`, build output, VCS, logs)
- **Deterministic installs**: use `npm ci` and commit `package-lock.json`
- **Run as non-root** where possible to reduce blast radius security-wise

~~~dockerfile
# Example: non-root + tini (PID 1) for proper signal handling
FROM node:20-alpine
RUN addgroup -S app && adduser -S app -G app \
  && apk add --no-cache tini
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
EXPOSE 3000
USER app
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["npm", "start"]
~~~

> **Why tini?** PID 1 in containers ignores signals by default; `tini` (or `--init` in Compose) forwards signals so your app exits cleanly.

### Security & Secrets
- **Never bake secrets** into images; use env vars or mounted files. Don’t commit real `.env` values—ship a `.env.example`
- **Limit container privileges** when feasible:
  - Read-only FS, drop capabilities, no-new-privileges
  - `Avoid mounting the Docker socket into app containers`

~~~yaml
services:
  app:
    # For local dev you can enable some of these gradually
    read_only: false          # set true if your app writes only to writable mounts
    security_opt:
      - no-new-privileges:true
    cap_drop: ["ALL"]        # add back only what you need
    tmpfs: ["/tmp"]
    # init forwards signals like tini would
    init: true
~~~

### Runtime & Ops
- **Healthchecks** for key services (`/health`, `pg_isready`, `redis-cli ping`). Gate startup with `depends_on.condition: service_healthy`
- **Logs**: use structured logs; rotate the default driver to avoid disk bloat

~~~yaml
services:
  app:
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
~~~

- **Resource limits**: if you need limits in production, configure them in the orchestrator (K8s/Swarm). Compose’s `deploy.resources` is ignored outside Swarm; for local testing prefer OS/Docker Desktop limits or run-time flags
- **Image scanning** in CI with tools like Trivy or Docker Scout; fix CVEs by updating bases and deps

### Networking & Data
- Keep a **private backend network** for DB/cache; only expose the **app** port to the host
- Prefer **named volumes** for stateful services (Postgres/Redis). Avoid bind-mounting their data directories from your host
- Use **profiles** to enable optional tools (e.g., Adminer) only when needed

~~~yaml
services:
  adminer:
    profiles: ["tools"]
# run with: docker compose --profile tools up -d
~~~

### Node-specific
- Track **LTS Node** versions and update regularly
- For hot-reload, prefer **bind mounts + `npm run dev`**; avoid mounting host `node_modules` (slow on macOS/Windows)
- If you need native addons, perform builds in a **builder stage** with required toolchains, then copy only the result to the runtime image

~~~dockerfile
# Builder for native deps
FROM node:20-alpine AS builder
RUN apk add --no-cache python3 make g++
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Runtime
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app ./
ENV NODE_ENV=production
CMD ["node", "server.js"]
~~~

---

## Copy-Paste Starters

### .env.example
~~~bash
APP_PORT=3000
NODE_ENV=development

DB_HOST=postgres
DB_PORT=5432
DB_NAME=myapp
DB_USER=postgres
DB_PASSWORD=example

REDIS_HOST=redis
REDIS_PORT=6379
~~~

### Healthchecks
~~~yaml
healthcheck:
  test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
  interval: 30s
  timeout: 3s
  retries: 3
  start_period: 5s
~~~

### Inspect what Compose created
~~~bash
docker compose ps
docker compose ls
docker network ls
docker volume ls
~~~

### Minimal Express server with /health
~~~javascript
// server.js
import express from "express";
const app = express();
app.get("/health", (req, res) => res.send("ok"));
app.get("/", (req, res) => res.json({ hello: "world" }));
app.listen(3000, () => console.log("API on 3000"));
~~~

### package.json scripts (dev/prod)
~~~json
{
  "scripts": {
    "dev": "nodemon --legacy-watch server.js",
    "start": "node server.js"
  }
}
~~~

---

## Quick tips

- **“App can’t reach Postgres.”**
  Use hostname `postgres` and port `5432` inside the Compose network; confirm with `nc -zv postgres 5432`

- **“Code changes don’t show up.”**
  Use the dev override (bind-mount + `npm run dev`), or rebuild with `docker compose up --build`

- **“I need to inspect DB.”**
  Open Adminer on `http://localhost:8080` (System: PostgreSQL, Server: `postgres`, User: `postgres`, Password: from `.env`, DB: `myapp`)

- **“Multiple stacks?”**
  Use separate folders or a project name: `docker compose -p myproj up -d`

---

>  When stuck: **logs first**, then **networks/ports**, then **mounts/env**, then **rebuild**.
