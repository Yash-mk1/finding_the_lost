from rest_framework import serializers

from lostfound.serializers import AuthorSerializer, PostImageSerializer

from .models import Conversation, Message


class MessageSerializer(serializers.ModelSerializer):
    sender_is_me = serializers.SerializerMethodField()
    is_read = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = ["id", "body", "sender_is_me", "is_read", "created_at"]

    def get_sender_is_me(self, message):
        return message.sender_id == self.context["request"].user.pk

    def get_is_read(self, message):
        return message.read_at is not None


class ConversationSerializer(serializers.ModelSerializer):
    post = serializers.SerializerMethodField()
    other_user = serializers.SerializerMethodField()
    i_am_author = serializers.SerializerMethodField()
    last_message = serializers.SerializerMethodField()
    unread = serializers.SerializerMethodField()
    blocked = serializers.SerializerMethodField()
    blocked_by_me = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = ["id", "post", "other_user", "i_am_author", "last_message", "unread", "blocked", "blocked_by_me",
                  "created_at", "last_message_at"]

    def _me(self):
        return self.context["request"].user

    def get_post(self, convo):
        post = convo.post
        first = post.images.first()
        url = PostImageSerializer(first, context=self.context).data["url"] if first else None
        return {"id": post.id, "title": post.title, "post_type": post.post_type, "status": post.status,
                "category": post.category, "thumbnail": url}

    def get_other_user(self, convo):
        return AuthorSerializer(convo.other_side(self._me())).data

    def get_i_am_author(self, convo):
        return convo.author_id == self._me().pk

    def get_last_message(self, convo):
        message = convo.messages.order_by("-id").first()
        if message is None:
            return None
        return {"body": message.body, "sender_is_me": message.sender_id == self._me().pk, "created_at": message.created_at}

    def get_unread(self, convo):
        value = getattr(convo, "unread_count", None)
        if value is not None:
            return value
        return convo.messages.filter(read_at__isnull=True).exclude(sender=self._me()).count()

    def get_blocked(self, convo):
        return convo.blocked_by_id is not None

    def get_blocked_by_me(self, convo):
        return convo.blocked_by_id == self._me().pk
