#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# MONIHOOK — Script de Instalação Completa
# Versão: 1.0.0
# Compatível: Ubuntu 22.04+, Debian 12+
# ═══════════════════════════════════════════════════════════════════
set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

MONIHOOK_DIR="/opt/monihook"
MONIHOOK_VERSION="1.0.0"

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   ███╗   ███╗ ██████╗ ███╗   ██╗██╗██╗  ██╗ ██████╗  ██████╗  ██╗  ██╗ ║"
    echo "║   ████╗ ████║██╔═══██╗████╗  ██║██║██║ ██╔╝██╔═══██╗██╔═══██╗ ██║ ██╔╝ ║"
    echo "║   ██╔████╔██║██║   ██║██╔██╗ ██║██║█████╔╝ ██║   ██║██║   ██║ █████╔╝  ║"
    echo "║   ██║╚██╔╝██║██║   ██║██║╚██╗██║██║██╔═██╗ ██║   ██║██║   ██║██╔═██╗  ║"
    echo "║   ██║ ╚═╝ ██║╚██████╔╝██║ ╚████║██║██║  ██╗╚██████╔╝╚██████╔╝██║  ██╗ ║"
    echo "║   ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝ ║"
    echo "║                                                               ║"
    echo "║   Monitoramento de Serviços de Privacidade                    ║"
    echo "║   LGPD (Brasil) · GDPR (Europa)                              ║"
    echo "║                                                               ║"
    echo "║   v${MONIHOOK_VERSION}                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; }
log_step()    { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# ─── Verificações Iniciais ──────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Execute como root: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        log_info "Sistema detectado: $PRETTY_NAME"
    else
        log_error "Sistema operacional não suportado"
        exit 1
    fi
}

# ─── Instalar Dependências ──────────────────────────────────────
install_dependencies() {
    log_step "Instalando dependências do sistema"

    apt update -qq
    apt install -y -qq curl wget git unzip ufw ca-certificates gnupg lsb-release

    # Docker
    if ! command -v docker &> /dev/null; then
        log_info "Instalando Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        systemctl enable docker
        systemctl start docker
        rm /tmp/get-docker.sh
    else
        log_info "Docker já instalado: $(docker --version)"
    fi

    # Docker Compose
    if ! docker compose version &> /dev/null; then
        log_info "Instalando Docker Compose plugin..."
        apt install -y -qq docker-compose-plugin
    fi

    log_info "Docker Compose: $(docker compose version)"
}

# ─── Configurar Firewall ────────────────────────────────────────
setup_firewall() {
    log_step "Configurando firewall"

    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        log_info "Portas 22, 80, 443 liberadas"
    fi
}

# ─── Criar Estrutura do Projeto ─────────────────────────────────
create_project_structure() {
    log_step "Criando estrutura do projeto em ${MONIHOOK_DIR}"

    mkdir -p "${MONIHOOK_DIR}"/{backend/app/{models,schemas,routers,services,middleware,utils},backend/alembic/versions,frontend/{public,src/{contexts,services,components/{Auth,Layout,Dashboard,Privacy,Infrastructure,Tickets,Reports,Settings},utils}},database,nginx}

    log_info "Estrutura de pastas criada"
}

