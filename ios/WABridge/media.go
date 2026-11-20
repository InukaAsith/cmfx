package wabridge

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
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
		return nil, errors.New("not a sticker or photo")
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
	if err == nil && !isPicture(b) {
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
