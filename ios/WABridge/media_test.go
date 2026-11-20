package wabridge

import (
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestIPhonePhotos(t *testing.T) {
	album := &waE2E.Message{AssociatedChildMessage: &waE2E.FutureProofMessage{
		Message: &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("beach")}}}}
	if k, text, ok := content(album); !ok || k != kindPhoto || text != "beach" {
		t.Fatalf("album photo: %d %q %v", k, text, ok)
	}
	doc := &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{Mimetype: proto.String("image/jpeg")}}
	if k, _, ok := content(doc); !ok || k != kindPhoto {
		t.Fatalf("photo as a file: %d %v", k, ok)
	}
	if _, _, ok := content(&waE2E.Message{AlbumMessage: &waE2E.AlbumMessage{}}); ok {
		t.Fatal("the album itself is not a message")
	}
	pdf := &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{Mimetype: proto.String("application/pdf"), FileName: proto.String("a.pdf")}}
	if k, _, _ := content(pdf); k != kindText {
		t.Fatal("a pdf stays a document")
	}
}

func TestPictureKinds(t *testing.T) {
	webp := append([]byte("RIFF\x00\x00\x00\x00WEBP"), 0)
	if !isPicture(webp) || !isPicture([]byte{0xFF, 0xD8, 0}) || isPicture([]byte("PK\x03\x04lottie")) {
		t.Fatal("isPicture")
	}
	lottie := &waE2E.Message{StickerMessage: &waE2E.StickerMessage{IsLottie: proto.Bool(true), PngThumbnail: []byte("png")}}
	if f, p := mediaOf(lottie); f == nil || string(p) != "png" {
		t.Fatal("a sticker's preview")
	}
	hd := &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{Mimetype: proto.String("image/heic"), JPEGThumbnail: []byte("j")}}
	if f, p := mediaOf(hd); f == nil || string(p) != "j" {
		t.Fatal("a photo sent as a file")
	}
}
