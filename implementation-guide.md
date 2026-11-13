# Implementation Guide MicroCRM Deployment

> **Purpose:** Step-by-step instructions to build Docker images, configure the
> environment, and run the entire MicroCRM stack with Docker Compose.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Environment Variables Reference](#3-environment-variables-reference)
4. [Building Docker Images](#4-building-docker-images)
5. [PostgreSQL Database Setup](#5-postgresql--database-setup)
6. [Docker Compose Full Stack](#6-docker-compose--full-stack)
7. [Running the Stack](#7-running-the-stack)
8. [Verification](#8-verification)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Architecture Overview

```
                    ┌──────────────────────┐
                    │      Internet        │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ Frontend (Next.js)   │  Port 3000
                    │ image: frontend      │
                    │                      │
                    │  ┌───────────────┐   │
                    │  │ Rewrite Proxy │   │  ← /api/* → backend
                    │  └──────┬────────┘   │
                    └─────────┼────────────┘
                              │  proxied to api:4000
                              │  (Docker internal DNS)
                    ┌─────────▼────────────┐
                    │ API Service          │  Port 4000
                    │ image: api           │
                    │ (Next.js API)        │
                    └───────┬─────────────┘
                            │
             ┌──────────────┴──────────────┐
             │                             │
   ┌─────────▼────────┐       ┌────────────▼─────────┐
   │ PostgreSQL       │       │ Notification Service │
   │ Port 5432        │       │ Port 5000            │
   │ DB: crm          │       │ Express.js           │
   └──────────────────┘       │ image: notif-svc     │
                              └──────────────────────┘
```

| Service | Technology | Container Port | Host Port | Docker Image Name |
|---|---|---|---|---|
| Frontend | Next.js (App Router) | 3000 | 3000 | `frontend` |
| API Service | Next.js (API routes) | 4000 | 4000 | `api` |
| Notification Service | Node.js + Express | 5000 | 5000 | `notification-service` |
| PostgreSQL | PostgreSQL | 5432 | 5432 | `postgres:16-alpine` |

---

## 2. Prerequisites

- **Docker** and **Docker Compose** installed
- Git repository cloned: `CRM-MS-DevOps/`
- Terminal open at the repository root

```bash
git clone https://github.com/MoHussam-865/CRM-MS-DevOps
cd CRM-MS-DevOps
```

---

## 3. Environment Variables Reference

All environment variables consumed by each service. **Required** variables must be
set in the Docker Compose file. Variables with defaults are optional but listed for
awareness.

### 3.1 Frontend

| Variable | Required | Docker Value | Description |
|---|---|---|---|
| `API_URL` | **Yes** | `http://api:4000` | Backend API URL used by the Next.js rewrite proxy (server-side only) |

> `API_URL` is a **runtime environment variable** read only by the Next.js server
> during `async rewrites()` in `next.config.ts`. It is **not** prefixed with
> `NEXT_PUBLIC_`, so it stays out of the client-side JavaScript bundle. The browser
> never directly calls the API — it calls `/api/*` on the same origin, and the
> Next.js server proxies those requests to the backend.

| Old approach (replaced) | New approach (current) |
|---|---|
| `NEXT_PUBLIC_API_URL=http://192.168.1.35:4000`  →  client calls API directly | `API_URL=http://api:4000`  →  Next.js rewrite proxy handles API calls |
| Browser must resolve the API hostname (problematic in Docker) | Browser only talks to its own origin (localhost:3000) |
| Rebuild required when changing the host | Change env var at runtime, restart container |

### 3.2 API Service

| Variable | Required | Docker Value | Description |
|---|---|---|---|
| `PORT` | No (default: `4000`) | `4000` | Port the service listens on |
| `DATABASE_URL` | **Yes** | `postgresql://user:password@postgres:5432/crm` | PostgreSQL connection string |
| `NOTIFICATION_SERVICE_URL` | **Yes** | `http://notification-service:5000` | Notification service base URL |
| `JWT_SECRET` | **Yes** | Pick a strong random string | Secret key for signing JWTs |
| `ADMIN_EMAIL` | No (default: `admin@crm.local`) | `admin@crm.local` | Email of seeded admin user |
| `ADMIN_PASSWORD` | No (default: `admin123`) | `admin123` | Password of seeded admin user |

### 3.3 Notification Service

| Variable | Required | Docker Value | Description |
|---|---|---|---|
| `PORT` | No (default: `5000`) | `5000` | Port the service listens on |
| `DATABASE_URL` | **Yes** | `postgresql://user:password@postgres:5432/crm` | PostgreSQL connection string |

### 3.4 PostgreSQL (Docker Hub `postgres:16-alpine`)

| Variable | Required | Description |
|---|---|---|
| `POSTGRES_USER` | **Yes** | Database user (e.g. `user`) |
| `POSTGRES_PASSWORD` | **Yes** | Database password (e.g. `password`) |
| `POSTGRES_DB` | **Yes** | Database name (e.g. `crm`) |

> When you set `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` on the
> `postgres` container, the official PostgreSQL image **automatically** creates the
> database, the user, and sets the password on first startup. You do **not** need to
> run `CREATE DATABASE` or `CREATE USER` manually.

---

## 4. Building Docker Images

Build each image from the repository root. The image names (`frontend`, `api`,
`notification-service`) match the service names used in Docker Compose.

### 4.1 Frontend

```bash
docker build -t frontend ./frontend
```

### 4.2 API Service

```bash
docker build -t api ./api-service
```

### 4.3 Notification Service

```bash
docker build -t notification-service ./notification-service
```

### 4.4 Build all at once

```bash
docker build -t frontend ./frontend && \
docker build -t api ./api-service && \
docker build -t notification-service ./notification-service
```

### 4.5 Image details

| Image | Base | Stages | Runs as |
|---|---|---|---|
| `frontend` | `node:20-alpine` | 2 (builder â†’ runner) | `node` user |
| `api` | `node:20-alpine` | 2 (builder â†’ runner) | `node` user |
| `notification-service` | `node:22-alpine` | 2 (builder â†’ runner) | `appuser` (non-root) |

---

## 5. PostgreSQL Database Setup

The PostgreSQL database is provided by the official Docker Hub image
`postgres:16-alpine`. No manual setup is required the official image handles
everything via environment variables.

### 5.1 What the official image does automatically

When the `postgres` container starts for the **first time** (empty data directory),
it automatically:

1. Creates the database named by `POSTGRES_DB` (e.g. `crm`)
2. Creates the user named by `POSTGRES_USER` (e.g. `user`)
3. Sets the user's password to `POSTGRES_PASSWORD`
4. Grants the user full access to the database

**You do NOT need to run `CREATE DATABASE crm` or `CREATE USER` manually.**

### 5.2 What the application services do on startup

Each service runs its own database migrations automatically when it starts:

| Service | Migration file | Tables created |
|---|---|---|
| **API Service** | `lib/migrations/001_init.sql` | `users`, `companies`, `customers`, `tasks` + seed admin user |
| **Notification Service** | `src/migrations/001_create_notifications.sql` | `notifications` |

All migrations use `CREATE TABLE IF NOT EXISTS` / `CREATE EXTENSION IF NOT EXISTS`,
so they are **idempotent** safe to run multiple times.

### 5.3 Database schema summary

```
Database: crm

├── users
│   └── (id, email, password_hash, name, created_at)
│
├── companies
│   └── (id, name, industry, phone, website, created_at)
│
├── customers
│   └── (id, company_id → companies, name, email, phone, position, status, created_at)
│
├── tasks
│   └── (id, customer_id → customers, title, description, priority, status, due_date, created_at)
│
└── notifications
    └── (id, title, message, created_at)
```

### 5.4 Enabling the pgcrypto extension

The API service migration (`001_init.sql`) includes:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

This extension is needed for hashing the admin user's password (`gen_random_uuid()`,
`crypt()`, `gen_salt()`). The `pgcrypto` extension comes **built-in** with the
official PostgreSQL image no extra setup needed.

### 5.5 Data persistence

A named volume (`postgres_data`) is mounted at `/var/lib/postgresql/data` in the
container to persist data across container restarts and removals.

---

## 6. Docker Compose Full Stack

file named `docker-compose.yml` at the repository root (`CRM-MS-DevOps/`).


### 6.1 Port mapping summary

| Service | Host Port | Container Port | Access URL (local) |
|---|---|---|---|
| Frontend | 3000 | 3000 | `http://localhost:3000` |
| API Service | 4000 | 4000 | `http://localhost:4000` |
| Notification Service | 5000 | 5000 | `http://localhost:5000` |
| PostgreSQL | 5432 | 5432 | `localhost:5432` (for DB tools) |

### 6.2 Startup order & health checks

- **PostgreSQL** starts first with a health check (`pg_isready`)
- **Notification Service** starts after PostgreSQL is healthy (`service_healthy`)
- **API Service** starts after PostgreSQL is healthy and notification-service has started
- **Frontend** starts after the API service (`depends_on: api`)

### 6.3 Customizing values

Change these to match your environment:

| Variable | Where to set | Notes |
|---|---|---|
| Database password | `POSTGRES_PASSWORD` in `postgres` + `DATABASE_URL` in `api` and `notification-service` | Must match in all three places |
| JWT secret | `JWT_SECRET` in `api` | Use a strong random string |
| Admin email / password | `ADMIN_EMAIL` / `ADMIN_PASSWORD` in `api` | Only used on first run (seed) |
| API URL for frontend | `API_URL` in `frontend` | `http://api:4000` for Docker |

---

## 7. Running the Stack

### 7.1 Start everything

```bash
# From the repository root
docker compose up -d
```

The `-d` flag runs containers in detached mode (background).

### 7.2 View logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f api
docker compose logs -f frontend
docker compose logs -f notification-service
docker compose logs -f postgres
```

### 7.3 Stop everything

```bash
docker compose down
```

### 7.4 Stop and remove volumes (reset database)

```bash
docker compose down -v
```

> note: `-v` deletes the `postgres_data` volume all data will be lost. Use only if you
> want a fresh start.

### 7.5 Rebuild images after code changes

```bash
# Rebuild and restart
docker compose up -d --build

# Or rebuild a specific service
docker compose build api
docker compose up -d api
```

---

## 8. Verification

### 8.1 Check all containers are running

```bash
docker compose ps
```

Expected: 4 services with `Up` status.

### 8.2 Test the API health endpoint

```bash
curl http://localhost:4000/api/health
```

Expected: `{"status":"ok"}`

### 8.3 Test Notification Service health

```bash
curl http://localhost:5000/health
```

Expected: `{"status":"ok"}`

### 8.4 Test login

```bash
curl -X POST http://localhost:4000/api/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"admin@crm.local\",\"password\":\"admin123\"}"
```

Expected: `{"success":true,"data":{"token":"...","user":{...}}}`

### 8.5 Open the frontend

Navigate to **http://localhost:3000** in your browser.

- Login screen should appear
- Login with `admin@crm.local` / `admin123`
- Dashboard, Companies, Customers, Tasks, Notifications, Profile should all be accessible

---

## 9. Troubleshooting

### 9.1 API calls failing from the browser (404, DNS errors)

With Next.js Rewrites, the browser **never directly calls the API backend** — it
makes requests to `/api/*` on its own origin (port 3000), and the Next.js server
proxies them to the backend using the internal Docker hostname `api:4000`.

If API calls fail from the browser:

- **404 errors** → The rewrite is likely not matching. Check `docker compose logs frontend`
  for rewrite activity. Ensure the frontend's `next.config.ts` includes the `async rewrites()` block.
- **Connection refused** → Ensure the `api` container is healthy: `docker compose ps api`.
  The frontend depends on the API service, but if the API isn't up yet, the frontend
  may start first. Restart the frontend: `docker compose restart frontend`.
- **Wrong backend URL** → Verify the frontend's `API_URL` env var in Compose is
  set to `http://api:4000`. This is a **server-side runtime variable**, not a
  client-side build-time variable, so you can change it and restart without rebuilding.

### 9.2 Database connection errors

```
Error: connect ECONNREFUSED 127.0.0.1:5432
```

- Ensure PostgreSQL container is healthy: `docker compose ps postgres`
- Check logs: `docker compose logs postgres`
- Wait a few seconds after first start PostgreSQL takes time to initialize

### 9.3 Migration runs but tables don't exist

Both services run migrations on startup. If a migration fails:

- Check the service logs: `docker compose logs api`
- Ensure `pgcrypto` extension loaded successfully (API service only)
- Restart the service: `docker compose restart api`

### 9.4 Port already in use

If ports 3000, 4000, 5000, or 5432 are already in use:

- Stop the conflicting process
- Or change the host-side port in `docker-compose.yml` (e.g. `"3001:3000"`)

### 9.5 Docker image rebuild needed

After any code change to a service:

```bash
docker compose up -d --build
```

### 9.6 Notification service is down but API still works

This is **expected behavior**. The API service calls the notification service as
**fire-and-forget** if it's down, the error is logged but the API request does
not fail. Notifications simply won't be created until the service is back up.

---

## Quick Reference Card

```bash
# -- Build all images --
docker build --build-arg NEXT_PUBLIC_API_URL=http://192.168.1.35:4000 -t frontend ./frontend
docker build -t api ./api-service
docker build -t notification-service ./notification-service

# -- Start the stack --
docker compose up -d

# -- View status --
docker compose ps
docker compose logs -f

# -- Stop the stack --
docker compose down

# -- Full reset (destroy data) --
docker compose down -v

# -- Rebuild & restart --
docker compose up -d --build

# -- Access --
# Frontend:  http://localhost:3000
# API:       http://localhost:4000
# Notif:     http://localhost:5000/health
# Login:     admin@crm.local / admin123
```
