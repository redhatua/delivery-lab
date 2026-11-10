FROM python:3.13-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /venv && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
ARG GIT_SHA=unknown
ENV BUILD_SHA=${GIT_SHA} \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    PATH=/venv/bin:$PATH
COPY --from=build /venv /venv
WORKDIR /app
COPY VERSION ./VERSION
COPY src ./src
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001
EXPOSE 8080
CMD ["python", "-m", "messenger"]
