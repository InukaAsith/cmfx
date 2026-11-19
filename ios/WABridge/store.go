package wabridge

import (
	"database/sql"
	"strings"
	"time"
)

// CMFX's own small chat store: whatsmeow keeps keys and contacts, not history. The chat list (names, unread,
// preview) and the last `keep` messages per chat, filled from live messages, a limited history sync and own sends.

const keep = 50

const schema = `
CREATE TABLE IF NOT EXISTS chats (
	jid     TEXT PRIMARY KEY,
	name    TEXT NOT NULL DEFAULT '',
	unread  INTEGER NOT NULL DEFAULT 0,
	preview TEXT NOT NULL DEFAULT '',
	ts      INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS msgs (
	jid     TEXT NOT NULL,
	id      TEXT NOT NULL,
	from_me INTEGER NOT NULL,
	kind    INTEGER NOT NULL,
	text    TEXT NOT NULL,
	sender  TEXT NOT NULL DEFAULT '',
	who     TEXT NOT NULL DEFAULT '',
	ts      INTEGER NOT NULL,
	unread  INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (jid, id)
);
CREATE INDEX IF NOT EXISTS msgs_ts ON msgs (jid, ts);
`

type store struct{ db *sql.DB }

type msg struct {
	jid, id     string
	fromMe      bool
	kind        int
	text        string
	sender, who string // sender's JID (groups: for the read receipt) and shown name
	ts          time.Time
	unread      bool
	group       bool
}

func openStore(path string) (*store, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &store{db}, nil
}

func preview(m msg) string {
	t := m.text
	if t == "" {
		t = kindName(m.kind)
	}
	switch {
	case m.fromMe:
		return "You: " + t
	case m.group && m.who != "":
		return m.who + ": " + t
	}
	return t
}

// add keeps a message (a repeat of the same id is ignored) and, when it is the chat's newest, its preview.
// live: counts as unread when it is not ours.
func (s *store) add(m msg, live bool) bool {
	unread := live && !m.fromMe
	res, err := s.db.Exec(`INSERT OR IGNORE INTO msgs (jid, id, from_me, kind, text, sender, who, ts, unread)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, m.jid, m.id, m.fromMe, m.kind, m.text, m.sender, m.who, m.ts.Unix(), unread || m.unread)
	if err != nil {
		return false
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false
	}
	ts := m.ts.Unix()
	s.db.Exec(`INSERT INTO chats (jid, preview, ts) VALUES (?, ?, ?) ON CONFLICT (jid) DO UPDATE SET
		preview = CASE WHEN excluded.ts >= chats.ts THEN excluded.preview ELSE chats.preview END,
		ts = MAX(chats.ts, excluded.ts)`, m.jid, preview(m), ts)
	if unread {
		s.db.Exec(`UPDATE chats SET unread = unread + 1 WHERE jid = ?`, m.jid)
	} else if live && m.fromMe {
		// answered from another device: read there
		s.db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, m.jid)
		s.db.Exec(`UPDATE msgs SET unread = 0 WHERE jid = ?`, m.jid)
	}
	s.db.Exec(`DELETE FROM msgs WHERE jid = ? AND id NOT IN
		(SELECT id FROM msgs WHERE jid = ? ORDER BY ts DESC, rowid DESC LIMIT ?)`, m.jid, m.jid, keep)
	return true
}

func (s *store) setName(jid, name string) {
	if name = strings.TrimSpace(name); name == "" {
		return
	}
	s.db.Exec(`INSERT INTO chats (jid, name) VALUES (?, ?) ON CONFLICT (jid) DO UPDATE SET name = excluded.name`, jid, name)
}

func (s *store) name(jid string) string {
	var n string
	s.db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, jid).Scan(&n)
	return n
}

func (s *store) setUnread(jid string, n int) {
	s.db.Exec(`UPDATE chats SET unread = ? WHERE jid = ?`, n, jid)
}

type chatRow struct {
	JID     string `json:"jid"`
	Name    string `json:"name"`
	Unread  int    `json:"unread"`
	Preview string `json:"preview"`
	Time    int64  `json:"time"`
}

func (s *store) chats(n int) []chatRow {
	out := []chatRow{}
	rows, err := s.db.Query(`SELECT jid, name, unread, preview, ts FROM chats WHERE ts > 0 ORDER BY ts DESC LIMIT ?`, n)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var c chatRow
		if rows.Scan(&c.JID, &c.Name, &c.Unread, &c.Preview, &c.Time) == nil {
			out = append(out, c)
		}
	}
	return out
}

type msgRow struct {
	FromMe bool   `json:"fromMe"`
	Kind   int    `json:"kind"`
	Text   string `json:"text"`
	Who    string `json:"who,omitempty"`
	Time   int64  `json:"time"`
}

// messages: the last n, oldest first.
func (s *store) messages(jid string, n int) []msgRow {
	out := []msgRow{}
	rows, err := s.db.Query(`SELECT from_me, kind, text, who, ts FROM
		(SELECT from_me, kind, text, who, ts, rowid r FROM msgs WHERE jid = ? ORDER BY ts DESC, rowid DESC LIMIT ?)
		ORDER BY ts, r`, jid, n)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var m msgRow
		if rows.Scan(&m.FromMe, &m.Kind, &m.Text, &m.Who, &m.Time) == nil {
			out = append(out, m)
		}
	}
	return out
}

// unreadIDs: the unread messages of jid, by sender (groups need one receipt per sender).
func (s *store) unreadIDs(jid string) (map[string][]string, int64) {
	out := map[string][]string{}
	var last int64
	rows, err := s.db.Query(`SELECT id, sender, ts FROM msgs WHERE jid = ? AND unread = 1 AND from_me = 0`, jid)
	if err != nil {
		return out, 0
	}
	defer rows.Close()
	for rows.Next() {
		var id, sender string
		var ts int64
		if rows.Scan(&id, &sender, &ts) == nil {
			out[sender] = append(out[sender], id)
			last = max(last, ts)
		}
	}
	return out, last
}

func (s *store) markRead(jid string) {
	s.db.Exec(`UPDATE msgs SET unread = 0 WHERE jid = ?`, jid)
	s.setUnread(jid, 0)
}

// historyUnread: a history sync's unread count, the newest n messages from others marked unread (for receipts).
func (s *store) historyUnread(jid string, n int) {
	s.setUnread(jid, n)
	if n > 0 {
		s.db.Exec(`UPDATE msgs SET unread = 1 WHERE jid = ? AND id IN
			(SELECT id FROM msgs WHERE jid = ? AND from_me = 0 ORDER BY ts DESC LIMIT ?)`, jid, jid, n)
	}
}

// edit: an edited or deleted message's new text, and the chat's preview when it is the newest.
func (s *store) edit(jid, id, text string) {
	s.db.Exec(`UPDATE msgs SET text = ?, kind = 0 WHERE jid = ? AND id = ?`, text, jid, id)
	var m msg
	var ts int64
	if s.db.QueryRow(`SELECT id, from_me, kind, text, who, ts FROM msgs WHERE jid = ? ORDER BY ts DESC, rowid DESC LIMIT 1`, jid).
		Scan(&m.id, &m.fromMe, &m.kind, &m.text, &m.who, &ts) == nil && m.id == id {
		m.group = strings.HasSuffix(jid, "@g.us")
		s.db.Exec(`UPDATE chats SET preview = ? WHERE jid = ?`, preview(m), jid)
	}
}

func (s *store) clear() {
	s.db.Exec(`DELETE FROM msgs`)
	s.db.Exec(`DELETE FROM chats`)
}
