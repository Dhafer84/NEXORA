FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --require-hashes -r requirements.txt \
    && groupadd --gid 10001 nexora \
    && useradd --uid 10001 --gid nexora --no-create-home nexora \
    && mkdir -p /host/proc /host-disk
COPY app/ ./app/
# Readable by any runtime uid, whatever the file modes of the build checkout.
RUN chmod -R a+rX,go-w /app/app
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-proxy-headers", "--no-access-log"]
