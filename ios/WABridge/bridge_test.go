package wabridge

import (
	"strings"
	"testing"
	"time"
)

func TestOpenAndStore(t *testing.T) {
	if err := Open(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if Linked() || State() != "unlinked" {
		t.Fatal("a fresh store is not linked")
	}
	now := time.Now()
	for i := 0; i < 60; i++ {
		own.add(msg{jid: "1@s.whatsapp.net", id: string(rune('A' + i)), text: "hi", ts: now.Add(time.Duration(i) * time.Second)}, true)
	}
	own.add(msg{jid: "1@s.whatsapp.net", id: string(rune('A' + 59)), text: "dup", ts: now}, true)
	own.add(msg{jid: "2@g.us", id: "x", kind: kindPhoto, who: "Sam", ts: now.Add(-time.Hour), group: true}, false)
	own.setName("2@g.us", "Team")
	c := Chats()
	if !strings.Contains(c, `"unread":60`) || !strings.Contains(c, `"preview":"Sam: Photo"`) || strings.Index(c, `"1@`) > strings.Index(c, `"2@`) {
		t.Fatal(c)
	}
	if m := Messages("1@s.whatsapp.net"); strings.Count(m, "fromMe") != 12 {
		t.Fatal(m)
	}
	var n int
	own.db.QueryRow(`SELECT COUNT(*) FROM msgs WHERE jid = '1@s.whatsapp.net'`).Scan(&n)
	if n != keep {
		t.Fatal(n)
	}
	own.edit("1@s.whatsapp.net", string(rune('A'+59)), "[Deleted]")
	MarkRead("1@s.whatsapp.net")
	if c := Chats(); !strings.Contains(c, `"unread":0,"preview":"[Deleted]"`) {
		t.Fatal(c)
	}
}
