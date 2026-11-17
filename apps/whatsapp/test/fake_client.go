package main

// A fake WhatsApp, for the test: it takes client.go's place in the link's program, so nothing the test runs
// reaches WhatsApp. Underneath is whatsmeow's own client and store, never connected: the session it keeps,
// parsing messages and contacts are whatsmeow's. What would reach WhatsApp is played here instead, by the
// signals the test sends the program:
//
//   - SIGUSR1 is the phone scanning the QR code: it links as +61 400 000 001, with made-up contacts and chats,
//     which arrive as WhatsApp's history sync does.
//   - SIGUSR2 is a message arriving from Kim.
//
// What it sends is written to its log, which the test reads.

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

const (
	me     = "61400000001"
	kim    = "61400000002"
	lee    = "61400000003"
	family = "120363000000000001@g.us"
)

type fake struct {
	*whatsmeow.Client
	device *store.Device

	mu        sync.Mutex
	handlers  []whatsmeow.EventHandler
	connected bool
	qrs       chan whatsmeow.QRChannelItem
	sent      int
}

func newClient(device *store.Device) whatsApp {
	f := &fake{Client: whatsmeow.NewClient(device, logger{"whatsmeow"}), device: device}
	signals := make(chan os.Signal, 4)
	signal.Notify(signals, syscall.SIGUSR1, syscall.SIGUSR2)
	go func() {
		for s := range signals {
			if s == syscall.SIGUSR1 {
				f.scanned()
			} else {
				f.arrives()
			}
		}
	}()
	return f
}

func (f *fake) dispatch(evt any) {
	f.mu.Lock()
	handlers := append([]whatsmeow.EventHandler(nil), f.handlers...)
	f.mu.Unlock()
	for _, h := range handlers {
		h(evt)
	}
}

func (f *fake) AddEventHandler(h whatsmeow.EventHandler) uint32 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.handlers = append(f.handlers, h)
	return uint32(len(f.handlers))
}

func (f *fake) Connect() error {
	if f.device.ID == nil {
		f.mu.Lock()
		qrs := f.qrs
		f.mu.Unlock()
		if qrs != nil {
			qrs <- whatsmeow.QRChannelItem{Event: whatsmeow.QRChannelEventCode, Code: "2@fake-whatsapp-code-for-the-test"}
		}
		return nil
	}
	f.mu.Lock()
	f.connected = true
	f.mu.Unlock()
	log.Printf("fake WhatsApp: connected as +%s", f.device.ID.User)
	f.dispatch(&events.Connected{})
	return nil
}

func (f *fake) Disconnect() {
	f.mu.Lock()
	f.connected = false
	f.mu.Unlock()
}

func (f *fake) IsConnected() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.connected
}

func (f *fake) IsLoggedIn() bool { return f.IsConnected() && f.device.ID != nil }

func (f *fake) GetQRChannel(ctx context.Context) (<-chan whatsmeow.QRChannelItem, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.qrs = make(chan whatsmeow.QRChannelItem, 4)
	return f.qrs, nil
}

func (f *fake) PairPhone(ctx context.Context, phone string, show bool, client whatsmeow.PairClientType, name string) (string, error) {
	return "FAKE-C0DE", nil
}

