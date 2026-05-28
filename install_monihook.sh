#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# MONIHOOK — Script de Instalação Completa (CORRIGIDO)
# Versão: 1.0.1
# Compatível: Ubuntu 22.04+, Debian 12+
# ═══════════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

MONIHOOK_DIR="/opt/monihook"
MONIHOOK_VERSION="1.0.1"

print_banner() {
    echo -e "${CYAN}"
    echo "  ========================================================"
    echo "                    MONIHOOK v${MONIHOOK_VERSION}"
    echo "  Monitoramento de Servicos de Privacidade"
    echo "  LGPD (Brasil) / GDPR (Europa)"
    echo "  ========================================================"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERRO]${NC} $1"; }
log_step()    { echo -e "\n${BLUE}--- $1 ---${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Execute como root: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "Sistema detectado: $PRETTY_NAME"
    else
        log_error "Sistema operacional nao suportado"
        exit 1
    fi
}

install_dependencies() {
    log_step "Instalando dependencias do sistema"
    apt update -qq
    apt install -y -qq curl wget git unzip ufw ca-certificates gnupg lsb-release

    if ! command -v docker &> /dev/null; then
        log_info "Instalando Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        systemctl enable docker
        systemctl start docker
        rm -f /tmp/get-docker.sh
    else
        log_info "Docker ja instalado: $(docker --version)"
    fi

    if ! docker compose version &> /dev/null; then
        log_info "Instalando Docker Compose plugin..."
        apt install -y -qq docker-compose-plugin
    fi
    log_info "Docker Compose: $(docker compose version)"
}

setup_firewall() {
    log_step "Configurando firewall"
    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        log_info "Portas 22, 80, 443 liberadas"
    fi
}

create_project_structure() {
    log_step "Criando estrutura do projeto em ${MONIHOOK_DIR}"
    mkdir -p "${MONIHOOK_DIR}"/{backend/app/{models,schemas,routers,services,middleware,utils},backend/alembic/versions,frontend/{public,src/{contexts,services,components/{Auth,Layout,Dashboard,Privacy,Infrastructure,Tickets,Reports,Settings},utils}},database,nginx,docs}
    log_info "Estrutura de pastas criada"
}

generate_env() {
    log_step "Gerando configuracao de ambiente"
    SECRET_KEY=$(openssl rand -hex 32)
    DB_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
    ADMIN_PASSWORD="Admin@$(date +%Y)!Monihook"

    cat > "${MONIHOOK_DIR}/.env" << ENVEOF
DB_ENGINE=postgresql
DB_HOST=db
DB_PORT=5432
DB_NAME=monihook
DB_USER=monihook_user
DB_PASSWORD=${DB_PASSWORD}
SECRET_KEY=${SECRET_KEY}
JWT_ALGORITHM=HS256
JWT_EXPIRE_MINUTES=480
REFRESH_TOKEN_EXPIRE_DAYS=30
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=SEU_EMAIL@gmail.com
SMTP_PASSWORD=SUA_SENHA_DE_APP
SMTP_FROM=Monihook <noreply@seudominio.com.br>
FRONTEND_URL=http://localhost
BACKEND_URL=http://localhost
GRAFANA_URL=https://dashboard.cmtech.com.br
PRIVACYTOOLS_BASE_URL=https://dpo.privacytools.com.br/external_api_v2
ADMIN_EMAIL=admin@monihook.com.br
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_NAME=Administrador
ADMIN_COMPANY=Monihook Admin
REDIS_URL=redis://redis:6379/0
BACKEND_PORT=8000
FRONTEND_PORT=3000
ENVEOF
    chmod 600 "${MONIHOOK_DIR}/.env"

    cat > "${MONIHOOK_DIR}/.credentials" << CREDEOF
========================================
 CREDENCIAIS DE ACESSO - MONIHOOK
 Gerado em: $(date)
========================================
 ACESSO ADMINISTRATIVO:
 URL:      http://$(hostname -I | awk '{print $1}')
 Email:    admin@monihook.com.br
 Senha:    ${ADMIN_PASSWORD}
 BANCO DE DADOS:
 Host:     localhost:5432
 Banco:    monihook
 Usuario:  monihook_user
 Senha:    ${DB_PASSWORD}
 CHAVE SECRETA JWT:
 ${SECRET_KEY}
========================================
 GUARDE ESTE ARQUIVO EM LOCAL SEGURO!
========================================
CREDEOF
    chmod 600 "${MONIHOOK_DIR}/.credentials"
    log_info "Arquivo .env gerado"
    log_info "Credenciais salvas em ${MONIHOOK_DIR}/.credentials"
}

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

generate_init_sql() {
    cat > "${MONIHOOK_DIR}/database/init.sql" << 'SQLEOF'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

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

CREATE TABLE auth_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(10) NOT NULL,
    token_type VARCHAR(20) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

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

CREATE TABLE ticket_comments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id UUID NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    author_name VARCHAR(255),
    content TEXT NOT NULL,
    is_internal BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT NOW()
);

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

INSERT INTO tenants (name, slug, primary_color, secondary_color, accent_color, theme_mode, email)
VALUES ('Monihook Admin', 'admin', '#1B5E8C', '#E8A838', '#2ECC71', 'dark', 'admin@monihook.com.br');
SQLEOF
    log_info "init.sql gerado"
}

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

generate_backend() {
    log_step "Gerando Backend (Python/FastAPI)"

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

    touch "${MONIHOOK_DIR}/backend/app/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/models/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/schemas/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/routers/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/services/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/middleware/__init__.py"
    touch "${MONIHOOK_DIR}/backend/app/utils/__init__.py"

    cat > "${MONIHOOK_DIR}/backend/app/config.py" << 'PYEOF'
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    APP_NAME: str = "Monihook"
    APP_VERSION: str = "1.0.1"
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
_ekey = base64.urlsafe_b64encode(hashlib.sha256(settings.SECRET_KEY.encode()).digest())
_fernet = Fernet(_ekey)

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

    cat > "${MONIHOOK_DIR}/backend/app/utils/totp.py" << 'PYEOF'
import secrets, string
from datetime import datetime, timedelta, timezone

def generate_email_token(length: int = 6) -> str:
    return "".join(secrets.choice(string.digits) for _ in range(length))

def get_token_expiry(minutes: int = 10) -> datetime:
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/tenant.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, Text, DateTime
from sqlalchemy.dialects.postgresql import UUID, JSONB
from app.database import Base

class Tenant(Base):
    __tablename__ = "tenants"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(255), nullable=False)
    slug = Column(String(100), unique=True, nullable=False)
    domain = Column(String(255))
    logo_url = Column(Text)
    favicon_url = Column(Text)
    primary_color = Column(String(7), default="#1B5E8C")
    secondary_color = Column(String(7), default="#E8A838")
    accent_color = Column(String(7), default="#2ECC71")
    theme_mode = Column(String(10), default="dark")
    custom_css = Column(Text)
    cnpj = Column(String(20))
    address = Column(Text)
    phone = Column(String(30))
    email = Column(String(255))
    is_active = Column(Boolean, default=True)
    plan = Column(String(50), default="professional")
    max_users = Column(Integer, default=50)
    settings = Column(JSONB, default={})
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/user.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, Text, DateTime, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import relationship
from app.database import Base

class User(Base):
    __tablename__ = "users"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    email = Column(String(255), nullable=False)
    password_hash = Column(String(255), nullable=False)
    full_name = Column(String(255), nullable=False)
    role = Column(String(20), default="user")
    avatar_url = Column(Text)
    phone = Column(String(30))
    department = Column(String(100))
    auth_status = Column(String(20), default="pending_2fa")
    two_factor_enabled = Column(Boolean, default=False)
    two_factor_secret = Column(String(255))
    recovery_token = Column(String(255))
    recovery_token_expires = Column(DateTime)
    last_login = Column(DateTime)
    login_attempts = Column(Integer, default=0)
    locked_until = Column(DateTime)
    preferences = Column(JSONB, default={})
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    sessions = relationship("UserSession", back_populates="user", cascade="all, delete-orphan")

class UserSession(Base):
    __tablename__ = "user_sessions"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    token_hash = Column(String(255), nullable=False)
    refresh_token_hash = Column(String(255))
    ip_address = Column(String(45))
    user_agent = Column(Text)
    expires_at = Column(DateTime, nullable=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    user = relationship("User", back_populates="sessions")

class AuthToken(Base):
    __tablename__ = "auth_tokens"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    token = Column(String(10), nullable=False)
    token_type = Column(String(20), nullable=False)
    expires_at = Column(DateTime, nullable=False)
    used = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)

class AuditLog(Base):
    __tablename__ = "audit_logs"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"))
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    action = Column(String(100), nullable=False)
    resource_type = Column(String(100))
    resource_id = Column(UUID(as_uuid=True))
    old_values = Column(JSONB)
    new_values = Column(JSONB)
    ip_address = Column(String(45))
    user_agent = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)

class ServiceType(Base):
    __tablename__ = "service_types"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(255), nullable=False)
    category = Column(String(100))
    description = Column(Text)
    icon = Column(String(50))
    color = Column(String(7))
    sla_hours = Column(Integer, default=24)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/platform.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, Text, DateTime, ForeignKey
from sqlalchemy.dialects.postgresql import UUID, JSONB
from app.database import Base

class Platform(Base):
    __tablename__ = "platforms"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(255), nullable=False)
    platform_type = Column(String(50), nullable=False)
    base_url = Column(Text, nullable=False)
    description = Column(Text)
    auth_type = Column(String(50), default="api_key")
    api_key_encrypted = Column(Text)
    username_encrypted = Column(Text)
    password_encrypted = Column(Text)
    client_id_encrypted = Column(Text)
    client_secret_encrypted = Column(Text)
    bearer_token_encrypted = Column(Text)
    extra_config = Column(JSONB, default={})
    polling_interval_seconds = Column(Integer, default=300)
    is_active = Column(Boolean, default=True)
    last_sync_at = Column(DateTime)
    last_sync_status = Column(String(20))
    created_by = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/privacy.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, Text, DateTime, Date, ForeignKey, Numeric
from sqlalchemy.dialects.postgresql import UUID, JSONB, ARRAY
from app.database import Base

class ProcessingActivity(Base):
    __tablename__ = "processing_activities"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    name = Column(String(255), nullable=False)
    description = Column(Text)
    legal_basis = Column(String(100))
    data_categories = Column(ARRAY(Text))
    data_subjects = Column(ARRAY(Text))
    purpose = Column(Text)
    retention_period = Column(String(100))
    responsible_team = Column(String(255))
    dpo_name = Column(String(255))
    risk_level = Column(String(20), default="medium")
    status = Column(String(50), default="active")
    last_review_at = Column(DateTime)
    next_review_at = Column(DateTime)
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class ConsentRecord(Base):
    __tablename__ = "consent_records"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    data_subject_name = Column(String(255))
    data_subject_email = Column(String(255))
    purpose = Column(Text, nullable=False)
    legal_basis = Column(String(100))
    status = Column(String(20), default="active")
    collected_at = Column(DateTime)
    withdrawn_at = Column(DateTime)
    expires_at = Column(DateTime)
    channel = Column(String(100))
    proof_url = Column(Text)
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)

class DSARRequest(Base):
    __tablename__ = "dsar_requests"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    request_type = Column(String(100), nullable=False)
    data_subject_name = Column(String(255))
    data_subject_email = Column(String(255))
    data_subject_document = Column(String(50))
    description = Column(Text)
    status = Column(String(20), default="received")
    priority = Column(String(20), default="medium")
    assigned_to = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    due_date = Column(Date)
    completed_at = Column(DateTime)
    resolution_notes = Column(Text)
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class Incident(Base):
    __tablename__ = "incidents"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    title = Column(String(255), nullable=False)
    description = Column(Text)
    severity = Column(String(20), default="medium")
    affected_data_categories = Column(ARRAY(Text))
    affected_data_subjects_count = Column(Integer)
    root_cause = Column(Text)
    containment_actions = Column(Text)
    corrective_actions = Column(Text)
    notified_anpd = Column(Boolean, default=False)
    notified_at = Column(DateTime)
    notified_data_subjects = Column(Boolean, default=False)
    status = Column(String(50), default="open")
    detected_at = Column(DateTime)
    contained_at = Column(DateTime)
    resolved_at = Column(DateTime)
    assigned_to = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class RiskAssessment(Base):
    __tablename__ = "risk_assessments"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    activity_id = Column(UUID(as_uuid=True), ForeignKey("processing_activities.id"))
    assessment_type = Column(String(50))
    title = Column(String(255), nullable=False)
    description = Column(Text)
    risk_level = Column(String(20), default="medium")
    probability = Column(String(50))
    impact = Column(String(50))
    mitigation_measures = Column(Text)
    residual_risk_level = Column(String(20))
    assessor_name = Column(String(255))
    reviewed_by = Column(String(255))
    assessment_date = Column(Date)
    next_review_date = Column(Date)
    status = Column(String(50), default="draft")
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/monitoring.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, ForeignKey, Numeric
from sqlalchemy.dialects.postgresql import UUID, JSONB
from app.database import Base

class InfrastructureMetric(Base):
    __tablename__ = "infrastructure_metrics"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    service_name = Column(String(255), nullable=False)
    metric_type = Column(String(100), nullable=False)
    metric_value = Column(Numeric(15, 4))
    metric_unit = Column(String(20))
    period_start = Column(DateTime)
    period_end = Column(DateTime)
    metadata = Column(JSONB, default={})
    collected_at = Column(DateTime, default=datetime.utcnow)

class UptimeLog(Base):
    __tablename__ = "uptime_logs"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    service_name = Column(String(255), nullable=False)
    status = Column(String(20), nullable=False)
    response_time_ms = Column(Integer)
    status_code = Column(Integer)
    error_message = Column(String)
    checked_at = Column(DateTime, default=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/ticket.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, Text, DateTime, ForeignKey, Numeric
from sqlalchemy.dialects.postgresql import UUID, JSONB, ARRAY
from sqlalchemy.orm import relationship
from app.database import Base

class Ticket(Base):
    __tablename__ = "tickets"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    platform_id = Column(UUID(as_uuid=True), ForeignKey("platforms.id"))
    external_id = Column(String(100))
    ticket_number = Column(String(50))
    title = Column(String(255), nullable=False)
    description = Column(Text)
    category = Column(String(100))
    priority = Column(String(20), default="medium")
    status = Column(String(20), default="open")
    assigned_to = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    requested_by = Column(String(255))
    requester_email = Column(String(255))
    sla_deadline = Column(DateTime)
    sla_breached = Column(Boolean, default=False)
    first_response_at = Column(DateTime)
    resolved_at = Column(DateTime)
    closed_at = Column(DateTime)
    response_time_minutes = Column(Integer)
    resolution_time_minutes = Column(Integer)
    satisfaction_score = Column(Numeric(3, 2))
    tags = Column(ARRAY(Text))
    metadata = Column(JSONB, default={})
    synced_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    comments = relationship("TicketComment", back_populates="ticket", cascade="all, delete-orphan")

class TicketComment(Base):
    __tablename__ = "ticket_comments"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    ticket_id = Column(UUID(as_uuid=True), ForeignKey("tickets.id", ondelete="CASCADE"), nullable=False)
    author_name = Column(String(255))
    content = Column(Text, nullable=False)
    is_internal = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    ticket = relationship("Ticket", back_populates="comments")
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/models/report.py" << 'PYEOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Text, DateTime, Date, ForeignKey, BigInteger
from sqlalchemy.dialects.postgresql import UUID, JSONB, ARRAY
from app.database import Base

class ReportTemplate(Base):
    __tablename__ = "report_templates"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(255), nullable=False)
    description = Column(Text)
    report_type = Column(String(100), nullable=False)
    period = Column(String(20), default="monthly")
    sections = Column(JSONB, default=[])
    format = Column(String(20), default="pdf")
    is_active = Column(Boolean, default=True)
    created_by = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class GeneratedReport(Base):
    __tablename__ = "generated_reports"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    template_id = Column(UUID(as_uuid=True), ForeignKey("report_templates.id"))
    title = Column(String(255), nullable=False)
    report_type = Column(String(100))
    period = Column(String(20))
    period_start = Column(Date)
    period_end = Column(Date)
    status = Column(String(20), default="pending")
    file_url = Column(Text)
    file_size_bytes = Column(BigInteger)
    generated_by = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    error_message = Column(Text)
    metadata = Column(JSONB, default={})
    created_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime)

class ReportSchedule(Base):
    __tablename__ = "report_schedules"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    tenant_id = Column(UUID(as_uuid=True), ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False)
    template_id = Column(UUID(as_uuid=True), ForeignKey("report_templates.id"), nullable=False)
    cron_expression = Column(String(50))
    recipient_emails = Column(ARRAY(Text))
    is_active = Column(Boolean, default=True)
    last_run_at = Column(DateTime)
    next_run_at = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow)
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/dependencies.py" << 'PYEOF'
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from jose import jwt, JWTError
from uuid import UUID
from app.database import get_db
from app.config import get_settings
from app.models.user import User
from app.models.tenant import Tenant

settings = get_settings()
security = HTTPBearer()

