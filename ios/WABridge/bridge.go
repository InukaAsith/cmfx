// Package wabridge makes CMFX a WhatsApp linked device (like WhatsApp Web) with whatsmeow (go.mau.fi/whatsmeow,
// MPL-2.0), for the watch's WhatsApp app. Built for iOS with `gomobile bind`: its API is strings, ints, bools and
// one callback interface. It connects only when CMFX asks (the watch talked) and keeps a small chat store of its
// own, since whatsmeow keeps no history.
package wabridge

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	wastore "go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite" // pure Go: database/sql driver "sqlite"
)

// Listener hears from the bridge, on a Go thread.
type Listener interface {
	// OnMessage: a new message from someone else in jid (live, not from history).
	OnMessage(jid string)
	// OnState: "connected", "synced" (the offline messages are in), "disconnected", "paired", "pair-failed",
	// "logged-out".
	OnState(s string)
	// OnReceipt: our messages in jid were delivered or read.
	OnReceipt(jid string)
	// OnPresence: jid (watched with Watch) came online or went offline.
	OnPresence(jid string, online bool)
}

const (
	maxChats = 12
	maxMsgs  = 12
	// conversations taken from one history sync blob
	historyChats = 40
)

var (
	mu        sync.Mutex
	container *sqlstore.Container
	cli       *whatsmeow.Client
	own       *store
	listener  Listener
	synced    bool
)

var errNotOpen = errors.New("the WhatsApp bridge is not open")
var errNotLinked = errors.New("WhatsApp is not linked")

func timeout(d time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), d)
}

// SetListener: who hears about messages and state (nil for none).
func SetListener(l Listener) {
	mu.Lock()
	listener = l
	mu.Unlock()
}

func state(s string) {
	mu.Lock()
	l := listener
	mu.Unlock()
	if l != nil {
		l.OnState(s)
	}
}

func client() *whatsmeow.Client {
	mu.Lock()
	defer mu.Unlock()
	return cli
}

// Open loads the session and the chat store from dir (the app's Application Support); nothing goes online.
func Open(dir string) error {
	mu.Lock()
	defer mu.Unlock()
	if cli != nil {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	wastore.SetOSInfo("CMFX", [3]uint32{1, 0, 0})
	// a watch shows 12 chats of 12 messages: ask the phone for little history
	h := wastore.DeviceProps.HistorySyncConfig
	h.FullSyncDaysLimit = proto.Uint32(1)
	h.FullSyncSizeMbLimit = proto.Uint32(5)
	h.RecentSyncDaysLimit = proto.Uint32(1)
	h.StorageQuotaMb = proto.Uint32(100)
	h.InitialSyncMaxMessagesPerChat = proto.Uint32(keep)
	h.ThumbnailSyncDaysLimit = proto.Uint32(0)

	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	dsn := "file:" + filepath.Join(dir, "session.db") + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	c, err := sqlstore.New(ctx, "sqlite", dsn, nil)
	if err != nil {
		return err
	}
	dev, err := c.GetFirstDevice(ctx)
	if err != nil {
		c.Close()
		return err
	}
	s, err := openStore(filepath.Join(dir, "chats.db"))
	if err != nil {
		c.Close()
		return err
	}
	container, own = c, s
	cli = newClient(dev)
	return nil
}

func newClient(dev *wastore.Device) *whatsmeow.Client {
	c := whatsmeow.NewClient(dev, nil)
	c.AddEventHandler(func(evt any) { handle(c, evt) })
	return c
}

// Linked: a device is paired.
func Linked() bool {
	c := client()
	return c != nil && c.Store.ID != nil
}

// Me: the linked account, "<number> <push name>" (empty when not linked).
func Me() string {
	c := client()
	if c == nil || c.Store.ID == nil {
		return ""
	}
	return strings.TrimSpace("+" + c.Store.ID.User + " " + c.Store.PushName)
}

// State: "unlinked", "disconnected", "connected" or "synced".
func State() string {
	c := client()
	switch {
	case c == nil || c.Store.ID == nil:
		return "unlinked"
	case !c.IsConnected():
		return "disconnected"
	}
	mu.Lock()
	defer mu.Unlock()
	if synced {
		return "synced"
	}
	return "connected"
}

// Connect goes online (returns once the socket is up; "synced" follows when the offline messages are in).
func Connect() error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	if c.Store.ID == nil {
		return errNotLinked
	}
	if c.IsConnected() {
		return nil
	}
	mu.Lock()
	synced = false
	mu.Unlock()
	return c.Connect()
}

