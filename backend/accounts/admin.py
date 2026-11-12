from django.contrib import admin
from django.utils import timezone

from .models import EmailVerification


@admin.register(EmailVerification)
class EmailVerificationAdmin(admin.ModelAdmin):
    list_display = ["user", "verified_at", "last_sent_at", "attempts", "created_at"]
    list_filter = [("verified_at", admin.EmptyFieldListFilter)]
    search_fields = ["user__username", "user__email"]
    readonly_fields = ["code_hash", "code_expires_at", "attempts", "last_sent_at", "created_at"]
    actions = ["mark_verified"]

    @admin.action(description="Mark selected accounts as verified")
    def mark_verified(self, request, queryset):
        queryset.filter(verified_at__isnull=True).update(verified_at=timezone.now(), code_hash="")
