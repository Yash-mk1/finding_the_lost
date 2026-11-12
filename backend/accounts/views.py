from django.conf import settings
from django.contrib.auth import authenticate, get_user_model, password_validation
from django.db import transaction
from django.db.models import Q
from rest_framework import permissions, serializers, status
from rest_framework.authtoken.models import Token
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import EmailVerification
from .verification import (
    EmailSendError,
    VerificationError,
    check_code,
    free_stale_signups,
    is_verified,
    mask_email,
    send_code,
)

User = get_user_model()


def _verification_on():
    return settings.FTL["REQUIRE_EMAIL_VERIFICATION"]


def _token_response(user, status_code=status.HTTP_200_OK):
    token, _ = Token.objects.get_or_create(user=user)
    return Response({"token": token.key, "user": UserSerializer(user).data}, status=status_code)


def _needs_verification_response(user, status_code, detail, wait_seconds=0, email_failed=False):
    return Response(
        {
            "detail": detail,
            "code": "email_unverified",
            "verification_required": True,
            "username": user.username,
            "email_hint": mask_email(user.email),
            "resend_in": wait_seconds,
            "email_failed": email_failed,
        },
        status=status_code,
    )


class UserSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(source="first_name", required=False, allow_blank=True, max_length=60)

    class Meta:
        model = User
        fields = ["id", "username", "email", "display_name", "date_joined"]
        # Email is read-only: it is a login name, so letting someone change it
        # to another person's address would break that person's login.
        read_only_fields = ["id", "username", "email", "date_joined"]


class RegisterSerializer(serializers.Serializer):
    username = serializers.RegexField(r"^[A-Za-z0-9_.]{3,30}$", error_messages={
        "invalid": "Use 3-30 letters, numbers, dots or underscores."
    })
    email = serializers.EmailField()
    password = serializers.CharField(write_only=True, min_length=8)
    display_name = serializers.CharField(required=False, allow_blank=True, max_length=60)

    def validate_username(self, value):
        if User.objects.filter(username__iexact=value).exists():
            raise serializers.ValidationError("That username is taken.")
        return value

    def validate_email(self, value):
        if User.objects.filter(email__iexact=value).exists():
            raise serializers.ValidationError("An account with this email already exists.")
        return value.lower()

    def validate(self, attrs):
        candidate = User(username=attrs["username"], email=attrs["email"])
        password_validation.validate_password(attrs["password"], candidate)
        return attrs

    def create(self, validated_data):
        return User.objects.create_user(
            username=validated_data["username"],
            email=validated_data["email"],
            password=validated_data["password"],
            first_name=validated_data.get("display_name", ""),
        )


class RegisterView(APIView):
    # No token check here: an old or deleted token saved on the phone must
    # never stop someone from signing up or logging in again.
    authentication_classes = []
    permission_classes = [permissions.AllowAny]
    throttle_scope = "auth"

    def post(self, request):
        data = request.data if hasattr(request.data, "get") else {}
        free_stale_signups(str(data.get("username") or ""), str(data.get("email") or ""))
        serializer = RegisterSerializer(data=data)
        serializer.is_valid(raise_exception=True)
        if not _verification_on():
            return _token_response(serializer.save(), status.HTTP_201_CREATED)

        with transaction.atomic():
            user = serializer.save()
            EmailVerification.objects.create(user=user)
        hint = mask_email(user.email)
        try:
            send_code(user, force=True)
        except EmailSendError:
            # The account exists; the person can ask for the code again once
            # email is working.
            return _needs_verification_response(
                user, status.HTTP_201_CREATED,
                "Your account was created, but we couldn't send the email. Tap 'Send a new code' to try again.",
                email_failed=True,
            )
        return _needs_verification_response(
            user, status.HTTP_201_CREATED, f"We've emailed a 6-digit code to {hint}. Enter it to finish signing up."
        )


class LoginView(APIView):
    """Log in with username or email + password; returns an API token."""

    authentication_classes = []
    permission_classes = [permissions.AllowAny]
    throttle_scope = "auth"

    def post(self, request):
        data = request.data if hasattr(request.data, "get") else {}
        identifier = str(data.get("username") or "").strip()
        password = str(data.get("password") or "")
        match = User.objects.filter(Q(username__iexact=identifier) | Q(email__iexact=identifier)).first()
        user = authenticate(request, username=match.username, password=password) if match else None
        if user is None:
            return Response({"detail": "Wrong username or password."}, status=status.HTTP_400_BAD_REQUEST)
        if _verification_on() and not is_verified(user):
            # Right password, but the email was never confirmed: send a code
            # (unless one went out in the last minute) and ask for it.
            try:
                wait = send_code(user)
            except EmailSendError:
                return _needs_verification_response(
                    user, status.HTTP_403_FORBIDDEN,
                    "Confirm your email to log in. We couldn't send the email just now; tap 'Send a new code'.",
                    email_failed=True,
                )
            return _needs_verification_response(
                user, status.HTTP_403_FORBIDDEN,
                f"Confirm your email to log in. Enter the 6-digit code we sent to {mask_email(user.email)}.",
                wait_seconds=wait,
            )
        return _token_response(user)


def _find_user(identifier):
    identifier = str(identifier or "").strip()
    if not identifier:
        return None
    return User.objects.filter(Q(username__iexact=identifier) | Q(email__iexact=identifier)).first()


class VerifyEmailView(APIView):
    """POST {username, code}: confirms the email and returns a login token."""

    authentication_classes = []
    permission_classes = [permissions.AllowAny]
    throttle_scope = "auth"

    def post(self, request):
        data = request.data if hasattr(request.data, "get") else {}
        user = _find_user(data.get("username"))
        if user is None:
            return Response({"detail": "That code isn't right."}, status=status.HTTP_400_BAD_REQUEST)
        try:
            check_code(user, data.get("code", ""))
        except VerificationError as exc:
            return Response({"detail": str(exc), "code": "bad_code"}, status=status.HTTP_400_BAD_REQUEST)
        return _token_response(user)


class ResendCodeView(APIView):
    """POST {username}: emails a new code. Answers the same way whether or not
    the account exists, so it can't be used to find out who has signed up."""

    authentication_classes = []
    permission_classes = [permissions.AllowAny]
    throttle_scope = "auth"

    def post(self, request):
        data = request.data if hasattr(request.data, "get") else {}
        user = _find_user(data.get("username"))
        wait = 0
        if user is not None and not is_verified(user):
            try:
                wait = send_code(user)
            except EmailSendError:
                return Response(
                    {"detail": "We couldn't send the email just now. Try again in a minute."},
                    status=status.HTTP_503_SERVICE_UNAVAILABLE,
                )
        if wait:
            return Response(
                {"detail": f"Please wait {wait} seconds before asking for another code.", "resend_in": wait},
                status=status.HTTP_429_TOO_MANY_REQUESTS,
            )
        return Response({"detail": "If that account needs confirming, a new code is on its way.", "resend_in": 60})


class LogoutView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        Token.objects.filter(user=request.user).delete()
        return Response(status=status.HTTP_204_NO_CONTENT)


class MeView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        return Response(UserSerializer(request.user).data)

    def patch(self, request):
        serializer = UserSerializer(request.user, data=request.data, partial=True)
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data)
