from lostfound.tests import ApiTestCase

from .models import Conversation, Message


class ChatTests(ApiTestCase):
    def setUp(self):
        super().setUp()
        self.post = self.create_found()  # by self.finder, kept, with a question

    def claim(self, user, answer):
        self.as_user(user)
        res = self.client.post(f"/api/posts/{self.post['id']}/claims/", {"answer": answer})
        self.assertEqual(res.status_code, 201, res.data)

    def start(self, user, body=None, **extra):
        self.as_user(user)
        data = {"body": body} if body else {}
        data.update(extra)
        return self.client.post(f"/api/posts/{self.post['id']}/conversation/", data)

    def test_anyone_can_message_the_author_and_both_see_it(self):
        res = self.start(self.owner, "Hi, I think this is my phone.")
        self.assertEqual(res.status_code, 200, res.data)
        convo_id = res.data["id"]
        self.assertEqual(res.data["other_user"]["username"], "finder")
        # The author sees it as unread, reads it and replies.
        self.as_user(self.finder)
        self.assertEqual(self.client.get("/api/me/unread/").data["unread"], 1)
        listing = self.client.get("/api/conversations/").data["results"]
        self.assertEqual(listing[0]["other_user"]["username"], "owner")
        self.assertEqual(listing[0]["unread"], 1)
        msgs = self.client.get(f"/api/conversations/{convo_id}/messages/").data
        self.assertEqual([m["body"] for m in msgs["results"]], ["Hi, I think this is my phone."])
        self.assertFalse(msgs["results"][0]["sender_is_me"])
        self.assertEqual(self.client.get("/api/me/unread/").data["unread"], 0)
        reply = self.client.post(f"/api/conversations/{convo_id}/messages/", {"body": "What colour is the case?"})
        self.assertEqual(reply.status_code, 201)
        # Polling with ?after returns only the new message.
        self.as_user(self.owner)
        first_id = msgs["results"][0]["id"]
        new = self.client.get(f"/api/conversations/{convo_id}/messages/?after={first_id}").data["results"]
        self.assertEqual([m["body"] for m in new], ["What colour is the case?"])
        # Starting again returns the same conversation.
        self.assertEqual(self.start(self.owner).data["id"], convo_id)

    def test_strangers_cannot_read_a_chat(self):
        convo_id = self.start(self.owner, "hello").data["id"]
        self.as_user(self.stranger)
        self.assertEqual(self.client.get(f"/api/conversations/{convo_id}/messages/").status_code, 404)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/messages/", {"body": "x"}).status_code, 404)
        self.assertEqual(self.client.get("/api/conversations/").data["results"], [])

    def test_author_can_message_only_people_who_engaged(self):
        self.as_user(self.finder)
        res = self.client.post(f"/api/posts/{self.post['id']}/conversation/", {"user_id": self.stranger["id"], "body": "hi"})
        self.assertEqual(res.status_code, 403)
        self.claim(self.owner, "black cat")
        self.as_user(self.finder)
        res = self.client.post(f"/api/posts/{self.post['id']}/conversation/", {"user_id": self.owner["id"], "body": "Hi!"})
        self.assertEqual(res.status_code, 200, res.data)

    def test_follow_up_goes_privately_to_each_waiting_claimant(self):
        self.claim(self.owner, "black cat")
        self.claim(self.stranger, "black cat")
        self.as_user(self.finder)
        res = self.client.post(f"/api/posts/{self.post['id']}/follow-up/", {"question": "What app is on the home screen?"})
        self.assertEqual(res.status_code, 200, res.data)
        self.assertEqual(res.data["sent"], 2)
        self.assertEqual(Conversation.objects.filter(post_id=self.post["id"]).count(), 2)
        # Each claimant sees only their own chat.
        for user in (self.owner, self.stranger):
            self.as_user(user)
            chats = self.client.get("/api/conversations/").data["results"]
            self.assertEqual(len(chats), 1)
            self.assertIn("Follow-up question", chats[0]["last_message"]["body"])
        # Only the author can ask.
        self.assertEqual(self.client.post(f"/api/posts/{self.post['id']}/follow-up/", {"question": "hello?"}).status_code, 404)

    def test_block_stops_messages_and_report_is_recorded(self):
        convo_id = self.start(self.owner, "hello").data["id"]
        self.as_user(self.finder)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/block/").status_code, 200)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/report/", {"reason": "asked for money"}).status_code, 200)
        self.as_user(self.owner)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/messages/", {"body": "pls"}).status_code, 403)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/unblock/").status_code, 403)
        self.as_user(self.finder)
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/unblock/").status_code, 200)

    def test_cannot_message_yourself_or_send_empty(self):
        self.as_user(self.finder)
        self.assertEqual(self.client.post(f"/api/posts/{self.post['id']}/conversation/", {"user_id": self.finder["id"]}).status_code, 403)
        convo_id = self.start(self.owner).data["id"]
        self.assertEqual(self.client.post(f"/api/conversations/{convo_id}/messages/", {"body": "  "}).status_code, 400)
        # A chat with no messages isn't listed.
        self.assertEqual(self.client.get("/api/conversations/").data["results"], [])
        self.assertEqual(Message.objects.count(), 0)
