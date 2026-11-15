from django.db import models


class ClientHit(models.Model):
    """
    One write request (sign-up, log in, new post, comment, claim, report),
    used to rate-limit each client.

    Kept in the database, not Django's cache: the default cache lives inside
    each gunicorn worker, so with several workers an in-memory counter lets a
    client through roughly once per worker and forgets everything on restart.
    The database is shared by every worker and survives restarts.

    `client` is a salted hash, never the IP address itself (see throttling.py).
    """

    scope = models.CharField(max_length=32)
    client = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        indexes = [models.Index(fields=["scope", "client", "created_at"])]

    def __str__(self):
        return f"{self.scope} {self.client[:10]}… {self.created_at:%Y-%m-%d %H:%M:%S}"
