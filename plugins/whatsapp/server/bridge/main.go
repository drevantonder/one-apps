// The WhatsApp link: one WhatsApp account, linked as WhatsApp Desktop is linked, run by its plugin's service
// (`WhatsApp.Link`), which started this program and speaks to it in lines of JSON.
//
// Its first line in is the session to carry on with, `{"session": "<base64>"}`, empty for a new link. Each line
// after is a command, `{"id": 1, "do": "send", ...}`, answered by a line with the same id and `ok` or `error`.
// Every other line out is an event: `{"event": "messages", ...}`. The session is whatsmeow's own database, which
// is kept in memory only and never written to disk: it goes out as the event `session`, for the service to keep
// encrypted, as soon as the phone links it and then whenever it has changed, at most every five minutes.
//
// It never tells WhatsApp the user is online or has read a message, so the phone keeps notifying and senders see
// no reads. It ends when its input closes.
package main

import (
	"bufio"
	"bytes"
	"cmp"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

// How often the session is looked at, to send it again if it changed.
const keepEvery = 5 * time.Minute

var out = struct {
	sync.Mutex
	*json.Encoder
}{Encoder: json.NewEncoder(os.Stdout)}

func emit(v any) {
	out.Lock()
	defer out.Unlock()
	if err := out.Encode(v); err != nil {
		log.Fatalf("writing out: %v", err)
	}
}

// whatsApp is what of whatsmeow's client the link uses: everything that reaches WhatsApp goes through it. The test
// puts a fake in client.go's place, so nothing it runs reaches WhatsApp.
type whatsApp interface {
	Connect() error
	Disconnect()
	IsConnected() bool
	IsLoggedIn() bool
	Logout(ctx context.Context) error
	AddEventHandler(handler whatsmeow.EventHandler) uint32
	GetQRChannel(ctx context.Context) (<-chan whatsmeow.QRChannelItem, error)
	PairPhone(ctx context.Context, phone string, showPushNotification bool, clientType whatsmeow.PairClientType, clientDisplayName string) (string, error)
	SendMessage(ctx context.Context, to types.JID, message *waE2E.Message, extra ...whatsmeow.SendRequestExtra) (whatsmeow.SendResponse, error)
	IsOnWhatsApp(ctx context.Context, phones []string) ([]types.IsOnWhatsAppResponse, error)
	GetGroupInfo(ctx context.Context, jid types.JID) (*types.GroupInfo, error)
	ParseWebMessage(chatJID types.JID, webMsg *waWeb.WebMessageInfo) (*events.Message, error)
}

type link struct {
	db     *sql.DB
	device *store.Device
	client whatsApp

	mu     sync.Mutex
	kept   [32]byte          // the hash of the session sent last
	groups map[string]string // groups' names, as they're learnt
}

type command struct {
	ID    int64  `json:"id"`
	Do    string `json:"do"`
	Phone string `json:"phone"`
	To    string `json:"to"`
	Text  string `json:"text"`
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("whatsapp link: ")
	store.SetOSInfo("The One App", [3]uint32{0, 3, 0})
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 256<<20)
	if !in.Scan() {
		return
	}
	var first struct{ Session string }
	if err := json.Unmarshal(in.Bytes(), &first); err != nil {
		log.Fatalf("its first line isn't a session: %v", err)
	}
	l, err := open(first.Session)
	if err != nil {
		log.Fatalf("opening the session: %v", err)
	}
	if l.device.ID != nil {
		l.kept = l.hash()
		if err := l.client.Connect(); err != nil {
			log.Printf("connecting: %v", err)
		}
	}
	go l.keeping()
	for in.Scan() {
		var c command
		if err := json.Unmarshal(in.Bytes(), &c); err != nil {
			log.Printf("a command that isn't one: %v", err)
			continue
		}
		go func() {
			ok, err := l.do(c)
			if err != nil {
				emit(map[string]any{"id": c.ID, "error": err.Error()})
			} else {
				emit(map[string]any{"id": c.ID, "ok": ok})
			}
		}()
	}
	l.client.Disconnect()
}

