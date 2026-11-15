from django.conf import settings
from django.contrib import admin
from django.urls import include, path, re_path
from django.views.static import serve
from rest_framework.routers import DefaultRouter

from accounts.views import LoginView, LogoutView, MeView, RegisterView, ResendCodeView, VerifyEmailView
from chat.views import ConversationViewSet, follow_up, start_conversation, unread
from lostfound.views import ClaimViewSet, MyClaimsViewSet, MyPostsViewSet, PostViewSet, health, meta
from web.views import index

router = DefaultRouter()
router.register("posts", PostViewSet, basename="post")
router.register("claims", ClaimViewSet, basename="claim")
router.register("me/posts", MyPostsViewSet, basename="my-post")
router.register("me/claims", MyClaimsViewSet, basename="my-claim")
router.register("conversations", ConversationViewSet, basename="conversation")

admin.site.site_header = "Findit — moderation"

urlpatterns = [
    path(settings.ADMIN_URL, admin.site.urls),
    path("", index, name="web-index"),
    path("api/auth/register/", RegisterView.as_view()),
    path("api/auth/login/", LoginView.as_view()),
    path("api/auth/verify-email/", VerifyEmailView.as_view()),
    path("api/auth/resend-code/", ResendCodeView.as_view()),
    path("api/auth/logout/", LogoutView.as_view()),
    path("api/auth/me/", MeView.as_view()),
    path("api/meta/", meta),
    path("api/health/", health),
    path("api/posts/<int:pk>/conversation/", start_conversation),
    path("api/posts/<int:pk>/follow-up/", follow_up),
    path("api/me/unread/", unread),
    path("api/", include(router.urls)),
]

# Uploaded photos kept on disk (docker-compose setup). With S3_BUCKET set,
# photos are served by the storage service instead. The website's and the
# admin's CSS/JS are served by WhiteNoise (see MIDDLEWARE).
if (settings.DEBUG or settings.SERVE_MEDIA) and not settings.S3_BUCKET:
    urlpatterns.append(re_path(r"^media/(?P<path>.*)$", serve, {"document_root": settings.MEDIA_ROOT}))
