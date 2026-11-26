package wabridge

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// Media: the picture of sticker or photo id in jid, downloaded from WhatsApp (webp, png or jpeg). A file WhatsApp no
// longer has (older ones) is asked again from the sender's phone; an animated sticker WhatsApp cannot give as a
// picture gives its still preview; a photo that cannot be had gives its small preview.
func Media(jid, id string) ([]byte, error) {
	c := client()
	if c == nil {
		return nil, errNotOpen
	}
	raw, fromMe, sender := own.mediaInfo(jid, id)
	if len(raw) == 0 {
		return nil, errors.New("this picture came before CMFX kept pictures")
	}
	var whole waE2E.Message
	if err := proto.Unmarshal(raw, &whole); err != nil {
		return nil, err
	}
	m := unwrap(&whole)
	file, preview := mediaOf(m)
	if file == nil {
		return nil, errors.New("not a sticker, photo or voice message")
	}
	ctx, cancel := timeout(90 * time.Second)
	defer cancel()
	b, err := c.Download(ctx, file)
	if isGone(err) {
		if again(ctx, c, jid, id, fromMe, sender, file) {
			own.setMedia(jid, id, mustMarshal(&whole, raw))
			b, err = c.Download(ctx, file)
		}
	}
	if err == nil && m.GetAudioMessage() == nil && !isPicture(b) {
		// a Lottie sticker (a zip of an animation)
		err = errors.New("an animation, not a picture")
	}
	if err != nil {
		if len(preview) > 0 {
			return preview, nil
		}
		return nil, err
	}
	return b, nil
}

// mediaOf: the downloadable part and its preview.
func mediaOf(m *waE2E.Message) (whatsmeow.DownloadableMessage, []byte) {
	switch {
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage(), m.GetStickerMessage().GetPngThumbnail()
	case m.GetImageMessage() != nil:
		return m.GetImageMessage(), m.GetImageMessage().GetJPEGThumbnail()
	case imageDoc(m) != nil:
		return imageDoc(m), imageDoc(m).GetJPEGThumbnail()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage(), nil
	}
	return nil, nil
}

func isGone(err error) bool {
	return errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
		errors.Is(err, whatsmeow.ErrNoURLPresent)
}

func isPicture(b []byte) bool {
	return (len(b) > 12 && bytes.Equal(b[:4], []byte("RIFF")) && bytes.Equal(b[8:12], []byte("WEBP"))) ||
		bytes.HasPrefix(b, []byte("\x89PNG")) || bytes.HasPrefix(b, []byte{0xFF, 0xD8}) ||
		bytes.HasPrefix(b, []byte("GIF8"))
}

func mustMarshal(m *waE2E.Message, old []byte) []byte {
	if b, err := proto.Marshal(m); err == nil {
		return b
	}
	return old
}

// The answers to "upload it again", by message id.
var retries = struct {
	sync.Mutex
	wait map[string]chan *events.MediaRetry
}{wait: map[string]chan *events.MediaRetry{}}

func retried(e *events.MediaRetry) {
	retries.Lock()
	ch := retries.wait[e.MessageID]
	retries.Unlock()
	if ch != nil {
		select {
		case ch <- e:
		default:
		}
	}
}

// again: asks the sender's phone to upload the file again; on success file has its new path.
func again(ctx context.Context, c *whatsmeow.Client, jid, id string, fromMe bool, sender string, file whatsmeow.DownloadableMessage) bool {
	chat, err := types.ParseJID(jid)
	if err != nil {
		return false
	}
	from := chat
	if fromMe && c.Store.ID != nil {
		from = c.Store.ID.ToNonAD()
	} else if s, err := types.ParseJID(sender); err == nil && sender != "" {
		from = s
	}
	info := &types.MessageInfo{ID: id, MessageSource: types.MessageSource{Chat: chat, Sender: from, IsFromMe: fromMe,
		IsGroup: chat.Server == types.GroupServer}}
	ch := make(chan *events.MediaRetry, 1)
	retries.Lock()
	retries.wait[id] = ch
	retries.Unlock()
	defer func() {
		retries.Lock()
		delete(retries.wait, id)
		retries.Unlock()
	}()
	key := file.GetMediaKey()
	if err := c.SendMediaRetryReceipt(ctx, info, key); err != nil {
		return false
	}
	wait, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	select {
	case e := <-ch:
		n, err := whatsmeow.DecryptMediaRetryNotification(e, key)
		if err != nil || n.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS || n.GetDirectPath() == "" {
			return false
		}
		path := proto.String(n.GetDirectPath())
		switch f := file.(type) {
		case *waE2E.StickerMessage:
			f.DirectPath = path
		case *waE2E.ImageMessage:
			f.DirectPath = path
		case *waE2E.DocumentMessage:
			f.DirectPath = path
		default:
			return false
		}
		return true
	case <-wait.Done():
		return false
	}
}