func open(session string) (*link, error) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", "file::memory:?_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	// One connection, which holds the whole database in memory for as long as the program runs.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)
	if session != "" {
		raw, err := unpack(session)
		if err != nil {
			return nil, fmt.Errorf("the session doesn't unpack: %w", err)
		}
		if err := onConnection(db, func(c serializer) error { return c.Deserialize(raw) }); err != nil {
			return nil, err
		}
	}
	container := sqlstore.NewWithDB(db, "sqlite", logger{"store"})
	if err := container.Upgrade(ctx); err != nil {
		return nil, err
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		return nil, err
	}
	l := &link{db: db, device: device, groups: map[string]string{}}
	l.client = newClient(device)
	l.client.AddEventHandler(l.handle)
	return l, nil
}

type serializer interface {
	Serialize() ([]byte, error)
	Deserialize([]byte) error
}

// onConnection runs f on the database's one connection, as the driver has it.
func onConnection(db *sql.DB, f func(serializer) error) error {
	c, err := db.Conn(context.Background())
	if err != nil {
		return err
	}
	defer c.Close()
	return c.Raw(func(driver any) error { return f(driver.(serializer)) })
}

// session is the whole database, gzipped.
func (l *link) session() ([]byte, error) {
	var raw []byte
	err := onConnection(l.db, func(c serializer) (err error) {
		raw, err = c.Serialize()
		return err
	})
	if err != nil {
		return nil, err
	}
	var b bytes.Buffer
	z := gzip.NewWriter(&b)
	z.Write(raw)
	z.Close()
	return b.Bytes(), nil
}

func unpack(session string) ([]byte, error) {
	z, err := gzip.NewReader(base64.NewDecoder(base64.StdEncoding, strings.NewReader(session)))
	if err != nil {
		return nil, err
	}
	return io.ReadAll(z)
}

func (l *link) hash() [32]byte {
	s, err := l.session()
	if err != nil {
		return [32]byte{}
	}
	return sha256.Sum256(s)
}

// keep sends the session out if it changed since it was last sent, or always with force.
func (l *link) keep(force bool) (string, error) {
	if l.device.ID == nil {
		return "", errors.New("nothing is linked")
	}
	s, err := l.session()
	if err != nil {
		return "", err
	}
	l.mu.Lock()
	changed := sha256.Sum256(s) != l.kept
	l.kept = sha256.Sum256(s)
	l.mu.Unlock()
	data := base64.StdEncoding.EncodeToString(s)
	if changed || force {
		emit(map[string]any{"event": "session", "data": data})
	}
	return data, nil
}

func (l *link) keeping() {
	for range time.Tick(keepEvery) {
		if l.device.ID != nil {
			if _, err := l.keep(false); err != nil {
				log.Printf("keeping the session: %v", err)
			}
		}
	}
}

func (l *link) do(c command) (any, error) {
	ctx := context.Background()
	switch c.Do {
	case "pair":
		return l.pair(ctx, c.Phone)
	case "send":
		return l.send(ctx, c.To, c.Text)
	case "state":
		account := ""
		if l.device.ID != nil {
			account = l.device.ID.User
		}
		return map[string]any{"account": account, "connected": l.client.IsConnected() && l.client.IsLoggedIn()}, nil
	case "session":
		return l.keep(true)
	case "logout":
		if l.device.ID == nil {
			return nil, errors.New("nothing is linked")
		}
		return "unlinked", l.client.Logout(ctx)
	}
	return nil, fmt.Errorf("no command %q", c.Do)
}