# ─── Gerar Arquivo .env ─────────────────────────────────────────
generate_env() {
    log_step "Gerando configuração de ambiente"

    # Gerar chaves aleatórias
    SECRET_KEY=$(openssl rand -hex 32)
    DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    ADMIN_PASSWORD="Admin@$(date +%Y)!Monihook"

    cat > "${MONIHOOK_DIR}/.env" << ENVEOF
# ═══════════════════════════════════════════════
# MONIHOOK - Configuração de Ambiente
# Gerado automaticamente em $(date)
# ═══════════════════════════════════════════════

# Banco de Dados PostgreSQL
DB_ENGINE=postgresql
DB_HOST=db
DB_PORT=5432
DB_NAME=monihook
DB_USER=monihook_user
DB_PASSWORD=${DB_PASSWORD}

# Segurança da Aplicação
SECRET_KEY=${SECRET_KEY}
JWT_ALGORITHM=HS256
JWT_EXPIRE_MINUTES=480
REFRESH_TOKEN_EXPIRE_DAYS=30

# Email (SMTP) — CONFIGURE SEUS DADOS
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=SEU_EMAIL@gmail.com
SMTP_PASSWORD=SUA_SENHA_DE_APP
SMTP_FROM=Monihook <noreply@seudominio.com.br>

# URLs — ALTERE PARA SEU DOMÍNIO
FRONTEND_URL=http://localhost
BACKEND_URL=http://localhost
GRAFANA_URL=https://dashboard.cmtech.com.br
PRIVACYTOOLS_BASE_URL=https://dpo.privacytools.com.br/external_api_v2

# Admin Inicial
ADMIN_EMAIL=admin@monihook.com.br
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_NAME=Administrador
ADMIN_COMPANY=Monihook Admin

# Redis
REDIS_URL=redis://redis:6379/0

# Portas
BACKEND_PORT=8000
FRONTEND_PORT=3000
ENVEOF

    chmod 600 "${MONIHOOK_DIR}/.env"

    # Salvar credenciais em arquivo seguro
    cat > "${MONIHOOK_DIR}/.credentials" << CREDEOF
══════════════════════════════════════════════════
 CREDENCIAIS DE ACESSO — MONIHOOK
 Gerado em: $(date)
══════════════════════════════════════════════════

  ACESSO ADMINISTRATIVO:
  URL:      http://$(hostname -I | awk '{print $1}')
  Email:    admin@monihook.com.br
  Senha:    ${ADMIN_PASSWORD}

  BANCO DE DADOS:
  Host:     localhost:5432
  Banco:    monihook
  Usuário:  monihook_user
  Senha:    ${DB_PASSWORD}

  CHAVE SECRETA JWT:
  ${SECRET_KEY}

══════════════════════════════════════════════════
 GUARDE ESTE ARQUIVO EM LOCAL SEGURO!
══════════════════════════════════════════════════
CREDEOF

    chmod 600 "${MONIHOOK_DIR}/.credentials"
    log_info "Arquivo .env gerado"
    log_info "Credenciais salvas em ${MONIHOOK_DIR}/.credentials"
}

# ─── docker-compose.yml ─────────────────────────────────────────
generate_docker_compose() {
    cat > "${MONIHOOK_DIR}/docker-compose.yml" << 'DCEOF'
version: "3.9"

services:
  db:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./database/init.sql:/docker-entrypoint-initdb.d/init.sql
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    restart: always
    env_file:
      - .env
    ports:
      - "${BACKEND_PORT}:8000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - uploaded_files:/app/uploads

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    restart: always
    ports:
      - "${FRONTEND_PORT}:80"
    depends_on:
      - backend

  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf
    depends_on:
      - frontend
      - backend

volumes:
  postgres_data:
  redis_data:
  uploaded_files:
DCEOF

    log_info "docker-compose.yml gerado"
}

# ─── database/init.sql ──────────────────────────────────────────
generate_init_sql() {
    cat > "${MONIHOOK_DIR}/database/init.sql" << 'SQLEOF'
-- ═══════════════════════════════════════════════════════════
-- MONIHOOK - Schema Inicial do Banco de Dados
-- ═══════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ENUMS
CREATE TYPE user_role AS ENUM ('super_admin', 'admin', 'manager', 'user', 'readonly');
CREATE TYPE platform_type AS ENUM ('privacytools', 'grafana', 'jira', 'servicedesk', 'custom');
CREATE TYPE report_period AS ENUM ('weekly', 'monthly', 'quarterly', 'semi_annual', 'annual', 'custom');
CREATE TYPE report_status AS ENUM ('pending', 'generating', 'completed', 'failed');
CREATE TYPE ticket_priority AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE ticket_status AS ENUM ('open', 'in_progress', 'waiting', 'resolved', 'closed');
CREATE TYPE incident_severity AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE consent_status AS ENUM ('active', 'withdrawn', 'expired');
CREATE TYPE dsar_status AS ENUM ('received', 'in_review', 'processing', 'completed', 'denied');
CREATE TYPE risk_level AS ENUM ('very_low', 'low', 'medium', 'high', 'very_high');
CREATE TYPE auth_status AS ENUM ('pending_2fa', 'active', 'locked', 'disabled');

-- TENANTS
CREATE TABLE tenants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(100) UNIQUE NOT NULL,
    domain VARCHAR(255),
    logo_url TEXT,
    favicon_url TEXT,
    primary_color VARCHAR(7) DEFAULT '#1B5E8C',
    secondary_color VARCHAR(7) DEFAULT '#E8A838',
    accent_color VARCHAR(7) DEFAULT '#2ECC71',
    theme_mode VARCHAR(10) DEFAULT 'dark',
    custom_css TEXT,
    cnpj VARCHAR(20),
    address TEXT,
    phone VARCHAR(30),
    email VARCHAR(255),
    is_active BOOLEAN DEFAULT TRUE,
    plan VARCHAR(50) DEFAULT 'professional',
    max_users INT DEFAULT 50,
    settings JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- USERS
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'user',
    avatar_url TEXT,
    phone VARCHAR(30),
    department VARCHAR(100),
    auth_status VARCHAR(20) DEFAULT 'pending_2fa',
    two_factor_enabled BOOLEAN DEFAULT FALSE,
    two_factor_secret VARCHAR(255),
    recovery_token VARCHAR(255),
    recovery_token_expires TIMESTAMP,
    last_login TIMESTAMP,
    login_attempts INT DEFAULT 0,
    locked_until TIMESTAMP,
    preferences JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(tenant_id, email)
);