// Disconnect goes offline.
func Disconnect() {
	if c := client(); c != nil {
		c.Disconnect()
	}
}

// PairPhone starts linking by phone number (E.164, "+" and spaces allowed) and returns the 8-character code to
// type in WhatsApp › Linked devices › Link with phone number instead. "paired" or "pair-failed" follows.
func PairPhone(phone string) (string, error) {
	c := client()
	if c == nil {
		return "", errNotOpen
	}
	if c.Store.ID != nil {
		return "", errors.New("already linked: unlink first")
	}
	c.Disconnect()
	// whatsmeow wants the QR channel and its first code before a pairing code (the login socket is up then)
	qr, err := c.GetQRChannel(context.Background())
	if err != nil {
		return "", err
	}
	if err = c.Connect(); err != nil {
		return "", err
	}
	select {
	case evt := <-qr:
		if evt.Event != "code" {
			c.Disconnect()
			if evt.Error != nil {
				return "", evt.Error
			}
			return "", errors.New("pairing: " + evt.Event)
		}
	case <-time.After(30 * time.Second):
		c.Disconnect()
		return "", errors.New("WhatsApp did not answer")
	}
	go func() {
		for evt := range qr {
			switch evt.Event {
			case "code":
			case "success":
				state("paired")
			default:
				state("pair-failed")
			}
		}
	}()
	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	code, err := c.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		c.Disconnect()
		return "", err
	}
	return code, nil
}

// Logout unlinks this device (on WhatsApp too when it can reach it) and forgets the chats.
func Logout() error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	if c.Store.ID != nil {
		ctx, cancel := timeout(20 * time.Second)
		defer cancel()
		if !c.IsConnected() {
			_ = c.Connect()
			for i := 0; i < 50 && !c.IsLoggedIn(); i++ {
				time.Sleep(100 * time.Millisecond)
			}
		}
		if err := c.Logout(ctx); err != nil {
			// offline or refused: forget it here anyway (WhatsApp › Linked devices can remove it there)
			c.Disconnect()
			_ = c.Store.Delete(ctx)
		}
	}
	reset()
	return nil
}

// reset: a fresh unpaired device and an empty chat store.
func reset() {
	mu.Lock()
	defer mu.Unlock()
	if cli != nil {
		cli.Disconnect()
	}
	if own != nil {
		own.clear()
	}
	synced = false
	if container != nil {
		cli = newClient(container.NewDevice())
	}
}

// Chats: the newest 12 chats as JSON, [{jid, name, unread, preview, time}].
func Chats() string {
	c := client()
	mu.Lock()
	s := own
	mu.Unlock()
	if s == nil {
		return "[]"
	}
	rows := s.chats(maxChats)
	for i := range rows {
		if n := displayName(c, rows[i].JID, rows[i].Name); n != "" {
			rows[i].Name = n
		}
	}
	b, _ := json.Marshal(rows)
	return string(b)
}

// Messages: the last 12 of jid as JSON, oldest first, [{fromMe, kind, text, who, time}].
func Messages(jid string) string {
	mu.Lock()
	s := own
	mu.Unlock()
	if s == nil {
		return "[]"
	}
	b, _ := json.Marshal(s.messages(jid, maxMsgs))
	return string(b)
}