// pair starts linking a phone: the QR code to scan on it, and given a phone number, the code to type there instead.
// New QR codes go out as events until the phone links or they run out.
func (l *link) pair(ctx context.Context, phone string) (any, error) {
	if l.device.ID != nil {
		return nil, fmt.Errorf("already linked, as +%s", l.device.ID.User)
	}
	qrs, err := l.client.GetQRChannel(ctx)
	if err != nil {
		return nil, err
	}
	if err := l.client.Connect(); err != nil {
		return nil, err
	}
	var first whatsmeow.QRChannelItem
	select {
	case first = <-qrs:
	case <-time.After(20 * time.Second):
		l.client.Disconnect()
		return nil, errors.New("WhatsApp didn't answer")
	}
	if first.Event != whatsmeow.QRChannelEventCode {
		return nil, fmt.Errorf("WhatsApp didn't give a code: %s", first.Event)
	}
	go func() {
		for item := range qrs {
			if item.Event == whatsmeow.QRChannelEventCode {
				emit(qrEvent(item.Code))
			} else if item.Event == whatsmeow.QRChannelTimeout.Event {
				emit(map[string]any{"event": "unpaired", "ran_out": true})
			} else if item.Event != "success" {
				emit(map[string]any{"event": "unpaired", "why": unpaired(item)})
			}
		}
	}()
	answer := qrEvent(first.Code)
	if phone != "" {
		code, err := l.client.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
		if err != nil {
			return nil, err
		}
		answer["code"] = code
	}
	return answer, nil
}

// unpaired is why WhatsApp wouldn't link the phone, as whatsmeow names it.
func unpaired(item whatsmeow.QRChannelItem) string {
	switch item.Event {
	case whatsmeow.QRChannelClientOutdated.Event:
		return "WhatsApp says this link is out of date"
	case whatsmeow.QRChannelScannedWithoutMultidevice.Event:
		return "The phone scanned it without linked devices switched on"
	}
	if item.Error != nil {
		return item.Error.Error()
	}
	return "WhatsApp stopped linking: " + item.Event
}