CREATE INDEX idx_users_tenant ON users(tenant_id);
CREATE INDEX idx_users_email ON users(email);

-- SESSIONS
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    refresh_token_hash VARCHAR(255),
    ip_address VARCHAR(45),
    user_agent TEXT,
    expires_at TIMESTAMP NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- AUTH TOKENS (2FA / Password Reset)
CREATE TABLE auth_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(10) NOT NULL,
    token_type VARCHAR(20) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- PLATFORMS
CREATE TABLE platforms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    platform_type VARCHAR(50) NOT NULL,
    base_url TEXT NOT NULL,
    description TEXT,
    auth_type VARCHAR(50) DEFAULT 'api_key',
    api_key_encrypted TEXT,
    username_encrypted TEXT,
    password_encrypted TEXT,
    client_id_encrypted TEXT,
    client_secret_encrypted TEXT,
    bearer_token_encrypted TEXT,
    extra_config JSONB DEFAULT '{}',
    polling_interval_seconds INT DEFAULT 300,
    is_active BOOLEAN DEFAULT TRUE,
    last_sync_at TIMESTAMP,
    last_sync_status VARCHAR(20),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_platforms_tenant ON platforms(tenant_id);

-- PROCESSING ACTIVITIES
CREATE TABLE processing_activities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    legal_basis VARCHAR(100),
    data_categories TEXT[],
    data_subjects TEXT[],
    purpose TEXT,
    retention_period VARCHAR(100),
    responsible_team VARCHAR(255),
    dpo_name VARCHAR(255),
    risk_level VARCHAR(20) DEFAULT 'medium',
    status VARCHAR(50) DEFAULT 'active',
    last_review_at TIMESTAMP,
    next_review_at TIMESTAMP,
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- CONSENTS
CREATE TABLE consent_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    data_subject_name VARCHAR(255),
    data_subject_email VARCHAR(255),
    purpose TEXT NOT NULL,
    legal_basis VARCHAR(100),
    status VARCHAR(20) DEFAULT 'active',
    collected_at TIMESTAMP,
    withdrawn_at TIMESTAMP,
    expires_at TIMESTAMP,
    channel VARCHAR(100),
    proof_url TEXT,
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

