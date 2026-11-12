# Pinned to Debian 12 (bookworm) so the GDAL version under GeoDjango doesn't
# change underneath the project when the base image is updated.
FROM python:3.12-slim-bookworm

# GeoDjango needs GDAL, GEOS and PROJ at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gdal-bin libgdal-dev binutils libproj-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
# Start-up: update the database tables, collect the admin's CSS, create the
# admin account / demo data from environment variables (prepare_server), then
# serve. PORT is set by hosts like Render; docker-compose uses 8000.
# Threaded workers with a long timeout: photo uploads from a phone on slow
# Wi-Fi can take a while and must not be cut off mid-upload.
CMD ["sh", "-c", "python manage.py migrate --noinput && python manage.py collectstatic --noinput && python manage.py prepare_server && exec gunicorn config.wsgi:application --bind 0.0.0.0:${PORT:-8000} --workers ${WEB_CONCURRENCY:-2} --worker-class gthread --threads 4 --timeout 120"]