func qrEvent(code string) map[string]any {
	q, _ := qrcode.New(code, qrcode.Low)
	png, _ := qrcode.Encode(code, qrcode.Medium, 512)
	return map[string]any{"event": "qr", "text": q.ToSmallString(false), "png": "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)}
}

var phone = regexp.MustCompile(`^\+[\d\s().-]{7,}$`)

// send sends a message to a JID, a phone number with its country code, or a contact by their exact name.
func (l *link) send(ctx context.Context, to, text string) (any, error) {
	if l.device.ID == nil {
		return nil, errors.New("nothing is linked")
	}
	jid, err := l.resolve(ctx, strings.TrimSpace(to))
	if err != nil {
		return nil, err
	}
	resp, err := l.client.SendMessage(ctx, jid, &waE2E.Message{Conversation: proto.String(text)})
	if err != nil {
		return nil, err
	}
	sent := stored{Chat: l.key(ctx, jid), ID: resp.ID, Sender: l.device.ID.ToNonAD().String(), FromMe: true, Time: resp.Timestamp.Unix(), Text: text}
	sent.ChatName = l.name(ctx, sent.Chat, "")
	emit(map[string]any{"event": "messages", "messages": []stored{sent}})
	return map[string]any{"chat": sent.Chat, "name": sent.ChatName}, nil
}

func (l *link) resolve(ctx context.Context, to string) (types.JID, error) {
	switch {
	case strings.Contains(to, "@"):
		return types.ParseJID(to)
	case phone.MatchString(to):
		found, err := l.client.IsOnWhatsApp(ctx, []string{to})
		if err != nil {
			return types.JID{}, err
		}
		if len(found) == 0 || !found[0].IsIn {
			return types.JID{}, fmt.Errorf("%s isn't on WhatsApp", to)
		}
		return found[0].JID.ToNonAD(), nil
	}
	known, err := l.device.Contacts.GetAllContacts(ctx)
	if err != nil {
		return types.JID{}, err
	}
	var exact []types.JID
	for jid, c := range known {
		if jid.Server == types.DefaultUserServer && strings.EqualFold(c.FullName, to) {
			exact = append(exact, jid)
		}
	}
	switch len(exact) {
	case 1:
		return exact[0], nil
	case 0:
		return types.JID{}, fmt.Errorf("no chat or contact called %q", to)
	}
	return types.JID{}, fmt.Errorf("several contacts are called %q: give a phone number instead", to)
}

// stored is a message as the plugin keeps it.
type stored struct {
	Chat       string `json:"chat"`
	ChatName   string `json:"chat_name"`
	ID         string `json:"id"`
	Sender     string `json:"sender"`
	SenderName string `json:"sender_name"`
	FromMe     bool   `json:"from_me"`
	Time       int64  `json:"time"`
	Text       string `json:"text"`
}

func (l *link) handle(evt any) {
	ctx := context.Background()
	switch e := evt.(type) {
	case *events.PairSuccess:
		emit(map[string]any{"event": "paired", "account": e.ID.User})
		if _, err := l.keep(true); err != nil {
			log.Printf("keeping the session: %v", err)
		}
	case *events.Connected:
		emit(map[string]any{"event": "connected"})
	case *events.Disconnected:
		emit(map[string]any{"event": "disconnected"})
	case *events.LoggedOut:
		emit(map[string]any{"event": "unlinked", "why": fmt.Sprint(e.Reason)})
	case *events.StreamReplaced:
		emit(map[string]any{"event": "replaced"})
	case *events.Message:
		if m, ok := l.message(ctx, e); ok {
			emit(map[string]any{"event": "messages", "messages": []stored{m}})
		}
	case *events.HistorySync:
		var chats []map[string]any
		var messages []stored
		for _, conv := range e.Data.GetConversations() {
			jid, err := types.ParseJID(conv.GetID())
			if err != nil {
				continue
			}
			key := l.key(ctx, jid)
			if jid.Server == types.GroupServer && conv.GetName() != "" {
				l.mu.Lock()
				l.groups[key] = conv.GetName()
				l.mu.Unlock()
			}
			for _, h := range conv.GetMessages() {
				if msg, err := l.client.ParseWebMessage(jid, h.GetMessage()); err == nil {
					if m, ok := l.message(ctx, msg); ok {
						messages = append(messages, m)
					}
				}
			}
			chats = append(chats, map[string]any{"jid": key, "name": l.name(ctx, key, ""), "unread": conv.GetUnreadCount(), "last": conv.GetConversationTimestamp()})
		}
		emit(map[string]any{"event": "history", "chats": chats, "messages": messages})
	case *events.MarkChatAsRead:
		unread := 0
		if !e.Action.GetRead() {
			unread = 1
		}
		emit(map[string]any{"event": "unread", "jid": l.key(ctx, e.JID), "unread": unread})
	case *events.GroupInfo:
		if e.Name != nil {
			l.named(e.JID.String(), e.Name.Name)
		}
	case *events.JoinedGroup:
		l.named(e.JID.String(), e.GroupName.Name)
	case *events.Contact:
		if n := cmp.Or(e.Action.GetFullName(), e.Action.GetFirstName()); n != "" {
			emit(map[string]any{"event": "name", "jid": l.key(ctx, e.JID), "name": n})
		}
	case *events.PushName:
		emit(map[string]any{"event": "name", "jid": l.key(ctx, e.JID), "name": l.name(ctx, l.key(ctx, e.JID), e.NewPushName)})
	}
}

func (l *link) named(jid, name string) {
	l.mu.Lock()
	l.groups[jid] = name
	l.mu.Unlock()
	emit(map[string]any{"event": "name", "jid": jid, "name": name})
}

// message is how a message is kept, or false for what isn't for people (reactions, key exchanges) and for edits
// and deletions, which go out as events of their own.
func (l *link) message(ctx context.Context, e *events.Message) (stored, bool) {
	chat := l.key(ctx, e.Info.Chat)
	if pm := e.Message.GetProtocolMessage(); pm != nil {
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			emit(map[string]any{"event": "edit", "chat": chat, "id": pm.GetKey().GetID(), "text": "(deleted)"})
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if t := text(pm.GetEditedMessage()); t != "" {
				emit(map[string]any{"event": "edit", "chat": chat, "id": pm.GetKey().GetID(), "text": t})
			}
		}
		return stored{}, false
	}
	t := text(e.Message)
	if t == "" || e.Info.Chat.Server == types.BroadcastServer {
		return stored{}, false
	}
	if e.Info.IsGroup && l.group(chat) == "" {
		go func() {
			if info, err := l.client.GetGroupInfo(ctx, e.Info.Chat); err == nil {
				l.named(chat, info.Name)
			}
		}()
	}
	sender := l.key(ctx, e.Info.Sender)
	return stored{Chat: chat, ChatName: l.name(ctx, chat, ""), ID: e.Info.ID, Sender: sender, SenderName: l.name(ctx, sender, e.Info.PushName),
		FromMe: e.Info.IsFromMe, Time: e.Info.Timestamp.Unix(), Text: t}, true
}

