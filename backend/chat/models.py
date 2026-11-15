"""
Private messages about a post.

A conversation is always about one post and has two people: the post's
author and one other person. Anyone can start one from a post; the author
can start one with someone who claimed or commented on their post. Only the
two people in it can read it. Either of them can block it (no more messages)
or report it to the moderators.
"""
from django.conf import settings
from django.db import models

from lostfound.models import Post

User = settings.AUTH_USER_MODEL


class Conversation(models.Model):
    post = models.ForeignKey(Post, on_delete=models.CASCADE, related_name="conversations")
    author = models.ForeignKey(User, on_delete=models.CASCADE, related_name="conversations_as_author")
    other = models.ForeignKey(User, on_delete=models.CASCADE, related_name="conversations_as_other")
    created_at = models.DateTimeField(auto_now_add=True)
    last_message_at = models.DateTimeField(null=True, blank=True, db_index=True)
    blocked_by = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name="+")

    class Meta:
        ordering = ["-last_message_at", "-created_at"]
        constraints = [models.UniqueConstraint(fields=["post", "other"], name="one_chat_per_post_and_person")]

    def __str__(self):
        return f"#{self.pk} {self.author} ↔ {self.other} about post #{self.post_id}"

    def has_member(self, user):
        return user.pk in (self.author_id, self.other_id)

    def other_side(self, user):
        return self.other if user.pk == self.author_id else self.author


class Message(models.Model):
    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name="messages")
    sender = models.ForeignKey(User, on_delete=models.CASCADE, related_name="+")
    body = models.TextField(max_length=2000)
    created_at = models.DateTimeField(auto_now_add=True)
    read_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["created_at", "id"]
        indexes = [models.Index(fields=["conversation", "id"])]

    def __str__(self):
        return f"{self.sender}: {self.body[:40]}"


class ChatReport(models.Model):
    """A person flagged a conversation; moderators can read it in the admin."""

    conversation = models.ForeignKey(Conversation, on_delete=models.CASCADE, related_name="reports")
    reporter = models.ForeignKey(User, on_delete=models.CASCADE, related_name="+")
    reason = models.CharField(max_length=300, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["conversation", "reporter"], name="one_chat_report_per_person")]