// Send sends text to jid and keeps it (the watch shows its own bubble).
func Send(jid, text string) error {
	c := client()
	if c == nil {
		return errNotOpen
	}
	to, err := types.ParseJID(jid)
	if err != nil {
		return err
	}
	ctx, cancel := timeout(30 * time.Second)
	defer cancel()
	resp, err := c.SendMessage(ctx, to, &waE2E.Message{Conversation: proto.String(text)})
	if err != nil {
		return err
	}
	own.add(msg{jid: jid, id: resp.ID, fromMe: true, kind: kindText, text: text, ts: resp.Timestamp,
		group: to.Server == types.GroupServer}, true)
	return nil
}

// MarkRead: read receipts for jid's unread messages, and its unread count to 0.
func MarkRead(jid string) {
	c := client()
	mu.Lock()
	s := own
	mu.Unlock()
	if s == nil {
		return
	}
	chat, err := types.ParseJID(jid)
	if c != nil && err == nil && c.IsConnected() {
		bySender, last := s.unreadIDs(jid)
		ctx, cancel := timeout(15 * time.Second)
		defer cancel()
		for sender, ids := range bySender {
			from := types.EmptyJID
			if sender != "" {
				from, _ = types.ParseJID(sender)
			}
			_ = c.MarkRead(ctx, ids, time.Unix(last, 0), chat, from)
		}
	}
	s.markRead(jid)
}

// MARK: events

func handle(c *whatsmeow.Client, evt any) {
	switch e := evt.(type) {
	case *events.Connected:
		state("connected")
	case *events.OfflineSyncCompleted:
		mu.Lock()
		synced = true
		mu.Unlock()
		state("synced")
	case *events.Disconnected, *events.StreamReplaced:
		mu.Lock()
		synced = false
		mu.Unlock()
		state("disconnected")
	case *events.PairSuccess:
		state("paired")
	case *events.LoggedOut:
		// whatsmeow deletes the session itself
		go func() {
			reset()
			state("logged-out")
		}()
	case *events.Message:
		if m, ok := keepMessage(c, e, true); ok && !m.fromMe {
			mu.Lock()
			l := listener
			mu.Unlock()
			if l != nil {
				l.OnMessage(m.jid)
			}
		}
	case *events.HistorySync:
		history(c, e.Data)
	case *events.Receipt:
		st := 0
		switch e.Type {
		case types.ReceiptTypeDelivered:
			st = 1
		case types.ReceiptTypeRead, types.ReceiptTypePlayed:
			st = 2
		}
		if st == 0 || e.IsFromMe {
			return
		}
		chat := chatOf(c, e.Chat)
		if chat.IsEmpty() || !own.raise(chat.String(), e.MessageIDs, st) {
			return
		}
		if l := current(); l != nil {
			l.OnReceipt(chat.String())
		}
	case *events.MediaRetry:
		retried(e)
	case *events.Presence:
		chat := chatOf(c, e.From)
		if !chat.IsEmpty() && e.Unavailable && !e.LastSeen.IsZero() {
			seenMu.Lock()
			seen[chat.String()] = e.LastSeen.Unix()
			seenMu.Unlock()
		}
		if l := current(); !chat.IsEmpty() && l != nil {
			l.OnPresence(chat.String(), !e.Unavailable)
		}
	}
}

func current() Listener {
	mu.Lock()
	defer mu.Unlock()
	return listener
}

// Watch: CMFX shows as online and asks for jid's online state (WhatsApp tells only those online themselves; while
// online, the phone's own WhatsApp may hold its notifications back, as with WhatsApp Web open). Unwatch ends it.
func Watch(jid string) {
	c := client()
	j, err := types.ParseJID(jid)
	if c == nil || err != nil || j.Server == types.GroupServer || !c.IsConnected() {
		return
	}
	ctx, cancel := timeout(10 * time.Second)
	defer cancel()
	if c.SendPresence(ctx, types.PresenceAvailable) == nil {
		c.SubscribePresence(ctx, j)
	}
}