-- DSAR REQUESTS
CREATE TABLE dsar_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    request_type VARCHAR(100) NOT NULL,
    data_subject_name VARCHAR(255),
    data_subject_email VARCHAR(255),
    data_subject_document VARCHAR(50),
    description TEXT,
    status VARCHAR(20) DEFAULT 'received',
    priority VARCHAR(20) DEFAULT 'medium',
    assigned_to UUID REFERENCES users(id),
    due_date DATE,
    completed_at TIMESTAMP,
    resolution_notes TEXT,
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- INCIDENTS
CREATE TABLE incidents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    severity VARCHAR(20) DEFAULT 'medium',
    affected_data_categories TEXT[],
    affected_data_subjects_count INT,
    root_cause TEXT,
    containment_actions TEXT,
    corrective_actions TEXT,
    notified_anpd BOOLEAN DEFAULT FALSE,
    notified_at TIMESTAMP,
    notified_data_subjects BOOLEAN DEFAULT FALSE,
    status VARCHAR(50) DEFAULT 'open',
    detected_at TIMESTAMP,
    contained_at TIMESTAMP,
    resolved_at TIMESTAMP,
    assigned_to UUID REFERENCES users(id),
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- RISK ASSESSMENTS
CREATE TABLE risk_assessments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    activity_id UUID REFERENCES processing_activities(id),
    assessment_type VARCHAR(50),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    risk_level VARCHAR(20) DEFAULT 'medium',
    probability VARCHAR(50),
    impact VARCHAR(50),
    mitigation_measures TEXT,
    residual_risk_level VARCHAR(20),
    assessor_name VARCHAR(255),
    reviewed_by VARCHAR(255),
    assessment_date DATE,
    next_review_date DATE,
    status VARCHAR(50) DEFAULT 'draft',
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- INFRASTRUCTURE METRICS
CREATE TABLE infrastructure_metrics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    service_name VARCHAR(255) NOT NULL,
    metric_type VARCHAR(100) NOT NULL,
    metric_value DECIMAL(15,4),
    metric_unit VARCHAR(20),
    period_start TIMESTAMP,
    period_end TIMESTAMP,
    metadata JSONB DEFAULT '{}',
    collected_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_infra_tenant_service ON infrastructure_metrics(tenant_id, service_name);
CREATE INDEX idx_infra_collected ON infrastructure_metrics(collected_at);

-- UPTIME LOGS
CREATE TABLE uptime_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    service_name VARCHAR(255) NOT NULL,
    status VARCHAR(20) NOT NULL,
    response_time_ms INT,
    status_code INT,
    error_message TEXT,
    checked_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_uptime_tenant ON uptime_logs(tenant_id, service_name, checked_at);

-- TICKETS
CREATE TABLE tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    platform_id UUID REFERENCES platforms(id),
    external_id VARCHAR(100),
    ticket_number VARCHAR(50),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    category VARCHAR(100),
    priority VARCHAR(20) DEFAULT 'medium',
    status VARCHAR(20) DEFAULT 'open',
    assigned_to UUID REFERENCES users(id),
    requested_by VARCHAR(255),
    requester_email VARCHAR(255),
    sla_deadline TIMESTAMP,
    sla_breached BOOLEAN DEFAULT FALSE,
    first_response_at TIMESTAMP,
    resolved_at TIMESTAMP,
    closed_at TIMESTAMP,
    response_time_minutes INT,
    resolution_time_minutes INT,
    satisfaction_score DECIMAL(3,2),
    tags TEXT[],
    metadata JSONB DEFAULT '{}',
    synced_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_tickets_tenant ON tickets(tenant_id);
CREATE INDEX idx_tickets_status ON tickets(status);
CREATE INDEX idx_tickets_sla ON tickets(sla_deadline, sla_breached);

-- TICKET COMMENTS
CREATE TABLE ticket_comments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id UUID NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    author_name VARCHAR(255),
    content TEXT NOT NULL,
    is_internal BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- REPORT TEMPLATES
CREATE TABLE report_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    report_type VARCHAR(100) NOT NULL,
    period VARCHAR(20) DEFAULT 'monthly',
    sections JSONB DEFAULT '[]',
    format VARCHAR(20) DEFAULT 'pdf',
    is_active BOOLEAN DEFAULT TRUE,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- GENERATED REPORTS
CREATE TABLE generated_reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    template_id UUID REFERENCES report_templates(id),
    title VARCHAR(255) NOT NULL,
    report_type VARCHAR(100),
    period VARCHAR(20),
    period_start DATE,
    period_end DATE,
    status VARCHAR(20) DEFAULT 'pending',
    file_url TEXT,
    file_size_bytes BIGINT,
    generated_by UUID REFERENCES users(id),
    error_message TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

-- REPORT SCHEDULES
CREATE TABLE report_schedules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    template_id UUID NOT NULL REFERENCES report_templates(id),
    cron_expression VARCHAR(50),
    recipient_emails TEXT[],
    is_active BOOLEAN DEFAULT TRUE,
    last_run_at TIMESTAMP,
    next_run_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

-- AUDIT LOGS
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id),
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(100),
    resource_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_audit_tenant ON audit_logs(tenant_id, created_at);

-- SERVICE TYPES
CREATE TABLE service_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(100),
    description TEXT,
    icon VARCHAR(50),
    color VARCHAR(7),
    sla_hours INT DEFAULT 24,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- INITIAL DATA
