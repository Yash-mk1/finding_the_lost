"""
Django settings for the Finding the Lost API.

Everything environment-specific is read from environment variables so the
same file works on a laptop, in Docker and on a server. See .env.example.
"""
import os
from pathlib import Path

from django.core.exceptions import ImproperlyConfigured

BASE_DIR = Path(__file__).resolve().parent.parent


def env(name, default=None):
    return os.environ.get(name, default)


def env_bool(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


_DEV_SECRET_KEYS = {"dev-only-insecure-key-change-me", "change-me-to-a-long-random-string"}
SECRET_KEY = env("DJANGO_SECRET_KEY", "dev-only-insecure-key-change-me")
DEBUG = env_bool("DJANGO_DEBUG", True)
if not DEBUG and SECRET_KEY in _DEV_SECRET_KEYS:
    raise ImproperlyConfigured(
        "Set DJANGO_SECRET_KEY to a long random value before running with DJANGO_DEBUG=false. "
        'Generate one with: python -c "import secrets; print(secrets.token_urlsafe(50))"'
    )
ALLOWED_HOSTS = [h.strip() for h in env("DJANGO_ALLOWED_HOSTS", "*").split(",") if h.strip()]

# GeoDjango needs the GDAL and GEOS C libraries. On Linux/macOS they are found
# automatically; on Windows point these at your OSGeo4W install if needed.
if env("GDAL_LIBRARY_PATH"):
    GDAL_LIBRARY_PATH = env("GDAL_LIBRARY_PATH")
if env("GEOS_LIBRARY_PATH"):
    GEOS_LIBRARY_PATH = env("GEOS_LIBRARY_PATH")

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.gis",
    "rest_framework",
    "rest_framework.authtoken",
    "accounts",
    "lostfound",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "config.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.contrib.gis.db.backends.postgis",
        "NAME": env("POSTGRES_DB", "ftl"),
        "USER": env("POSTGRES_USER", "ftl"),
        "PASSWORD": env("POSTGRES_PASSWORD", "ftl"),
        "HOST": env("POSTGRES_HOST", "localhost"),
        "PORT": env("POSTGRES_PORT", "5432"),
    }
}

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = "en-us"
TIME_ZONE = env("DJANGO_TIME_ZONE", "Asia/Kolkata")
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
MEDIA_URL = "/media/"
MEDIA_ROOT = Path(env("MEDIA_ROOT", str(BASE_DIR / "media")))
# Let Django serve uploaded photos and the admin's CSS itself (fine for a class
# demo; use a CDN or Nginx in real production).
SERVE_MEDIA = env_bool("SERVE_MEDIA", True)

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# Uploaded photos are re-encoded server-side; keep the raw upload bounded.
DATA_UPLOAD_MAX_MEMORY_SIZE = 50 * 1024 * 1024
FILE_UPLOAD_MAX_MEMORY_SIZE = 10 * 1024 * 1024

REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "rest_framework.authentication.TokenAuthentication",
        "rest_framework.authentication.SessionAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticatedOrReadOnly",
    ],
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 20,
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
        "rest_framework.throttling.ScopedRateThrottle",
    ],
    "DEFAULT_THROTTLE_RATES": {
        "anon": env("THROTTLE_ANON", "120/min"),
        "user": env("THROTTLE_USER", "600/min"),
        # Per network address. A whole class on one Wi-Fi shares an address, so
        # this is roomy enough for everyone to sign up during a demo.
        "auth": env("THROTTLE_AUTH", "30/min"),
        "comment": env("THROTTLE_COMMENT", "30/min"),
        "post_create": env("THROTTLE_POST_CREATE", "20/hour"),
        "claim": env("THROTTLE_CLAIM", "10/hour"),
    },
}

# App rules (see lostfound/models.py for how they are used).
# ---------------------------------------------------------------- email ---
# Sign-up codes are emailed. With no EMAIL_HOST_USER set, emails are printed
# in the server's log instead (see `docker compose logs api`), which is handy
# for a demo. Set the EMAIL_* values in .env to send real emails (Gmail needs
# an "app password", not your normal password).
EMAIL_HOST = env("EMAIL_HOST", "smtp.gmail.com")
EMAIL_PORT = int(env("EMAIL_PORT", "587"))
EMAIL_HOST_USER = env("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = env("EMAIL_HOST_PASSWORD", "")
EMAIL_USE_TLS = env_bool("EMAIL_USE_TLS", True)
EMAIL_TIMEOUT = 15
EMAIL_BACKEND = env(
    "EMAIL_BACKEND",
    "django.core.mail.backends.smtp.EmailBackend" if EMAIL_HOST_USER else "django.core.mail.backends.console.EmailBackend",
)
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL", f"Finding the Lost <{EMAIL_HOST_USER or 'no-reply@localhost'}>")

# ---------------------------------------------------------------- HTTPS ---
# When the server sits behind an HTTPS proxy or tunnel (Cloudflare tunnel,
# Caddy, Nginx), trust its note that the visitor used HTTPS. Without this,
# photo links come back as http:// and the admin login fails its security
# check. Only turn it off if the server is reachable directly, with no proxy.
if env_bool("BEHIND_HTTPS_PROXY", True):
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    USE_X_FORWARDED_HOST = True

FTL = {
    # New accounts must confirm their email with a 6-digit code before they
    # can log in. Turn off only for quick local testing.
    "REQUIRE_EMAIL_VERIFICATION": env_bool("FTL_REQUIRE_EMAIL_VERIFICATION", True),
    # Posts disappear from the feed after this many days unless renewed.
    "POST_LIFETIME_DAYS": int(env("FTL_POST_LIFETIME_DAYS", "30")),
    # "Kept it with me" posts show only an approximate area of this size.
    "APPROX_RADIUS_M": int(env("FTL_APPROX_RADIUS_M", "250")),
    # A post is hidden for review once this many different users report it.
    "AUTO_HIDE_REPORTS": int(env("FTL_AUTO_HIDE_REPORTS", "3")),
    "MAX_IMAGES_PER_POST": 5,
    "MAX_IMAGE_MB": 10,
    "IMAGE_MAX_SIDE_PX": 1600,
}