// scanned links the phone: the device gets its id and is saved in whatsmeow's store, the phone's contacts arrive,
// and then the chats WhatsApp sends a newly linked device.
func (f *fake) scanned() {
	ctx := context.Background()
	id := types.NewADJID(me, 0, 7)
	f.device.ID = &id
	f.device.PushName = "Sam"
	f.device.Account = &waAdv.ADVSignedDeviceIdentity{
		Details: []byte("fake"), AccountSignature: make([]byte, 64), AccountSignatureKey: make([]byte, 32), DeviceSignature: make([]byte, 64),
	}
	if err := f.device.Save(ctx); err != nil {
		log.Printf("fake WhatsApp: saving the device: %v", err)
	}
	for jid, name := range map[string]string{kim: "Kim Lee", lee: "Lee Park"} {
		if err := f.device.Contacts.PutContactName(ctx, types.NewJID(jid, types.DefaultUserServer), strings.Fields(name)[0], name); err != nil {
			log.Printf("fake WhatsApp: keeping a contact: %v", err)
		}
	}
	f.dispatch(&events.PairSuccess{ID: id, Platform: "fake"})
	f.mu.Lock()
	qrs := f.qrs
	f.qrs = nil
	f.connected = true
	f.mu.Unlock()
	if qrs != nil {
		qrs <- whatsmeow.QRChannelItem{Event: "success"}
		close(qrs)
	}
	log.Printf("fake WhatsApp: the phone scanned the code, linked as +%s", me)
	f.dispatch(&events.Connected{})

	at := time.Now().Add(-2 * time.Hour)
	said := func(chat, from, id, text string, minutes int, fromMe bool) *waHistorySync.HistorySyncMsg {
		key := &waCommon.MessageKey{RemoteJID: proto.String(chat), FromMe: proto.Bool(fromMe), ID: proto.String(id)}
		if strings.HasSuffix(chat, "@g.us") && !fromMe {
			key.Participant = proto.String(from)
		}
		return &waHistorySync.HistorySyncMsg{Message: &waWeb.WebMessageInfo{
			Key:              key,
			MessageTimestamp: proto.Uint64(uint64(at.Add(time.Duration(minutes) * time.Minute).Unix())),
			Message:          &waE2E.Message{Conversation: proto.String(text)},
		}}
	}
	k, l := kim+"@s.whatsapp.net", lee+"@s.whatsapp.net"
	f.dispatch(&events.HistorySync{Data: &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_INITIAL_BOOTSTRAP.Enum(),
		Conversations: []*waHistorySync.Conversation{
			{ID: proto.String(k), UnreadCount: proto.Uint32(1), ConversationTimestamp: proto.Uint64(uint64(at.Add(30 * time.Minute).Unix())), Messages: []*waHistorySync.HistorySyncMsg{
				said(k, k, "K1", "Are we still on for lunch on Friday?", 0, false),
				said(k, "", "K2", "Yes, 12:30 at the usual place", 10, true),
				said(k, k, "K3", "Great, I'll book the table for four", 30, false),
			}},
			{ID: proto.String(family), Name: proto.String("Family"), ConversationTimestamp: proto.Uint64(uint64(at.Add(20 * time.Minute).Unix())), Messages: []*waHistorySync.HistorySyncMsg{
				said(family, l, "F1", "Who's bringing dessert on Sunday?", 5, false),
				said(family, "", "F2", "I'll bring the pavlova", 20, true),
			}},
			{ID: proto.String(l), ConversationTimestamp: proto.Uint64(uint64(at.Add(-24 * time.Hour).Unix())), Messages: []*waHistorySync.HistorySyncMsg{
				said(l, l, "L1", "The lunch booking is confirmed for twelve thirty", -1440, false),
			}},
		},
	}})
}

func (f *fake) arrives() {
	f.dispatch(&events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: types.NewJID(kim, types.DefaultUserServer), Sender: types.NewJID(kim, types.DefaultUserServer)},
			ID:            fmt.Sprintf("K-live-%d", time.Now().UnixNano()),
			PushName:      "Kim",
			Timestamp:     time.Now(),
		},
		Message: &waE2E.Message{Conversation: proto.String("Running ten minutes late, sorry!")},
	})
	log.Printf("fake WhatsApp: a message arrived from Kim")
}

func (f *fake) SendMessage(ctx context.Context, to types.JID, message *waE2E.Message, extra ...whatsmeow.SendRequestExtra) (whatsmeow.SendResponse, error) {
	if !f.IsLoggedIn() {
		return whatsmeow.SendResponse{}, fmt.Errorf("not connected")
	}
	f.mu.Lock()
	f.sent++
	n := f.sent
	f.mu.Unlock()
	log.Printf("fake WhatsApp: sent to %s: %s", to, message.GetConversation())
	return whatsmeow.SendResponse{ID: fmt.Sprintf("SENT%d-%d", time.Now().UnixNano(), n), Timestamp: time.Now()}, nil
}

func (f *fake) IsOnWhatsApp(ctx context.Context, phones []string) ([]types.IsOnWhatsAppResponse, error) {
	var out []types.IsOnWhatsAppResponse
	for _, p := range phones {
		digits := strings.Map(func(r rune) rune {
			if r >= '0' && r <= '9' {
				return r
			}
			return -1
		}, p)
		out = append(out, types.IsOnWhatsAppResponse{Query: p, JID: types.NewJID(digits, types.DefaultUserServer), IsIn: true})
	}
	return out, nil
}

func (f *fake) GetGroupInfo(ctx context.Context, jid types.JID) (*types.GroupInfo, error) {
	return &types.GroupInfo{JID: jid, GroupName: types.GroupName{Name: "Family"}}, nil
}

// Logout unlinks it, as WhatsApp does: the device is deleted from the store.
func (f *fake) Logout(ctx context.Context) error {
	log.Printf("fake WhatsApp: unlinked +%s", f.device.ID.User)
	f.Disconnect()
	return f.device.Delete(ctx)
}
