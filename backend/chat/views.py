from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.db.models import Count, Q
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import mixins, permissions, status, viewsets
from rest_framework.decorators import action, api_view, permission_classes, throttle_classes
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.response import Response

from lostfound.models import Claim, Comment, Post
from web.throttling import DatabaseScopedRateThrottle

from .models import ChatReport, Conversation, Message
from .serializers import ConversationSerializer, MessageSerializer

MAX_BODY = 2000
SAFETY_NOTE = "Keep it on Findit. Never send money, OTPs or bank details to get an item back."


class MessageThrottle(DatabaseScopedRateThrottle):
    def allow_request(self, request, view):
        view.throttle_scope = "message"
        return super().allow_request(request, view)


def _clean_body(data):
    body = str((data or {}).get("body") or "").strip()
    if not body:
        raise ValidationError({"body": "Write a message first."})
    if len(body) > MAX_BODY:
        raise ValidationError({"body": f"Keep it under {MAX_BODY} characters."})
    return body


def _send(convo, sender, body):
    message = Message.objects.create(conversation=convo, sender=sender, body=body)
    Conversation.objects.filter(pk=convo.pk).update(last_message_at=message.created_at)
    return message


def _open_conversation(post, author, other):
    try:
        with transaction.atomic():
            convo, _ = Conversation.objects.get_or_create(post=post, other=other, defaults={"author": author})
    except IntegrityError:  # two taps at once: the other request made it
        convo = Conversation.objects.get(post=post, other=other)
    return convo


def _visible_post(user, pk):
    visible = ~Q(status=Post.Status.HIDDEN) | Q(author=user)
    return get_object_or_404(Post.objects.filter(visible), pk=pk)


def _has_engaged(post, user_id):
    return (Claim.objects.filter(post=post, claimant_id=user_id).exists()
            or Comment.objects.filter(post=post, author_id=user_id).exists())


@api_view(["POST"])
@permission_classes([permissions.IsAuthenticated])
@throttle_classes([MessageThrottle])
def start_conversation(request, pk):
    """
    POST /api/posts/{id}/conversation/  -> the chat about this post.
    Anyone but the author: chat with the author. The author: pass user_id of
    someone who claimed or commented on the post. An optional `body` sends the
    first message.
    """
    post = _visible_post(request.user, pk)
    if post.author_id == request.user.pk:
        try:
            other_id = int((request.data or {}).get("user_id"))
        except (TypeError, ValueError):
            raise ValidationError({"user_id": "Choose who to message."})
        if other_id == request.user.pk or not _has_engaged(post, other_id):
            raise PermissionDenied("You can message people who claimed or commented on your post.")
        convo = _open_conversation(post, request.user, get_user_model().objects.get(pk=other_id))
    else:
        convo = _open_conversation(post, post.author, request.user)
    if convo.blocked_by_id and request.data.get("body"):
        raise PermissionDenied("This chat is blocked.")
    if request.data.get("body"):
        _send(convo, request.user, _clean_body(request.data))
    convo.refresh_from_db()
    return Response(ConversationSerializer(convo, context={"request": request}).data, status=status.HTTP_200_OK)


@api_view(["POST"])
@permission_classes([permissions.IsAuthenticated])
@throttle_classes([MessageThrottle])
def follow_up(request, pk):
    """
    POST /api/posts/{id}/follow-up/ {question}: the finder asks everyone with a
    waiting claim one more question, in each person's private chat. Answers
    stay private, so claimants can't copy each other.
    """
    post = get_object_or_404(Post, pk=pk, author=request.user)
    question = str((request.data or {}).get("question") or "").strip()
    if len(question) < 5:
        raise ValidationError({"question": "Write the question you want to ask."})
    if len(question) > 500:
        raise ValidationError({"question": "Keep the question under 500 characters."})
    pending = list(post.claims.filter(status=Claim.Status.PENDING).select_related("claimant"))
    if not pending:
        raise ValidationError({"detail": "There are no waiting claims to ask."})
    body = f"Follow-up question from the finder: {question}"
    sent = 0
    for claim in pending:
        convo = _open_conversation(post, request.user, claim.claimant)
        if convo.blocked_by_id:
            continue
        _send(convo, request.user, body)
        sent += 1
    return Response({"sent": sent, "detail": f"Asked {sent} {'person' if sent == 1 else 'people'}. Their answers will appear in Messages."})