func Unwatch() {
	c := client()
	if c == nil || !c.IsConnected() {
		return
	}
	ctx, cancel := timeout(10 * time.Second)
	defer cancel()
	c.SendPresence(ctx, types.PresenceUnavailable)
}

// chatOf: the chat's JID as CMFX keys it (a phone number rather than a LID when known), "" for chats not shown
// (status, broadcast lists, channels).
func chatOf(c *whatsmeow.Client, j types.JID) types.JID {
	j = j.ToNonAD()
	switch j.Server {
	case types.DefaultUserServer, types.GroupServer:
		return j
	case types.HiddenUserServer:
		if c.Store.LIDs == nil {
			return j
		}
		ctx, cancel := timeout(5 * time.Second)
		defer cancel()
		if pn, err := c.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
		return j
	}
	return types.EmptyJID
}

func keepMessage(c *whatsmeow.Client, e *events.Message, live bool) (msg, bool) {
	chat := chatOf(c, e.Info.Chat)
	if chat.IsEmpty() || e.Message == nil {
		return msg{}, false
	}
	jid := chat.String()
	if pm := e.Message.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if _, text, ok := content(pm.GetEditedMessage()); ok {
				own.edit(jid, pm.GetKey().GetID(), text)
			}
		case waE2E.ProtocolMessage_REVOKE:
			own.edit(jid, pm.GetKey().GetID(), "[Deleted]")
		}
		return msg{}, false
	}
	if e.IsEdit {
		if _, text, ok := content(e.Message); ok {
			own.edit(jid, e.Info.ID, text)
		}
		return msg{}, false
	}
	kind, text, ok := content(e.Message)
	if !ok {
		return msg{}, false
	}
	m := msg{jid: jid, id: e.Info.ID, fromMe: e.Info.IsFromMe, kind: kind, text: text, ts: e.Info.Timestamp,
		group: chat.Server == types.GroupServer}
	if kind == kindSticker || kind == kindPhoto || kind == kindVoice {
		// kept to download the picture (the voice note) if the watch asks
		m.media, _ = proto.Marshal(e.Message)
	}
	if m.group && !m.fromMe {
		m.sender = e.Info.Sender.ToNonAD().String()
		m.who = shortName(displayName(c, chatOf(c, e.Info.Sender).String(), e.Info.PushName))
	}
	if !own.add(m, live) {
		return msg{}, false
	}
	if own.name(jid) == "" {
		own.setName(jid, nameFor(c, chat, e.Info.PushName, m.fromMe))
	}
	return m, true
}

// nameFor: a new chat's name: the group's subject, else the contact's or push name, else the number.
func nameFor(c *whatsmeow.Client, chat types.JID, push string, fromMe bool) string {
	if chat.Server == types.GroupServer {
		ctx, cancel := timeout(10 * time.Second)
		defer cancel()
		if g, err := c.GetGroupInfo(ctx, chat); err == nil && g.Name != "" {
			return g.Name
		}
		return "Group"
	}
	if n := displayName(c, chat.String(), ""); n != "" {
		return n
	}
	if push != "" && !fromMe {
		return push
	}
	return "+" + chat.User
}

// displayName: the address book's name for a person, else their business or push name, else `fallback`.
func displayName(c *whatsmeow.Client, jid, fallback string) string {
	j, err := types.ParseJID(jid)
	if c == nil || c.Store.Contacts == nil || err != nil || j.Server == types.GroupServer {
		return fallback
	}
	ctx, cancel := timeout(5 * time.Second)
	defer cancel()
	ci, err := c.Store.Contacts.GetContact(ctx, j)
	if err != nil || !ci.Found {
		return fallback
	}
	for _, n := range []string{ci.FullName, ci.FirstName, ci.BusinessName, ci.PushName} {
		if n = strings.TrimSpace(n); n != "" {
			return n
		}
	}
	return fallback
}

