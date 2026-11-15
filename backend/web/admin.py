from django.contrib import admin

from .models import ClientHit


@admin.register(ClientHit)
class ClientHitAdmin(admin.ModelAdmin):
    list_display = ("scope", "client", "created_at")
    list_filter = ("scope",)
    readonly_fields = ("scope", "client", "created_at")
