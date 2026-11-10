FROM node:22.23.4-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202 AS ui
WORKDIR /ui
COPY ui/package.json ui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ui/ ./
RUN npm run build

FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS build
WORKDIR /build
COPY requirements.lock .
RUN python -m venv /venv && /venv/bin/pip install --no-cache-dir --require-hashes -r requirements.lock

FROM python:3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
ARG GIT_SHA=unknown
ENV BUILD_SHA=${GIT_SHA} \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PATH=/venv/bin:$PATH
COPY --from=build /venv /venv
WORKDIR /app
COPY VERSION ./VERSION
COPY src ./src
COPY --from=ui /ui/dist ./static
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 8080
CMD ["python", "-m", "messenger"]
