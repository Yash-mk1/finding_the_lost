from django.contrib import admin
from django.contrib.gis.admin import GISModelAdmin
from django.utils.html import format_html

from .models import Claim, Comment, Post, PostImage, Report


class PostImageInline(admin.TabularInline):
    model = PostImage
    extra = 0
    readonly_fields = ["preview", "width", "height"]
    fields = ["preview", "image", "width", "height", "position"]

    @admin.display(description="Photo")
    def preview(self, obj):
        return format_html('<img src="{}" style="max-height:120px">', obj.image.url) if obj.image else ""


class ReportInline(admin.TabularInline):
    model = Report
    extra = 0
    readonly_fields = ["reporter", "reason", "details", "created_at"]
    can_delete = True


@admin.register(Post)
class PostAdmin(GISModelAdmin):
    list_display = ["title", "post_type", "category", "handover", "status", "author", "report_count", "created_at"]
    list_filter = ["status", "post_type", "category", "handover"]
    search_fields = ["title", "description", "landmark", "author__username"]
    readonly_fields = ["public_location", "score", "created_at", "updated_at"]
    inlines = [PostImageInline, ReportInline]
    actions = ["hide_posts", "reopen_posts"]

    @admin.display(description="Reports")
    def report_count(self, obj):
        return obj.reports.count()

    @admin.action(description="Hide selected posts")
    def hide_posts(self, request, queryset):
        queryset.update(status=Post.Status.HIDDEN)

    @admin.action(description="Reopen selected posts (clear hidden)")
    def reopen_posts(self, request, queryset):
        queryset.update(status=Post.Status.OPEN)


@admin.register(Claim)
class ClaimAdmin(admin.ModelAdmin):
    list_display = ["post", "claimant", "status", "created_at", "decided_at"]
    list_filter = ["status"]
    search_fields = ["post__title", "claimant__username"]


@admin.register(Comment)
class CommentAdmin(admin.ModelAdmin):
    list_display = ["post", "author", "body", "created_at"]
    search_fields = ["body", "author__username"]


@admin.register(Report)
class ReportAdmin(admin.ModelAdmin):
    list_display = ["post", "reporter", "reason", "created_at"]
    list_filter = ["reason"]