func (l *link) group(jid string) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.groups[jid]
}

// key is how a chat or person is kept: by phone number where WhatsApp gave a private id (a LID) whose number is
// known, so each person is one chat.
func (l *link) key(ctx context.Context, jid types.JID) string {
	jid = jid.ToNonAD()
	if jid.Server == types.HiddenUserServer {
		if pn, err := l.device.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
			jid = pn.ToNonAD()
		}
	}
	return jid.String()
}

// name is what a person or a group is called: a group by its subject, a person as the phone's contacts have them,
// else as they named themselves, else by their number.
func (l *link) name(ctx context.Context, jid, pushName string) string {
	j, err := types.ParseJID(jid)
	if err != nil {
		return jid
	}
	if j.Server == types.GroupServer {
		return l.group(jid)
	}
	if c, err := l.device.Contacts.GetContact(ctx, j); err == nil {
		if n := cmp.Or(c.FullName, c.FirstName, c.BusinessName, c.PushName); n != "" {
			return n
		}
	}
	if pushName != "" {
		return pushName
	}
	if j.Server == types.DefaultUserServer {
		return "+" + j.User
	}
	return j.User
}

// text is how a message reads; empty for ones that aren't for people.
func text(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	with := func(kind, caption string) string {
		if caption = strings.TrimSpace(caption); caption != "" {
			return "(" + kind + ") " + caption
		}
		return "(" + kind + ")"
	}
	switch {
	case m.GetConversation() != "":
		return m.GetConversation()
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetText()
	case m.GetImageMessage() != nil:
		return with("photo", m.GetImageMessage().GetCaption())
	case m.GetVideoMessage() != nil:
		return with("video", m.GetVideoMessage().GetCaption())
	case m.GetAudioMessage() != nil:
		if m.GetAudioMessage().GetPTT() {
			return "(voice message)"
		}
		return "(audio)"
	case m.GetDocumentMessage() != nil:
		return with("document", m.GetDocumentMessage().GetFileName()+" "+m.GetDocumentMessage().GetCaption())
	case m.GetStickerMessage() != nil:
		return "(sticker)"
	case m.GetLocationMessage() != nil:
		return with("location", m.GetLocationMessage().GetName())
	case m.GetLiveLocationMessage() != nil:
		return "(live location)"
	case m.GetContactMessage() != nil:
		return with("contact", m.GetContactMessage().GetDisplayName())
	case m.GetPollCreationMessage() != nil:
		return with("poll", m.GetPollCreationMessage().GetName())
	case m.GetPollCreationMessageV3() != nil:
		return with("poll", m.GetPollCreationMessageV3().GetName())
	}
	return ""
}

type logger struct{ module string }

func (l logger) Errorf(msg string, args ...any) { log.Printf(l.module+": "+msg, args...) }
func (l logger) Warnf(msg string, args ...any)  { log.Printf(l.module+": "+msg, args...) }
func (logger) Infof(string, ...any)             {}
func (logger) Debugf(string, ...any)            {}
func (l logger) Sub(m string) waLog.Logger      { return logger{l.module + "/" + m} }