async def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(security), db: AsyncSession = Depends(get_db)) -> User:
    token = credentials.credentials
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])
        user_id = payload.get("sub")
        tenant_id = payload.get("tenant_id")
        if not user_id or not tenant_id:
            raise HTTPException(status_code=401, detail="Token invalido")
    except JWTError:
        raise HTTPException(status_code=401, detail="Token invalido ou expirado")
    result = await db.execute(select(User).where(User.id == UUID(user_id), User.tenant_id == UUID(tenant_id), User.is_active == True))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=401, detail="Usuario nao encontrado ou inativo")
    return user

async def get_current_tenant(current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)) -> Tenant:
    result = await db.execute(select(Tenant).where(Tenant.id == current_user.tenant_id, Tenant.is_active == True))
    tenant = result.scalar_one_or_none()
    if not tenant:
        raise HTTPException(status_code=403, detail="Organizacao inativa")
    return tenant

def require_roles(*allowed_roles: str):
    async def role_checker(current_user: User = Depends(get_current_user)):
        if current_user.role not in allowed_roles:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Permissao insuficiente")
        return current_user
    return role_checker
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/services/email_service.py" << 'PYEOF'
import aiosmtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from jinja2 import Template
from app.config import get_settings

settings = get_settings()

BODY_TPL = """
<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="font-family:sans-serif;background:#0f1117;color:#e0e0e0;padding:40px;margin:0;">
<div style="max-width:520px;margin:0 auto;background:#1a1d27;border-radius:12px;overflow:hidden;border:1px solid #2a2d3a;">
<div style="background:linear-gradient(135deg,{{pc}},{{sc}});padding:32px;text-align:center;">
<h1 style="margin:0;color:#fff;font-size:24px;">{{app}}</h1></div>
<div style="padding:32px;">{{content}}</div>
<div style="padding:16px 32px;background:#13151d;text-align:center;font-size:12px;color:#666;">
Email automatico do {{app}}.</div></div></body></html>"""

async def send_email(to_email: str, subject: str, content_html: str, colors: dict = None):
    c = colors or {"pc": "#1B5E8C", "sc": "#E8A838", "app": "Monihook"}
    body = Template(BODY_TPL).render(content=content_html, **c)
    msg = MIMEMultipart("alternative")
    msg["From"] = settings.SMTP_FROM
    msg["To"] = to_email
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "html"))
    try:
        await aiosmtplib.send(msg, hostname=settings.SMTP_HOST, port=settings.SMTP_PORT, start_tls=True, username=settings.SMTP_USER, password=settings.SMTP_PASSWORD)
        return True
    except Exception as e:
        print(f"[EMAIL ERROR] {to_email}: {e}")
        return False

async def send_2fa_code(to_email: str, name: str, code: str, colors: dict = None):
    c = colors or {}
    pc = c.get("primary_color", "#1B5E8C")
    ac = c.get("accent_color", "#2ECC71")
    html = f'<h2 style="color:#f0f0f0;font-size:18px;">Codigo de Verificacao</h2><p style="color:#b0b0b0;">Ola {name},</p><p style="color:#b0b0b0;">Seu codigo:</p><div style="background:#0f1117;border:2px dashed {pc};border-radius:8px;padding:24px;text-align:center;margin:24px 0;"><span style="font-size:36px;font-weight:800;color:{ac};letter-spacing:8px;font-family:monospace;">{code}</span></div><p style="color:#888;font-size:13px;">Expira em 10 minutos.</p>'
    return await send_email(to_email, "Seu codigo de verificacao - Monihook", html, {"pc": pc, "sc": c.get("secondary_color", "#E8A838"), "app": "Monihook"})

async def send_password_reset(to_email: str, name: str, reset_url: str, colors: dict = None):
    c = colors or {}
    pc = c.get("primary_color", "#1B5E8C")
    html = f'<h2 style="color:#f0f0f0;font-size:18px;">Recuperacao de Senha</h2><p style="color:#b0b0b0;">Ola {name},</p><p style="color:#b0b0b0;">Clique no botao para redefinir sua senha:</p><div style="text-align:center;margin:32px 0;"><a href="{reset_url}" style="display:inline-block;background:{pc};color:#fff;padding:14px 32px;border-radius:8px;text-decoration:none;font-weight:600;">Redefinir Senha</a></div><p style="color:#888;font-size:13px;">Expira em 1 hora.</p>'
    return await send_email(to_email, "Recuperacao de Senha - Monihook", html, {"pc": pc, "sc": c.get("secondary_color", "#E8A838"), "app": "Monihook"})
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/services/auth_service.py" << 'PYEOF'
from datetime import datetime, timezone, timedelta
from uuid import UUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from fastapi import HTTPException
import secrets
from app.models.user import User, AuthToken
from app.models.tenant import Tenant
from app.utils.security import hash_password, verify_password, create_access_token, create_refresh_token
from app.utils.totp import generate_email_token, get_token_expiry
from app.services.email_service import send_2fa_code, send_password_reset
from app.config import get_settings

settings = get_settings()

class AuthService:
    @staticmethod
    async def login(db: AsyncSession, email: str, password: str, ip: str = None, ua: str = None):
        result = await db.execute(select(User).join(Tenant).where(User.email == email, User.is_active == True, Tenant.is_active == True))
        user = result.scalar_one_or_none()
        if not user or not verify_password(password, user.password_hash):
            raise HTTPException(status_code=401, detail="Email ou senha incorretos")
        if user.locked_until and user.locked_until > datetime.now(timezone.utc):
            remaining = int((user.locked_until - datetime.now(timezone.utc)).total_seconds() / 60)
            raise HTTPException(status_code=423, detail=f"Conta bloqueada. Tente em {remaining} minutos.")
        tenant_result = await db.execute(select(Tenant).where(Tenant.id == user.tenant_id))
        tenant = tenant_result.scalar_one()
        code = generate_email_token(6)
        db.add(AuthToken(user_id=user.id, token=code, token_type="2fa_login", expires_at=get_token_expiry(10)))
        user.login_attempts = 0
        await db.flush()
        tc = {"primary_color": tenant.primary_color, "secondary_color": tenant.secondary_color, "accent_color": tenant.accent_color}
        await send_2fa_code(user.email, user.full_name, code, tc)
        session_token = secrets.token_urlsafe(32)
        return {"session_token": session_token, "message": "Codigo enviado para seu email", "_user_id": str(user.id)}

    @staticmethod
    async def verify_2fa(db: AsyncSession, user_id: UUID, code: str):
        result = await db.execute(select(User).where(User.id == user_id))
        user = result.scalar_one_or_none()
        if not user:
            raise HTTPException(status_code=404, detail="Usuario nao encontrado")
        token_result = await db.execute(select(AuthToken).where(AuthToken.user_id == user.id, AuthToken.token == code, AuthToken.token_type == "2fa_login", AuthToken.used == False, AuthToken.expires_at > datetime.now(timezone.utc)).order_by(AuthToken.created_at.desc()).limit(1))
        auth_token = token_result.scalar_one_or_none()
        if not auth_token:
            raise HTTPException(status_code=401, detail="Codigo invalido ou expirado")
        auth_token.used = True
        user.last_login = datetime.now(timezone.utc)
        user.auth_status = "active"
        await db.flush()
        access_token = create_access_token(user.id, user.tenant_id, user.role)
        refresh_token = create_refresh_token(user.id, user.tenant_id)
        tenant_result = await db.execute(select(Tenant).where(Tenant.id == user.tenant_id))
        tenant = tenant_result.scalar_one()
        return {"access_token": access_token, "refresh_token": refresh_token, "token_type": "bearer", "user": {"id": str(user.id), "email": user.email, "full_name": user.full_name, "role": user.role, "tenant_id": str(user.tenant_id), "tenant_name": tenant.name, "tenant_slug": tenant.slug, "avatar_url": user.avatar_url, "two_factor_enabled": user.two_factor_enabled}}

    @staticmethod
    async def forgot_password(db: AsyncSession, email: str):
        result = await db.execute(select(User).join(Tenant).where(User.email == email, User.is_active == True))
        user = result.scalar_one_or_none()
        if not user:
            return {"message": "Se o email estiver cadastrado, voce recebera um link"}
        recovery_token = secrets.token_urlsafe(48)
        user.recovery_token = recovery_token
        user.recovery_token_expires = datetime.now(timezone.utc) + timedelta(hours=1)
        tenant_result = await db.execute(select(Tenant).where(Tenant.id == user.tenant_id))
        tenant = tenant_result.scalar_one()
        reset_url = f"{settings.FRONTEND_URL}/reset-password?token={recovery_token}"
        tc = {"primary_color": tenant.primary_color, "secondary_color": tenant.secondary_color, "accent_color": tenant.accent_color}
        await send_password_reset(user.email, user.full_name, reset_url, tc)
        return {"message": "Se o email estiver cadastrado, voce recebera um link"}

    @staticmethod
    async def reset_password(db: AsyncSession, token: str, new_password: str):
        result = await db.execute(select(User).where(User.recovery_token == token, User.recovery_token_expires > datetime.now(timezone.utc)))
        user = result.scalar_one_or_none()
        if not user:
            raise HTTPException(status_code=400, detail="Token invalido ou expirado")
        user.password_hash = hash_password(new_password)
        user.recovery_token = None
        user.recovery_token_expires = None
        user.login_attempts = 0
        user.locked_until = None
        return {"message": "Senha redefinida com sucesso"}

    @staticmethod
    async def change_password(db: AsyncSession, user: User, current_password: str, new_password: str):
        if not verify_password(current_password, user.password_hash):
            raise HTTPException(status_code=400, detail="Senha atual incorreta")
        user.password_hash = hash_password(new_password)
        return {"message": "Senha alterada com sucesso"}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/services/privacytools_service.py" << 'PYEOF'
import httpx
from typing import Optional
from uuid import UUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.platform import Platform
from app.utils.security import decrypt_value

class PrivacyToolsService:
    def __init__(self, platform: Platform):
        self.base_url = platform.base_url.rstrip("/")
        self.headers = {"Content-Type": "application/json"}
        if platform.api_key_encrypted:
            self.headers["Authorization"] = f"ApiKey {decrypt_value(platform.api_key_encrypted)}"
        elif platform.bearer_token_encrypted:
            self.headers["Authorization"] = f"Bearer {decrypt_value(platform.bearer_token_encrypted)}"

    async def _request(self, method: str, endpoint: str, **kwargs) -> dict:
        url = f"{self.base_url}{endpoint}"
        async with httpx.AsyncClient(timeout=30.0) as client:
            r = await client.request(method, url, headers=self.headers, **kwargs)
            r.raise_for_status()
            return r.json()

    async def get_activities(self, page=1, per_page=50):
        return await self._request("GET", "/processing-activities", params={"page": page, "per_page": per_page})

    async def get_consents(self, page=1, per_page=50):
        return await self._request("GET", "/consents", params={"page": page, "per_page": per_page})

    async def get_dsar_requests(self, page=1, per_page=50):
        return await self._request("GET", "/dsar-requests", params={"page": page, "per_page": per_page})

    async def get_incidents(self, page=1, per_page=50):
        return await self._request("GET", "/incidents", params={"page": page, "per_page": per_page})

    async def health_check(self) -> bool:
        try:
            await self._request("GET", "/health")
            return True
        except Exception:
            return False

async def get_privacytools_service(db: AsyncSession, tenant_id: UUID) -> Optional[PrivacyToolsService]:
    result = await db.execute(select(Platform).where(Platform.tenant_id == tenant_id, Platform.platform_type == "privacytools", Platform.is_active == True))
    platform = result.scalar_one_or_none()
    return PrivacyToolsService(platform) if platform else None
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/services/grafana_service.py" << 'PYEOF'
import httpx, base64
from typing import Optional
from uuid import UUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from app.models.platform import Platform
from app.utils.security import decrypt_value

class GrafanaService:
    def __init__(self, platform: Platform):
        self.base_url = platform.base_url.rstrip("/")
        self.headers = {"Content-Type": "application/json"}
        if platform.api_key_encrypted:
            self.headers["Authorization"] = f"Bearer {decrypt_value(platform.api_key_encrypted)}"
        elif platform.username_encrypted and platform.password_encrypted:
            u = decrypt_value(platform.username_encrypted)
            p = decrypt_value(platform.password_encrypted)
            creds = base64.b64encode(f"{u}:{p}".encode()).decode()
            self.headers["Authorization"] = f"Basic {creds}"

    async def _req(self, method, endpoint, **kwargs):
        url = f"{self.base_url}/api{endpoint}"
        async with httpx.AsyncClient(timeout=30.0, verify=False) as client:
            r = await client.request(method, url, headers=self.headers, **kwargs)
            r.raise_for_status()
            return r.json()

    async def get_dashboards(self):
        return await self._req("GET", "/search?type=dash-db")

    async def get_health(self):
        async with httpx.AsyncClient(timeout=10.0, verify=False) as client:
            r = await client.get(f"{self.base_url}/api/health")
            return r.json()

    async def health_check(self) -> bool:
        try:
            h = await self.get_health()
            return h.get("database") == "ok"
        except Exception:
            return False

async def get_grafana_service(db: AsyncSession, tenant_id: UUID) -> Optional[GrafanaService]:
    result = await db.execute(select(Platform).where(Platform.tenant_id == tenant_id, Platform.platform_type == "grafana", Platform.is_active == True))
    platform = result.scalar_one_or_none()
    return GrafanaService(platform) if platform else None
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/services/report_service.py" << 'PYEOF'
from datetime import datetime, date, timedelta
from uuid import UUID
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, and_, case
from calendar import monthrange
from app.models.privacy import ProcessingActivity, ConsentRecord, DSARRequest, Incident, RiskAssessment
from app.models.monitoring import UptimeLog, InfrastructureMetric
from app.models.ticket import Ticket

class ReportService:
    @staticmethod
    def get_period_dates(period: str, custom_start=None, custom_end=None):
        today = date.today()
        if period == "weekly":
            start = today - timedelta(days=today.weekday() + 7)
            end = start + timedelta(days=6)
        elif period == "monthly":
            first = today.replace(day=1)
            end = first - timedelta(days=1)
            start = end.replace(day=1)
        elif period == "quarterly":
            q = (today.month - 1) // 3
            if q == 0:
                start, end = date(today.year - 1, 10, 1), date(today.year - 1, 12, 31)
            else:
                start = date(today.year, (q - 1) * 3 + 1, 1)
                em = q * 3
                end = date(today.year, em, monthrange(today.year, em)[1])
        elif period == "semi_annual":
            if today.month <= 6:
                start, end = date(today.year - 1, 7, 1), date(today.year - 1, 12, 31)
            else:
                start, end = date(today.year, 1, 1), date(today.year, 6, 30)
        elif period == "annual":
            start, end = date(today.year - 1, 1, 1), date(today.year - 1, 12, 31)
        elif period == "custom" and custom_start and custom_end:
            start, end = custom_start, custom_end
        else:
            start, end = today - timedelta(days=30), today
        return start, end

    @staticmethod
    async def generate_privacy_data(db, tenant_id, start, end):
        sd = datetime.combine(start, datetime.min.time())
        ed = datetime.combine(end, datetime.max.time())
        total_act = (await db.execute(select(func.count(ProcessingActivity.id)).where(ProcessingActivity.tenant_id == tenant_id))).scalar() or 0
        active_act = (await db.execute(select(func.count(ProcessingActivity.id)).where(ProcessingActivity.tenant_id == tenant_id, ProcessingActivity.status == "active"))).scalar() or 0
        cons_active = (await db.execute(select(func.count(ConsentRecord.id)).where(ConsentRecord.tenant_id == tenant_id, ConsentRecord.status == "active"))).scalar() or 0
        cons_withdrawn = (await db.execute(select(func.count(ConsentRecord.id)).where(ConsentRecord.tenant_id == tenant_id, ConsentRecord.status == "withdrawn", ConsentRecord.withdrawn_at.between(sd, ed)))).scalar() or 0
        dsar_total = (await db.execute(select(func.count(DSARRequest.id)).where(DSARRequest.tenant_id == tenant_id, DSARRequest.created_at.between(sd, ed)))).scalar() or 0
        inc_total = (await db.execute(select(func.count(Incident.id)).where(Incident.tenant_id == tenant_id, Incident.created_at.between(sd, ed)))).scalar() or 0
        inc_open = (await db.execute(select(func.count(Incident.id)).where(Incident.tenant_id == tenant_id, Incident.status == "open"))).scalar() or 0
        high_risk = (await db.execute(select(func.count(RiskAssessment.id)).where(RiskAssessment.tenant_id == tenant_id, RiskAssessment.risk_level.in_(["high", "very_high"])))).scalar() or 0
        return {"processing_activities": {"total": total_act, "active": active_act}, "consents": {"active": cons_active, "withdrawn_in_period": cons_withdrawn}, "dsar_requests": {"total_in_period": dsar_total}, "incidents": {"total_in_period": inc_total, "open": inc_open}, "high_risks": high_risk}

    @staticmethod
    async def generate_ticket_data(db, tenant_id, start, end):
        sd = datetime.combine(start, datetime.min.time())
        ed = datetime.combine(end, datetime.max.time())
        total = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant_id, Ticket.created_at.between(sd, ed)))).scalar() or 0
        sla_total = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant_id, Ticket.created_at.between(sd, ed), Ticket.sla_deadline.isnot(None)))).scalar() or 0
        sla_breached = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant_id, Ticket.created_at.between(sd, ed), Ticket.sla_breached == True))).scalar() or 0
        avg_resp = (await db.execute(select(func.avg(Ticket.response_time_minutes)).where(Ticket.tenant_id == tenant_id, Ticket.created_at.between(sd, ed), Ticket.response_time_minutes.isnot(None)))).scalar()
        avg_res = (await db.execute(select(func.avg(Ticket.resolution_time_minutes)).where(Ticket.tenant_id == tenant_id, Ticket.created_at.between(sd, ed), Ticket.resolution_time_minutes.isnot(None)))).scalar()
        sla_comp = round((1 - sla_breached / sla_total) * 100, 1) if sla_total > 0 else 100
        return {"total_in_period": total, "sla": {"compliance_percentage": sla_comp, "total_with_sla": sla_total, "breached": sla_breached}, "tma_minutes": round(float(avg_resp or 0), 1), "tmr_minutes": round(float(avg_res or 0), 1)}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/auth.py" << 'PYEOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from datetime import datetime, timezone