INSERT INTO tenants (name, slug, primary_color, secondary_color, accent_color, theme_mode, email)
VALUES ('Monihook Admin', 'admin', '#1B5E8C', '#E8A838', '#2ECC71', 'dark', 'admin@monihook.com.br');
SQLEOF

    log_info "init.sql gerado"
}

# ─── nginx/default.conf ─────────────────────────────────────────
generate_nginx() {
    cat > "${MONIHOOK_DIR}/nginx/default.conf" << 'NGEOF'
upstream backend_api {
    server backend:8000;
}
upstream frontend_app {
    server frontend:80;
}
server {
    listen 80;
    server_name _;
    client_max_body_size 50M;

    location /api/ {
        proxy_pass http://backend_api/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }

    location /ws/ {
        proxy_pass http://backend_api/ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://frontend_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGEOF

    log_info "nginx/default.conf gerado"
}

# ─── Backend Files ──────────────────────────────────────────────
generate_backend() {
    log_step "Gerando Backend (Python/FastAPI)"

    # Dockerfile
    cat > "${MONIHOOK_DIR}/backend/Dockerfile" << 'BDEOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN mkdir -p /app/uploads
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
BDEOF

    # requirements.txt
    cat > "${MONIHOOK_DIR}/backend/requirements.txt" << 'REQEOF'
fastapi==0.111.0
uvicorn[standard]==0.30.1
sqlalchemy==2.0.31
asyncpg==0.29.0
psycopg2-binary==2.9.9
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
pydantic[email]==2.7.4
pydantic-settings==2.3.4
python-multipart==0.0.9
httpx==0.27.0
jinja2==3.1.4
aiosmtplib==3.0.1
pyotp==2.9.0
redis==5.0.7
cryptography==42.0.8
python-dateutil==2.9.0
REQEOF

    # app/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/__init__.py"

    # app/config.py
    cat > "${MONIHOOK_DIR}/backend/app/config.py" << 'PYEOF'
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    APP_NAME: str = "Monihook"
    APP_VERSION: str = "1.0.0"
    DEBUG: bool = False
    DB_ENGINE: str = "postgresql"
    DB_HOST: str = "db"
    DB_PORT: int = 5432
    DB_NAME: str = "monihook"
    DB_USER: str = "monihook_user"
    DB_PASSWORD: str = "change_me"
    SECRET_KEY: str = "change-this-secret-key"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRE_MINUTES: int = 480
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30
    SMTP_HOST: str = "smtp.gmail.com"
    SMTP_PORT: int = 587
    SMTP_USER: str = ""
    SMTP_PASSWORD: str = ""
    SMTP_FROM: str = "Monihook <noreply@monihook.com.br>"
    FRONTEND_URL: str = "http://localhost"
    BACKEND_URL: str = "http://localhost"
    GRAFANA_URL: str = "https://dashboard.cmtech.com.br"
    PRIVACYTOOLS_BASE_URL: str = "https://dpo.privacytools.com.br/external_api_v2"
    ADMIN_EMAIL: str = "admin@monihook.com.br"
    ADMIN_PASSWORD: str = "Admin@2024!"
    ADMIN_NAME: str = "Administrador"
    ADMIN_COMPANY: str = "Monihook Admin"
    REDIS_URL: str = "redis://redis:6379/0"

    @property
    def DATABASE_URL(self) -> str:
        return f"postgresql+asyncpg://{self.DB_USER}:{self.DB_PASSWORD}@{self.DB_HOST}:{self.DB_PORT}/{self.DB_NAME}"

    class Config:
        env_file = ".env"
        case_sensitive = True

@lru_cache()
def get_settings() -> Settings:
    return Settings()
PYEOF

    # app/database.py
    cat > "${MONIHOOK_DIR}/backend/app/database.py" << 'PYEOF'
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase
from app.config import get_settings

settings = get_settings()
engine = create_async_engine(settings.DATABASE_URL, echo=settings.DEBUG, pool_size=20, max_overflow=10, pool_pre_ping=True)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

async def get_db() -> AsyncSession:
    async with AsyncSessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
PYEOF

    # app/utils/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/utils/__init__.py"

    # app/utils/security.py
    cat > "${MONIHOOK_DIR}/backend/app/utils/security.py" << 'PYEOF'
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID
from passlib.context import CryptContext
from jose import jwt
from cryptography.fernet import Fernet
import base64, hashlib
from app.config import get_settings

settings = get_settings()
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
_encryption_key = base64.urlsafe_b64encode(hashlib.sha256(settings.SECRET_KEY.encode()).digest())
_fernet = Fernet(_encryption_key)

def hash_password(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def create_access_token(user_id: UUID, tenant_id: UUID, role: str, expires_delta: Optional[timedelta] = None) -> str:
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=settings.JWT_EXPIRE_MINUTES))
    payload = {"sub": str(user_id), "tenant_id": str(tenant_id), "role": role, "exp": expire, "type": "access"}
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.JWT_ALGORITHM)

def create_refresh_token(user_id: UUID, tenant_id: UUID) -> str:
    expire = datetime.now(timezone.utc) + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {"sub": str(user_id), "tenant_id": str(tenant_id), "exp": expire, "type": "refresh"}
    return jwt.encode(payload, settings.SECRET_KEY, algorithm=settings.JWT_ALGORITHM)

def decode_token(token: str) -> dict:
    return jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])