// shortName: a sender's first name in a group's bubbles.
func shortName(n string) string {
	if f := strings.Fields(n); len(f) > 0 && !strings.HasPrefix(n, "+") {
		return f[0]
	}
	return n
}

// history keeps the newest conversations of a history sync blob (a few dozen, the last `keep` messages each).
func history(c *whatsmeow.Client, h *waHistorySync.HistorySync) {
	if h == nil {
		return
	}
	convs := h.GetConversations()
	sort.Slice(convs, func(i, j int) bool { return stamp(convs[i]) > stamp(convs[j]) })
	if len(convs) > historyChats {
		convs = convs[:historyChats]
	}
	for _, conv := range convs {
		raw, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		chat := chatOf(c, raw)
		if chat.IsEmpty() {
			continue
		}
		jid := chat.String()
		if n := conv.GetName(); n != "" {
			own.setName(jid, n)
		}
		msgs := conv.GetMessages()
		if len(msgs) > keep {
			msgs = msgs[:keep]
		}
		push := ""
		for _, hm := range msgs {
			e, err := c.ParseWebMessage(raw, hm.GetMessage())
			if err != nil {
				continue
			}
			if !e.Info.IsFromMe && push == "" {
				push = e.Info.PushName
			}
			keepMessage(c, e, false)
			if e.Info.IsFromMe {
				// how far it got, as of the sync
				switch st := hm.GetMessage().GetStatus(); {
				case st >= waWeb.WebMessageInfo_READ:
					own.raise(jid, []string{e.Info.ID}, 2)
				case st == waWeb.WebMessageInfo_DELIVERY_ACK:
					own.raise(jid, []string{e.Info.ID}, 1)
				}
			}
		}
		if own.name(jid) == "" && !stampless(conv) {
			own.setName(jid, nameFor(c, chat, push, false))
		}
		if n := int(conv.GetUnreadCount()); n >= 0 {
			own.historyUnread(jid, n)
		}
	}
}

func stamp(c *waHistorySync.Conversation) uint64 {
	return max(c.GetConversationTimestamp(), c.GetLastMsgTimestamp())
}

func stampless(c *waHistorySync.Conversation) bool { return stamp(c) == 0 && len(c.GetMessages()) == 0 }

// MARK: who the open chat is

var (
	seenMu sync.Mutex
	// when each watched contact was last online (unix seconds), from their presence
	seen = map[string]int64{}
)

// LastSeen: when jid was last online (unix seconds), 0 if WhatsApp hasn't said (it tells only while watched, and
// not for those who hide it).
func LastSeen(jid string) int64 {
	seenMu.Lock()
	defer seenMu.Unlock()
	return seen[jid]
}

// Avatar: jid's profile picture, the small preview WhatsApp keeps (a jpeg of ~96 px), nil without one.
func Avatar(jid string) ([]byte, error) {
	c := client()
	j, err := types.ParseJID(jid)
	if c == nil || err != nil {
		return nil, errNotOpen
	}
	ctx, cancel := timeout(15 * time.Second)
	defer cancel()
	info, err := c.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || info == nil || info.URL == "" {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, info.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New(resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 256<<10))
}

// Contacts: the address book WhatsApp shares with linked devices, as JSON [{jid, name}] sorted by name (saved
// names only: those the phone knows by a name you gave them), for the watch's new-chat picker.
func Contacts() string {
	c := client()
	if c == nil {
		return "[]"
	}
	ctx, cancel := timeout(10 * time.Second)
	defer cancel()
	all, err := c.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		return "[]"
	}
	type contact struct {
		JID  string `json:"jid"`
		Name string `json:"name"`
	}
	out := []contact{}
	for j, info := range all {
		if j.Server != types.DefaultUserServer || info.FullName == "" {
			continue
		}
		out = append(out, contact{j.String(), info.FullName})
	}
	sort.Slice(out, func(a, b int) bool { return strings.ToLower(out[a].Name) < strings.ToLower(out[b].Name) })
	b, _ := json.Marshal(out)
	return string(b)
}