// SendVoice sends a voice note (Ogg Opus, as WhatsApp's own) to jid and keeps it (the watch can play it back).
func SendVoice(jid string, ogg []byte, seconds int64) error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	to, err := types.ParseJID(jid)
	if err != nil {
		return err
	}
	ctx, cancel := timeout(90 * time.Second)
	defer cancel()
	up, err := c.Upload(ctx, ogg, whatsmeow.MediaAudio)
	if err != nil {
		return err
	}
	whole := &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
		URL:           proto.String(up.URL),
		DirectPath:    proto.String(up.DirectPath),
		MediaKey:      up.MediaKey,
		Mimetype:      proto.String("audio/ogg; codecs=opus"),
		FileEncSHA256: up.FileEncSHA256,
		FileSHA256:    up.FileSHA256,
		FileLength:    proto.Uint64(up.FileLength),
		Seconds:       proto.Uint32(uint32(seconds)),
		PTT:           proto.Bool(true),
	}}
	resp, err := c.SendMessage(ctx, to, whole)
	if err != nil {
		return err
	}
	m := msg{jid: jid, id: resp.ID, fromMe: true, kind: kindVoice, text: length(uint32(seconds)), ts: resp.Timestamp,
		group: to.Server == types.GroupServer}
	m.media, _ = proto.Marshal(whole)
	own.add(m, true)
	return nil
}

// whose: the sender of message id in jid, as WhatsApp addresses it (ours: our own JID; theirs in a chat: the
// chat; in a group: its sender).
func whose(c *whatsmeow.Client, chat types.JID, fromMe bool, sender string) types.JID {
	if fromMe && c.Store.ID != nil {
		return c.Store.ID.ToNonAD()
	}
	if s, err := types.ParseJID(sender); err == nil && sender != "" {
		return s
	}
	return chat
}

// React puts emoji on message id of jid (empty: takes ours back) and keeps it.
func React(jid, id, emoji string) error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	chat, err := types.ParseJID(jid)
	if err != nil {
		return err
	}
	_, _, fromMe, sender, ok := own.quoted(jid, id)
	if !ok {
		return errors.New("that message is gone")
	}
	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	if _, err := c.SendMessage(ctx, chat, c.BuildReaction(chat, whose(c, chat, fromMe, sender), id, emoji)); err != nil {
		return err
	}
	own.react(jid, id, emoji)
	return nil
}

// SendReply sends text to jid as a reply to message id (quoted above it, as WhatsApp shows) and keeps it.
func SendReply(jid, text, id string) error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	to, err := types.ParseJID(jid)
	if err != nil {
		return err
	}
	q, kind, fromMe, sender, ok := own.quoted(jid, id)
	if !ok {
		return Send(jid, text)
	}
	if q == "" {
		q = kindName(kind)
	}
	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	m := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text: proto.String(text),
		ContextInfo: &waE2E.ContextInfo{
			StanzaID:      proto.String(id),
			Participant:   proto.String(whose(c, to, fromMe, sender).String()),
			QuotedMessage: &waE2E.Message{Conversation: proto.String(q)},
		},
	}}
	resp, err := c.SendMessage(ctx, to, m)
	if err != nil {
		return err
	}
	own.add(msg{jid: jid, id: resp.ID, fromMe: true, kind: kindText, text: text, ts: resp.Timestamp,
		group: to.Server == types.GroupServer}, true)
	return nil
}

// deleted: what a message deleted for everyone says (WhatsApp's words).
const deleted = "This message was deleted"

// Delete deletes message id of jid: for everyone (WhatsApp's revoke: ours only) or for me (the app state patch WhatsApp
// syncs to the phone and its other devices), and keeps that.
func Delete(jid, id string, everyone bool) error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	chat, err := types.ParseJID(jid)
	if err != nil {
		return err
	}
	_, _, fromMe, sender, ok := own.quoted(jid, id)
	if !ok {
		return errors.New("that message is gone")
	}
	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	if everyone {
		if !fromMe {
			return errors.New("only your own messages")
		}
		if _, err := c.SendMessage(ctx, chat, c.BuildRevoke(chat, types.EmptyJID, id)); err != nil {
			return err
		}
		own.edit(jid, id, deleted)
		return nil
	}
	isMe, who := "0", "0"
	if fromMe {
		isMe = "1"
	} else if chat.Server == types.GroupServer && sender != "" {
		who = sender
	}
	ts := own.sentAt(jid, id)
	patch := appstate.PatchInfo{
		Type: appstate.WAPatchRegularHigh,
		Mutations: []appstate.MutationInfo{{
			Index:   []string{appstate.IndexDeleteMessageForMe, chat.String(), id, isMe, who},
			Version: 3,
			Value: &waSyncAction.SyncActionValue{DeleteMessageForMeAction: &waSyncAction.DeleteMessageForMeAction{
				DeleteMedia: proto.Bool(true), MessageTimestamp: proto.Int64(ts),
			}},
		}},
	}
	if err := c.SendAppState(ctx, patch); err != nil {
		return err
	}
	own.remove(jid, id)
	return nil
}
