from django.contrib import admin

from .models import ChatReport, Conversation, Message


class MessageInline(admin.TabularInline):
    model = Message
    extra = 0
    fields = ("sender", "body", "created_at", "read_at")
    readonly_fields = fields
    can_delete = True


@admin.register(Conversation)
class ConversationAdmin(admin.ModelAdmin):
    list_display = ("id", "post", "author", "other", "last_message_at", "blocked_by")
    list_filter = ("blocked_by",)
    search_fields = ("post__title", "author__username", "other__username")
    raw_id_fields = ("post", "author", "other", "blocked_by")
    inlines = [MessageInline]


@admin.register(ChatReport)
class ChatReportAdmin(admin.ModelAdmin):
    list_display = ("conversation", "reporter", "reason", "created_at")
    raw_id_fields = ("conversation", "reporter")