from app.database import get_db
from app.models.user import User, AuthToken
from app.models.tenant import Tenant
from app.services.auth_service import AuthService
from app.dependencies import get_current_user
from app.utils.security import decode_token, create_access_token, create_refresh_token

router = APIRouter(prefix="/api/auth", tags=["Auth"])

class LoginReq:
    def __init__(self, email: str, password: str):
        self.email = email
        self.password = password

@router.post("/login")
async def login(data: dict, db: AsyncSession = Depends(get_db)):
    result = await AuthService.login(db, data.get("email"), data.get("password"))
    return {"session_token": result["session_token"], "message": result["message"]}

@router.post("/verify-2fa")
async def verify_2fa(data: dict, db: AsyncSession = Depends(get_db)):
    code = data.get("code")
    token_result = await db.execute(select(AuthToken).where(AuthToken.token == code, AuthToken.token_type == "2fa_login", AuthToken.used == False, AuthToken.expires_at > datetime.now(timezone.utc)).order_by(AuthToken.created_at.desc()).limit(1))
    auth_token = token_result.scalar_one_or_none()
    if not auth_token:
        raise HTTPException(status_code=401, detail="Codigo invalido ou expirado")
    return await AuthService.verify_2fa(db, auth_token.user_id, code)

@router.post("/forgot-password")
async def forgot_password(data: dict, db: AsyncSession = Depends(get_db)):
    return await AuthService.forgot_password(db, data.get("email"))

@router.post("/reset-password")
async def reset_password(data: dict, db: AsyncSession = Depends(get_db)):
    return await AuthService.reset_password(db, data.get("token"), data.get("new_password"))

@router.post("/change-password")
async def change_password(data: dict, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await AuthService.change_password(db, current_user, data.get("current_password"), data.get("new_password"))

@router.post("/refresh")
async def refresh_token(data: dict, db: AsyncSession = Depends(get_db)):
    try:
        payload = decode_token(data.get("refresh_token"))
        if payload.get("type") != "refresh":
            raise HTTPException(status_code=401, detail="Token invalido")
    except Exception:
        raise HTTPException(status_code=401, detail="Refresh token invalido")
    from uuid import UUID
    user_id = UUID(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id, User.is_active == True))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=401, detail="Usuario nao encontrado")
    at = create_access_token(user.id, user.tenant_id, user.role)
    rt = create_refresh_token(user.id, user.tenant_id)
    return {"access_token": at, "refresh_token": rt, "token_type": "bearer"}

@router.get("/me")
async def get_me(current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t = (await db.execute(select(Tenant).where(Tenant.id == current_user.tenant_id))).scalar_one()
    return {"id": str(current_user.id), "email": current_user.email, "full_name": current_user.full_name, "role": current_user.role, "tenant_id": str(current_user.tenant_id), "tenant_name": t.name, "tenant_slug": t.slug}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/dashboard.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, and_, case
from datetime import datetime
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant
from app.models.user import User
from app.models.tenant import Tenant
from app.models.privacy import ProcessingActivity, ConsentRecord, DSARRequest, Incident, RiskAssessment
from app.models.ticket import Ticket
from app.models.monitoring import UptimeLog
from app.services.grafana_service import get_grafana_service
from app.services.report_service import ReportService

router = APIRouter(prefix="/api/dashboard", tags=["Dashboard"])

@router.get("/overview")
async def dashboard_overview(period: str = Query("monthly"), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    start, end = ReportService.get_period_dates(period)
    sd = datetime.combine(start, datetime.min.time())
    ed = datetime.combine(end, datetime.max.time())

    pa_total = (await db.execute(select(func.count(ProcessingActivity.id)).where(ProcessingActivity.tenant_id == tenant.id))).scalar() or 0
    pa_active = (await db.execute(select(func.count(ProcessingActivity.id)).where(ProcessingActivity.tenant_id == tenant.id, ProcessingActivity.status == "active"))).scalar() or 0
    c_active = (await db.execute(select(func.count(ConsentRecord.id)).where(ConsentRecord.tenant_id == tenant.id, ConsentRecord.status == "active"))).scalar() or 0
    c_withdrawn = (await db.execute(select(func.count(ConsentRecord.id)).where(ConsentRecord.tenant_id == tenant.id, ConsentRecord.status == "withdrawn", ConsentRecord.withdrawn_at.between(sd, ed)))).scalar() or 0
    d_open = (await db.execute(select(func.count(DSARRequest.id)).where(DSARRequest.tenant_id == tenant.id, DSARRequest.status.in_(["received", "in_review", "processing"])))).scalar() or 0
    d_done = (await db.execute(select(func.count(DSARRequest.id)).where(DSARRequest.tenant_id == tenant.id, DSARRequest.status == "completed", DSARRequest.completed_at.between(sd, ed)))).scalar() or 0
    i_open = (await db.execute(select(func.count(Incident.id)).where(Incident.tenant_id == tenant.id, Incident.status == "open"))).scalar() or 0
    i_period = (await db.execute(select(func.count(Incident.id)).where(Incident.tenant_id == tenant.id, Incident.created_at.between(sd, ed)))).scalar() or 0
    hr = (await db.execute(select(func.count(RiskAssessment.id)).where(RiskAssessment.tenant_id == tenant.id, RiskAssessment.risk_level.in_(["high", "very_high"])))).scalar() or 0
    t_open = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id, Ticket.status.in_(["open", "in_progress", "waiting"])))).scalar() or 0
    t_period = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id, Ticket.created_at.between(sd, ed)))).scalar() or 0
    sla_br = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id, Ticket.sla_breached == True, Ticket.created_at.between(sd, ed)))).scalar() or 0
    avg_tma = (await db.execute(select(func.avg(Ticket.response_time_minutes)).where(Ticket.tenant_id == tenant.id, Ticket.created_at.between(sd, ed), Ticket.response_time_minutes.isnot(None)))).scalar()
    avg_tmr = (await db.execute(select(func.avg(Ticket.resolution_time_minutes)).where(Ticket.tenant_id == tenant.id, Ticket.created_at.between(sd, ed), Ticket.resolution_time_minutes.isnot(None)))).scalar()

    gs = "not_configured"
    gd = {}
    gsrv = await get_grafana_service(db, tenant.id)
    if gsrv:
        try:
            gd = await gsrv.get_health()
            gs = "connected"
        except Exception:
            gs = "error"

    ust = await db.execute(select(UptimeLog.service_name, func.count(UptimeLog.id).label("t"), func.sum(case((UptimeLog.status == "up", 1), else_=0)).label("u"), func.avg(UptimeLog.response_time_ms).label("r")).where(UptimeLog.tenant_id == tenant.id, UptimeLog.checked_at.between(sd, ed)).group_by(UptimeLog.service_name))
    uv = [{"service": r.service_name, "uptime_pct": round(r.u / r.t * 100, 2) if r.t > 0 else 0, "avg_response_ms": round(float(r.r or 0), 2)} for r in ust.all()]

    return {"period": period, "period_start": start.isoformat(), "period_end": end.isoformat(), "tenant": {"name": tenant.name, "slug": tenant.slug, "theme_mode": tenant.theme_mode, "primary_color": tenant.primary_color, "secondary_color": tenant.secondary_color, "accent_color": tenant.accent_color}, "privacy": {"processing_activities": {"total": pa_total, "active": pa_active}, "consents": {"active": c_active, "withdrawn_in_period": c_withdrawn}, "dsar": {"open": d_open, "completed_in_period": d_done}, "incidents": {"open": i_open, "in_period": i_period}, "high_risks": hr}, "tickets": {"open": t_open, "in_period": t_period, "sla_breached": sla_br, "tma_minutes": round(float(avg_tma or 0), 1), "tmr_minutes": round(float(avg_tmr or 0), 1)}, "infrastructure": {"grafana_status": gs, "grafana_health": gd, "uptime_services": uv}}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/privacy.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from typing import Optional
from uuid import UUID
from datetime import datetime
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User
from app.models.tenant import Tenant
from app.models.privacy import ProcessingActivity, ConsentRecord, DSARRequest, Incident, RiskAssessment
from app.services.privacytools_service import get_privacytools_service

router = APIRouter(prefix="/api/privacy", tags=["Privacy"])