@api_view(["GET"])
@permission_classes([permissions.IsAuthenticated])
def unread(request):
    """GET /api/me/unread/ -> {"unread": n} for the Messages badge."""
    count = (Message.objects.filter(read_at__isnull=True, conversation__blocked_by__isnull=True)
             .filter(Q(conversation__author=request.user) | Q(conversation__other=request.user))
             .exclude(sender=request.user).count())
    return Response({"unread": count})


class ConversationViewSet(mixins.ListModelMixin, mixins.RetrieveModelMixin, viewsets.GenericViewSet):
    serializer_class = ConversationSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_throttles(self):
        if self.request.method == "POST":
            return [MessageThrottle()]
        return super().get_throttles()

    def get_queryset(self):
        me = self.request.user
        return (Conversation.objects.filter(Q(author=me) | Q(other=me))
                .select_related("post", "author", "other")
                .annotate(unread_count=Count("messages", filter=Q(messages__read_at__isnull=True) & ~Q(messages__sender=me)))
                .order_by("-last_message_at", "-created_at"))

    def list(self, request, *args, **kwargs):
        # Chats with no messages yet (opened, then nothing sent) stay out of the list.
        queryset = self.filter_queryset(self.get_queryset()).filter(last_message_at__isnull=False)
        page = self.paginate_queryset(queryset)
        serializer = self.get_serializer(page if page is not None else queryset, many=True)
        return self.get_paginated_response(serializer.data) if page is not None else Response(serializer.data)

    @action(detail=True, methods=["get", "post"])
    def messages(self, request, pk=None):
        """
        GET ?after=<message id>: new messages (all of them, oldest first, if no
        `after`); marks the other person's messages as read.
        POST {body}: send a message.
        """
        convo = self.get_object()
        if request.method == "POST":
            if convo.blocked_by_id:
                raise PermissionDenied("This chat is blocked.")
            message = _send(convo, request.user, _clean_body(request.data))
            return Response(MessageSerializer(message, context={"request": request}).data, status=status.HTTP_201_CREATED)
        messages = convo.messages.all()
        after = request.query_params.get("after")
        if after:
            try:
                messages = messages.filter(id__gt=int(after))
            except ValueError:
                raise ValidationError({"after": "Must be a message id."})
        else:  # the latest 300
            recent = list(convo.messages.order_by("-id").values_list("id", flat=True)[:300])
            messages = messages.filter(id__in=recent)
        convo.messages.filter(read_at__isnull=True).exclude(sender=request.user).update(read_at=timezone.now())
        data = MessageSerializer(list(messages), many=True, context={"request": request}).data
        return Response({"results": data, "blocked": convo.blocked_by_id is not None,
                         "blocked_by_me": convo.blocked_by_id == request.user.pk, "safety_note": SAFETY_NOTE})

    @action(detail=True, methods=["post"])
    def block(self, request, pk=None):
        convo = self.get_object()
        if convo.blocked_by_id and convo.blocked_by_id != request.user.pk:
            raise PermissionDenied("The other person has already blocked this chat.")
        convo.blocked_by = request.user
        convo.save(update_fields=["blocked_by"])
        return Response({"detail": "Chat blocked. Neither of you can send messages now."})

    @action(detail=True, methods=["post"])
    def unblock(self, request, pk=None):
        convo = self.get_object()
        if convo.blocked_by_id != request.user.pk:
            raise PermissionDenied("Only the person who blocked this chat can unblock it.")
        convo.blocked_by = None
        convo.save(update_fields=["blocked_by"])
        return Response({"detail": "Chat unblocked."})

    @action(detail=True, methods=["post"])
    def report(self, request, pk=None):
        convo = self.get_object()
        reason = str((request.data or {}).get("reason") or "")[:300]
        ChatReport.objects.get_or_create(conversation=convo, reporter=request.user, defaults={"reason": reason})
        return Response({"detail": "Thanks. A moderator will look at this chat."})