def encrypt_value(value: str) -> str:
    if not value: return ""
    return _fernet.encrypt(value.encode()).decode()

def decrypt_value(encrypted: str) -> str:
    if not encrypted: return ""
    return _fernet.decrypt(encrypted.encode()).decode()
PYEOF

    # app/utils/totp.py
    cat > "${MONIHOOK_DIR}/backend/app/utils/totp.py" << 'PYEOF'
import pyotp, secrets, string
from datetime import datetime, timedelta, timezone

def generate_email_token(length: int = 6) -> str:
    return "".join(secrets.choice(string.digits) for _ in range(length))

def get_token_expiry(minutes: int = 10) -> datetime:
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)
PYEOF

    # app/models/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/models/__init__.py"

    # app/schemas/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/schemas/__init__.py"

    # app/routers/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/routers/__init__.py"

    # app/services/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/services/__init__.py"

    # app/middleware/__init__.py
    touch "${MONIHOOK_DIR}/backend/app/middleware/__init__.py"

    log_info "Backend base gerado"
    log_warn "Os arquivos completos do backend devem ser copiados manualmente"
    log_warn "Consulte a documentação em docs/ para a lista completa de arquivos"
}

# ─── Frontend Files ─────────────────────────────────────────────
generate_frontend() {
    log_step "Gerando Frontend (React)"

    # Dockerfile
    cat > "${MONIHOOK_DIR}/frontend/Dockerfile" << 'FDEOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
FDEOF

    # frontend/nginx.conf
    cat > "${MONIHOOK_DIR}/frontend/nginx.conf" << 'FNEOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
FNEOF

    # package.json
    cat > "${MONIHOOK_DIR}/frontend/package.json" << 'PJEOF'
{
  "name": "monihook-frontend",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-router-dom": "^6.25.0",
    "react-scripts": "5.0.1",
    "axios": "^1.7.2",
    "recharts": "^2.12.7",
    "lucide-react": "^0.400.0",
    "date-fns": "^3.6.0",
    "react-hot-toast": "^2.4.1"
  },
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build"
  },
  "browserslist": {
    "production": [">0.2%", "not dead", "not op_mini all"],
    "development": ["last 1 chrome version", "last 1 firefox version", "last 1 safari version"]
  }
}
PJEOF

    # public/index.html
    mkdir -p "${MONIHOOK_DIR}/frontend/public"
    cat > "${MONIHOOK_DIR}/frontend/public/index.html" << 'HTEOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;600;700;800&family=DM+Mono:wght@300;400;500&display=swap" rel="stylesheet">
  <title>Monihook</title>
</head>
<body><div id="root"></div></body>
</html>
HTEOF

    log_info "Frontend base gerado"
    log_warn "Os arquivos completos do frontend devem ser copiados manualmente"
}

# ─── Gerar Documentação ─────────────────────────────────────────
generate_documentation() {
    log_step "Gerando documentação"

    mkdir -p "${MONIHOOK_DIR}/docs"

    cat > "${MONIHOOK_DIR}/docs/GUIA_IMPLANTACAO.md" << 'DOCEOF'
# Monihook — Guia Completo de Implantação

## 1. Visão Geral

O Monihook é uma aplicação SaaS multi-tenant para monitoramento de serviços
de privacidade (LGPD/GDPR), infraestrutura (Grafana) e tickets (SLA/TMA).

### Arquitetura