@router.get("/activities")
async def list_activities(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), search: Optional[str] = None, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(ProcessingActivity).where(ProcessingActivity.tenant_id == tenant.id)
    if search: q = q.where(ProcessingActivity.name.ilike(f"%{search}%"))
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(ProcessingActivity.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(r.id), "name": r.name, "legal_basis": r.legal_basis, "risk_level": r.risk_level, "status": r.status, "responsible_team": r.responsible_team, "next_review_at": str(r.next_review_at) if r.next_review_at else None, "created_at": r.created_at.isoformat()} for r in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/activities", status_code=201)
async def create_activity(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    a = ProcessingActivity(tenant_id=tenant.id, **data)
    db.add(a)
    await db.flush()
    return {"id": str(a.id)}

@router.get("/consents")
async def list_consents(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), status: Optional[str] = None, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(ConsentRecord).where(ConsentRecord.tenant_id == tenant.id)
    if status: q = q.where(ConsentRecord.status == status)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(ConsentRecord.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(r.id), "data_subject_name": r.data_subject_name, "purpose": r.purpose, "status": r.status, "channel": r.channel, "created_at": r.created_at.isoformat()} for r in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.get("/dsar")
async def list_dsar(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), status: Optional[str] = None, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(DSARRequest).where(DSARRequest.tenant_id == tenant.id)
    if status: q = q.where(DSARRequest.status == status)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(DSARRequest.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(r.id), "request_type": r.request_type, "data_subject_name": r.data_subject_name, "status": r.status, "priority": r.priority, "created_at": r.created_at.isoformat()} for r in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/dsar", status_code=201)
async def create_dsar(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    d = DSARRequest(tenant_id=tenant.id, **data)
    db.add(d)
    await db.flush()
    return {"id": str(d.id)}

@router.get("/incidents")
async def list_incidents(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(Incident).where(Incident.tenant_id == tenant.id)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(Incident.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(r.id), "title": r.title, "severity": r.severity, "status": r.status, "notified_anpd": r.notified_anpd, "created_at": r.created_at.isoformat()} for r in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/incidents", status_code=201)
async def create_incident(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    i = Incident(tenant_id=tenant.id, **data)
    db.add(i)
    await db.flush()
    return {"id": str(i.id)}

@router.get("/risks")
async def list_risks(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(RiskAssessment).where(RiskAssessment.tenant_id == tenant.id)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(RiskAssessment.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(r.id), "title": r.title, "assessment_type": r.assessment_type, "risk_level": r.risk_level, "status": r.status, "created_at": r.created_at.isoformat()} for r in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/sync")
async def sync_privacytools(current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    service = await get_privacytools_service(db, tenant.id)
    if not service:
        raise HTTPException(status_code=404, detail="PrivacyTools nao configurado")
    synced = {"activities": 0}
    try:
        activities = await service.get_activities()
        for item in activities.get("data", activities.get("items", [])):
            existing = await db.execute(select(ProcessingActivity).where(ProcessingActivity.tenant_id == tenant.id, ProcessingActivity.external_id == str(item.get("id"))))
            if not existing.scalar_one_or_none():
                db.add(ProcessingActivity(tenant_id=tenant.id, external_id=str(item.get("id")), name=item.get("name", "Sem nome"), description=item.get("description"), legal_basis=item.get("legal_basis"), status=item.get("status", "active"), synced_at=datetime.utcnow()))
                synced["activities"] += 1
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Erro ao sincronizar: {str(e)}")
    return {"message": "Sincronizacao concluida", "synced": synced}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/monitoring.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from typing import Optional
from datetime import datetime, timedelta
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant
from app.models.user import User
from app.models.tenant import Tenant
from app.models.monitoring import UptimeLog, InfrastructureMetric
from app.services.grafana_service import get_grafana_service

router = APIRouter(prefix="/api/monitoring", tags=["Monitoring"])

@router.get("/grafana/dashboards")
async def grafana_dashboards(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    service = await get_grafana_service(db, tenant.id)
    if not service:
        raise HTTPException(status_code=404, detail="Grafana nao configurado")
    try:
        return {"dashboards": await service.get_dashboards()}
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))

@router.get("/grafana/health")
async def grafana_health(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    service = await get_grafana_service(db, tenant.id)
    if not service:
        return {"status": "not_configured"}
    try:
        return {"status": "connected", "health": await service.get_health()}
    except Exception:
        return {"status": "error"}

@router.get("/uptime")
async def get_uptime(service_name: Optional[str] = None, hours: int = Query(24, ge=1, le=720), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    since = datetime.utcnow() - timedelta(hours=hours)
    q = select(UptimeLog).where(UptimeLog.tenant_id == tenant.id, UptimeLog.checked_at >= since)
    if service_name: q = q.where(UptimeLog.service_name == service_name)
    q = q.order_by(UptimeLog.checked_at.desc()).limit(1000)
    result = await db.execute(q)
    return {"logs": [{"service_name": l.service_name, "status": l.status, "response_time_ms": l.response_time_ms, "checked_at": l.checked_at.isoformat()} for l in result.scalars()]}

@router.get("/embed-url")
async def get_embed_url(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    service = await get_grafana_service(db, tenant.id)
    if not service:
        raise HTTPException(status_code=404, detail="Grafana nao configurado")
    return {"embed_url": f"{service.base_url}/?orgId=1&kiosk&theme=dark", "base_url": service.base_url}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/tickets.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, and_, case
from typing import Optional
from uuid import UUID
from datetime import datetime, date, timedelta
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User
from app.models.tenant import Tenant
from app.models.ticket import Ticket
from app.services.report_service import ReportService

router = APIRouter(prefix="/api/tickets", tags=["Tickets"])

@router.get("/")
async def list_tickets(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), status: Optional[str] = None, priority: Optional[str] = None, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(Ticket).where(Ticket.tenant_id == tenant.id)
    if status: q = q.where(Ticket.status == status)
    if priority: q = q.where(Ticket.priority == priority)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(Ticket.created_at.desc())
    result = await db.execute(q)
    return {"items": [{"id": str(t.id), "ticket_number": t.ticket_number, "title": t.title, "priority": t.priority, "status": t.status, "sla_breached": t.sla_breached, "response_time_minutes": t.response_time_minutes, "created_at": t.created_at.isoformat()} for t in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/", status_code=201)
async def create_ticket(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager", "user")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    t = Ticket(tenant_id=tenant.id, **data)
    count = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id))).scalar()
    t.ticket_number = f"TKT-{(count or 0) + 1:06d}"
    db.add(t)
    await db.flush()
    return {"id": str(t.id), "ticket_number": t.ticket_number}

@router.put("/{ticket_id}")
async def update_ticket(ticket_id: UUID, data: dict, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Ticket).where(Ticket.id == ticket_id, Ticket.tenant_id == tenant.id))
    ticket = result.scalar_one_or_none()
    if not ticket:
        raise HTTPException(status_code=404, detail="Ticket nao encontrado")
    for k, v in data.items():
        setattr(ticket, k, v)
    if data.get("status") == "resolved" and not ticket.resolved_at:
        ticket.resolved_at = datetime.utcnow()
        if ticket.created_at:
            ticket.resolution_time_minutes = int((ticket.resolved_at - ticket.created_at).total_seconds() / 60)
    return {"message": "Ticket atualizado"}

@router.get("/metrics/sla")
async def sla_metrics(period: str = Query("monthly"), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    start, end = ReportService.get_period_dates(period)
    sd = datetime.combine(start, datetime.min.time())
    ed = datetime.combine(end, datetime.max.time())
    bf = and_(Ticket.tenant_id == tenant.id, Ticket.created_at.between(sd, ed))
    total_sla = (await db.execute(select(func.count(Ticket.id)).where(bf, Ticket.sla_deadline.isnot(None)))).scalar() or 0
    sla_met = (await db.execute(select(func.count(Ticket.id)).where(bf, Ticket.sla_breached == False, Ticket.sla_deadline.isnot(None)))).scalar() or 0
    tma_by_p = await db.execute(select(Ticket.priority, func.avg(Ticket.response_time_minutes).label("ar"), func.avg(Ticket.resolution_time_minutes).label("are"), func.count(Ticket.id).label("c")).where(bf).group_by(Ticket.priority))
    weekly = []
    for i in range(7, -1, -1):
        ws = date.today() - timedelta(days=date.today().weekday() + 7 * (i + 1))
        we = ws + timedelta(days=6)
        wsd = datetime.combine(ws, datetime.min.time())
        wed = datetime.combine(we, datetime.max.time())
        wt = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id, Ticket.created_at.between(wsd, wed)))).scalar() or 0
        wb = (await db.execute(select(func.count(Ticket.id)).where(Ticket.tenant_id == tenant.id, Ticket.created_at.between(wsd, wed), Ticket.sla_breached == True))).scalar() or 0
        weekly.append({"week_start": ws.isoformat(), "total": wt, "breached": wb, "compliance": round((1 - wb / wt) * 100, 1) if wt > 0 else 100})
    return {"period": period, "sla_compliance_pct": round(sla_met / total_sla * 100, 1) if total_sla > 0 else 100, "total_with_sla": total_sla, "sla_met": sla_met, "sla_breached": total_sla - sla_met, "by_priority": [{"priority": r.priority, "avg_response_min": round(float(r.ar or 0), 1), "avg_resolution_min": round(float(r.are or 0), 1), "count": r.c} for r in tma_by_p.all()], "weekly_trend": weekly}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/reports.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User
from app.models.tenant import Tenant
from app.models.report import ReportTemplate, GeneratedReport, ReportSchedule
from app.services.report_service import ReportService

router = APIRouter(prefix="/api/reports", tags=["Reports"])

@router.get("/templates")
async def list_templates(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(ReportTemplate).where(ReportTemplate.tenant_id == tenant.id).order_by(ReportTemplate.name))
    return {"items": [{"id": str(t.id), "name": t.name, "report_type": t.report_type, "period": t.period, "format": t.format} for t in result.scalars()]}

@router.post("/templates", status_code=201)
async def create_template(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    t = ReportTemplate(tenant_id=tenant.id, created_by=current_user.id, **data)
    db.add(t)
    await db.flush()
    return {"id": str(t.id)}

@router.post("/generate")
async def generate_report(data: dict, current_user: User = Depends(require_roles("super_admin", "admin", "manager")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    tr = (await db.execute(select(ReportTemplate).where(ReportTemplate.id == UUID(data["template_id"]), ReportTemplate.tenant_id == tenant.id))).scalar_one_or_none()
    if not tr:
        raise HTTPException(status_code=404, detail="Template nao encontrado")
    from datetime import date as dt
    ps = dt.fromisoformat(data["period_start"])
    pe = dt.fromisoformat(data["period_end"])
    report = GeneratedReport(tenant_id=tenant.id, template_id=tr.id, title=f"{tr.name} - {ps} a {pe}", report_type=tr.report_type, period=tr.period, period_start=ps, period_end=pe, status="generating", generated_by=current_user.id)
    db.add(report)
    await db.flush()
    rd = {}
    if tr.report_type in ("privacy", "combined"):
        rd["privacy"] = await ReportService.generate_privacy_data(db, tenant.id, ps, pe)
    if tr.report_type in ("tickets", "combined"):
        rd["tickets"] = await ReportService.generate_ticket_data(db, tenant.id, ps, pe)
    report.status = "completed"
    report.metadata = rd
    return {"id": str(report.id), "status": "completed", "data": rd}

@router.get("/history")
async def report_history(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(GeneratedReport).where(GeneratedReport.tenant_id == tenant.id).order_by(GeneratedReport.created_at.desc()).offset((page - 1) * per_page).limit(per_page))
    return {"items": [{"id": str(r.id), "title": r.title, "report_type": r.report_type, "status": r.status, "period_start": str(r.period_start) if r.period_start else None, "period_end": str(r.period_end) if r.period_end else None, "created_at": r.created_at.isoformat()} for r in result.scalars()]}

@router.post("/schedules", status_code=201)
async def create_schedule(data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    s = ReportSchedule(tenant_id=tenant.id, **data)
    db.add(s)
    await db.flush()
    return {"id": str(s.id)}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/users.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from typing import Optional
from uuid import UUID
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User, ServiceType
from app.models.tenant import Tenant
from app.utils.security import hash_password

router = APIRouter(prefix="/api/users", tags=["Users"])

@router.get("/")
async def list_users(page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100), role: Optional[str] = None, current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    q = select(User).where(User.tenant_id == tenant.id)
    if role: q = q.where(User.role == role)
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar()
    q = q.offset((page - 1) * per_page).limit(per_page).order_by(User.full_name)
    result = await db.execute(q)
    return {"items": [{"id": str(u.id), "email": u.email, "full_name": u.full_name, "role": u.role, "department": u.department, "two_factor_enabled": u.two_factor_enabled, "is_active": u.is_active, "last_login": u.last_login.isoformat() if u.last_login else None, "created_at": u.created_at.isoformat()} for u in result.scalars()], "total": total, "page": page, "per_page": per_page}

@router.post("/", status_code=201)
async def create_user(data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    existing = await db.execute(select(User).where(User.tenant_id == tenant.id, User.email == data.get("email")))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Email ja cadastrado")
    uc = (await db.execute(select(func.count(User.id)).where(User.tenant_id == tenant.id))).scalar() or 0
    if uc >= tenant.max_users:
        raise HTTPException(status_code=403, detail="Limite de usuarios atingido")
    u = User(tenant_id=tenant.id, email=data["email"], password_hash=hash_password(data["password"]), full_name=data["full_name"], role=data.get("role", "user"), phone=data.get("phone"), department=data.get("department"))
    db.add(u)
    await db.flush()
    return {"id": str(u.id)}

@router.put("/{user_id}")
async def update_user(user_id: UUID, data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.id == user_id, User.tenant_id == tenant.id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Usuario nao encontrado")
    for k, v in data.items():
        if k != "password":
            setattr(user, k, v)
    return {"message": "Usuario atualizado"}

@router.get("/service-types")
async def list_service_types(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(ServiceType).where(ServiceType.tenant_id == tenant.id).order_by(ServiceType.name))
    return {"items": [{"id": str(s.id), "name": s.name, "category": s.category, "sla_hours": s.sla_hours, "is_active": s.is_active} for s in result.scalars()]}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/platforms.py" << 'PYEOF'
from fastapi import APIRouter, Depends, Query, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User
from app.models.tenant import Tenant
from app.models.platform import Platform
from app.utils.security import encrypt_value

router = APIRouter(prefix="/api/platforms", tags=["Platforms"])

@router.get("/")
async def list_platforms(current_user: User = Depends(get_current_user), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Platform).where(Platform.tenant_id == tenant.id).order_by(Platform.name))
    return {"items": [{"id": str(p.id), "name": p.name, "platform_type": p.platform_type, "base_url": p.base_url, "auth_type": p.auth_type, "is_active": p.is_active, "last_sync_at": p.last_sync_at.isoformat() if p.last_sync_at else None, "polling_interval_seconds": p.polling_interval_seconds, "created_at": p.created_at.isoformat()} for p in result.scalars()]}

@router.post("/", status_code=201)
async def create_platform(data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    p = Platform(tenant_id=tenant.id, name=data["name"], platform_type=data["platform_type"], base_url=data["base_url"], description=data.get("description"), auth_type=data.get("auth_type", "api_key"), extra_config=data.get("extra_config", {}), polling_interval_seconds=data.get("polling_interval_seconds", 300), created_by=current_user.id)
    if data.get("api_key"): p.api_key_encrypted = encrypt_value(data["api_key"])
    if data.get("username"): p.username_encrypted = encrypt_value(data["username"])
    if data.get("password"): p.password_encrypted = encrypt_value(data["password"])
    if data.get("bearer_token"): p.bearer_token_encrypted = encrypt_value(data["bearer_token"])
    db.add(p)
    await db.flush()
    return {"id": str(p.id)}

@router.put("/{platform_id}")
async def update_platform(platform_id: UUID, data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Platform).where(Platform.id == platform_id, Platform.tenant_id == tenant.id))
    p = result.scalar_one_or_none()
    if not p:
        raise HTTPException(status_code=404, detail="Plataforma nao encontrada")
    for k, v in data.items():
        if k == "api_key" and v: p.api_key_encrypted = encrypt_value(v)
        elif k == "username" and v: p.username_encrypted = encrypt_value(v)
        elif k == "password" and v: p.password_encrypted = encrypt_value(v)
        elif k not in ("api_key", "username", "password"): setattr(p, k, v)
    return {"message": "Plataforma atualizada"}

@router.delete("/{platform_id}")
async def delete_platform(platform_id: UUID, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Platform).where(Platform.id == platform_id, Platform.tenant_id == tenant.id))
    p = result.scalar_one_or_none()
    if not p:
        raise HTTPException(status_code=404, detail="Plataforma nao encontrada")
    p.is_active = False
    return {"message": "Plataforma desativada"}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/routers/tenants.py" << 'PYEOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from uuid import UUID
from app.database import get_db
from app.dependencies import get_current_user, get_current_tenant, require_roles
from app.models.user import User
from app.models.tenant import Tenant

router = APIRouter(prefix="/api/tenants", tags=["Tenants"])

@router.get("/current")
async def get_current_tenant_info(tenant: Tenant = Depends(get_current_tenant)):
    return {"id": str(tenant.id), "name": tenant.name, "slug": tenant.slug, "domain": tenant.domain, "logo_url": tenant.logo_url, "favicon_url": tenant.favicon_url, "primary_color": tenant.primary_color, "secondary_color": tenant.secondary_color, "accent_color": tenant.accent_color, "theme_mode": tenant.theme_mode, "plan": tenant.plan, "max_users": tenant.max_users}

@router.put("/current/branding")
async def update_branding(data: dict, current_user: User = Depends(require_roles("super_admin", "admin")), tenant: Tenant = Depends(get_current_tenant), db: AsyncSession = Depends(get_db)):
    for k, v in data.items():
        setattr(tenant, k, v)
    return {"message": "Branding atualizado"}

@router.post("/", status_code=201)
async def create_tenant(data: dict, current_user: User = Depends(require_roles("super_admin")), db: AsyncSession = Depends(get_db)):
    existing = await db.execute(select(Tenant).where(Tenant.slug == data.get("slug")))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409, detail="Slug ja em uso")
    t = Tenant(**data)
    db.add(t)
    await db.flush()
    return {"id": str(t.id)}
PYEOF

    cat > "${MONIHOOK_DIR}/backend/app/main.py" << 'PYEOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from app.config import get_settings
from app.routers import auth, dashboard, privacy, monitoring, tickets, reports, users, platforms, tenants

settings = get_settings()

@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"Monihook v{settings.APP_VERSION} iniciando...")
    yield
    print("Monihook encerrando...")

app = FastAPI(title="Monihook API", version=settings.APP_VERSION, lifespan=lifespan, docs_url="/api/docs", redoc_url="/api/redoc")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.include_router(auth.router)
app.include_router(dashboard.router)
app.include_router(privacy.router)
app.include_router(monitoring.router)
app.include_router(tickets.router)
app.include_router(reports.router)
app.include_router(users.router)
app.include_router(platforms.router)
app.include_router(tenants.router)

@app.get("/api/health")
async def health_check():
    return {"status": "healthy", "version": settings.APP_VERSION}
PYEOF

    # Admin bootstrap script
    cat > "${MONIHOOK_DIR}/backend/app/seed_admin.py" << 'PYEOF'
"""Seed admin user on first startup."""
import asyncio
from sqlalchemy import select
from app.database import AsyncSessionLocal, engine, Base
from app.models.tenant import Tenant
from app.models.user import User
from app.utils.security import hash_password
from app.config import get_settings

settings = get_settings()

async def seed():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(Tenant).where(Tenant.slug == "admin"))
        tenant = result.scalar_one_or_none()
        if not tenant:
            tenant = Tenant(name=settings.ADMIN_COMPANY, slug="admin", email=settings.ADMIN_EMAIL)
            db.add(tenant)
            await db.flush()
        user_result = await db.execute(select(User).where(User.tenant_id == tenant.id, User.email == settings.ADMIN_EMAIL))
        if not user_result.scalar_one_or_none():
            admin = User(tenant_id=tenant.id, email=settings.ADMIN_EMAIL, password_hash=hash_password(settings.ADMIN_PASSWORD), full_name=settings.ADMIN_NAME, role="super_admin", auth_status="active")
            db.add(admin)
            await db.commit()
            print(f"Admin criado: {settings.ADMIN_EMAIL}")
        else:
            print("Admin ja existe")

if __name__ == "__main__":
    asyncio.run(seed())
PYEOF

    log_info "Backend completo gerado"
}

generate_frontend() {
    log_step "Gerando Frontend (React)"

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

    cat > "${MONIHOOK_DIR}/frontend/nginx.conf" << 'FNEOF'
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
FNEOF

    cat > "${MONIHOOK_DIR}/frontend/package.json" << 'PJEOF'
{
  "name": "monihook-frontend",
  "version": "1.0.1",
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

    cat > "${MONIHOOK_DIR}/frontend/src/index.js" << 'JSEOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
const s = document.createElement('style');
s.textContent = '*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}body{-webkit-font-smoothing:antialiased}::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:#2a2d3a;border-radius:3px}';
document.head.appendChild(s);
ReactDOM.createRoot(document.getElementById('root')).render(<App />);
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/theme.js" << 'JSEOF'
export const defaultTheme = {
  dark: { bg: '#0b0e14', surface: '#111520', surfaceHover: '#181d2a', border: '#1e2333', text: '#e4e8ef', textMuted: '#6b7280', primary: '#1B5E8C', secondary: '#E8A838', accent: '#2ECC71', danger: '#EF4444', warning: '#F59E0B', info: '#3B82F6', cardBg: '#131720' },
  light: { bg: '#f5f6fa', surface: '#ffffff', surfaceHover: '#f0f1f5', border: '#e2e5ee', text: '#1a1d27', textMuted: '#6b7280', primary: '#1B5E8C', secondary: '#E8A838', accent: '#2ECC71', danger: '#EF4444', warning: '#F59E0B', info: '#3B82F6', cardBg: '#ffffff' },
};
export function buildTheme(b, mode = 'dark') {
  const base = defaultTheme[mode] || defaultTheme.dark;
  if (!b) return base;
  return { ...base, primary: b.primary_color || base.primary, secondary: b.secondary_color || base.secondary, accent: b.accent_color || base.accent };
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/services/api.js" << 'JSEOF'
import axios from 'axios';
const API = process.env.REACT_APP_API_URL || '/api';
const api = axios.create({ baseURL: API, timeout: 30000, headers: { 'Content-Type': 'application/json' } });
api.interceptors.request.use((c) => { const t = localStorage.getItem('access_token'); if (t) c.headers.Authorization = `Bearer ${t}`; return c; });
api.interceptors.response.use((r) => r, async (e) => {
  const o = e.config;
  if (e.response?.status === 401 && !o._retry) {
    o._retry = true;
    try {
      const rt = localStorage.getItem('refresh_token');
      const r = await axios.post(`${API}/auth/refresh`, { refresh_token: rt });
      localStorage.setItem('access_token', r.data.access_token);
      localStorage.setItem('refresh_token', r.data.refresh_token);
      o.headers.Authorization = `Bearer ${r.data.access_token}`;
      return api(o);
    } catch (re) { localStorage.clear(); window.location.href = '/login'; }
  }
  return Promise.reject(e);
});
export default api;
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/contexts/AuthContext.js" << 'JSEOF'
import React, { createContext, useContext, useState, useEffect } from 'react';
import api from '../services/api';
const AuthContext = createContext(null);
export function AuthProvider({ children }) {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => { const u = localStorage.getItem('user'); const t = localStorage.getItem('access_token'); if (u && t) setUser(JSON.parse(u)); setLoading(false); }, []);
  const login = async (email, password) => { const r = await api.post('/auth/login', { email, password }); return r.data; };
  const verify2FA = async (code) => { const r = await api.post('/auth/verify-2fa', { code }); const d = r.data; localStorage.setItem('access_token', d.access_token); localStorage.setItem('refresh_token', d.refresh_token); localStorage.setItem('user', JSON.stringify(d.user)); setUser(d.user); return d; };
  const logout = () => { localStorage.clear(); setUser(null); };
  return (<AuthContext.Provider value={{ user, loading, login, verify2FA, logout }}>{children}</AuthContext.Provider>);
}
export const useAuth = () => useContext(AuthContext);
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/contexts/ThemeContext.js" << 'JSEOF'
import React, { createContext, useContext, useState, useEffect } from 'react';
import { buildTheme } from '../theme';
import api from '../services/api';
const ThemeContext = createContext(null);
export function ThemeProvider({ children }) {
  const [mode, setMode] = useState('dark');
  const [branding, setBranding] = useState(null);
  const [theme, setTheme] = useState(buildTheme(null, 'dark'));
  useEffect(() => { api.get('/tenants/current').then(r => { setBranding(r.data); setMode(r.data.theme_mode || 'dark'); }).catch(() => {}); }, []);
  useEffect(() => { setTheme(buildTheme(branding, mode)); }, [mode, branding]);
  const toggleMode = () => setMode(m => m === 'dark' ? 'light' : 'dark');
  const loadBranding = async () => { try { const r = await api.get('/tenants/current'); setBranding(r.data); setMode(r.data.theme_mode || 'dark'); } catch(e){} };
  return (<ThemeContext.Provider value={{ theme, mode, branding, toggleMode, loadBranding }}>{children}</ThemeContext.Provider>);
}
export const useTheme = () => useContext(ThemeContext);
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/App.js" << 'JSEOF'
import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './contexts/AuthContext';
import { ThemeProvider, useTheme } from './contexts/ThemeContext';
import { Toaster } from 'react-hot-toast';
import LoginPage from './components/Auth/LoginPage';
import TwoFactorPage from './components/Auth/TwoFactorPage';
import ForgotPassword from './components/Auth/ForgotPassword';
import ResetPassword from './components/Auth/ResetPassword';
import MainLayout from './components/Layout/MainLayout';
import DashboardPage from './components/Dashboard/DashboardPage';
import PrivacyPage from './components/Privacy/PrivacyPage';
import InfrastructurePage from './components/Infrastructure/InfrastructurePage';
import TicketsPage from './components/Tickets/TicketsPage';
import ReportsPage from './components/Reports/ReportsPage';
import SettingsPage from './components/Settings/SettingsPage';

function ProtectedRoute({ children }) {
  const { user, loading } = useAuth();
  if (loading) return <div style={{display:'flex',justifyContent:'center',alignItems:'center',height:'100vh',background:'#0b0e14',color:'#6b7280'}}>Carregando...</div>;
  if (!user) return <Navigate to="/login" />;
  return children;
}

function AppContent() {
  const { theme } = useTheme();
  return (
    <div style={{ fontFamily: "'DM Mono', monospace", background: theme.bg, color: theme.text, minHeight: '100vh' }}>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route path="/verify-2fa" element={<TwoFactorPage />} />
          <Route path="/forgot-password" element={<ForgotPassword />} />
          <Route path="/reset-password" element={<ResetPassword />} />
          <Route path="/" element={<ProtectedRoute><MainLayout /></ProtectedRoute>}>
            <Route index element={<DashboardPage />} />
            <Route path="privacy/*" element={<PrivacyPage />} />
            <Route path="infrastructure/*" element={<InfrastructurePage />} />
            <Route path="tickets/*" element={<TicketsPage />} />
            <Route path="reports/*" element={<ReportsPage />} />
            <Route path="settings/*" element={<SettingsPage />} />
          </Route>
        </Routes>
      </BrowserRouter>
      <Toaster position="top-right" />
    </div>
  );
}

export default function App() {
  return (<AuthProvider><ThemeProvider><AppContent /></ThemeProvider></AuthProvider>);
}
JSEOF

    # Auth components
    mkdir -p "${MONIHOOK_DIR}/frontend/src/components/Auth"
    cat > "${MONIHOOK_DIR}/frontend/src/components/Auth/LoginPage.js" << 'JSEOF'
import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { useTheme } from '../../contexts/ThemeContext';
import { Shield, Eye, EyeOff } from 'lucide-react';
import toast from 'react-hot-toast';
export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPw, setShowPw] = useState(false);
  const [loading, setLoading] = useState(false);
  const { login } = useAuth();
  const { theme } = useTheme();
  const navigate = useNavigate();
  const handleSubmit = async (e) => { e.preventDefault(); setLoading(true); try { await login(email, password); navigate('/verify-2fa'); } catch (err) { toast.error(err.response?.data?.detail || 'Erro ao fazer login'); } finally { setLoading(false); } };
  const s = { container: { minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: theme.bg, padding: 20 }, card: { width: '100%', maxWidth: 420, background: theme.surface, borderRadius: 16, border: `1px solid ${theme.border}`, padding: 48, position: 'relative', overflow: 'hidden' }, glow: { position: 'absolute', top: 0, left: 0, right: 0, height: 3, background: `linear-gradient(90deg, ${theme.primary}, ${theme.secondary}, ${theme.accent})` }, title: { fontFamily: "'Syne', sans-serif", fontSize: 28, fontWeight: 800, color: theme.text, letterSpacing: -1, marginBottom: 6, textAlign: 'center' }, sub: { fontSize: 13, color: theme.textMuted, textAlign: 'center', marginBottom: 32 }, input: { width: '100%', padding: '12px 16px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 10, color: theme.text, fontSize: 14, fontFamily: "'DM Mono', monospace", outline: 'none', marginBottom: 16 }, btn: { width: '100%', padding: '14px 0', background: `linear-gradient(135deg, ${theme.primary}, ${theme.secondary})`, border: 'none', borderRadius: 10, color: '#fff', fontSize: 14, fontWeight: 700, fontFamily: "'Syne', sans-serif", cursor: 'pointer', marginTop: 8 }, link: { color: theme.primary, textDecoration: 'none', fontSize: 13, textAlign: 'center', display: 'block', marginTop: 16 } };
  return (
    <div style={s.container}>
      <div style={s.card}>
        <div style={s.glow} />
        <div style={{ textAlign: 'center', marginBottom: 24 }}><div style={{ width: 56, height: 56, borderRadius: 14, background: `linear-gradient(135deg, ${theme.primary}, ${theme.secondary})`, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginBottom: 16 }}><Shield color="#fff" size={28} /></div></div>
        <h1 style={s.title}>Monihook</h1>
        <p style={s.sub}>Monitoramento de Servicos de Privacidade</p>
        <form onSubmit={handleSubmit}>
          <input style={s.input} type="email" value={email} onChange={e => setEmail(e.target.value)} placeholder="Email" required autoFocus />
          <div style={{ position: 'relative' }}>
            <input style={{ ...s.input, paddingRight: 40 }} type={showPw ? 'text' : 'password'} value={password} onChange={e => setPassword(e.target.value)} placeholder="Senha" required />
            <button type="button" onClick={() => setShowPw(!showPw)} style={{ position: 'absolute', right: 12, top: 14, background: 'none', border: 'none', color: theme.textMuted, cursor: 'pointer' }}>{showPw ? <EyeOff size={16} /> : <Eye size={16} />}</button>
          </div>
          <button type="submit" style={{ ...s.btn, opacity: loading ? 0.6 : 1 }} disabled={loading}>{loading ? 'Verificando...' : 'Entrar'}</button>
        </form>
        <a style={s.link} href="/forgot-password">Esqueci minha senha</a>
      </div>
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Auth/TwoFactorPage.js" << 'JSEOF'
import React, { useState, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { useTheme } from '../../contexts/ThemeContext';
import { ShieldCheck } from 'lucide-react';
import toast from 'react-hot-toast';
export default function TwoFactorPage() {
  const [code, setCode] = useState(['','','','','','']);
  const [loading, setLoading] = useState(false);
  const refs = useRef([]);
  const { verify2FA } = useAuth();
  const { theme } = useTheme();
  const navigate = useNavigate();
  const handleChange = (i, v) => { if (!/^\d*$/.test(v)) return; const c = [...code]; c[i] = v.slice(-1); setCode(c); if (v && i < 5) refs.current[i+1]?.focus(); };
  const handleKey = (i, e) => { if (e.key === 'Backspace' && !code[i] && i > 0) refs.current[i-1]?.focus(); };
  const handlePaste = (e) => { e.preventDefault(); const p = e.clipboardData.getData('text').replace(/\D/g,'').slice(0,6); if (p.length === 6) { setCode(p.split('')); refs.current[5]?.focus(); } };
  const handleSubmit = async (e) => { e.preventDefault(); const fc = code.join(''); if (fc.length !== 6) { toast.error('Digite o codigo completo'); return; } setLoading(true); try { await verify2FA(fc); navigate('/'); toast.success('Bem-vindo!'); } catch (err) { toast.error(err.response?.data?.detail || 'Codigo invalido'); setCode(['','','','','','']); refs.current[0]?.focus(); } finally { setLoading(false); } };
  const s = { container: { minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: theme.bg, padding: 20 }, card: { width: '100%', maxWidth: 420, background: theme.surface, borderRadius: 16, border: `1px solid ${theme.border}`, padding: 48, textAlign: 'center', position: 'relative', overflow: 'hidden' }, glow: { position: 'absolute', top: 0, left: 0, right: 0, height: 3, background: `linear-gradient(90deg, ${theme.primary}, ${theme.accent})` }, title: { fontFamily: "'Syne', sans-serif", fontSize: 22, fontWeight: 700, color: theme.text, marginBottom: 8 }, sub: { fontSize: 13, color: theme.textMuted, marginBottom: 32 }, codeRow: { display: 'flex', gap: 10, justifyContent: 'center', marginBottom: 32 }, codeInput: { width: 48, height: 56, textAlign: 'center', fontSize: 24, fontFamily: "'DM Mono', monospace", fontWeight: 700, background: theme.bg, border: `2px solid ${theme.border}`, borderRadius: 12, color: theme.text, outline: 'none' }, btn: { width: '100%', padding: '14px 0', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, border: 'none', borderRadius: 10, color: '#fff', fontSize: 14, fontWeight: 700, fontFamily: "'Syne', sans-serif", cursor: 'pointer' } };
  return (
    <div style={s.container}>
      <div style={s.card}>
        <div style={s.glow} />
        <div style={{ width: 56, height: 56, borderRadius: 14, background: `linear-gradient(135deg, ${theme.accent}, ${theme.primary})`, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginBottom: 20 }}><ShieldCheck color="#fff" size={28} /></div>
        <h2 style={s.title}>Verificacao em Duas Etapas</h2>
        <p style={s.sub}>Enviamos um codigo de 6 digitos para seu email.</p>
        <form onSubmit={handleSubmit}>
          <div style={s.codeRow} onPaste={handlePaste}>
            {code.map((d, i) => (<input key={i} ref={el => refs.current[i] = el} style={{ ...s.codeInput, borderColor: d ? theme.primary : theme.border }} type="text" inputMode="numeric" maxLength={1} value={d} onChange={e => handleChange(i, e.target.value)} onKeyDown={e => handleKey(i, e)} />))}
          </div>
          <button type="submit" style={{ ...s.btn, opacity: loading ? 0.6 : 1 }} disabled={loading}>{loading ? 'Verificando...' : 'Verificar'}</button>
        </form>
      </div>
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Auth/ForgotPassword.js" << 'JSEOF'
import React, { useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { KeyRound, ArrowLeft } from 'lucide-react';
import api from '../../services/api';
export default function ForgotPassword() {
  const [email, setEmail] = useState(''); const [sent, setSent] = useState(false); const [loading, setLoading] = useState(false);
  const { theme } = useTheme();
  const handleSubmit = async (e) => { e.preventDefault(); setLoading(true); try { await api.post('/auth/forgot-password', { email }); } catch(e){} setSent(true); setLoading(false); };
  const s = { container: { minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: theme.bg, padding: 20 }, card: { width: '100%', maxWidth: 420, background: theme.surface, borderRadius: 16, border: `1px solid ${theme.border}`, padding: 48, textAlign: 'center' }, title: { fontFamily: "'Syne', sans-serif", fontSize: 22, fontWeight: 700, color: theme.text, marginBottom: 12 }, text: { fontSize: 13, color: theme.textMuted, marginBottom: 24 }, input: { width: '100%', padding: '12px 16px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 10, color: theme.text, fontSize: 14, fontFamily: "'DM Mono', monospace", outline: 'none', marginBottom: 16 }, btn: { width: '100%', padding: '14px 0', background: `linear-gradient(135deg, ${theme.primary}, ${theme.secondary})`, border: 'none', borderRadius: 10, color: '#fff', fontSize: 14, fontWeight: 700, cursor: 'pointer' }, link: { display: 'inline-flex', alignItems: 'center', gap: 6, color: theme.primary, textDecoration: 'none', fontSize: 13, marginTop: 16 } };
  if (sent) return (<div style={s.container}><div style={s.card}><h2 style={s.title}>Email Enviado</h2><p style={s.text}>Se o email estiver cadastrado, voce recebera um link.</p><a href="/login" style={s.link}><ArrowLeft size={14} />Voltar ao login</a></div></div>);
  return (<div style={s.container}><div style={s.card}><div style={{ width: 48, height: 48, borderRadius: 12, background: `linear-gradient(135deg, ${theme.primary}, ${theme.secondary})`, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', marginBottom: 20 }}><KeyRound color="#fff" size={22} /></div><h2 style={s.title}>Recuperar Senha</h2><p style={s.text}>Informe seu email para receber um link de recuperacao.</p><form onSubmit={handleSubmit}><input style={s.input} type="email" value={email} onChange={e => setEmail(e.target.value)} placeholder="seu@email.com" required /><button type="submit" style={s.btn} disabled={loading}>{loading ? 'Enviando...' : 'Enviar Link'}</button></form><a href="/login" style={s.link}><ArrowLeft size={14} />Voltar ao login</a></div></div>);
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Auth/ResetPassword.js" << 'JSEOF'
import React, { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import toast from 'react-hot-toast';
export default function ResetPassword() {
  const [sp] = useSearchParams(); const [pw, setPw] = useState(''); const [cf, setCf] = useState(''); const [loading, setLoading] = useState(false);
  const { theme } = useTheme(); const navigate = useNavigate(); const token = sp.get('token');
  const handleSubmit = async (e) => { e.preventDefault(); if (pw !== cf) { toast.error('Senhas nao conferem'); return; } setLoading(true); try { await api.post('/auth/reset-password', { token, new_password: pw }); toast.success('Senha redefinida!'); navigate('/login'); } catch(e) { toast.error(e.response?.data?.detail || 'Token invalido'); } setLoading(false); };
  const s = { container: { minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: theme.bg }, card: { width: '100%', maxWidth: 420, background: theme.surface, borderRadius: 16, border: `1px solid ${theme.border}`, padding: 48 }, title: { fontFamily: "'Syne', sans-serif", fontSize: 22, fontWeight: 700, color: theme.text, marginBottom: 24, textAlign: 'center' }, label: { fontSize: 12, color: theme.textMuted, marginBottom: 4, display: 'block' }, input: { width: '100%', padding: '12px 16px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 10, color: theme.text, fontSize: 14, fontFamily: "'DM Mono', monospace", outline: 'none', marginBottom: 16 }, btn: { width: '100%', padding: '14px 0', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, border: 'none', borderRadius: 10, color: '#fff', fontSize: 14, fontWeight: 700, cursor: 'pointer', marginTop: 8 } };
  return (<div style={s.container}><div style={s.card}><h2 style={s.title}>Nova Senha</h2><form onSubmit={handleSubmit}><label style={s.label}>Nova Senha</label><input style={s.input} type="password" value={pw} onChange={e => setPw(e.target.value)} required /><label style={s.label}>Confirmar</label><input style={s.input} type="password" value={cf} onChange={e => setCf(e.target.value)} required /><button type="submit" style={s.btn} disabled={loading}>{loading ? 'Redefinindo...' : 'Redefinir Senha'}</button></form></div></div>);
}
JSEOF

    # Layout components
    mkdir -p "${MONIHOOK_DIR}/frontend/src/components/Layout"
    cat > "${MONIHOOK_DIR}/frontend/src/components/Layout/Sidebar.js" << 'JSEOF'
import React from 'react';
import { NavLink } from 'react-router-dom';
import { useTheme } from '../../contexts/ThemeContext';
import { useAuth } from '../../contexts/AuthContext';
import { LayoutDashboard, Shield, Server, Ticket, FileBarChart, Settings, LogOut, ChevronLeft, ChevronRight } from 'lucide-react';
const nav = [
  { to: '/', icon: LayoutDashboard, label: 'Dashboard', end: true },
  { to: '/privacy', icon: Shield, label: 'Privacidade' },
  { to: '/infrastructure', icon: Server, label: 'Infraestrutura' },
  { to: '/tickets', icon: Ticket, label: 'Tickets' },
  { to: '/reports', icon: FileBarChart, label: 'Relatorios' },
  { to: '/settings', icon: Settings, label: 'Configuracoes' },
];
export default function Sidebar({ collapsed, onToggle }) {
  const { theme, branding } = useTheme();
  const { user, logout } = useAuth();
  const s = { sidebar: { width: collapsed ? 72 : 260, minHeight: '100vh', background: theme.surface, borderRight: `1px solid ${theme.border}`, display: 'flex', flexDirection: 'column', transition: 'width 0.25s', overflow: 'hidden', flexShrink: 0 }, header: { padding: collapsed ? '20px 12px' : '20px', display: 'flex', alignItems: 'center', gap: 12, borderBottom: `1px solid ${theme.border}`, minHeight: 72 }, logo: { width: 36, height: 36, borderRadius: 10, background: `linear-gradient(135deg, ${theme.primary}, ${theme.secondary})`, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, fontSize: 16, fontWeight: 800, color: '#fff' }, brand: { fontFamily: "'Syne', sans-serif", fontSize: 18, fontWeight: 800, color: theme.text, letterSpacing: -0.5, whiteSpace: 'nowrap', overflow: 'hidden' }, nav: { flex: 1, padding: '12px 8px', display: 'flex', flexDirection: 'column', gap: 2 }, link: (a) => ({ display: 'flex', alignItems: 'center', gap: 12, padding: collapsed ? '12px 0' : '10px 14px', justifyContent: collapsed ? 'center' : 'flex-start', borderRadius: 10, textDecoration: 'none', color: a ? '#fff' : theme.textMuted, background: a ? `linear-gradient(135deg, ${theme.primary}22, ${theme.primary}44)` : 'transparent', border: a ? `1px solid ${theme.primary}55` : '1px solid transparent', fontSize: 13, fontWeight: a ? 600 : 400, whiteSpace: 'nowrap', transition: 'all 0.15s' }), footer: { padding: '16px 8px', borderTop: `1px solid ${theme.border}` }, toggle: { width: '100%', padding: '10px', background: 'transparent', border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.textMuted, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, fontSize: 12 }, avatar: { width: 32, height: 32, borderRadius: 8, background: `linear-gradient(135deg, ${theme.accent}, ${theme.primary})`, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: 13, fontWeight: 700, flexShrink: 0 } };
  return (
    <div style={s.sidebar}>
      <div style={s.header}><div style={s.logo}>{branding?.logo_url ? <img src={branding.logo_url} alt="" style={{width:24,height:24,objectFit:'contain'}} /> : 'M'}</div>{!collapsed && <span style={s.brand}>{branding?.name || 'Monihook'}</span>}</div>
      <nav style={s.nav}>{nav.map(i => (<NavLink key={i.to} to={i.to} end={i.end} style={({isActive}) => s.link(isActive)}><i.icon size={18} />{!collapsed && <span>{i.label}</span>}</NavLink>))}</nav>
      <div style={s.footer}>
        <div style={{ padding: collapsed ? '12px 8px' : '12px 14px', display: 'flex', alignItems: 'center', gap: 10, borderTop: `1px solid ${theme.border}` }}>
          <div style={s.avatar}>{user?.full_name?.[0]?.toUpperCase()}</div>
          {!collapsed && <><div style={{ flex: 1, overflow: 'hidden' }}><div style={{ fontSize: 13, color: theme.text, fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{user?.full_name}</div><div style={{ fontSize: 11, color: theme.textMuted, textTransform: 'uppercase' }}>{user?.role}</div></div><button onClick={logout} style={{ background: 'none', border: 'none', color: theme.textMuted, cursor: 'pointer' }}><LogOut size={16} /></button></>}
        </div>
        <button style={s.toggle} onClick={onToggle}>{collapsed ? <ChevronRight size={16} /> : <><ChevronLeft size={16} /> Recolher</>}</button>
      </div>
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Layout/Header.js" << 'JSEOF'
import React from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { Moon, Sun, Bell } from 'lucide-react';
export default function Header() {
  const { theme, mode, toggleMode, branding } = useTheme();
  const s = { header: { height: 64, background: theme.surface, borderBottom: `1px solid ${theme.border}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 24px', flexShrink: 0 }, iconBtn: { width: 36, height: 36, borderRadius: 8, background: 'transparent', border: `1px solid ${theme.border}`, color: theme.textMuted, cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center' } };
  return (<div style={s.header}><span style={{ fontFamily: "'Syne', sans-serif", fontSize: 15, fontWeight: 600, color: theme.textMuted }}>{branding?.name || ''}</span><div style={{ display: 'flex', gap: 12 }}><button style={s.iconBtn} onClick={toggleMode}>{mode === 'dark' ? <Sun size={16} /> : <Moon size={16} />}</button><button style={s.iconBtn}><Bell size={16} /></button></div></div>);
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Layout/MainLayout.js" << 'JSEOF'
import React, { useState } from 'react';
import { Outlet } from 'react-router-dom';
import Sidebar from './Sidebar';
import Header from './Header';
import { useTheme } from '../../contexts/ThemeContext';
export default function MainLayout() {
  const [collapsed, setCollapsed] = useState(false);
  const { theme } = useTheme();
  return (<div style={{ display: 'flex', minHeight: '100vh' }}><Sidebar collapsed={collapsed} onToggle={() => setCollapsed(!collapsed)} /><div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}><Header /><main style={{ flex: 1, padding: 24, background: theme.bg, overflow: 'auto' }}><Outlet /></main></div></div>);
}
JSEOF

    # Dashboard components
    mkdir -p "${MONIHOOK_DIR}/frontend/src/components/Dashboard"
    cat > "${MONIHOOK_DIR}/frontend/src/components/Dashboard/StatCard.js" << 'JSEOF'
import React from 'react';
import { useTheme } from '../../contexts/ThemeContext';
export default function StatCard({ icon: Icon, label, value, subValue, color }) {
  const { theme } = useTheme();
  const c = color || theme.primary;
  return (
    <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 20, display: 'flex', flexDirection: 'column', gap: 12, transition: 'border-color 0.2s, transform 0.2s', cursor: 'default' }}
      onMouseEnter={e => { e.currentTarget.style.borderColor = c + '66'; e.currentTarget.style.transform = 'translateY(-2px)'; }}
      onMouseLeave={e => { e.currentTarget.style.borderColor = theme.border; e.currentTarget.style.transform = 'translateY(0)'; }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ fontSize: 12, color: theme.textMuted, textTransform: 'uppercase', letterSpacing: 0.8, fontWeight: 500 }}>{label}</span>
        {Icon && <div style={{ width: 40, height: 40, borderRadius: 10, background: `${c}18`, border: `1px solid ${c}33`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon size={18} color={c} /></div>}
      </div>
      <div style={{ fontFamily: "'Syne', sans-serif", fontSize: 32, fontWeight: 800, color: theme.text, letterSpacing: -1 }}>{value}</div>
      {subValue && <span style={{ fontSize: 12, color: theme.textMuted }}>{subValue}</span>}
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Dashboard/DashboardPage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import StatCard from './StatCard';
import { Shield, FileCheck, AlertTriangle, Ticket, Clock, Server, Timer, ShieldAlert, ClipboardList, Users } from 'lucide-react';
const PERIODS = [{ value: 'weekly', label: 'Semanal' }, { value: 'monthly', label: 'Mensal' }, { value: 'quarterly', label: 'Trimestral' }, { value: 'semi_annual', label: 'Semestral' }, { value: 'annual', label: 'Anual' }];
export default function DashboardPage() {
  const { theme } = useTheme();
  const [period, setPeriod] = useState('monthly');
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => { setLoading(true); api.get(`/dashboard/overview?period=${period}`).then(r => setData(r.data)).catch(console.error).finally(() => setLoading(false)); }, [period]);
  if (loading || !data) return <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', minHeight: 300, color: theme.textMuted }}>Carregando dashboard...</div>;
  const p = data.privacy || {}; const t = data.tickets || {}; const infra = data.infrastructure || {};
  const s = { sectionTitle: { fontFamily: "'Syne', sans-serif", fontSize: 16, fontWeight: 700, color: theme.text, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }, bar: { display: 'flex', gap: 4, background: theme.surface, borderRadius: 10, padding: 4, border: `1px solid ${theme.border}` }, pbtn: (a) => ({ padding: '8px 16px', borderRadius: 8, border: 'none', background: a ? theme.primary : 'transparent', color: a ? '#fff' : theme.textMuted, fontSize: 12, cursor: 'pointer', fontFamily: "'DM Mono', monospace" }), dot: (c) => ({ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '4px 10px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: c === 'connected' ? `${theme.accent}18` : `${theme.warning}18`, color: c === 'connected' ? theme.accent : theme.warning, border: `1px solid ${c === 'connected' ? theme.accent : theme.warning}33` }) };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 16 }}>
        <div><h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 28, fontWeight: 800, color: theme.text, letterSpacing: -1 }}>Dashboard</h1><p style={{ fontSize: 13, color: theme.textMuted, marginTop: 4 }}>{data.period_start} a {data.period_end}</p></div>
        <div style={s.bar}>{PERIODS.map(p => <button key={p.value} style={s.pbtn(period === p.value)} onClick={() => setPeriod(p.value)}>{p.label}</button>)}</div>
      </div>
      <div style={s.sectionTitle}><div style={{ width: 6, height: 20, borderRadius: 3, background: theme.primary }} />Privacidade (LGPD / GDPR)</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))', gap: 16 }}>
        <StatCard icon={ClipboardList} label="Atividades de Tratamento" value={p.processing_activities?.total || 0} subValue={`${p.processing_activities?.active || 0} ativas`} color={theme.primary} />
        <StatCard icon={FileCheck} label="Consentimentos Ativos" value={p.consents?.active || 0} subValue={`${p.consents?.withdrawn_in_period || 0} retirados`} color={theme.accent} />
        <StatCard icon={Users} label="DSAR Abertas" value={p.dsar?.open || 0} subValue={`${p.dsar?.completed_in_period || 0} concluidas`} color={theme.info} />
        <StatCard icon={ShieldAlert} label="Incidentes Abertos" value={p.incidents?.open || 0} subValue={`${p.incidents?.in_period || 0} no periodo`} color={theme.danger} />
        <StatCard icon={AlertTriangle} label="Riscos Altos/Criticos" value={p.high_risks || 0} color={theme.warning} />
      </div>
      <div style={s.sectionTitle}><div style={{ width: 6, height: 20, borderRadius: 3, background: theme.secondary }} />Tickets e SLA</div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(240px, 1fr))', gap: 16 }}>
        <StatCard icon={Ticket} label="Tickets Abertos" value={t.open || 0} subValue={`${t.in_period || 0} no periodo`} color={theme.secondary} />
        <StatCard icon={Clock} label="TMA" value={`${t.tma_minutes || 0} min`} color={theme.info} />
        <StatCard icon={Timer} label="TMR" value={`${t.tmr_minutes || 0} min`} color={theme.info} />
        <StatCard icon={ShieldAlert} label="Violacoes de SLA" value={t.sla_breached || 0} color={theme.danger} />
      </div>
      <div style={s.sectionTitle}><div style={{ width: 6, height: 20, borderRadius: 3, background: theme.accent }} />Infraestrutura{infra.grafana_status && <span style={s.dot(infra.grafana_status)}>{infra.grafana_status === 'connected' ? 'Grafana Conectado' : 'Grafana: ' + infra.grafana_status}</span>}</div>
      {infra.uptime_services?.length > 0 ? (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
          {infra.uptime_services.map(svc => (
            <div key={svc.service} style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 12, padding: 16 }}>
              <div style={{ fontSize: 14, fontWeight: 600, color: theme.text, marginBottom: 8 }}>{svc.service}</div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', fontSize: 13 }}><span style={{ color: theme.textMuted }}>Uptime</span><span style={{ fontFamily: "'DM Mono', monospace", color: svc.uptime_pct >= 99 ? theme.accent : svc.uptime_pct >= 95 ? theme.warning : theme.danger }}>{svc.uptime_pct}%</span></div>
              <div style={{ height: 6, background: theme.border, borderRadius: 3, overflow: 'hidden', marginTop: 8 }}><div style={{ height: '100%', width: `${Math.min(svc.uptime_pct, 100)}%`, borderRadius: 3, background: svc.uptime_pct >= 99 ? theme.accent : svc.uptime_pct >= 95 ? theme.warning : theme.danger }} /></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', fontSize: 13 }}><span style={{ color: theme.textMuted }}>Resp. Media</span><span style={{ fontFamily: "'DM Mono', monospace" }}>{svc.avg_response_ms} ms</span></div>
            </div>
          ))}
        </div>
      ) : (
        <div style={{ textAlign: 'center', padding: 40, color: theme.textMuted, fontSize: 13 }}><Server size={32} style={{ opacity: 0.3, marginBottom: 12 }} /><p>Nenhum dado de infraestrutura. Configure Grafana em Configuracoes.</p></div>
      )}
    </div>
  );
}
JSEOF

    # Stub components (Privacy, Infrastructure, Tickets, Reports, Settings)
    for dir in Privacy Infrastructure Tickets Reports Settings; do
        mkdir -p "${MONIHOOK_DIR}/frontend/src/components/${dir}"
    done

    cat > "${MONIHOOK_DIR}/frontend/src/components/Privacy/PrivacyPage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import { ClipboardList, FileCheck, UserCheck, ShieldAlert, AlertTriangle, Search } from 'lucide-react';
const TABS = [{ key: 'activities', label: 'Atividades', icon: ClipboardList }, { key: 'consents', label: 'Consentimentos', icon: FileCheck }, { key: 'dsar', label: 'DSAR', icon: UserCheck }, { key: 'incidents', label: 'Incidentes', icon: ShieldAlert }, { key: 'risks', label: 'Riscos', icon: AlertTriangle }];
const RC = { very_low: '#22c55e', low: '#84cc16', medium: '#f59e0b', high: '#ef4444', very_high: '#dc2626' };
const SC = { active: '#22c55e', open: '#f59e0b', received: '#3b82f6', in_review: '#8b5cf6', processing: '#f59e0b', completed: '#22c55e', draft: '#6b7280' };
export default function PrivacyPage() {
  const { theme } = useTheme(); const [tab, setTab] = useState('activities'); const [data, setData] = useState({ items: [], total: 0 }); const [loading, setLoading] = useState(true); const [search, setSearch] = useState(''); const [page, setPage] = useState(1);
  useEffect(() => { setLoading(true); const p = { page, per_page: 15 }; if (search) p.search = search; api.get(`/privacy/${tab}`, { params: p }).then(r => setData(r.data)).catch(console.error).finally(() => setLoading(false)); }, [tab, page, search]);
  const badge = (c) => ({ display: 'inline-block', padding: '3px 10px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: `${c}18`, color: c, border: `1px solid ${c}33` });
  const th = { padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 600, color: theme.textMuted, textTransform: 'uppercase', background: theme.surface, borderBottom: `1px solid ${theme.border}` };
  const td = { padding: '12px 16px', fontSize: 13, color: theme.text, borderBottom: `1px solid ${theme.border}` };
  const hdrs = { activities: ['Nome', 'Base Legal', 'Risco', 'Status', 'Equipe'], consents: ['Titular', 'Email', 'Finalidade', 'Canal', 'Status'], dsar: ['Tipo', 'Titular', 'Status', 'Prioridade', 'Criado'], incidents: ['Titulo', 'Severidade', 'Status', 'ANPD', 'Criado'], risks: ['Titulo', 'Tipo', 'Risco', 'Residual', 'Status'] };
  const renderRow = (i) => {
    if (tab === 'activities') return <tr key={i.id}><td style={td}>{i.name}</td><td style={td}>{i.legal_basis||'-'}</td><td style={td}><span style={badge(RC[i.risk_level]||theme.warning)}>{i.risk_level}</span></td><td style={td}><span style={badge(SC[i.status]||theme.textMuted)}>{i.status}</span></td><td style={td}>{i.responsible_team||'-'}</td></tr>;
    if (tab === 'consents') return <tr key={i.id}><td style={td}>{i.data_subject_name||'-'}</td><td style={td}>{i.data_subject_email||'-'}</td><td style={td}>{i.purpose}</td><td style={td}>{i.channel||'-'}</td><td style={td}><span style={badge(SC[i.status])}>{i.status}</span></td></tr>;
    if (tab === 'dsar') return <tr key={i.id}><td style={td}>{i.request_type}</td><td style={td}>{i.data_subject_name||'-'}</td><td style={td}><span style={badge(SC[i.status])}>{i.status}</span></td><td style={td}><span style={badge(i.priority==='critical'?'#dc2626':i.priority==='high'?'#ef4444':'#f59e0b')}>{i.priority}</span></td><td style={td}>{new Date(i.created_at).toLocaleDateString('pt-BR')}</td></tr>;
    if (tab === 'incidents') return <tr key={i.id}><td style={td}>{i.title}</td><td style={td}><span style={badge(i.severity==='critical'?'#dc2626':i.severity==='high'?'#ef4444':'#f59e0b')}>{i.severity}</span></td><td style={td}><span style={badge(SC[i.status])}>{i.status}</span></td><td style={td}>{i.notified_anpd?'Sim':'Nao'}</td><td style={td}>{new Date(i.created_at).toLocaleDateString('pt-BR')}</td></tr>;
    if (tab === 'risks') return <tr key={i.id}><td style={td}>{i.title}</td><td style={td}>{i.assessment_type||'-'}</td><td style={td}><span style={badge(RC[i.risk_level])}>{i.risk_level}</span></td><td style={td}><span style={badge(RC[i.residual_risk_level]||theme.textMuted)}>{i.residual_risk_level||'-'}</span></td><td style={td}><span style={badge(SC[i.status])}>{i.status}</span></td></tr>;
  };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 24, fontWeight: 800, color: theme.text }}>Privacidade</h1>
      <div style={{ display: 'flex', gap: 4, background: theme.surface, borderRadius: 10, padding: 4, border: `1px solid ${theme.border}` }}>
        {TABS.map(t => <button key={t.key} onClick={() => { setTab(t.key); setPage(1); }} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '8px 14px', borderRadius: 8, border: 'none', background: tab === t.key ? theme.primary : 'transparent', color: tab === t.key ? '#fff' : theme.textMuted, fontSize: 12, cursor: 'pointer', fontFamily: "'DM Mono', monospace" }}><t.icon size={14} />{t.label}</button>)}
      </div>
      <div style={{ position: 'relative' }}><Search size={14} style={{ position: 'absolute', left: 12, top: '50%', transform: 'translateY(-50%)', color: theme.textMuted }} /><input style={{ padding: '8px 14px 8px 36px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.text, fontSize: 13, fontFamily: "'DM Mono', monospace", outline: 'none', width: 260 }} placeholder="Buscar..." value={search} onChange={e => { setSearch(e.target.value); setPage(1); }} /></div>
      {loading ? <div style={{ textAlign: 'center', padding: 40, color: theme.textMuted }}>Carregando...</div> : data.items.length === 0 ? <div style={{ textAlign: 'center', padding: 40, color: theme.textMuted }}>Nenhum registro</div> : (
        <>
          <table style={{ width: '100%', borderCollapse: 'collapse', background: theme.cardBg, borderRadius: 12, overflow: 'hidden', border: `1px solid ${theme.border}` }}>
            <thead><tr>{(hdrs[tab]||[]).map(h => <th key={h} style={th}>{h}</th>)}</tr></thead>
            <tbody>{data.items.map(renderRow)}</tbody>
          </table>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 0' }}>
            <span style={{ fontSize: 12, color: theme.textMuted }}>{data.total} registros</span>
            <div style={{ display: 'flex', gap: 8 }}>
              <button onClick={() => setPage(page - 1)} disabled={page <= 1} style={{ padding: '6px 14px', borderRadius: 6, border: `1px solid ${theme.border}`, background: 'transparent', color: page <= 1 ? theme.border : theme.text, fontSize: 12, cursor: page <= 1 ? 'not-allowed' : 'pointer' }}>Anterior</button>
              <span style={{ fontSize: 12, color: theme.textMuted, display: 'flex', alignItems: 'center' }}>Pagina {page}</span>
              <button onClick={() => setPage(page + 1)} disabled={data.items.length < 15} style={{ padding: '6px 14px', borderRadius: 6, border: `1px solid ${theme.border}`, background: 'transparent', color: data.items.length < 15 ? theme.border : theme.text, fontSize: 12, cursor: data.items.length < 15 ? 'not-allowed' : 'pointer' }}>Proximo</button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Infrastructure/InfrastructurePage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import { Server, RefreshCw, ExternalLink } from 'lucide-react';
export default function InfrastructurePage() {
  const { theme } = useTheme(); const [health, setHealth] = useState(null); const [logs, setLogs] = useState([]); const [embedUrl, setEmbedUrl] = useState(''); const [loading, setLoading] = useState(true);
  useEffect(() => { Promise.allSettled([api.get('/monitoring/grafana/health'), api.get('/monitoring/uptime?hours=48'), api.get('/monitoring/embed-url')]).then(([h, u, e]) => { if (h.status === 'fulfilled') setHealth(h.value.data); if (u.status === 'fulfilled') setLogs(u.value.data.logs || []); if (e.status === 'fulfilled') setEmbedUrl(e.value.data.embed_url); }).finally(() => setLoading(false)); }, []);
  if (loading) return <div style={{ textAlign: 'center', padding: 40, color: theme.textMuted }}>Carregando...</div>;
  const svcMap = {}; logs.forEach(l => { if (!svcMap[l.service_name]) svcMap[l.service_name] = []; svcMap[l.service_name].push(l); });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 24, fontWeight: 800, color: theme.text }}>Infraestrutura</h1>
        <button onClick={() => window.location.reload()} style={{ padding: '8px 16px', borderRadius: 8, border: `1px solid ${theme.border}`, background: theme.surface, color: theme.textMuted, fontSize: 12, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6 }}><RefreshCw size={14} /> Atualizar</button>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
        <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 20 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: theme.text, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}><Server size={16} color={theme.primary} /> Grafana</div>
          {health && health.status !== 'not_configured' ? <p style={{ color: theme.accent, fontSize: 13 }}>Conectado - {health.health?.database || 'ok'}</p> : <p style={{ color: theme.textMuted, fontSize: 13 }}>Nao configurado. Adicione em Configuracoes.</p>}
        </div>
        {Object.entries(svcMap).map(([name, lgs]) => { const up = lgs.filter(l => l.status === 'up').length; const pct = ((up / lgs.length) * 100).toFixed(1); const avg = (lgs.reduce((a, l) => a + (l.response_time_ms || 0), 0) / lgs.length).toFixed(0); return (
          <div key={name} style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 20 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: theme.text, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}><div style={{ width: 8, height: 8, borderRadius: '50%', background: pct >= 99 ? theme.accent : theme.warning }} /> {name}</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', fontSize: 13 }}><span style={{ color: theme.textMuted }}>Uptime (48h)</span><span style={{ fontFamily: "'DM Mono', monospace", color: pct >= 99 ? theme.accent : theme.warning }}>{pct}%</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', fontSize: 13 }}><span style={{ color: theme.textMuted }}>Resp. Media</span><span style={{ fontFamily: "'DM Mono', monospace" }}>{avg} ms</span></div>
          </div>
        ); })}
        {Object.keys(svcMap).length === 0 && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 40, textAlign: 'center', color: theme.textMuted, gridColumn: '1 / -1', fontSize: 13 }}>Nenhum dado de monitoramento.</div>}
      </div>
      {embedUrl && <div style={{ borderRadius: 14, overflow: 'hidden', border: `1px solid ${theme.border}` }}>
        <div style={{ padding: '12px 20px', background: theme.surface, borderBottom: `1px solid ${theme.border}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: theme.text }}>Grafana</span>
          <a href={embedUrl} target="_blank" rel="noopener noreferrer" style={{ color: theme.primary, fontSize: 12, textDecoration: 'none', display: 'flex', alignItems: 'center', gap: 4 }}><ExternalLink size={12} /> Expandir</a>
        </div>
        <iframe title="Grafana" src={embedUrl} style={{ width: '100%', height: 600, border: 'none' }} />
      </div>}
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Tickets/TicketsPage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import { CheckCircle2, Clock, AlertTriangle, Timer } from 'lucide-react';
import StatCard from '../Dashboard/StatCard';
export default function TicketsPage() {
  const { theme } = useTheme(); const [tickets, setTickets] = useState({ items: [], total: 0 }); const [metrics, setMetrics] = useState(null); const [period, setPeriod] = useState('monthly'); const [page, setPage] = useState(1);
  useEffect(() => { api.get('/tickets/', { params: { page, per_page: 15 } }).then(r => setTickets(r.data)).catch(console.error); }, [page]);
  useEffect(() => { api.get(`/tickets/metrics/sla?period=${period}`).then(r => setMetrics(r.data)).catch(console.error); }, [period]);
  const PC = { low: '#22c55e', medium: '#f59e0b', high: '#ef4444', critical: '#dc2626' }; const SC = { open: '#3b82f6', in_progress: '#8b5cf6', waiting: '#f59e0b', resolved: '#22c55e', closed: '#6b7280' };
  const badge = (c) => ({ display: 'inline-block', padding: '3px 10px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: `${c}18`, color: c, border: `1px solid ${c}33` });
  const th = { padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 600, color: theme.textMuted, textTransform: 'uppercase', background: theme.surface, borderBottom: `1px solid ${theme.border}` };
  const td = { padding: '12px 16px', fontSize: 13, color: theme.text, borderBottom: `1px solid ${theme.border}` };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 24, fontWeight: 800, color: theme.text }}>Tickets e SLA</h1>
        <div style={{ display: 'flex', gap: 4, background: theme.surface, borderRadius: 10, padding: 4, border: `1px solid ${theme.border}` }}>
          {['weekly','monthly','quarterly','semi_annual','annual'].map(p => <button key={p} onClick={() => setPeriod(p)} style={{ padding: '6px 12px', borderRadius: 8, border: 'none', background: period === p ? theme.secondary : 'transparent', color: period === p ? '#fff' : theme.textMuted, fontSize: 11, cursor: 'pointer', fontFamily: "'DM Mono', monospace" }}>{p === 'weekly' ? 'Sem' : p === 'monthly' ? 'Mes' : p === 'quarterly' ? 'Trim' : p === 'semi_annual' ? 'Semest' : 'Anual'}</button>)}
        </div>
      </div>
      {metrics && <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 16 }}>
        <StatCard icon={CheckCircle2} label="Conformidade SLA" value={`${metrics.sla_compliance_pct}%`} color={metrics.sla_compliance_pct >= 95 ? theme.accent : theme.danger} />
        <StatCard icon={Clock} label="SLA Violados" value={metrics.sla_breached} color={theme.danger} />
        <StatCard icon={Timer} label="TMA" value={`${metrics.by_priority?.reduce((a,p)=>a+p.avg_response_min,0)/(metrics.by_priority?.length||1)} min`} color={theme.info} />
      </div>}
      <table style={{ width: '100%', borderCollapse: 'collapse', background: theme.cardBg, borderRadius: 12, overflow: 'hidden', border: `1px solid ${theme.border}` }}>
        <thead><tr><th style={th}>Numero</th><th style={th}>Titulo</th><th style={th}>Prioridade</th><th style={th}>Status</th><th style={th}>SLA</th><th style={th}>TMA</th><th style={th}>Criado</th></tr></thead>
        <tbody>{tickets.items.length === 0 ? <tr><td colSpan={7} style={{ ...td, textAlign: 'center', padding: 40 }}>Nenhum ticket</td></tr> : tickets.items.map(t => (
          <tr key={t.id}><td style={td}>{t.ticket_number}</td><td style={td}>{t.title}</td><td style={td}><span style={badge(PC[t.priority])}>{t.priority}</span></td><td style={td}><span style={badge(SC[t.status])}>{t.status}</span></td><td style={td}>{t.sla_breached ? <span style={badge(theme.danger)}>Violado</span> : <span style={badge(theme.accent)}>OK</span>}</td><td style={td}>{t.response_time_minutes ? `${t.response_time_minutes} min` : '-'}</td><td style={td}>{new Date(t.created_at).toLocaleDateString('pt-BR')}</td></tr>
        ))}</tbody>
      </table>
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Reports/ReportsPage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import api from '../../services/api';
import { FileBarChart, Plus } from 'lucide-react';
import toast from 'react-hot-toast';
export default function ReportsPage() {
  const { theme } = useTheme(); const [templates, setTemplates] = useState([]); const [history, setHistory] = useState([]); const [sel, setSel] = useState(''); const [d1, setD1] = useState(''); const [d2, setD2] = useState(''); const [result, setResult] = useState(null); const [gen, setGen] = useState(false);
  useEffect(() => { Promise.all([api.get('/reports/templates'), api.get('/reports/history')]).then(([t, h]) => { setTemplates(t.data.items || []); setHistory(h.data.items || []); }).catch(console.error); }, []);
  const generate = async () => { if (!sel || !d1 || !d2) { toast.error('Selecione template e periodo'); return; } setGen(true); try { const r = await api.post('/reports/generate', { template_id: sel, period_start: d1, period_end: d2 }); setResult(r.data.data); toast.success('Relatorio gerado!'); } catch(e) { toast.error('Erro'); } setGen(false); };
  const th = { padding: '12px 16px', textAlign: 'left', fontSize: 11, fontWeight: 600, color: theme.textMuted, textTransform: 'uppercase', background: theme.surface, borderBottom: `1px solid ${theme.border}` };
  const td = { padding: '12px 16px', fontSize: 13, color: theme.text, borderBottom: `1px solid ${theme.border}` };
  const badge = (s) => ({ display: 'inline-block', padding: '3px 10px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: s === 'completed' ? `${theme.accent}18` : `${theme.warning}18`, color: s === 'completed' ? theme.accent : theme.warning, border: `1px solid ${s === 'completed' ? theme.accent : theme.warning}33` });
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 24, fontWeight: 800, color: theme.text }}>Relatorios</h1>
      <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}><Plus size={16} /> Gerar Relatorio</div>
        <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div><label style={{ fontSize: 11, color: theme.textMuted, display: 'block', marginBottom: 4 }}>TEMPLATE</label><select style={{ padding: '10px 14px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.text, fontSize: 13, minWidth: 200 }} value={sel} onChange={e => setSel(e.target.value)}><option value="">Selecione...</option>{templates.map(t => <option key={t.id} value={t.id}>{t.name}</option>)}</select></div>
          <div><label style={{ fontSize: 11, color: theme.textMuted, display: 'block', marginBottom: 4 }}>INICIO</label><input type="date" style={{ padding: '10px 14px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.text, fontSize: 13 }} value={d1} onChange={e => setD1(e.target.value)} /></div>
          <div><label style={{ fontSize: 11, color: theme.textMuted, display: 'block', marginBottom: 4 }}>FIM</label><input type="date" style={{ padding: '10px 14px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.text, fontSize: 13 }} value={d2} onChange={e => setD2(e.target.value)} /></div>
          <button onClick={generate} disabled={gen} style={{ padding: '10px 20px', borderRadius: 8, border: 'none', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, color: '#fff', fontSize: 13, fontWeight: 700, cursor: 'pointer' }}>{gen ? 'Gerando...' : 'Gerar'}</button>
        </div>
      </div>
      {result && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <div style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text, marginBottom: 16 }}>Resultado</div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(250px, 1fr))', gap: 16 }}>
          {result.privacy && <div style={{ padding: 16, background: theme.surface, borderRadius: 10, border: `1px solid ${theme.border}` }}><div style={{ fontSize: 12, fontWeight: 700, color: theme.primary, marginBottom: 8 }}>PRIVACIDADE</div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>Atividades</span><span>{result.privacy.processing_activities?.total}</span></div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>Consent. Ativos</span><span>{result.privacy.consents?.active}</span></div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>Incidentes</span><span>{result.privacy.incidents?.total_in_period}</span></div></div>}
          {result.tickets && <div style={{ padding: 16, background: theme.surface, borderRadius: 10, border: `1px solid ${theme.border}` }}><div style={{ fontSize: 12, fontWeight: 700, color: theme.secondary, marginBottom: 8 }}>TICKETS</div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>Total</span><span>{result.tickets.total_in_period}</span></div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>SLA</span><span>{result.tickets.sla?.compliance_percentage}%</span></div><div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0' }}><span style={{ color: theme.textMuted }}>TMA</span><span>{result.tickets.tma_minutes} min</span></div></div>}
        </div>
      </div>}
      <h2 style={{ fontFamily: "'Syne', sans-serif", fontSize: 18, fontWeight: 700, color: theme.text }}>Historico</h2>
      {history.length === 0 ? <div style={{ textAlign: 'center', padding: 40, color: theme.textMuted }}>Nenhum relatorio gerado</div> : (
        <table style={{ width: '100%', borderCollapse: 'collapse', background: theme.cardBg, borderRadius: 12, overflow: 'hidden', border: `1px solid ${theme.border}` }}>
          <thead><tr><th style={th}>Titulo</th><th style={th}>Tipo</th><th style={th}>Status</th><th style={th}>Criado</th></tr></thead>
          <tbody>{history.map(r => <tr key={r.id}><td style={td}>{r.title}</td><td style={td}>{r.report_type}</td><td style={td}><span style={badge(r.status)}>{r.status}</span></td><td style={td}>{new Date(r.created_at).toLocaleDateString('pt-BR')}</td></tr>)}</tbody>
        </table>
      )}
    </div>
  );
}
JSEOF

    cat > "${MONIHOOK_DIR}/frontend/src/components/Settings/SettingsPage.js" << 'JSEOF'
import React, { useState, useEffect } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { useAuth } from '../../contexts/AuthContext';
import api from '../../services/api';
import { Users, Globe, Palette, Settings, Plus, Save } from 'lucide-react';
import toast from 'react-hot-toast';
const TABS = [{ key: 'users', label: 'Usuarios', icon: Users }, { key: 'platforms', label: 'Plataformas', icon: Globe }, { key: 'branding', label: 'Aparencia', icon: Palette }, { key: 'services', label: 'Servicos', icon: Settings }];
export default function SettingsPage() {
  const { theme, loadBranding } = useTheme(); const { user } = useAuth(); const [tab, setTab] = useState('users');
  const [users, setUsers] = useState([]); const [platforms, setPlatforms] = useState([]); const [branding, setBranding] = useState({}); const [showU, setShowU] = useState(false); const [showP, setShowP] = useState(false);
  const [nu, setNu] = useState({ email: '', password: '', full_name: '', role: 'user', department: '' });
  const [np, setNp] = useState({ name: '', platform_type: 'privacytools', base_url: '', auth_type: 'api_key', api_key: '', username: '', password: '' });
  useEffect(() => { if (tab === 'users') api.get('/users/').then(r => setUsers(r.data.items||[])).catch(()=>{}); if (tab === 'platforms') api.get('/platforms/').then(r => setPlatforms(r.data.items||[])).catch(()=>{}); if (tab === 'branding') api.get('/tenants/current').then(r => setBranding(r.data)).catch(()=>{}); }, [tab]);
  const createUser = async () => { try { await api.post('/users/', nu); toast.success('Usuario criado'); setShowU(false); setNu({ email: '', password: '', full_name: '', role: 'user', department: '' }); api.get('/users/').then(r => setUsers(r.data.items||[])); } catch(e) { toast.error(e.response?.data?.detail || 'Erro'); } };
  const createPlatform = async () => { try { await api.post('/platforms/', np); toast.success('Plataforma adicionada'); setShowP(false); setNp({ name: '', platform_type: 'privacytools', base_url: '', auth_type: 'api_key', api_key: '', username: '', password: '' }); api.get('/platforms/').then(r => setPlatforms(r.data.items||[])); } catch(e) { toast.error(e.response?.data?.detail || 'Erro'); } };
  const saveBranding = async () => { try { await api.put('/tenants/current/branding', branding); toast.success('Salvo'); loadBranding(); } catch(e) { toast.error('Erro'); } };
  const canManage = ['super_admin','admin'].includes(user?.role);
  const badge = (c) => ({ display: 'inline-block', padding: '2px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, background: `${c}18`, color: c, border: `1px solid ${c}33` });
  const th = { padding: '10px 14px', textAlign: 'left', fontSize: 11, fontWeight: 600, color: theme.textMuted, textTransform: 'uppercase', borderBottom: `1px solid ${theme.border}` };
  const td = { padding: '10px 14px', fontSize: 13, color: theme.text, borderBottom: `1px solid ${theme.border}` };
  const input = { padding: '10px 14px', background: theme.bg, border: `1px solid ${theme.border}`, borderRadius: 8, color: theme.text, fontSize: 13, fontFamily: "'DM Mono', monospace", outline: 'none' };
  const select = { ...input };
  const label = { fontSize: 11, fontWeight: 600, color: theme.textMuted, textTransform: 'uppercase', letterSpacing: 0.8 };
  const formGroup = { display: 'flex', flexDirection: 'column', gap: 4 };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
      <h1 style={{ fontFamily: "'Syne', sans-serif", fontSize: 24, fontWeight: 800, color: theme.text }}>Configuracoes</h1>
      <div style={{ display: 'flex', gap: 4, background: theme.surface, borderRadius: 10, padding: 4, border: `1px solid ${theme.border}` }}>
        {TABS.map(t => <button key={t.key} onClick={() => setTab(t.key)} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '8px 14px', borderRadius: 8, border: 'none', background: tab === t.key ? theme.primary : 'transparent', color: tab === t.key ? '#fff' : theme.textMuted, fontSize: 12, cursor: 'pointer', fontFamily: "'DM Mono', monospace" }}><t.icon size={14} />{t.label}</button>)}
      </div>
      {tab === 'users' && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 16 }}><span style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text }}>Usuarios</span>{canManage && <button onClick={() => setShowU(!showU)} style={{ padding: '8px 16px', borderRadius: 8, border: 'none', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, color: '#fff', fontSize: 12, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6 }}><Plus size={14} /> Novo</button>}</div>
        {showU && <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))', gap: 12, marginBottom: 16 }}>
          <div style={formGroup}><label style={label}>Nome</label><input style={input} value={nu.full_name} onChange={e => setNu({...nu, full_name: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>Email</label><input style={input} value={nu.email} onChange={e => setNu({...nu, email: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>Senha</label><input style={input} type="password" value={nu.password} onChange={e => setNu({...nu, password: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>Papel</label><select style={select} value={nu.role} onChange={e => setNu({...nu, role: e.target.value})}><option value="readonly">Somente Leitura</option><option value="user">Usuario</option><option value="manager">Gerente</option><option value="admin">Admin</option></select></div>
          <div style={{ display: 'flex', alignItems: 'flex-end' }}><button onClick={createUser} style={{ padding: '10px 20px', borderRadius: 8, border: 'none', background: theme.primary, color: '#fff', fontSize: 12, cursor: 'pointer' }}><Save size={14} /> Salvar</button></div>
        </div>}
        <table style={{ width: '100%', borderCollapse: 'collapse' }}><thead><tr><th style={th}>Nome</th><th style={th}>Email</th><th style={th}>Papel</th><th style={th}>2FA</th><th style={th}>Status</th></tr></thead>
        <tbody>{users.map(u => <tr key={u.id}><td style={td}>{u.full_name}</td><td style={td}>{u.email}</td><td style={td}><span style={badge(theme.primary)}>{u.role}</span></td><td style={td}>{u.two_factor_enabled ? <span style={badge(theme.accent)}>Ativo</span> : <span style={badge(theme.textMuted)}>Off</span>}</td><td style={td}>{u.is_active ? <span style={badge(theme.accent)}>Ativo</span> : <span style={badge(theme.danger)}>Inativo</span>}</td></tr>)}</tbody></table>
      </div>}
      {tab === 'platforms' && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 16 }}><span style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text }}>Plataformas</span>{canManage && <button onClick={() => setShowP(!showP)} style={{ padding: '8px 16px', borderRadius: 8, border: 'none', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, color: '#fff', fontSize: 12, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 6 }}><Plus size={14} /> Nova</button>}</div>
        {showP && <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(180px, 1fr))', gap: 12, marginBottom: 16 }}>
          <div style={formGroup}><label style={label}>Nome</label><input style={input} value={np.name} onChange={e => setNp({...np, name: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>Tipo</label><select style={select} value={np.platform_type} onChange={e => setNp({...np, platform_type: e.target.value})}><option value="privacytools">PrivacyTools</option><option value="grafana">Grafana</option><option value="jira">Jira</option><option value="custom">Custom</option></select></div>
          <div style={formGroup}><label style={label}>URL</label><input style={input} value={np.base_url} onChange={e => setNp({...np, base_url: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>Auth</label><select style={select} value={np.auth_type} onChange={e => setNp({...np, auth_type: e.target.value})}><option value="api_key">API Key</option><option value="basic">User/Pass</option><option value="bearer">Bearer</option></select></div>
          {np.auth_type === 'api_key' && <div style={formGroup}><label style={label}>API Key</label><input style={input} type="password" value={np.api_key} onChange={e => setNp({...np, api_key: e.target.value})} /></div>}
          {np.auth_type === 'basic' && <><div style={formGroup}><label style={label}>User</label><input style={input} value={np.username} onChange={e => setNp({...np, username: e.target.value})} /></div><div style={formGroup}><label style={label}>Pass</label><input style={input} type="password" value={np.password} onChange={e => setNp({...np, password: e.target.value})} /></div></>}
          <div style={{ display: 'flex', alignItems: 'flex-end' }}><button onClick={createPlatform} style={{ padding: '10px 20px', borderRadius: 8, border: 'none', background: theme.primary, color: '#fff', fontSize: 12, cursor: 'pointer' }}><Save size={14} /> Salvar</button></div>
        </div>}
        <table style={{ width: '100%', borderCollapse: 'collapse' }}><thead><tr><th style={th}>Nome</th><th style={th}>Tipo</th><th style={th}>URL</th><th style={th}>Auth</th><th style={th}>Status</th></tr></thead>
        <tbody>{platforms.map(p => <tr key={p.id}><td style={td}>{p.name}</td><td style={td}><span style={badge(theme.primary)}>{p.platform_type}</span></td><td style={td}>{p.base_url}</td><td style={td}>{p.auth_type}</td><td style={td}>{p.is_active ? <span style={badge(theme.accent)}>Ativo</span> : <span style={badge(theme.danger)}>Off</span>}</td></tr>)}</tbody></table>
      </div>}
      {tab === 'branding' && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <span style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text, display: 'block', marginBottom: 16 }}>Personalizacao Visual</span>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))', gap: 12 }}>
          <div style={formGroup}><label style={label}>Cor Primaria</label><div style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="color" value={branding.primary_color || '#1B5E8C'} onChange={e => setBranding({...branding, primary_color: e.target.value})} style={{ width: 48, height: 36, padding: 0, border: `1px solid ${theme.border}`, borderRadius: 8, cursor: 'pointer' }} /><input style={{ ...input, width: 120 }} value={branding.primary_color || '#1B5E8C'} onChange={e => setBranding({...branding, primary_color: e.target.value})} /></div></div>
          <div style={formGroup}><label style={label}>Cor Secundaria</label><div style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="color" value={branding.secondary_color || '#E8A838'} onChange={e => setBranding({...branding, secondary_color: e.target.value})} style={{ width: 48, height: 36, padding: 0, border: `1px solid ${theme.border}`, borderRadius: 8, cursor: 'pointer' }} /><input style={{ ...input, width: 120 }} value={branding.secondary_color || '#E8A838'} onChange={e => setBranding({...branding, secondary_color: e.target.value})} /></div></div>
          <div style={formGroup}><label style={label}>Cor Destaque</label><div style={{ display: 'flex', gap: 8, alignItems: 'center' }}><input type="color" value={branding.accent_color || '#2ECC71'} onChange={e => setBranding({...branding, accent_color: e.target.value})} style={{ width: 48, height: 36, padding: 0, border: `1px solid ${theme.border}`, borderRadius: 8, cursor: 'pointer' }} /><input style={{ ...input, width: 120 }} value={branding.accent_color || '#2ECC71'} onChange={e => setBranding({...branding, accent_color: e.target.value})} /></div></div>
          <div style={formGroup}><label style={label}>Tema</label><select style={select} value={branding.theme_mode || 'dark'} onChange={e => setBranding({...branding, theme_mode: e.target.value})}><option value="dark">Escuro</option><option value="light">Claro</option></select></div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(250px, 1fr))', gap: 12, marginTop: 12 }}>
          <div style={formGroup}><label style={label}>URL Logo</label><input style={input} value={branding.logo_url || ''} onChange={e => setBranding({...branding, logo_url: e.target.value})} /></div>
          <div style={formGroup}><label style={label}>URL Favicon</label><input style={input} value={branding.favicon_url || ''} onChange={e => setBranding({...branding, favicon_url: e.target.value})} /></div>
        </div>
        <button onClick={saveBranding} style={{ padding: '10px 20px', borderRadius: 8, border: 'none', background: `linear-gradient(135deg, ${theme.primary}, ${theme.accent})`, color: '#fff', fontSize: 12, fontWeight: 700, cursor: 'pointer', marginTop: 16 }}><Save size={14} /> Salvar Aparencia</button>
      </div>}
      {tab === 'services' && <div style={{ background: theme.cardBg, border: `1px solid ${theme.border}`, borderRadius: 14, padding: 24 }}>
        <span style={{ fontFamily: "'Syne', sans-serif", fontWeight: 700, fontSize: 16, color: theme.text, display: 'block', marginBottom: 16 }}>Tipos de Servico</span>
        <p style={{ color: theme.textMuted, fontSize: 13 }}>Configure os tipos de servico monitorados na aba Usuarios (endpoint /api/users/service-types).</p>
      </div>}
    </div>
  );
}
JSEOF

    log_info "Frontend completo gerado"
}

generate_management_script() {
    cat > "${MONIHOOK_DIR}/monihook.sh" << 'MGEOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
case "$1" in
    start) echo "Iniciando Monihook..."; docker compose up -d; echo "Acesse: http://$(hostname -I | awk '{print $1}')";;
    stop) echo "Parando..."; docker compose down;;
    restart) echo "Reiniciando..."; docker compose restart;;
    status) docker compose ps;;
    logs) docker compose logs -f ${2:-backend};;
    backup) F="backup_$(date +%Y%m%d_%H%M%S).sql"; docker exec monihook-db-1 pg_dump -U monihook_user monihook > "$F"; echo "Backup: $F";;
    restore) [ -z "$2" ] && echo "Uso: $0 restore <arquivo.sql>" && exit 1; cat "$2" | docker exec -i monihook-db-1 psql -U monihook_user monihook; echo "Restaurado!";;
    update) echo "Atualizando..."; docker compose down; docker compose build --no-cache; docker compose up -d; echo "Atualizado!";;
    credentials) cat .credentials;;
    *) echo "Monihook - Gerenciamento"; echo ""; echo "start|stop|restart|status|logs|backup|restore|update|credentials";;
esac
MGEOF
    chmod +x "${MONIHOOK_DIR}/monihook.sh"
    log_info "monihook.sh gerado"
}

generate_docs() {
    log_step "Gerando documentacao"
    cat > "${MONIHOOK_DIR}/docs/GUIA_IMPLANTACAO.md" << 'D1EOF'
# Monihook - Guia de Implantacao

## 1. Requisitos
- Ubuntu 22.04+ / Debian 12+
- 4GB RAM minimo (8GB recomendado)
- 30GB disco SSD
- Portas: 22, 80, 443

## 2. Instalacao
sudo bash install_monihook.sh

## 3. Acesso
- URL: http://IP_DO_SERVIDOR
- Email: admin@monihook.com.br
- Senha: ver arquivo .credentials

## 4. Comandos
./monihook.sh start        - Iniciar
./monihook.sh stop         - Parar
./monihook.sh restart      - Reiniciar
./monihook.sh status       - Status
./monihook.sh logs         - Logs
./monihook.sh backup       - Backup
./monihook.sh credentials  - Ver senhas

## 5. Configurar PrivacyTools
1. Configuracoes > Plataformas > Nova
2. Tipo: PrivacyTools
3. URL: https://dpo.privacytools.com.br/external_api_v2
4. API Key: obtida no painel PrivacyTools

## 6. Configurar Grafana
1. Configuracoes > Plataformas > Nova
2. Tipo: Grafana
3. URL: https://dashboard.cmtech.com.br
4. Usuario e senha do Grafana

## 7. Backup
./monihook.sh backup

## 8. HTTPS com Let's Encrypt
apt install certbot
certbot certonly --standalone -d seu-dominio.com.br
D1EOF

    cat > "${MONIHOOK_DIR}/docs/ESTRUTURA.md" << 'D2EOF'
# Estrutura de Pastas

/opt/monihook/
  .env                    - Variaveis de ambiente
  .credentials            - Credenciais (GUARDE!)
  docker-compose.yml      - Containers Docker
  monihook.sh             - Script de gerenciamento
  database/
    init.sql              - Schema do banco PostgreSQL
  backend/
    Dockerfile
    requirements.txt
    app/
      main.py             - Entrada FastAPI
      config.py           - Configuracoes
      database.py         - Conexao banco
      dependencies.py     - Auth/permissoes
      models/             - ORM SQLAlchemy
      routers/            - Endpoints da API
      services/           - Logica de negocio
      utils/              - Seguranca, TOTP
  frontend/
    Dockerfile
    package.json
    src/
      App.js              - Roteamento
      theme.js            - Temas white-label
      contexts/           - React Contexts
      services/           - API client
      components/         - Componentes React
  nginx/
    default.conf          - Proxy reverso
  docs/
    GUIA_IMPLANTACAO.md
    ESTRUTURA.md

Rotas da API:
  POST /api/auth/login
  POST /api/auth/verify-2fa
  POST /api/auth/forgot-password
  POST /api/auth/reset-password
  POST /api/auth/change-password
  POST /api/auth/refresh
  GET  /api/auth/me
  GET  /api/dashboard/overview
  GET  /api/privacy/activities
  GET  /api/privacy/consents
  GET  /api/privacy/dsar
  GET  /api/privacy/incidents
  GET  /api/privacy/risks
  POST /api/privacy/sync
  GET  /api/monitoring/grafana/dashboards
  GET  /api/monitoring/grafana/health
  GET  /api/monitoring/uptime
  GET  /api/monitoring/metrics
  GET  /api/monitoring/embed-url
  GET  /api/tickets/
  POST /api/tickets/
  PUT  /api/tickets/{id}
  GET  /api/tickets/metrics/sla
  GET  /api/reports/templates
  POST /api/reports/templates
  POST /api/reports/generate
  GET  /api/reports/history
  POST /api/reports/schedules
  GET  /api/users/
  POST /api/users/
  PUT  /api/users/{id}
  GET  /api/users/service-types
  GET  /api/platforms/
  POST /api/platforms/
  PUT  /api/platforms/{id}
  DEL  /api/platforms/{id}
  GET  /api/tenants/current
  PUT  /api/tenants/current/branding
  POST /api/tenants/
D2EOF

    log_info "Documentacao gerada"
}

generate_readme() {
    cat > "${MONIHOOK_DIR}/README.md" << 'RMEOF'
# Monihook
Monitoramento de Servicos de Privacidade - LGPD e GDPR

## Quick Start
sudo bash install_monihook.sh

## Gerenciamento
./monihook.sh start
./monihook.sh stop
./monihook.sh restart
./monihook.sh status
./monihook.sh logs
./monihook.sh backup
./monihook.sh credentials
RMEOF
}

generate_zip() {
    log_step "Gerando arquivo compactado"
    cd /opt
    tar -czf monihook-v${MONIHOOK_VERSION}.tar.gz monihook/
    log_info "tar.gz: /opt/monihook-v${MONIHOOK_VERSION}.tar.gz"
}

# ═══════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════
main() {
    print_banner
    check_root
    check_os

    echo ""
    echo "Este script ira:"
    echo "  1. Instalar Docker e Docker Compose"
    echo "  2. Criar toda estrutura do Monihook"
    echo "  3. Gerar banco de dados e configuracoes"
    echo "  4. Compilar e iniciar containers"
    echo ""
    echo "Local: ${MONIHOOK_DIR}"
    echo ""

    read -p "Continuar? (s/n): " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[SsYy]$ ]] && echo "Cancelado." && exit 0

    install_dependencies
    setup_firewall
    create_project_structure
    generate_env
    generate_docker_compose
    generate_init_sql
    generate_nginx
    generate_backend
    generate_frontend
    generate_management_script
    generate_docs
    generate_readme

    log_step "Compilando e iniciando containers"
    cd "${MONIHOOK_DIR}"
    docker compose build 2>&1 | tail -20
    docker compose up -d 2>&1 | tail -10

    log_info "Aguardando servicos (30s)..."
    sleep 30
    docker compose ps

    generate_zip

    log_step "INSTALACAO CONCLUIDA!"
    echo ""
    cat "${MONIHOOK_DIR}/.credentials"
    echo ""
    echo "Comandos:"
    echo "  cd ${MONIHOOK_DIR}"
    echo "  ./monihook.sh status"
    echo "  ./monihook.sh logs"
    echo "  ./monihook.sh credentials"
    echo ""
    echo "Pacote: /opt/monihook-v${MONIHOOK_VERSION}.tar.gz"
}

main "$@"
