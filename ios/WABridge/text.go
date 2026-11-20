package wabridge

import (
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
)

// Message kinds on the watch (the chats app): text, sticker, photo. Everything else is text with a label.
const (
	kindText    = 0
	kindSticker = 1
	kindPhoto   = 2
)

func kindName(k int) string {
	switch k {
	case kindSticker:
		return "Sticker"
	case kindPhoto:
		return "Photo"
	}
	return ""
}

func label(l, s string) string {
	if s = strings.TrimSpace(s); s == "" {
		return "[" + l + "]"
	}
	return "[" + l + "] " + s
}

// content: what the watch shows for m; ok false for what is not a message to show (reactions, receipts of keys,
// protocol messages).
// unwrap: the message inside the wrappers whatsmeow leaves (an iPhone album's photos come as associated children).
func unwrap(m *waE2E.Message) *waE2E.Message {
	for i := 0; i < 4 && m != nil; i++ {
		switch {
		case m.GetAssociatedChildMessage().GetMessage() != nil:
			m = m.GetAssociatedChildMessage().GetMessage()
		case m.GetDocumentWithCaptionMessage().GetMessage() != nil:
			m = m.GetDocumentWithCaptionMessage().GetMessage()
		case m.GetEphemeralMessage().GetMessage() != nil:
			m = m.GetEphemeralMessage().GetMessage()
		case m.GetViewOnceMessage().GetMessage() != nil:
			m = m.GetViewOnceMessage().GetMessage()
		case m.GetViewOnceMessageV2().GetMessage() != nil:
			m = m.GetViewOnceMessageV2().GetMessage()
		default:
			return m
		}
	}
	return m
}

// imageDoc: a picture sent as a file (an iPhone's HD or "as document" photo).
func imageDoc(m *waE2E.Message) *waE2E.DocumentMessage {
	if d := m.GetDocumentMessage(); d != nil && strings.HasPrefix(d.GetMimetype(), "image/") {
		return d
	}
	return nil
}

func content(m *waE2E.Message) (kind int, text string, ok bool) {
	m = unwrap(m)
	if m == nil {
		return 0, "", false
	}
	switch {
	case m.AlbumMessage != nil:
		// the album itself; its photos come one by one
		return 0, "", false
	case imageDoc(m) != nil:
		return kindPhoto, imageDoc(m).GetCaption(), true
	case m.Conversation != nil:
		return kindText, m.GetConversation(), true
	case m.ExtendedTextMessage != nil:
		return kindText, m.GetExtendedTextMessage().GetText(), true
	case m.ImageMessage != nil:
		return kindPhoto, m.GetImageMessage().GetCaption(), true
	case m.StickerMessage != nil:
		return kindSticker, "", true
	case m.VideoMessage != nil:
		return kindText, label("Video", m.GetVideoMessage().GetCaption()), true
	case m.PtvMessage != nil:
		return kindText, "[Video message]", true
	case m.AudioMessage != nil:
		if m.GetAudioMessage().GetPTT() {
			return kindText, "[Voice message]", true
		}
		return kindText, "[Audio]", true
	case m.DocumentMessage != nil:
		d := m.GetDocumentMessage()
		name := d.GetFileName()
		if name == "" {
			name = d.GetTitle()
		}
		if c := d.GetCaption(); c != "" {
			name = c
		}
		return kindText, label("Document", name), true
	case m.LocationMessage != nil:
		return kindText, label("Location", m.GetLocationMessage().GetName()), true
	case m.LiveLocationMessage != nil:
		return kindText, "[Live location]", true
	case m.ContactMessage != nil:
		return kindText, label("Contact", m.GetContactMessage().GetDisplayName()), true
	case m.ContactsArrayMessage != nil:
		return kindText, "[Contacts]", true
	case m.PollCreationMessage != nil:
		return kindText, label("Poll", m.GetPollCreationMessage().GetName()), true
	case m.PollCreationMessageV3 != nil:
		return kindText, label("Poll", m.GetPollCreationMessageV3().GetName()), true
	case m.EventMessage != nil:
		return kindText, label("Event", m.GetEventMessage().GetName()), true
	case m.GroupInviteMessage != nil:
		return kindText, "[Group invite]", true
	}
	return 0, "", false
}
